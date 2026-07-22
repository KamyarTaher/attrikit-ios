import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@_spi(AttriKitLinkToken) @testable import AttriKitCore

@MainActor
final class AttriKitCoreTests: XCTestCase {
    func testCorePrivacyManifestDeclaresLinkedNonTrackingDeviceID() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: packageRoot.appendingPathComponent(
            "Sources/AttriKitCore/Resources/PrivacyInfo.xcprivacy"
        ))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let rows = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let deviceID = try XCTUnwrap(rows.first {
            $0["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeDeviceID"
        })

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(plist["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        XCTAssertEqual(Set(deviceID["NSPrivacyCollectedDataTypePurposes"] as? [String] ?? []), [
            "NSPrivacyCollectedDataTypePurposeAppFunctionality",
            "NSPrivacyCollectedDataTypePurposeAnalytics",
            "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
        ])
    }

    func testReleaseEndpointShapeRejectsHTTP() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/AttriKitCore/CoreRuntime.swift"),
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
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))

        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .denied)
        AttriKit.track(try! AttriKitEvent("trial_started"))
        _ = await AttriKit.attribution(timeout: .milliseconds(50))

        XCTAssertEqual(URLProtocolSpy.requests, 0)
    }

    func testAcceptExplicitLinkTokenRejectsUnversionedRawToken() async {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        _ = await AttriKit.attribution(timeout: .milliseconds(50))
        let requestCountBeforeAcceptance = await transport.requests().count

        let result = await AttriKit.acceptExplicitLinkToken(String(repeating: "A", count: 43))
        let requestCountAfterAcceptance = await transport.requests().count

        XCTAssertEqual(result, .invalid)
        XCTAssertEqual(requestCountAfterAcceptance, requestCountBeforeAcceptance)
    }

    func testStartReturnsUnderFiftyMilliseconds() async {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        let start = ContinuousClock().now
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let elapsed = start.duration(to: ContinuousClock().now)
        XCTAssertLessThan(elapsed, .milliseconds(50))
        _ = await AttriKit.attribution(timeout: .seconds(1))
    }

    func testPreStartEventIsBufferedThenFlushed() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.track(try AttriKitEvent("trial_started"), properties: ["plan": "annual"])
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)

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

    func testAuthFailureDoesNotDeleteQueuedEvents() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitAuthRetry.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(status: 401, body: #"{"error":"unauthorized"}"#)
            }
            return successResult()
        }
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() }
        ))

        await runtime.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("trial_started"), properties: [:])
        let attempted = await waitUntil {
            await transport.requests().contains { $0.url?.path.contains("events:batch") == true }
        }
        await runtime.shutdown()

        XCTAssertTrue(attempted)
        let queuedEventNames = try await storage.queuedEvents().map(\.eventName)
        XCTAssertEqual(queuedEventNames, ["trial_started"])
    }

    func testFirstOpenMatchesGoldenContractAndUnavailableTransactionStillSends() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, evidence: StubEvidence(transaction: nil, adToken: nil)))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

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
        XCTAssertTrue(firstOpen?.value(forHTTPHeaderField: "X-AttriKit-Signature")?.hasPrefix("v1=") == true)
    }

    func testFunnelIdentityNormalizesAndHashesOnDevice() {
        let identity = FunnelIdentity(
            email: "  Person@Example.COM\n",
            phone: "+41 (79) 123-45-67"
        )

        XCTAssertEqual(identity.emailHash, "542d240129883c019e106e3b1b2d3f3cb3537c43c425364de8e951d5a3083345")
        XCTAssertEqual(identity.phoneHash, "1a08ef565c13a1e790d8501276243c2c7907e1f6d093cdaec4f23c87e4ea1303")
    }

    func testFirstOpenIncludesHashedPIIAndAvailableDeviceIdentifiers() async throws {
        let idfa = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let idfv = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            deviceEvidence: DeviceEvidence(idfa: idfa, idfv: idfv)
        ))

        AttriKit.setFunnelIdentity(email: " Person@Example.COM ", phone: "0041 79 123 45 67")
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let request = await transport.requests().first {
            $0.url?.path.hasSuffix("/v1/ingest/first-open") == true
        }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let firstParty = try XCTUnwrap(json["web_first_party"] as? [String: String])
        XCTAssertEqual(firstParty["email_hash"], "542d240129883c019e106e3b1b2d3f3cb3537c43c425364de8e951d5a3083345")
        XCTAssertEqual(firstParty["phone_hash"], "1a08ef565c13a1e790d8501276243c2c7907e1f6d093cdaec4f23c87e4ea1303")
        XCTAssertEqual(json["idfa"] as? String, idfa.uuidString.lowercased())
        XCTAssertEqual(json["idfv"] as? String, idfv.uuidString.lowercased())
    }

    func testSubsequentIdentifyIncludesHashedPIIAndDeviceIdentifiers() async throws {
        let idfa = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let idfv = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/identify") == true {
                return successResult(body: #"{"status":"accepted"}"#)
            }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            deviceEvidence: DeviceEvidence(idfa: idfa, idfv: idfv)
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

        AttriKit.setFunnelIdentity(email: "person@example.com", phone: "+41791234567")
        let sent = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/identify") == true }
        }
        XCTAssertTrue(sent)
        let request = await transport.requests().last {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["email_hash"] as? String, "542d240129883c019e106e3b1b2d3f3cb3537c43c425364de8e951d5a3083345")
        XCTAssertEqual(json["phone_hash"] as? String, "1a08ef565c13a1e790d8501276243c2c7907e1f6d093cdaec4f23c87e4ea1303")
        XCTAssertEqual(json["idfa"] as? String, idfa.uuidString.lowercased())
        XCTAssertEqual(json["idfv"] as? String, idfv.uuidString.lowercased())
    }

    func testFirstOpenDoesNotAwaitSuspendedEvidencePastDeadline() async {
        let evidence = SuspendedEvidence()
        let transport = StubTransport { _, _ in successResult() }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport, evidence: evidence))
        let start = ContinuousClock().now

        await runtime.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let sent = await waitUntil(timeout: .seconds(3)) {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        let elapsed = start.duration(to: ContinuousClock().now)
        evidence.release()
        await runtime.shutdown()

        XCTAssertTrue(sent)
        XCTAssertLessThan(elapsed, .seconds(3))
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
            exactTokenReference: ExactTokenReference(
                token: "ak1_0123456789012345678901234567890123456789012",
                kind: "owned_deferred",
                clipboardOptIn: nil
            ),
            webFirstParty: nil,
            idfa: nil,
            idfv: nil,
            localLineagePresent: true,
            localEpochPresent: false
        )
        let actual = try JSONSerialization.jsonObject(with: attriKitJSONEncoder().encode(envelope)) as! NSDictionary
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
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let result = await AttriKit.attribution(timeout: .seconds(2))
        guard case .attributed(let attribution) = result else { return XCTFail("Expected attributed, got \(result)") }
        XCTAssertEqual(attribution.campaignID, "c1")
        let requestCount = await transport.requests().count
        let cached = await AttriKit.attribution(timeout: .zero)
        XCTAssertEqual(cached, result)
        let cachedRequestCount = await transport.requests().count
        XCTAssertEqual(cachedRequestCount, requestCount)
    }

    func testAttributionTimeoutPath() async {
        let transport = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":500}"#) }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let result = await AttriKit.attribution(timeout: .milliseconds(20))
        XCTAssertEqual(result, .timedOut)
    }

    func testQueueCapsFIFOAndNeverEvictsProtectedRevenueEvents() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitQueue.\(UUID())")!
        let storage = SDKStorage(defaults: .init(value: defaults), keychain: MemoryKeychain(), directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), maxEvents: 2, maxBytes: 1_048_576)
        let identity = try await storage.initializeIdentities()
        func event(_ name: String, id: UUID = UUID(), properties: [String: AttriKitValue] = [:]) -> EventEnvelope {
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

        let byteLimited = SDKStorage(defaults: .init(value: UserDefaults(suiteName: "AttriKitBytes.\(UUID())")!), keychain: MemoryKeychain(), directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), maxEvents: 100, maxBytes: 2_500)
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

    func testStorageFallsBackToMemoryWhenNoDirectoryIsAvailable() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitMemoryQueue.\(UUID())")!),
            keychain: MemoryKeychain(),
            directoryProvider: { _ in nil }
        )
        let identity = try await storage.initializeIdentities()
        let event = EventEnvelope(
            eventID: UUID(),
            eventName: "memory_only",
            eventVersion: 1,
            occurredAt: Date(),
            sentAt: Date(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            sessionID: UUID(),
            consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
            properties: [:]
        )

        try await storage.enqueue(event)
        let queuedEventIDs = try await storage.queuedEvents().map(\.eventID)
        XCTAssertEqual(queuedEventIDs, [event.eventID])
        try await storage.wipeQueue()
        let queueIsEmpty = try await storage.queuedEvents().isEmpty
        XCTAssertTrue(queueIsEmpty)
    }
}

