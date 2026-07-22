import Foundation
import XCTest
@testable import AttriKitCore

@MainActor
final class SessionTrackingTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    func testSessionEndUsesOrdinaryEventProtectionClass() throws {
        XCTAssertFalse(try AttriKitEvent("session_end").isProtectedRevenueEvent)
    }

    func testForegroundAndBackgroundEnqueueSessionEndWithSaneDuration() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 1.234)
        await lifecycle.send(.willResignActive)

        let delivered = await waitUntil {
            await sessionEvents(in: transport).count == 1
        }
        let capturedEvents = await sessionEvents(in: transport)
        let event = try XCTUnwrap(capturedEvents.first)
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])

        XCTAssertTrue(delivered)
        XCTAssertEqual(event["event_name"] as? String, "session_end")
        XCTAssertEqual(event["event_version"] as? Int, 1)
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 1_234)
        XCTAssertEqual((properties["session_index"] as? NSNumber)?.intValue, 1)
    }

    func testThirtySecondGapStartsNextInstallScopedSession() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)

        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 1)
        await lifecycle.send(.willResignActive)
        let deliveredFirst = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(deliveredFirst)

        clock.advance(by: 10)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 0.5)
        await lifecycle.send(.willResignActive)
        let deliveredSecond = await waitForSessionEventCount(2, in: transport)
        XCTAssertTrue(deliveredSecond)

        clock.advance(by: 30.001)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 2)
        await lifecycle.send(.willResignActive)
        let deliveredThird = await waitForSessionEventCount(3, in: transport)
        XCTAssertTrue(deliveredThird)

        let events = await sessionEvents(in: transport)
        let indexes = events.compactMap {
            (($0["properties"] as? [String: Any])?["session_index"] as? NSNumber)?.intValue
        }
        XCTAssertEqual(indexes, [1, 1, 2])
    }

    func testDeniedConsentSuppressesSessionEvents() async {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .denied)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await sessionEvents(in: transport)
        XCTAssertTrue(events.isEmpty)
    }

    func testOptOutBeforeStartSuppressesSessionEvents() async {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            lifecycle: lifecycle
        ))

        AttriKit.setSessionTrackingEnabled(false)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await sessionEvents(in: transport)
        XCTAssertTrue(events.isEmpty)
    }

    func testOptOutStopsAnAlreadyActiveSessionWithoutAnEndEvent() async {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        AttriKit.setSessionTrackingEnabled(false)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.willResignActive)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await sessionEvents(in: transport)
        XCTAssertTrue(events.isEmpty)
    }

    func testSessionIndexPersistsAcrossRuntimeReconfiguration() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitSessions.\(UUID())")!
        let keychain = MemoryKeychain()
        let firstLifecycle = ManualLifecycleObserver()
        let firstTransport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: firstTransport,
            keychain: keychain,
            defaults: defaults,
            lifecycle: firstLifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await firstLifecycle.send(.didBecomeActive)
        await firstLifecycle.send(.willResignActive)
        let firstDelivered = await waitForSessionEventCount(1, in: firstTransport)
        XCTAssertTrue(firstDelivered)

        let secondLifecycle = ManualLifecycleObserver()
        let secondTransport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: secondTransport,
            keychain: keychain,
            defaults: defaults,
            lifecycle: secondLifecycle
        ))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await secondLifecycle.send(.didBecomeActive)
        await secondLifecycle.send(.willResignActive)
        let secondDelivered = await waitForSessionEventCount(1, in: secondTransport)
        XCTAssertTrue(secondDelivered)

        let capturedEvent = await awaitedFirstSessionEvent(in: secondTransport)
        let event = try XCTUnwrap(capturedEvent)
        let properties = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual((properties["session_index"] as? NSNumber)?.intValue, 2)
    }

    func testLifecycleNotificationsBeforeStartProduceNoEvents() async {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            lifecycle: lifecycle
        ))

        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        try? await Task.sleep(for: .milliseconds(50))

        let events = await sessionEvents(in: transport)
        let requests = await transport.requests()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(requests.isEmpty)
    }

    private func sessionTransport() -> StubTransport {
        StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
    }

    private func waitForSessionEventCount(_ count: Int, in transport: StubTransport) async -> Bool {
        await waitUntil {
            await sessionEvents(in: transport).count == count
        }
    }

    private func awaitedFirstSessionEvent(in transport: StubTransport) async -> [String: Any]? {
        await sessionEvents(in: transport).first
    }
}

private func sessionEvents(in transport: StubTransport) async -> [[String: Any]] {
    var events: [[String: Any]] = []
    for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
        guard let compressed = request.httpBody,
              let body = try? gunzipStored(compressed),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let batch = json["events"] as? [[String: Any]] else { continue }
        events.append(contentsOf: batch.filter { $0["event_name"] as? String == "session_end" })
    }
    return events
}
