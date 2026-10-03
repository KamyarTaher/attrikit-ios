import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// The Apple Ads token funnel: collection, delivery, and the refresh of a token that aged in a
/// first-open the server never received.
@MainActor
final class AppleAdsTokenFunnelTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    private func makeStorage() -> SDKStorage {
        SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AppleAdsTokenFunnelTests.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    private func launch(storage: SDKStorage, transport: StubTransport, evidence: PlatformEvidenceProviding, clock: TestDateClock) -> CoreRuntime {
        CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: evidence,
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
    }

    private func firstOpens(_ transport: StubTransport) async -> [URLRequest] {
        await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
    }

    private func json(_ request: URLRequest?) throws -> [String: Any] {
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// A relaunch replays the persisted body and must not ask AdServices again: the collection
    /// used to start on every launch because an `async let` runs from the moment it is declared.
    func testARelaunchReplayingItsBodyDoesNotCallAdServicesAgain() async throws {
        let storage = makeStorage()
        let clock = TestDateClock()
        let evidence = ScriptedTokenEvidence(["token-launch-1"])
        let transport = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":60000}"#) }

        let first = launch(storage: storage, transport: transport, evidence: evidence, clock: clock)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let sent = await waitUntil { await self.firstOpens(transport).count == 1 }
        XCTAssertTrue(sent)
        await first.shutdown()

        let second = launch(storage: storage, transport: transport, evidence: evidence, clock: clock)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await self.firstOpens(transport).count == 2 }
        XCTAssertTrue(replayed)
        await second.shutdown()
        // Past the 250 ms first rung of the provider's own ladder: a call started now would show.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(evidence.calls, 1, "a relaunch with a persisted body collected a token it never uses")
    }

    /// The collection outcome travels with the first-open as a header today's strict body schema
    /// cannot refuse, so the server can count the funnel by outcome.
    func testTheFirstOpenCarriesTheCollectionOutcome() async throws {
        for (token, outcome) in [("token-1", "collected"), (nil, "unavailable")] {
            let evidence = ScriptedTokenEvidence([token])
            let transport = StubTransport { _, _ in successResult() }
            let runtime = launch(storage: makeStorage(), transport: transport, evidence: evidence, clock: TestDateClock())
            await runtime.start(apiKey: apiKey, consent: .measurementGranted)
            let sent = await waitUntil { await self.firstOpens(transport).count == 1 }
            XCTAssertTrue(sent)
            let header = await firstOpens(transport).first?.value(forHTTPHeaderField: "X-AttriKit-ASA-Token")
            XCTAssertTrue(header?.hasPrefix("outcome=\(outcome);attempts=1;latency_ms=") == true, "header was \(String(describing: header))")
            await runtime.shutdown()
        }
    }

    /// The token expires 24 hours after collection. A first-open that waited that long in the retry
    /// ladder must go out with a fresh token and its ORIGINAL occurred_at.
    func testAnUndeliveredBodyGetsAFreshTokenAndKeepsItsInstallInstant() async throws {
        let storage = makeStorage()
        let clock = TestDateClock()
        let evidence = ScriptedTokenEvidence(["token-stale", "token-fresh"])
        evidence.signals = DeviceSignals(deviceModel: "iPhone15,2", timezone: "Europe/Paris", screen: .init(w: 390, h: 844, scale: 3))
        let failing = StubTransport { _, _ in HTTPResult(statusCode: 503, data: Data(), headers: [:]) }

        let first = launch(storage: storage, transport: failing, evidence: evidence, clock: clock)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let attempted = await waitUntil { await self.firstOpens(failing).count == 1 }
        XCTAssertTrue(attempted)
        let original = try json(await firstOpens(failing).first)
        await first.shutdown()

        clock.advance(by: 23.5 * 3_600)
        // The second launch's provider has nothing to say, so signals in the refreshed body can only
        // have come from the stored one.
        evidence.signals = nil
        let accepting = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":60000}"#) }
        let second = launch(storage: storage, transport: accepting, evidence: evidence, clock: clock)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let delivered = await waitUntil { await self.firstOpens(accepting).count == 1 }
        XCTAssertTrue(delivered)
        let refreshed = try json(await firstOpens(accepting).first)
        await second.shutdown()

        XCTAssertEqual(original["asa_token"] as? String, "token-stale")
        XCTAssertEqual(refreshed["asa_token"] as? String, "token-fresh", "an expired token was sent")
        XCTAssertEqual(refreshed["occurred_at"] as? String, original["occurred_at"] as? String, "the install instant moved")
        XCTAssertEqual(refreshed["installation_id"] as? String, original["installation_id"] as? String)
        let originalSignals = try XCTUnwrap(original["device_signals"] as? [String: Any])
        let refreshedSignals = try XCTUnwrap(refreshed["device_signals"] as? [String: Any], "the token refresh dropped the device signals")
        XCTAssertEqual(refreshedSignals as NSDictionary, originalSignals as NSDictionary)

        let status = await second.appleAdsTokenStatus()
        XCTAssertNotNil(status?.deliveredAt)
        XCTAssertEqual(status?.outcome, "collected")
    }

