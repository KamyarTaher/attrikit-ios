import Foundation
import XCTest
@testable import AttriKitCore

@MainActor
final class SessionTrackingTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    func testLifecycleNotificationDeliveryIsNonblockingAndBackgroundTaskBounded() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AttriKitCore/SessionLifecycle.swift")
            .standardizedFileURL
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("DispatchSemaphore"))
        XCTAssertFalse(source.contains(".wait()"))
        XCTAssertTrue(source.contains("deliverWithBackgroundTime(.willResignActive"))
        XCTAssertTrue(source.contains("deliverWithBackgroundTime(.willTerminate"))
        XCTAssertTrue(source.contains("beginBackgroundTask(withName:"))
        XCTAssertTrue(source.contains("Task { @MainActor in lease?.end() }"))
        XCTAssertTrue(source.contains("application.endBackgroundTask(identifier)"))
        // The post instant travels with the event. Timestamping at processing time charged the
        // serialized delivery wait to the user's session.
        XCTAssertTrue(source.contains("await handler(event, occurredAt)"))
    }

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

    /// Regression for the cold-launch race from the InkLine field review (2026-07-28): a
    /// foreground notification landing before identity resolves from storage must not lose the
    /// install's first session. Two independent guards pin it.
    ///
    /// The RUNTIME guard — `beginMeasurement` re-firing didBecomeActive once identity arrives —
    /// is covered BEHAVIOURALLY by testActivationDeliveredBeforeStartIsRecoveredWhenMeasurementBegins
    /// below. Deleting that one line from beginMeasurement turns that test red on its own
    /// assertion (measured), so the source grep that used to duplicate it here was removed rather
    /// than kept as a second, weaker copy of a property already proven.
    ///
    /// The OBSERVER guard is what is left, and this is a SPELLING assertion, knowingly: it passes
    /// on a semantic regression that keeps the literal and fails on a harmless rename. It stays
    /// only because the property cannot be driven through the real type today:
    ///  * The synthesis lives inside `#if canImport(UIKit) && os(iOS)`. This package's tests build
    ///    arm64e-apple-macos, where UIKit is not importable, so `ApplicationLifecycleObserver.start`
    ///    compiles down to `_ = handler`. There is no code in this binary to drive.
    ///  * Even on an iOS destination the trigger is the process-global
    ///    `UIApplication.shared.applicationState`, read through a private static helper with no
    ///    injection point. A test bundle with no host app has no UIApplication at all, so the
    ///    synthesis could only ever be observed NOT firing; a hosted one is always `.active`, so
    ///    the negative half of the property is unreachable from the other side.
    ///  * `activationGeneration`, `subscriptionGeneration` and `isCurrentSubscription` are
    ///    private, so `@testable` does not reach the gating directly either.
    ///
    /// What would retire this test: an injectable application-state probe on the observer, in
    /// place of the hard-coded `sharedApplicationIfAvailable()`. With that seam the synthesis,
    /// both generation gates, and the resign-between-capture-and-delivery drop all become
    /// ordinary unit tests. That is a production change made for testability and belongs in its
    /// own decision, not in a test file.
    func testObserverColdLaunchSynthesisIsOnlyPinnedInSource() throws {
        let observerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AttriKitCore/SessionLifecycle.swift")
            .standardizedFileURL
        let observer = try String(contentsOf: observerURL, encoding: .utf8)
        XCTAssertTrue(observer.contains("applicationState == .active"),
                      "observer must synthesize didBecomeActive when subscribing while already active")

        // Scope the gate assertions to the synthesis block STRUCTURALLY rather than by hoping a
        // literal is unique. `isCurrentSubscription(installGen)` appears in every notification
        // observer too, so an earlier version of this test scoped it with an `&&` prefix — which
        // then failed the moment the block was legitimately rewritten into a guard list. Slicing at
        // the delivery call is stable under that kind of edit and still cannot match the other
        // observers.
        guard let synthesisStart = observer.range(of: "Self.deliverInOrder { [weak self] in"),
              let synthesisEnd = observer.range(of: "await handler(.didBecomeActive, observedAt)")
        else {
            return XCTFail("synthesis block not found — this test's anchors are stale, not the code")
        }
        let synthesis = String(observer[synthesisStart.lowerBound..<synthesisEnd.upperBound])

        // The synthesis WITHOUT its gates is the phantom-background-session bug the comment above
        // it describes, so pin the gates too. Deleting either one used to slip through this test.
        XCTAssertTrue(synthesis.contains("currentActivationGeneration() == captured"),
                      "a resign between capture and delivery must drop the synthesized activation")
        XCTAssertTrue(synthesis.contains("isCurrentSubscription(installGen)"),
                      "a replaced or stopped subscription must drop the synthesized activation")
        // Ordering: this delivery used to bypass `deliverInOrder`, so the synthesized activation
        // could invert with a genuine resign — the exact hazard the tail exists to remove, on the
        // path that only runs when a notification was already missed.
        XCTAssertTrue(observer.contains("Self.deliverInOrder { [weak self] in"),
                      "the synthesized activation must be serialized through the same delivery tail")
    }

    func testDidBecomeActiveBeforeIdentityResolutionStillStartsSession() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        // Actor barrier: subscription is live; identity may still be resolving.
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 2.5)
        await lifecycle.send(.willResignActive)

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the install's first session must not be lost on a cold launch")
    }

    /// Behavioural cover for the runtime half of the cold-launch recovery: an activation
    /// delivered BEFORE identity resolves cannot open a session at delivery time, so
    /// `beginMeasurement` must re-fire it once identity exists. The runtime is driven
    /// directly because the facade serialises `start` ahead of every other call, which
    /// makes the pre-start ordering unreachable from a facade-level test.
    func testActivationDeliveredBeforeStartIsRecoveredWhenMeasurementBegins() async throws {
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))

        // The activation lands before `start`: there is no api key and no identity yet, so
        // it can only record that the app is foregrounded.
        await runtime.applicationDidBecomeActive()
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        clock.advance(by: 2.5)
        await runtime.applicationWillResignActive()

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the install's first session must not be lost on a cold launch")
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 2_500)
        XCTAssertEqual((properties["session_index"] as? NSNumber)?.intValue, 1)
        await runtime.shutdown()
    }

    func testDuplicateActiveDeliveriesProduceExactlyOneSession() async throws {
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
        // Synthesized + OS duplicate deliveries of the same activation must not start two
        // sessions, covered here at the facade level.
        //
        // These `async let` sends were once described as expressing the concurrency hazard.
        // They do not: measured against a build with the duplicate-start guard deleted, this
        // test still passed five runs out of five, so the two deliveries never actually
        // overlapped inside the session-index window. The claim was removed rather than the
        // test, which still earns its place as facade-level cover for duplicate delivery.
        // The hazard itself is exercised deterministically, with a mutation control, by
        // testSecondActivationDuringTheSessionIndexWindowStartsNoSecondSession below.
        async let firstDelivery: Void = lifecycle.send(.didBecomeActive)
        async let secondDelivery: Void = lifecycle.send(.didBecomeActive)
        _ = await (firstDelivery, secondDelivery)
        clock.advance(by: 1.0)
        await lifecycle.send(.willResignActive)

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered)
        let events = await sessionEvents(in: transport)
        XCTAssertEqual(events.count, 1, "duplicate activations must yield exactly one session_end")
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual((properties["session_index"] as? NSNumber)?.intValue, 1)
    }

    /// Regression for the deleteData session wedge found in the release-gate review:
    /// a didBecomeActive interleaved with deleteData's network roundtrip used to leave a
    /// stale activeSession behind, blocking fresh sessions and later emitting a bogus
    /// session_end spanning the deletion window. The lifecycle guards now skip delivery
    /// while deletionPending, and deleteData clears session state after the wipe.
    /// Discriminator: the emitted session's duration must not span the deletion.
    func testDeleteDataDoesNotWedgeSessionTracking() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("v1/privacy/delete") == true {
                try? await Task.sleep(for: .milliseconds(300))
                return successResult()
            }
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)

        // Delete while the app is active; the activation arriving mid-roundtrip must not
        // leave a stale session behind.
        let deletionTask = Task { () -> Error? in
            do { try await AttriKit.deleteData(); return nil } catch { return error }
        }
        try? await Task.sleep(for: .milliseconds(80))
        await lifecycle.send(.didBecomeActive)
        let deletionError = await deletionTask.value
        XCTAssertNil(deletionError, "deleteData threw: \(String(describing: deletionError))")
        let deleteRequests = await transport.requests().filter { $0.url?.path.contains("privacy/delete") == true }
        XCTAssertEqual(deleteRequests.count, 1, "the deletion roundtrip must have fired")

        // Any session the interleave wrongly created now spans the deletion: mark it.
        clock.advance(by: 5.0)

        // Sessions must work again after a fresh start, with a sane duration.
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 1.0)
        await lifecycle.send(.willResignActive)

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "session tracking must resume after deleteData")
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        let durationMs = (properties["duration_ms"] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(durationMs, 1_000, "the emitted session must start after the deletion, not span it (stale interleaved session)")
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

    /// Deterministic replacement for the `async let` version of this test.
    ///
    /// The old one raced two activations and asserted one session. It never actually overlapped
    /// them: with the duplicate-start guard deleted it still passed five runs out of five, so it
    /// asserted nothing about the hazard it was named for. This parks the first activation inside
    /// the session-index window and delivers the second while it is demonstrably still there.
    func testSecondActivationDuringTheSessionIndexWindowStartsNoSecondSession() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitDupWindow.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let gate = TestGate()
        await storage.setSessionIndexGate { await gate.enterAndWait() }

        let firstActivation = Task { await runtime.applicationDidBecomeActive() }
        await gate.waitUntilEntered()
        // The first activation is now parked between its guards and the assignment. This is the
        // exact interleaving the duplicate-start guard exists for, and it is no longer luck.
        await runtime.applicationDidBecomeActive()
        await gate.release()
        await firstActivation.value

        clock.advance(by: 1.0)
        await runtime.applicationWillResignActive()

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the activation must still produce its session")
        let events = await sessionEvents(in: transport)
        XCTAssertEqual(events.count, 1, "two activations in one window are one session")
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual((properties["session_index"] as? NSNumber)?.intValue, 1)
        // The real discriminator, read straight off the counter rather than off the emitted
        // event: exactly one index may have been consumed, so the next one handed out is 2.
        // Without the guard the parked activation and the duplicate each take one and this is 3.
        let nextIndex = await storage.nextSessionIndex()
        XCTAssertEqual(nextIndex, 2, "the duplicate activation must not consume a second session index")
        await runtime.shutdown()
    }

    /// The P0 both review seats found independently: `applicationDidBecomeActive` checks every
    /// precondition BEFORE it suspends on the session-index hop, then assigns unconditionally when
    /// it resumes. A `deleteData` completing inside that window used to be resurrected: the
    /// activation installed a session built from pre-wipe state, so session state existed after a
    /// requested deletion AND every later activation was blocked for the process lifetime, because
    /// `applicationWillResignActive` early-returns on the now-nil identity and never clears it.
    func testDeletionInsideTheSessionIndexWindowIsNotResurrected() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitWipeWindow.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let gate = TestGate()
        await storage.setSessionIndexGate { await gate.enterAndWait() }
        let activation = Task { await runtime.applicationDidBecomeActive() }
        await gate.waitUntilEntered()

        // Age the parked activation so a resurrected session is distinguishable from a fresh
        // one: its startedAt was captured before the suspension, five seconds before the wipe.
        clock.advance(by: 5.0)
        // The wipe lands while the activation is parked mid-start. Note deleteData ends with its
        // own resetSessionState, so the damage needs the activation to resume AFTER that, which
        // is exactly what releasing the gate here produces.
        try await runtime.deleteData()
        await gate.release()
        await activation.value

        // The discriminator: the wiped runtime must be usable again. Re-consent, activate, resign.
        // If the parked activation resurrected its pre-wipe session, `activeSession` is non-nil,
        // this activation is refused, and no session_end is ever emitted.
        await runtime.setConsent(.measurementGranted)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.applicationDidBecomeActive()
        clock.advance(by: 1.0)
        await runtime.applicationWillResignActive()

        let recovered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(recovered, "a deletion racing an activation must not wedge session tracking")
        let events = await sessionEvents(in: transport)
        XCTAssertEqual(events.count, 1)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        // The discriminator. The post-wipe session ran for exactly one second. A resurrected
        // session carries the startedAt captured before the suspension, so it reports six and
        // its duration spans the deletion the user asked for.
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 1_000,
                       "the emitted session must not span the deletion window")
        await runtime.shutdown()
    }

    /// The ABA residual an adversarial review found on the first version of the fix.
    ///
    /// `applicationIsActive` is a level, not a history. With an activation parked in the
    /// session-index window, a resign followed by a fresh activation restores that flag to true,
    /// so the parked activation saw an unchanged level and installed a session whose startedAt
    /// predated the background interval. The reported duration then included time the app spent
    /// in the background. A foreground epoch makes the round trip visible.
    func testActivationParkedAcrossABackgroundRoundTripDoesNotSpanIt() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitABA.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let gate = TestGate()
        await storage.setSessionIndexGate { await gate.enterAndWait() }
        let parked = Task { await runtime.applicationDidBecomeActive() }
        await gate.waitUntilEntered()

        // The app leaves the foreground, stays away eight seconds, and comes back. The eight
        // seconds are spent BACKGROUNDED, between the resign and the re-activation, which is the
        // interval a stale session must not absorb. The re-activation is dropped at the in-flight
        // check and recorded as pending, and it restores applicationIsActive to true, which is
        // precisely what made the level check useless.
        await runtime.applicationWillResignActive()
        clock.advance(by: 8.0)
        await runtime.applicationDidBecomeActive()

        // Arm a second gate BEFORE releasing the first. The pending re-activation is fired from
        // the in-flight start's defer, so it lands the moment the parked task unwinds; parking it
        // here is what makes "the re-activation actually ran" observable instead of a sleep.
        let reactivation = TestGate()
        await storage.setSessionIndexGate { await reactivation.enterAndWait() }
        await gate.release()
        await parked.value
        let refired = await waitUntil { await reactivation.hasEntered() }
        XCTAssertTrue(refired, "the activation dropped during the in-flight start must be re-fired")
        await reactivation.release()
        // Wait for index 2, not 1: the parked activation consumed index 1 before it ever
        // suspended, so a >= 1 wait is satisfied before the replay runs and proves nothing about
        // whether the session was installed before the final resign below.
        let installed = await waitUntil { await storage.currentSessionIndexForTesting() >= 2 }
        XCTAssertTrue(installed, "the replayed activation must install its session before the resign")

        clock.advance(by: 2.0)
        await runtime.applicationWillResignActive()

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the live foreground period must still produce a session")
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        // 2000, the post-return foreground period. The stale activation would report 10000,
        // silently billing the eight backgrounded seconds as engagement.
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 2_000,
                       "a session must never span an interval the app spent in the background")
        await runtime.shutdown()
    }

    /// The single pending slot must keep the EARLIEST arrival of a foreground period.
    ///
    /// Reported by an adversarial review of the replay: with last-writer-wins, a second activation
    /// arriving while the start was still parked overwrote the first, so the replay began the
    /// session at the later time and the foreground interval was silently shortened.
    func testPendingActivationKeepsTheEarliestArrivalOfItsForegroundPeriod() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitCoalesce.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let gate = TestGate()
        await storage.setSessionIndexGate { await gate.enterAndWait() }
        let parked = Task { await runtime.applicationDidBecomeActive() }
        await gate.waitUntilEntered()

        await runtime.applicationWillResignActive()
        clock.advance(by: 9.0)
        // The user returns at t9. This is when the foreground period genuinely began.
        await runtime.applicationDidBecomeActive()
        clock.advance(by: 1.0)
        // A duplicate delivery of the SAME activation at t10 must not move the start time.
        await runtime.applicationDidBecomeActive()

        let replay = TestGate()
        await storage.setSessionIndexGate { await replay.enterAndWait() }
        await gate.release()
        await parked.value
        let refired = await waitUntil { await replay.hasEntered() }
        XCTAssertTrue(refired, "the pending activation must still be replayed")
        await replay.release()
        let installed = await waitUntil { await storage.currentSessionIndexForTesting() >= 2 }
        XCTAssertTrue(installed, "the replayed activation must install before the resign")

        clock.advance(by: 11.0)
        await runtime.applicationWillResignActive()

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered)
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        // t9 to t21. Last-writer-wins would start at t10 and report 11000, quietly losing the
        // first second of every foreground period that races a parked start.
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 12_000,
                       "the earliest arrival of the foreground period owns the session start")
        await runtime.shutdown()
    }

    /// Turning measurement off must not wedge session tracking for the process lifetime.
    ///
    /// `.unknown` is the one measurement-off consent that reaches neither the `.denied` nor the
    /// `.revoked` reset, so an open session used to survive it. It could never be closed either,
    /// because applicationWillResignActive requires consent and early-returns without clearing.
    /// Every later activation then failed the `activeSession == nil` check, and the eventual
    /// session_end spanned the whole consent-off interval.
    func testConsentGoingUnknownDoesNotWedgeSessionTracking() async throws {
        let clock = TestDateClock()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.applicationDidBecomeActive()

        clock.advance(by: 5.0)
        await runtime.setConsent(.unknown)
        clock.advance(by: 5.0)
        await runtime.setConsent(.measurementGranted)
        await runtime.applicationDidBecomeActive()
        clock.advance(by: 2.0)
        await runtime.applicationWillResignActive()

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "a session must still be startable after consent returns")
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        // 2000: the foreground period after consent came back. The wedged session reports 12000
        // and bills the ten seconds measurement was switched off.
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 2_000,
                       "the session must not span the interval measurement was off")
        await runtime.shutdown()
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

/// Lets a test park a caller inside a suspension point and hold it there.
///
/// Needed because the session-index hop is a plain actor hop over synchronous work: an
/// `async let` pair only overlaps by luck, and measurement showed it never did.
private actor TestGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    /// Pollable form. `waitUntilEntered` blocks forever if the caller never arrives, which turns a
    /// failing mutation control into a hung test instead of a red one.
    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
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