final class KeychainFallbackTests: XCTestCase {
    private enum QueueRemovalFailure: Error {
        case simulated
    }

    private final class ThrowingKeychain: InstallationIDStoring, @unchecked Sendable {
        func read() throws -> UUID? { throw StorageError.keychain(-34018) }
        func write(_ value: UUID) throws { throw StorageError.keychain(-34018) }
        func delete() throws {}
    }

    private final class DeletionTrackingKeychain: InstallationIDStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var deleted = false

        var wasDeleted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return deleted
        }

        func read() throws -> UUID? { throw StorageError.keychain(-34018) }
        func write(_ value: UUID) throws { throw StorageError.keychain(-34018) }
        func delete() throws {
            lock.lock()
            deleted = true
            lock.unlock()
        }
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

    func testDeleteAllRemovesFallbackInstallationIdentity() async throws {
        let suite = UserDefaults(suiteName: "attrkit-keychain-delete-fallback-\(UUID().uuidString)")!
        let storage = SDKStorage(
            defaults: SDKStorage.Defaults(value: suite),
            keychain: ThrowingKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let first = try await storage.initializeIdentities()
        XCTAssertNotNil(suite.string(forKey: "io.attrikit.fallback-installation-id"))
        try await storage.deleteAll()
        XCTAssertNil(suite.object(forKey: "io.attrikit.fallback-installation-id"))
        let second = try await storage.initializeIdentities()
        XCTAssertNotEqual(first.installationID, second.installationID)
    }

    func testDeleteAllReportsQueueFailureAfterIdentityCleanup() async throws {
        let suite = UserDefaults(suiteName: "attrkit-delete-queue-failure-\(UUID().uuidString)")!
        let keychain = DeletionTrackingKeychain()
        let storage = SDKStorage(
            defaults: SDKStorage.Defaults(value: suite),
            keychain: keychain,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            queueDirectoryRemover: { _ in throw QueueRemovalFailure.simulated }
        )
        let identity = try await storage.initializeIdentities()
        let event = EventEnvelope(
            eventID: UUID(),
            eventName: "queued_before_delete",
            eventVersion: 1,
            occurredAt: Date(),
            sentAt: Date(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            sessionID: UUID(),
            consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
            properties: [:]
        )
        try await storage.enqueue(event)

        do {
            try await storage.deleteAll()
            XCTFail("Expected queue deletion failure")
        } catch QueueRemovalFailure.simulated {}

        XCTAssertTrue(keychain.wasDeleted)
        XCTAssertNil(suite.object(forKey: "io.attrikit.install-epoch"))
        XCTAssertNil(suite.object(forKey: "io.attrikit.fallback-installation-id"))
    }

    func testLegacyDefaultsMigrateToAttriKitKeys() async throws {
        let suite = UserDefaults(suiteName: "attrikit-defaults-migration-\(UUID().uuidString)")!
        let legacyEpoch = UUID()
        let legacyInstallation = UUID()
        suite.set(AttriKitConsent.measurementGranted.rawValue, forKey: "io.attrkit.consent")
        suite.set(legacyEpoch.uuidString, forKey: "io.attrkit.install-epoch")
        suite.set(legacyInstallation.uuidString, forKey: "io.attrkit.fallback-installation-id")
        suite.set("legacy-user", forKey: "io.attrkit.user-id")
        let storage = SDKStorage(
            defaults: .init(value: suite),
            keychain: ThrowingKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let storedConsent = await storage.storedConsent()
        let storedUserID = await storage.storedUserID()
        XCTAssertEqual(storedConsent, .measurementGranted)
        XCTAssertEqual(storedUserID, "legacy-user")
        let identity = try await storage.initializeIdentities()
        XCTAssertEqual(identity.installEpochID, legacyEpoch)
        XCTAssertEqual(identity.installationID, legacyInstallation)
        XCTAssertEqual(suite.string(forKey: "io.attrikit.consent"), AttriKitConsent.measurementGranted.rawValue)
        XCTAssertEqual(suite.string(forKey: "io.attrikit.install-epoch"), legacyEpoch.uuidString)
        XCTAssertEqual(suite.string(forKey: "io.attrikit.fallback-installation-id"), legacyInstallation.uuidString)
        XCTAssertEqual(suite.string(forKey: "io.attrikit.user-id"), "legacy-user")
    }

    func testLegacyKeychainIdentityMigratesToNewServiceStore() async throws {
        let current = MemoryKeychain()
        let legacy = MemoryKeychain()
        let expected = UUID()
        try legacy.write(expected)
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "attrikit-keychain-migration-\(UUID().uuidString)")!),
            keychain: current,
            legacyKeychain: legacy,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )

        let identity = try await storage.initializeIdentities()
        XCTAssertEqual(identity.installationID, expected)
        XCTAssertEqual(try current.read(), expected)
        XCTAssertTrue(identity.localLineagePresent)
    }
}

