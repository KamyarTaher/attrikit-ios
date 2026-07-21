import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttrKitCore

@MainActor
final class AttrKitCoreTests: XCTestCase {
    func testReleaseEndpointShapeRejectsHTTP() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/AttrKitCore/CoreRuntime.swift"),
            encoding: .utf8
        )
        let releaseShape = source.replacingOccurrences(
            of: #"(?s)\s*#if DEBUG.*?#endif"#,
            with: "",
            options: .regularExpression
        )

        XCTAssertFalse(releaseShape.contains(#"url.scheme == "http""#))
        XCTAssertTrue(releaseShape.contains(#"url.scheme == "https""#))
    }

    func testDeniedConsentMakesZeroNetworkRequestsViaURLProtocol() async {
        URLProtocolSpy.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [URLProtocolSpy.self]
        let transport = URLSessionTransport(session: URLSession(configuration: sessionConfiguration))
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport))

        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .denied)
        AttrKit.track(try! AttrKitEvent("trial_started"))
        _ = await AttrKit.attribution(timeout: .milliseconds(50))

        XCTAssertEqual(URLProtocolSpy.requests, 0)
    }

    func testStartReturnsUnderFiftyMilliseconds() async {
        let transport = StubTransport { _, _ in successResult() }
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport))
        let start = ContinuousClock().now
        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let elapsed = start.duration(to: ContinuousClock().now)
        XCTAssertLessThan(elapsed, .milliseconds(50))
        _ = await AttrKit.attribution(timeout: .seconds(1))
    }

    func testPreStartEventIsBufferedThenFlushed() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttrKit.track(try AttrKitEvent("trial_started"), properties: ["plan": "annual"])
        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)

        let flushed = await waitUntil {
            await transport.requests().contains { $0.url?.path.contains("events:batch") == true }
        }
        XCTAssertTrue(flushed)
        let request = await transport.requests().first { $0.url?.path.contains("events:batch") == true }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["event_name"] as? String, "trial_started")
        XCTAssertEqual((events.first?["properties"] as? [String: Any])?["plan"] as? String, "annual")
    }

    func testFirstOpenMatchesGoldenContractAndUnavailableTransactionStillSends() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport, evidence: StubEvidence(transaction: nil, adToken: nil)))
        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        _ = await AttrKit.attribution(timeout: .seconds(1))

        let firstOpen = await transport.requests().first { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        XCTAssertNotNil(firstOpen)
        let body = try gunzipStored(XCTUnwrap(firstOpen?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["app_transaction_jws"])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertNotNil(json["installation_id"] as? String)
        XCTAssertNotNil(json["install_epoch_id"] as? String)
        XCTAssertEqual(Set(json.keys), [
            "schema_version", "installation_id", "install_epoch_id", "occurred_at", "app_version",
            "coarse_context", "consent", "local_lineage_present", "local_epoch_present", "local_signals_conflict"
        ])
        XCTAssertEqual(firstOpen?.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertNotNil(firstOpen?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertTrue(firstOpen?.value(forHTTPHeaderField: "X-AttrKit-Signature")?.hasPrefix("v1=") == true)
    }

    func testDeterministicFirstOpenEnvelopeEqualsGoldenJSON() throws {
        let date = ISO8601DateFormatter().date(from: "2026-07-14T10:00:00Z")!
        let envelope = FirstOpenEnvelope(
            installationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            installEpochID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            occurredAt: date,
            appVersion: "1.2.3 (42)",
            coarseContext: CoarseContext(countryCode: "CH", osMajor: "16.4", deviceClass: "phone", locale: "en-CH"),
            consent: ConsentPayload(state: .measurementGranted, policyVersion: 1),
            appTransactionJWS: "verified-jws-value",
            asaToken: "asa-token-value",
            exactTokenReference: ExactTokenReference(token: "abcdefghijklmnop", kind: "owned_deferred", clipboardOptIn: nil),
            localLineagePresent: true,
            localEpochPresent: false
        )
        let actual = try JSONSerialization.jsonObject(with: attrKitJSONEncoder().encode(envelope)) as! NSDictionary
        let goldenURL = try XCTUnwrap(Bundle.module.url(forResource: "first-open", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: goldenURL)) as! NSDictionary
        XCTAssertEqual(actual, expected)
    }

    func testAttributionSuspendsUntilResolvedThenCaches() async {
        let transport = StubTransport { request, count in
            if request.httpMethod == "GET", count >= 3 {
                return successResult(body: #"{"method":"deterministic","network":"apple_ads","campaign_id":"c1","finality":"provisional","policy_version":1,"version":1}"#, headers: ["etag": "\"v1\""])
            }
            return successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":10}"#)
        }
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let result = await AttrKit.attribution(timeout: .seconds(2))
        guard case .attributed(let attribution) = result else { return XCTFail("Expected attributed, got \(result)") }
        XCTAssertEqual(attribution.campaignID, "c1")
        let requestCount = await transport.requests().count
        let cached = await AttrKit.attribution(timeout: .zero)
        XCTAssertEqual(cached, result)
        let cachedRequestCount = await transport.requests().count
        XCTAssertEqual(cachedRequestCount, requestCount)
    }

    func testAttributionTimeoutPath() async {
        let transport = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":500}"#) }
        await AttrKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttrKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let result = await AttrKit.attribution(timeout: .milliseconds(20))
        XCTAssertEqual(result, .timedOut)
    }

    func testQueueCapsFIFOAndNeverEvictsProtectedRevenueEvents() async throws {
        let defaults = UserDefaults(suiteName: "AttrKitQueue.\(UUID())")!
        let storage = SDKStorage(defaults: .init(value: defaults), keychain: MemoryKeychain(), directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), maxEvents: 2, maxBytes: 1_048_576)
        let identity = try await storage.initializeIdentities()
        func event(_ name: String, id: UUID = UUID(), properties: [String: AttrKitValue] = [:]) -> EventEnvelope {
            EventEnvelope(eventID: id, eventName: name, eventVersion: 1, occurredAt: Date(), sentAt: Date(), installationID: identity.installationID, installEpochID: identity.installEpochID, sessionID: UUID(), consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1), properties: properties)
        }
        let first = event("view")
        let second = event("click")
        let third = event("signup")
        try await storage.enqueue(first)
        try await storage.enqueue(second)
        try await storage.enqueue(third)
        let ordinaryIDs = try await storage.queuedEvents().map(\.eventID)
        XCTAssertEqual(ordinaryIDs, [second.eventID, third.eventID])

        try await storage.wipeQueue()
        let purchase = event("purchase")
        let refund = event("refund")
        try await storage.enqueue(purchase)
        try await storage.enqueue(refund)
        do {
            try await storage.enqueue(event("purchase"))
            XCTFail("Expected protected-event capacity failure")
        } catch StorageError.queueFullForProtectedEvent {}
        let protectedIDs = try await storage.queuedEvents().map(\.eventID)
        XCTAssertEqual(protectedIDs, [purchase.eventID, refund.eventID])

        let byteLimited = SDKStorage(defaults: .init(value: UserDefaults(suiteName: "AttrKitBytes.\(UUID())")!), keychain: MemoryKeychain(), directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), maxEvents: 100, maxBytes: 2_500)
        let byteIdentity = try await byteLimited.initializeIdentities()
        func largeEvent(_ index: Int) -> EventEnvelope {
            EventEnvelope(eventID: UUID(), eventName: "event_\(index)", eventVersion: 1, occurredAt: Date(), sentAt: Date(), installationID: byteIdentity.installationID, installEpochID: byteIdentity.installEpochID, sessionID: UUID(), consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1), properties: ["payload": .string(String(repeating: "x", count: 900))])
        }
        for index in 0..<4 { try await byteLimited.enqueue(largeEvent(index)) }
        let byteCapped = try await byteLimited.queuedEvents()
        XCTAssertLessThan(byteCapped.count, 4)
        XCTAssertEqual(byteCapped.last?.eventName, "event_3")
    }

    func testKeychainIdentityPersistsAcrossSimulatedReinstall() async throws {
        let keychain = MemoryKeychain()
        let firstStorage = SDKStorage(defaults: .init(value: UserDefaults(suiteName: "InstallA.\(UUID())")!), keychain: keychain, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = try await firstStorage.initializeIdentities()
        let secondStorage = SDKStorage(defaults: .init(value: UserDefaults(suiteName: "InstallB.\(UUID())")!), keychain: keychain, directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let second = try await secondStorage.initializeIdentities()
        XCTAssertEqual(first.installationID, second.installationID)
        XCTAssertNotEqual(first.installEpochID, second.installEpochID)
        XCTAssertTrue(second.localLineagePresent)
        XCTAssertFalse(second.localEpochPresent)
    }
}

final class KeychainFallbackTests: XCTestCase {
    private final class ThrowingKeychain: InstallationIDStoring, @unchecked Sendable {
        func read() throws -> UUID? { throw StorageError.keychain(-34018) }
        func write(_ value: UUID) throws { throw StorageError.keychain(-34018) }
        func delete() throws {}
    }

    func testKeychainFailureDegradesToDefaultsIdentityWithoutLineage() async throws {
        let suite = UserDefaults(suiteName: "attrkit-keychain-fallback-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SDKStorage(defaults: SDKStorage.Defaults(value: suite), keychain: ThrowingKeychain(), directory: dir)

        let first = try await storage.initializeIdentities()
        XCTAssertFalse(first.localLineagePresent, "a keychain failure must never claim lineage")

        let second = try await storage.initializeIdentities()
        XCTAssertEqual(first.installationID, second.installationID, "fallback identity must be stable across launches")
    }
}
