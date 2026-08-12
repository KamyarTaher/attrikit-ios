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

    func testPreStartUserIDSendsOpaqueRevenueCatJoinAfterFirstOpen() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/identify") == true {
                return successResult(body: #"{"status":"accepted"}"#)
            }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.setUserID("customer-user-42")
        AttriKit.start(
            apiKey: String(repeating: "k", count: 20),
            consent: .measurementGranted
        )
        _ = await AttriKit.attribution(timeout: .seconds(1))

        let sent = await waitUntil {
            await transport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/identify") == true
            }
        }
        XCTAssertTrue(sent)
        let request = await transport.requests().last {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["customer_user_id"] as? String, "customer-user-42")
    }

    /// A relaunch must send the SAME first-open bytes as launch 1. The server hashes the whole
    /// envelope, so rebuilding with `occurredAt: configuration.now()` on every launch made
    /// launch 2 a 409 `idempotency_conflict` (handled as a registration, but needlessly); the
    /// persisted body makes the relaunch the clean `duplicate` it always was. The control is
    /// the clock: it advances one hour between launches, so a rebuild would betray itself in
    /// `occurred_at` even if the byte comparison were fooled.
    func testFirstOpenRelaunchResendsPersistedBodyByteForByte() async throws {
        let suite = UserDefaults(suiteName: "AttriKitTests.\(UUID())")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitTests-\(UUID())")
        let keychain = MemoryKeychain()
        let clock = TestDateClock()
        let transport = StubTransport { _, _ in successResult() }
        let apiKey = String(repeating: "k", count: 20)

        let first = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport, keychain: keychain, defaults: suite, directory: folder,
            now: { clock.now() }
        ))
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let sentFirst = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        await first.shutdown()
        XCTAssertTrue(sentFirst)
        let firstRequests = await transport.requests()
        let body1 = try gunzipStored(XCTUnwrap(
            firstRequests.last { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }?.httpBody
        ))

        clock.advance(by: 3_600)

        // Relaunch: a NEW runtime over the SAME storage. This is the shape the 360 audit's P0
        // regression came from — relaunch producing a conflict instead of a duplicate.
        let second = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport, keychain: keychain, defaults: suite, directory: folder,
            now: { clock.now() }
        ))
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let sentSecond = await waitUntil {
            await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }.count >= 2
        }
        await second.shutdown()
        XCTAssertTrue(sentSecond)
        let allRequests = await transport.requests()
        let body2 = try gunzipStored(XCTUnwrap(
            allRequests.last { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }?.httpBody
        ))

        XCTAssertEqual(body2, body1, "the relaunch rebuilt the envelope instead of resending the persisted body")
        // Non-vacuity: the relaunched body carries launch 1's occurred_at, NOT the advanced
        // clock's — without persistence it would carry the advanced one.
        let json2 = try XCTUnwrap(JSONSerialization.jsonObject(with: body2) as? [String: Any])
        let json1 = try XCTUnwrap(JSONSerialization.jsonObject(with: body1) as? [String: Any])
        XCTAssertEqual(json2["occurred_at"] as? String, json1["occurred_at"] as? String)
    }

    /// A persisted first-open without IDFA is still consent-bound. Replaying its bytes after a
    /// tracking downgrade would report tracking_granted and could replay other tracking evidence.
    func testFirstOpenRelaunchEvictsBodyProducedUnderDifferentConsentWithoutIDFA() async throws {
        let suite = UserDefaults(suiteName: "AttriKitTests.\(UUID())")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitTests-\(UUID())")
        let keychain = MemoryKeychain()
        let firstTransport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 503, body: #"{"error":"offline"}"#)
            }
            return successResult()
        }
        let firstStorage = SDKStorage(
            defaults: .init(value: suite),
            keychain: keychain,
            directory: folder
        )
        let first = CoreRuntime(configuration: makeTestConfiguration(
            transport: firstTransport,
            keychain: keychain,
            defaults: suite,
            directory: folder,
            deviceEvidence: DeviceEvidence(idfa: nil, idfv: nil)
        ))

        await first.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        let firstSent = await waitUntil {
            await firstTransport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/first-open") == true
            }
        }
        XCTAssertTrue(firstSent)
        await first.shutdown()
        try await firstStorage.setRetryState(nil)

        let firstRequests = await firstTransport.requests()
        let firstBody = try gunzipStored(XCTUnwrap(
            firstRequests.last { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }?.httpBody
        ))
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        XCTAssertNil(firstJSON["idfa"], "precondition: the stale body must not rely on the IDFA invalidation rule")

        let secondTransport = StubTransport { _, _ in successResult() }
        let second = CoreRuntime(configuration: makeTestConfiguration(
            transport: secondTransport,
            keychain: keychain,
            defaults: suite,
            directory: folder,
            deviceEvidence: DeviceEvidence(idfa: nil, idfv: nil)
        ))
        await second.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let secondSent = await waitUntil {
            await secondTransport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/first-open") == true
            }
        }
        XCTAssertTrue(secondSent)
        await second.shutdown()

        let secondRequests = await secondTransport.requests()
        let secondBody = try gunzipStored(XCTUnwrap(
            secondRequests.last { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }?.httpBody
        ))
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        let consent = try XCTUnwrap(secondJSON["consent"] as? [String: Any])
        XCTAssertEqual(
            consent["state"] as? String,
            AttriKitConsent.measurementGranted.rawValue,
            "a relaunch replayed the consent state that the user had downgraded"
        )
        XCTAssertNotEqual(secondBody, firstBody, "a consent mismatch must evict the stored bytes")
    }

    /// A consent flip can leave TWO first-open attempts alive: cancellation is cooperative and
    /// submitFirstOpen checks nothing. Measured without the re-read (adversarial review,
    /// 5bd2620): A persists+ sends bodyA (200), B wakes later, persists bodyB over it, and every
    /// relaunch resends bodyB — which the server has never seen — a 409 forever. The re-read
    /// before persist collapses the race into the duplicate it should have been. This test
    /// produces the exact race deterministically and emulates the server (sha256 of the body,
    /// 409 on same idempotency key with a different hash).
    func testFirstOpenConcurrentAttemptsCollapseToTheAcceptedBody() async throws {
        let evidence = GatedEvidence()
        let clock = TestDateClock()
        let server = FirstOpenServer()
        let transport = StubTransport { request, _ in
            guard request.url?.path.hasSuffix("/v1/ingest/first-open") == true,
                  let body = request.httpBody,
                  let key = request.value(forHTTPHeaderField: "Idempotency-Key") else {
                return successResult()
            }
            let decompressed = (try? gunzipStored(body)) ?? body
            return await server.register(idempotencyKey: key, body: decompressed)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport, evidence: evidence, now: { clock.now() }
        ))
        let apiKey = String(repeating: "k", count: 20)

        // Attempt A suspends on its evidence wait.
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let aWaiting = await evidence.waitForCalls(1)
        XCTAssertTrue(aWaiting)

        // A consent flip re-enters beginMeasurement and spawns attempt B, which ALSO finds no
        // persisted body yet and suspends. A is cancelled, but cancellation is cooperative and
        // nothing in submitFirstOpen observes it.
        await runtime.setConsent(.unknown)
        await runtime.setConsent(.measurementGranted)
        let bWaiting = await evidence.waitForCalls(2)
        XCTAssertTrue(bWaiting)

        // A wins: persists its body and sends it. The server has it now.
        evidence.release(1)
        let firstSent = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(firstSent)

        clock.advance(by: 3_600)

        // B wakes an hour later. Without the re-read it builds at the new clock, persists bodyB
        // over bodyA and 409s — and every relaunch would 409 forever. With it, B adopts the
        // body the server accepted and the duplicate succeeds.
        evidence.release(2)
        let secondSent = await waitUntil {
            await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }.count >= 2
        }
        await runtime.shutdown()
        XCTAssertTrue(secondSent)

        let statuses = await server.statuses()
        XCTAssertEqual(statuses, [200, 200],
                       "the superseded attempt corrupted the accepted body instead of adopting it")
        let allRequests = await transport.requests()
        let bodies = allRequests
            .filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
            .compactMap(\.httpBody)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1],
                       "the two attempts sent different bytes for the same epoch — the relaunch would 409 forever")
    }

    /// The persisted body is scoped to its epoch: after a wipe (which rotates the epoch), the
    /// next first-open must be freshly built — replaying the old epoch's body would submit
    /// evidence for an install the server considers deleted.
    func testFirstOpenBodyIsNotReplayedAcrossAnEpochRotation() async throws {
        let suite = UserDefaults(suiteName: "AttriKitTests.\(UUID())")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitTests-\(UUID())")
        let keychain = MemoryKeychain()
        let storage = SDKStorage(defaults: .init(value: suite), keychain: keychain, directory: folder)

        // Simulate a persisted body from a PREVIOUS epoch by hand: the storage layer is the
        // contract being tested here, and a hand-seeded body with the wrong epoch must be
        // discarded on read, never replayed.
        let staleBody = Data(#"{"stale":true}"#.utf8)
        try await storage.setFirstOpenBody(
            staleBody,
            installEpochID: UUID(),
            consent: .measurementGranted
        )
        let replayed = await storage.firstOpenBody(
            installEpochID: UUID(),
            consent: .measurementGranted
        )
        XCTAssertNil(replayed, "a body persisted under a different epoch was returned for replay")
        // And the read EVICTED it, so a later read cannot race into it.
        let reread = await storage.firstOpenBody(
            installEpochID: UUID(),
            consent: .measurementGranted
        )
        XCTAssertNil(reread)
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

    func testPlacementParametersBridgeCarriesOnlyDeterministicCampaignContext() async {
        let transport = StubTransport { _, _ in
            successResult(body: #"{"receipt_id":"r","status":"matched","attribution":{"method":"exact_single_use","source_type":"exact_token","network":"meta","campaign_id":"campaign-1","finality":"final","policy_version":1}}"#)
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)

        let parameters = await AttriKit.placementParameters(timeout: .seconds(1))

        XCTAssertEqual(parameters, [
            "attrkit_method": "exact_single_use",
            "attrkit_network": "meta",
            "attrkit_campaign_id": "campaign-1",
            "attrkit_source_type": "exact_token",
        ])
    }

    func testPlacementParametersRejectEveryNonDeterministicGrade() {
        for method in ["device_matched", "local_signals_only", "modeled_p50", "unattributed"] {
            let attribution = Attribution(
                method: method,
                sourceType: "device_match",
                network: "meta",
                campaignID: "must-not-leak",
                finality: "final",
                policyVersion: 1
            )
            XCTAssertEqual(attribution.placementParameters, [:], "method \(method) leaked user-level context")
        }
    }

    func testPlacementParametersAcceptEveryDeterministicGrade() {
        for method in ["deterministic", "platform_verified", "exact_single_use", "customer_signed"] {
            let attribution = Attribution(
                method: method,
                sourceType: nil,
                network: "meta",
                campaignID: "campaign-1",
                finality: "final",
                policyVersion: 1
            )
            XCTAssertEqual(attribution.placementParameters["attrkit_method"], method)
            XCTAssertEqual(attribution.placementParameters["attrkit_campaign_id"], "campaign-1")
        }
    }

    func testPlacementParametersReturnsEmptyForEveryUnresolvedState() async {
        let transport = StubTransport { _, _ in
            successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":500}"#)
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)

        let parameters = await AttriKit.placementParameters(timeout: .milliseconds(10))
        XCTAssertEqual(parameters, [:])
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

    // The two tests around this one only ever exercise a keychain that ALWAYS throws, which is why
    // the real case survived: keychain works, then fails for one launch, then works. The fallback
    // slot was written only in the failure path, so it was empty the first time it was needed and a
    // brand-new UUID was minted. The launches either side reported one installation_id and the
    // degraded launch reported another, which the server reads as a different install: split
    // attribution, and a first-open that can be counted twice.
    func testAKeychainOutageReusesTheInstallationIdInsteadOfMintingANewOne() async throws {
        let suite = UserDefaults(suiteName: "attrkit-keychain-outage-\(UUID().uuidString)")!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // PRE-SEEDED, which is the case that isolates the fix: an app upgrading from a build whose
        // keychain already held an identity but whose defaults had no fallback slot. A mutation
        // proved this matters - with a fresh keychain the MINT path populates the fallback and the
        // test passes even with the success-path mirror deleted, so it would have been testing
        // nothing about this branch.
        let healthy = MemoryKeychain()
        let seeded = UUID()
        try healthy.write(seeded)

        // Launch 1: healthy, reads the pre-existing identity.
        let first = SDKStorage(defaults: SDKStorage.Defaults(value: suite), keychain: healthy, directory: dir)
        let original = try await first.initializeIdentities()
        // A first-ever launch MINTS the id, so it correctly reports no lineage. Lineage is claimed
        // only when an existing keychain value is found, which is the launch below.
        XCTAssertEqual(original.installationID, seeded, "precondition: the stored identity is read")
        XCTAssertTrue(original.localLineagePresent, "precondition: an existing keychain id is lineage")

        // Launch 2: the keychain throws, as it does before the first unlock after a reboot.
        let outage = SDKStorage(
            defaults: SDKStorage.Defaults(value: suite),
            keychain: ThrowingKeychain(),
            directory: dir
        )
        let degraded = try await outage.initializeIdentities()
        XCTAssertEqual(
            degraded.installationID,
            original.installationID,
            "a keychain outage must not change the installation id the server already knows"
        )
        XCTAssertFalse(
            degraded.localLineagePresent,
            "control: the degraded launch must still report NO lineage, which is what keeps it honest"
        )

        // Launch 3: recovered, and the identity never moved.
        let recovered = SDKStorage(defaults: SDKStorage.Defaults(value: suite), keychain: healthy, directory: dir)
        let afterRecovery = try await recovered.initializeIdentities()
        XCTAssertEqual(afterRecovery.installationID, original.installationID)
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