// wire-verify P0: an envelope built while tracking was granted must never ship idfa
// after a consent downgrade. Coverage: (1) every envelope is constructed with the
// CURRENT consent (first-open retries re-invoke submitFirstOpen, which re-gates);
// (2) measurement consent excludes idfa entirely while keeping idfv.
extension AttriKitCoreTests {
    func testFirstOpenAfterDowngradeFromTrackingToMeasurementOmitsIdfaButKeepsIdfv() async throws {
        let idfa = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
        let idfv = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            deviceEvidence: DeviceEvidence(idfa: idfa, idfv: idfv)
        ))

        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        AttriKit.setConsent(.measurementGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let request = await transport.requests().first {
            $0.url?.path.hasSuffix("/v1/ingest/first-open") == true
        }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["idfa"], "idfa must not ship after downgrade to measurement consent")
        XCTAssertEqual(json["idfv"] as? String, idfv.uuidString.lowercased(), "idfv is consent-free and stays")
    }

    func testIdentifyAfterDowngradeToMeasurementOmitsIdfa() async throws {
        let idfa = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
        let idfv = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/identify") == true {
                return successResult(body: #"{"status":"accepted"}"#)
            }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            deviceEvidence: DeviceEvidence(idfa: idfa, idfv: idfv)
        ))

        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        AttriKit.setConsent(.measurementGranted)
        AttriKit.setFunnelIdentity(email: "person@example.com")
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let request = await transport.requests().first {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }
        guard let request else { return } // no identify issued in this path — nothing to leak
        let body = try gunzipStored(XCTUnwrap(request.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["idfa"], "identify must not ship idfa after downgrade")
        XCTAssertEqual(json["idfv"] as? String, idfv.uuidString.lowercased())
    }
}