    /// Once the server acknowledged the body it holds a token that was fresh when it arrived. A
    /// rebuild would only earn an idempotency conflict on every later launch.
    func testAnAcknowledgedBodyIsNeverRebuilt() async throws {
        let storage = makeStorage()
        let clock = TestDateClock()
        let evidence = ScriptedTokenEvidence(["token-original", "token-must-not-appear"])
        let transport = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":60000}"#) }

        let first = launch(storage: storage, transport: transport, evidence: evidence, clock: clock)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let sent = await waitUntil { await self.firstOpens(transport).count == 1 }
        XCTAssertTrue(sent)
        await first.shutdown()

        clock.advance(by: 30 * 3_600)
        let second = launch(storage: storage, transport: transport, evidence: evidence, clock: clock)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await self.firstOpens(transport).count == 2 }
        XCTAssertTrue(replayed)
        await second.shutdown()

        let bodies = await firstOpens(transport).map(\.httpBody)
        XCTAssertEqual(bodies[0], bodies[1], "an acknowledged first-open was rebuilt")
        XCTAssertEqual(evidence.calls, 1)
    }

    /// A collection that missed the first-open bound is tried again on the next attempt of a body
    /// the server has not received, instead of the install losing its Apple Ads rail for good.
    func testATimedOutCollectionIsRetriedOnTheNextUndeliveredAttempt() async throws {
        let storage = makeStorage()
        let clock = TestDateClock()
        let evidence = ScriptedTokenEvidence(["token-late"], hangFirstCall: true)
        let failing = StubTransport { _, _ in HTTPResult(statusCode: 503, data: Data(), headers: [:]) }

        let first = launch(storage: storage, transport: failing, evidence: evidence, clock: clock)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let attempted = await waitUntil(timeout: .seconds(4)) { await self.firstOpens(failing).count == 1 }
        XCTAssertTrue(attempted)
        let withoutToken = try json(await firstOpens(failing).first)
        XCTAssertNil(withoutToken["asa_token"])
        let header = await firstOpens(failing).first?.value(forHTTPHeaderField: "X-AttriKit-ASA-Token")
        XCTAssertTrue(header?.hasPrefix("outcome=timed_out;") == true, "header was \(String(describing: header))")
        await first.shutdown()

        clock.advance(by: 10)
        let accepting = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":60000}"#) }
        let second = launch(storage: storage, transport: accepting, evidence: evidence, clock: clock)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let delivered = await waitUntil { await self.firstOpens(accepting).count == 1 }
        XCTAssertTrue(delivered)
        let withToken = try json(await firstOpens(accepting).first)
        XCTAssertEqual(withToken["asa_token"] as? String, "token-late")
        await second.shutdown()
    }
}

/// Hands out scripted tokens in call order and counts every AdServices call.
private final class ScriptedTokenEvidence: PlatformEvidenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String?]
    private var hangNext: Bool
    private var count = 0

    init(_ tokens: [String?], hangFirstCall: Bool = false) {
        self.tokens = tokens
        self.hangNext = hangFirstCall
    }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// What `deviceSignals()` answers; a test changes it between launches.
    private var reportedSignals: DeviceSignals?
    var signals: DeviceSignals? {
        get { lock.lock(); defer { lock.unlock() }; return reportedSignals }
        set { lock.lock(); reportedSignals = newValue; lock.unlock() }
    }
    func deviceSignals() -> DeviceSignals? { signals }

    func appTransactionJWS() async -> String? { nil }
    func adServicesToken() async -> String? { await adServicesTokenCollection().token }

    func adServicesTokenCollection() async -> AdServicesTokenCollection {
        let (hang, token): (Bool, String?) = {
            lock.lock(); defer { lock.unlock() }
            count += 1
            if hangNext { hangNext = false; return (true, nil) }
            return (false, tokens.isEmpty ? nil : tokens.removeFirst())
        }()
        if hang { try? await Task.sleep(for: .seconds(3)) }
        return AdServicesTokenCollection(token: token, outcome: token == nil ? .unavailable : .collected, attempts: 1)
    }

    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "CH", osMajor: "17.0", deviceClass: "phone", locale: "en-CH")
    }
    func appVersion() -> String { "1.2.3 (42)" }
}
