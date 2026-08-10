import Foundation
import XCTest
@testable import AttriKitCore

/// Reproduction attempt for the one open item in the InkLine field report (AttriKit iOS 2.1.0):
///
/// SCOPE, stated so the names are not read as more than they are: the per-launch case drives six
/// `configureForTesting` cycles inside ONE process against a SHARED UserDefaults suite and keychain.
/// That models install persistence across launches faithfully, which is the property under test, but
/// it is not six real process launches — a genuine one would need a subprocess harness.
/// "no session_end event was ever emitted across roughly six background/foreground cycles".
///
/// The report's COUNT is the thing under test here, not the existence of a defect. Each test
/// below drives the real `CoreRuntime` through the real `ApplicationLifecycleObserving` seam and
/// counts `session_end` envelopes that reach the transport.
///
/// Test-lane caveat, stated once: `ApplicationLifecycleObserver.start` is inside
/// `#if canImport(UIKit) && os(iOS)` and this package tests as arm64e-apple-macos, so the real
/// observer's body — including its serialized `deliveryTail` and its cold-launch synthesis —
/// is not in this binary. What a `ManualLifecycleObserver` CAN model faithfully is the ORDER in
/// which the runtime observes events, and whether it observes them at all, which is exactly what
/// the two candidate mechanisms differ on.
///
/// DIRECTION — read before editing. Two of these tests assert the BUGGY counts: five of six in the
/// reordered case, and zero of six in the per-launch case. They document a runtime hole that is
/// still OPEN, so they run GREEN today and turn RED the moment someone closes it. That is
/// deliberate, and it is the opposite of every other test in this target.
///
/// The hole: `applicationDidBecomeActive` reads `epoch: foregroundEpoch` at call time, i.e. AFTER a
/// preceding resign already bumped it, so the epoch guard cannot tell that the activation it is
/// handling is stale. On iOS the ordering is instead guaranteed by the observer's serialized
/// delivery tail — which is compiled out of this lane.
///
/// So when a fix lands, do not "repair" these to keep them green: INVERT them. Both cases should
/// then assert six. If you find them failing and you did not touch the runtime, something restored
/// the hole.
@MainActor
final class ReportedSymptomTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)
    private let cycles = 6

    /// Non-vacuity control for everything below: six honest cycles produce six `session_end`.
    /// Without this, a zero-count assertion elsewhere could be measuring a broken harness.
    func testSixInOrderCyclesEmitSixSessionEnds() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = symptomTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)

        for _ in 0..<cycles {
            await lifecycle.send(.didBecomeActive)
            clock.advance(by: 2)
            await lifecycle.send(.willResignActive)
            // Past the 30s resume window, so every cycle is its own session.
            clock.advance(by: 60)
        }

        let expected = cycles
        let delivered = await waitUntil {
            await symptomSessionEnds(in: transport).count == expected
        }
        XCTAssertTrue(delivered, "control failed: the harness cannot observe session_end at all")
    }

    /// The leading hypothesis (commit 91b8501) at its ABSOLUTE WORST: every single cycle's resign
    /// overtakes the activation that physically preceded it, so the runtime observes
    /// resign-then-activation six times running.
    ///
    /// This is the strongest form of the out-of-order defect and it still does not reproduce the
    /// report. It loses exactly ONE session_end — the first — because the late activation strands
    /// a live `activeSession` in the background, and the NEXT cycle's resign finds it and emits.
    /// The reordering is self-healing from the second cycle onward.
    func testEveryCycleReorderedLosesOnlyTheFirstSessionEnd() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = symptomTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)

        for _ in 0..<cycles {
            // Physical order was activation-then-resign. Observed order is the inversion the
            // unstructured per-notification Tasks in 2.1.0 permitted.
            await lifecycle.send(.willResignActive)
            clock.advance(by: 2)
            await lifecycle.send(.didBecomeActive)
            clock.advance(by: 60)
        }

        let expected = cycles - 1
        let delivered = await waitUntil {
            await symptomSessionEnds(in: transport).count == expected
        }
        let count = await symptomSessionEnds(in: transport).count
        XCTAssertTrue(delivered, "expected \(expected) session_end from \(cycles) reordered cycles, saw \(count)")
        XCTAssertNotEqual(count, 0, "out-of-order delivery cannot suppress every cycle")
    }

    /// Same shape as the report's own caveat about a first-session-only defect: inside ONE process,
    /// losing the launch activation costs exactly one session_end, not six.
    func testInsideOneProcessALostLaunchActivationCostsOneSessionEnd() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = symptomTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        // The launch activation is posted before the runtime has subscribed, so it is dropped.
        await lifecycle.send(.didBecomeActive)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)

        clock.advance(by: 2)
        await lifecycle.send(.willResignActive)
        clock.advance(by: 60)
        // Every later cycle observes its own activation and closes normally.
        for _ in 1..<cycles {
            await lifecycle.send(.didBecomeActive)
            clock.advance(by: 2)
            await lifecycle.send(.willResignActive)
            clock.advance(by: 60)
        }

        let expected = cycles - 1
        let delivered = await waitUntil {
            await symptomSessionEnds(in: transport).count == expected
        }
        let count = await symptomSessionEnds(in: transport).count
        XCTAssertTrue(delivered, "expected \(expected) session_end, saw \(count)")
    }

    /// THE REPRODUCTION. Six PROCESS launches of the same install, each of which observes exactly
    /// one foreground transition and observes it too late to matter: the activation is posted
    /// before the runtime subscribes, so `applicationIsActive` is never set, no session ever
    /// opens, and every resign falls out of `applicationWillResignActive` on its
    /// `let activeSession else { return }` guard.
    ///
    /// Zero session_end across six cycles, with no second defect required.
    ///
    /// It also shows why the report's supporting observation proves nothing: a custom event in
    /// each launch carries a DIFFERENT session_id, because `sessionID` is a fresh per-process
    /// UUID that is initialized whether or not a session is ever tracked. "session_id visibly
    /// rotating across launches" is evidence of process restarts, not of session tracking.
    func testSixSimulatedLaunchesThatObserveNoActivationEmitZeroSessionEnds() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitReportedSymptom.\(UUID())")!
        let keychain = MemoryKeychain()
        let clock = TestDateClock()
        var sessionIDs: [String] = []
        var totalSessionEnds = 0

        for launch in 0..<cycles {
            let lifecycle = ManualLifecycleObserver()
            let transport = symptomTransport()
            await AttriKit.configureForTesting(makeTestConfiguration(
                transport: transport,
                keychain: keychain,
                defaults: defaults,
                now: { clock.now() },
                lifecycle: lifecycle
            ))

            // Cold launch: UIKit posts didBecomeActive before the actor's start() has reached
            // `configuration.lifecycle.start(...)`. Nothing is listening yet.
            await lifecycle.send(.didBecomeActive)
            AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
            _ = await AttriKit.attribution(timeout: .zero)

            AttriKit.track(try AttriKitEvent("probe_\(launch)", version: 1))
            clock.advance(by: 5)
            await lifecycle.send(.willResignActive)
            clock.advance(by: 60)

            let probeArrived = await waitUntil {
                await symptomEvents(in: transport).contains { $0.name == "probe_\(launch)" }
            }
            XCTAssertTrue(probeArrived, "launch \(launch): the probe event never reached the transport")

            // The probe arriving does NOT mean a session_end could not still be in flight, and this
            // test's assertion is a ZERO — so sampling here would let a session_end batched a
            // moment later slip past and turn a real failure into a pass. Give it the full window
            // to appear and require that it never does. `waitUntil` returning false is the wanted
            // outcome; a true here is the reproduction breaking, reported on the next assertion.
            _ = await waitUntil {
                await symptomEvents(in: transport).contains { $0.name == "session_end" }
            }

            let events = await symptomEvents(in: transport)
            totalSessionEnds += events.filter { $0.name == "session_end" }.count
            if let probe = events.first(where: { $0.name == "probe_\(launch)" }) {
                sessionIDs.append(probe.sessionID)
            }
        }

        XCTAssertEqual(totalSessionEnds, 0, "reproduction failed: some launch closed a session")
        XCTAssertEqual(sessionIDs.count, cycles)
        XCTAssertEqual(Set(sessionIDs).count, cycles,
                       "session_id must rotate per launch even though zero sessions were tracked")
    }

    private func symptomTransport() -> StubTransport {
        StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
    }
}

private struct SymptomEvent {
    let name: String
    let sessionID: String
}

private func symptomEvents(in transport: StubTransport) async -> [SymptomEvent] {
    var events: [SymptomEvent] = []
    for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
        guard let compressed = request.httpBody,
              let body = try? gunzipStored(compressed),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let batch = json["events"] as? [[String: Any]] else { continue }
        for event in batch {
            guard let name = event["event_name"] as? String,
                  let sessionID = event["session_id"] as? String else { continue }
            events.append(SymptomEvent(name: name, sessionID: sessionID))
        }
    }
    return events
}

private func symptomSessionEnds(in transport: StubTransport) async -> [SymptomEvent] {
    await symptomEvents(in: transport).filter { $0.name == "session_end" }
}
