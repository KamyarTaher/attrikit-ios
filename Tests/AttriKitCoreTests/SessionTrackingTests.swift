import Foundation
import XCTest
@testable import AttriKitCore

@MainActor
final class SessionTrackingTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    func testLifecycleNotificationDeliveryUsesAsyncBoundedBackgroundLeaseStructure() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AttriKitCore/SessionLifecycle.swift")
            .standardizedFileURL
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let observerStart = try XCTUnwrap(swiftBody(
            after: "func start(_ handler:",
            in: source
        ))
        let backgroundDelivery = try XCTUnwrap(swiftBody(
            after: "private static func deliverWithBackgroundTime(",
            in: source
        ))
        let leaseStart = try XCTUnwrap(swiftBody(
            after: "static func start(application:",
            in: source
        ))
        let leaseEnd = try XCTUnwrap(swiftBody(
            after: "func end()",
            in: source
        ))

        XCTAssertFalse(observerStart.contains("DispatchSemaphore"))
        XCTAssertFalse(observerStart.contains(".wait()"))
        XCTAssertTrue(observerStart.contains("deliverWithBackgroundTime(\n                        .willResignActive"))
        XCTAssertTrue(observerStart.contains("deliverWithBackgroundTime(\n                        .willTerminate"))
        XCTAssertTrue(backgroundDelivery.contains("BackgroundTaskLease.start("))
        XCTAssertTrue(backgroundDelivery.contains("deliveryChain.deliver"))
        XCTAssertTrue(backgroundDelivery.contains("defer { backgroundTask.end() }"))
        XCTAssertTrue(leaseStart.contains("beginBackgroundTask(withName:"))
        // UIApplication.h declares the expiration handler `NS_SWIFT_UI_ACTOR`, so it arrives already
        // isolated to the main actor and the system runs it synchronously on the main thread. The
        // task must be ended BEFORE that handler returns. This assertion used to require the
        // opposite -- `Task { @MainActor in lease?.end() }` -- which returns from the handler first
        // and ends the task on a later main-actor turn, the window in which the system terminates
        // the app. The identifier is adopted after the call so an early expiration cannot leak it.
        XCTAssertFalse(leaseStart.contains("Task {"))
        XCTAssertTrue(leaseStart.contains("beginBackgroundTask(withName: name) { [weak lease] in\n                lease?.end()\n            }"))
        XCTAssertTrue(leaseStart.contains("lease.adopt(identifier)"))
        XCTAssertTrue(leaseEnd.contains("guard !ended else { return }"))
        XCTAssertTrue(leaseEnd.contains("application.endBackgroundTask(identifier)"))
        // The post instant travels with the event. Timestamping at processing time charged the
        // serialized delivery wait to the user's session.
        XCTAssertTrue(backgroundDelivery.contains("await handler(event, occurredAt)"))
    }

    func testSessionDecoderReportsEveryMalformedBatchInsteadOfTreatingItAsNoEvents() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let endpoint = URL(string: "https://unit.test/v1/ingest/events:batch")!
        let malformed: [(body: Data?, encoding: String?)] = [
            (nil, "gzip"),
            (Data("not-gzip".utf8), "br"),
            (Data("not-gzip".utf8), "gzip"),
            (storedGzip(Data(#"{"unexpected":[]}"#.utf8)), "gzip"),
        ]
        for sample in malformed {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = sample.body
            if let encoding = sample.encoding {
                request.setValue(encoding, forHTTPHeaderField: "content-encoding")
            }
            _ = try await transport.send(request)
        }

        let diagnosticLog = MalformedDiagnosticLog()
        let events = await sessionEvents(in: transport) { diagnosticLog.append($0) }
        let diagnostics = diagnosticLog.values()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(diagnostics.count, malformed.count)
        XCTAssertTrue(diagnostics.contains { $0.contains("missing body") })
        XCTAssertTrue(diagnostics.contains { $0.contains("unsupported content-encoding") })
        XCTAssertTrue(diagnostics.contains { $0.contains("invalid gzip") })
        XCTAssertTrue(diagnostics.contains { $0.contains("events array") })
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
    /// The observer's application-state probe is injectable so this macOS test drives the same
    /// synthesis path used by UIKit. The source assertions remain as additional pins for the two
    /// generation gates and ordered delivery structure, but they are no longer the only evidence.
    func testObserverColdLaunchSynthesisIsOnlyPinnedInSource() async throws {
        let activeDeliveries = LifecycleEventRecorder()
        let activeObserver = ApplicationLifecycleObserver(applicationIsActive: { true })
        activeObserver.start { event, occurredAt in
            await activeDeliveries.record(event, occurredAt: occurredAt)
        }

        let synthesized = await waitUntil {
            await activeDeliveries.count() == 1
        }
        let activeSnapshot = await activeDeliveries.snapshot()
        XCTAssertTrue(synthesized, "an already-active app must receive a synthesized activation")
        XCTAssertEqual(activeSnapshot.count, 1)
        XCTAssertTrue(activeSnapshot.firstIsDidBecomeActive)
        XCTAssertNotNil(activeSnapshot.firstOccurredAt)
        activeObserver.stop()

        let inactiveDeliveries = LifecycleEventRecorder()
        let inactiveObserver = ApplicationLifecycleObserver(applicationIsActive: { false })
        inactiveObserver.start { event, occurredAt in
            await inactiveDeliveries.record(event, occurredAt: occurredAt)
        }
        try await Task.sleep(for: .milliseconds(50))
        let inactiveCount = await inactiveDeliveries.count()
        XCTAssertEqual(inactiveCount, 0,
                       "an inactive app must not receive a synthesized activation")
        inactiveObserver.stop()

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
        guard let synthesisStart = observer.range(of: "deliveryChain.deliver { [weak self] in"),
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
        // Ordering: this delivery used to bypass the subscription's DeliveryChain, so synthesis
        // could invert with a genuine resign — the exact hazard the tail exists to remove, on the
        // path that only runs when a notification was already missed.
        guard let tailStart = observer.range(of: "private final class DeliveryChain"),
              let tailEnd = observer.range(of: "private static func deliverAsynchronously", range: tailStart.upperBound..<observer.endIndex) else {
            return XCTFail("delivery-tail implementation not found — source anchors are stale")
        }
        let tail = String(observer[tailStart.lowerBound..<tailEnd.lowerBound])
        guard let readPrevious = tail.range(of: "let previous = tail"),
              let replaceTail = tail.range(of: "tail = Task { @MainActor in"),
              let awaitPrevious = tail.range(of: "await previous?.value"),
              let runWork = tail.range(of: "await work()") else {
            return XCTFail("delivery tail must retain and await its predecessor before work")
        }
        XCTAssertLessThan(readPrevious.lowerBound, replaceTail.lowerBound)
        XCTAssertLessThan(replaceTail.lowerBound, awaitPrevious.lowerBound)
        XCTAssertLessThan(awaitPrevious.lowerBound, runWork.lowerBound)
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
        // The roundtrip is held open by a gate rather than by a sleep, because the interleave
        // this test exists for has to happen INSIDE it. `deleteData` sets `deletionPending`
        // before it issues this request, so the responder being entered is proof the window is
        // open; a sleep only raced the unstructured deletion task, and on a loaded runner the
        // activation could land before `deleteData` had run at all -- outside the roundtrip,
        // green, and having exercised none of the deletionPending guards it is named for.
        let deleteGate = TestGate()
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("v1/privacy/delete") == true {
                await deleteGate.enterAndWait()
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
        let roundtripOpen = await deleteGate.waitUntilEntered()
        XCTAssertTrue(roundtripOpen, "deleteData must have issued its request before the activation")
        await lifecycle.send(.didBecomeActive)
        await deleteGate.release()
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

    func testDeniedConsentSuppressesSessionEvents() async throws {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let store = SuppressionStore()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            defaults: store.defaults,
            directory: store.directory,
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .denied)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)

        let queued = try await store.queuedSessionEndCount()
        XCTAssertEqual(queued, 0, "a denied consent must not even QUEUE a session")
        let events = await sessionEvents(in: transport)
        XCTAssertTrue(events.isEmpty)

        // The live control. This emptiness has no mutant that can break it -- a denied consent
        // never runs beginMeasurement, so `identity` stays nil and every session path refuses on
        // that alone -- which is exactly why the assertion above needs the fixture shown to
        // SPEAK. Granting consent on the same lifecycle, transport and queue must record one.
        AttriKit.setConsent(.measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the same fixture must record a session once consent allows it")
    }

    func testOptOutBeforeStartSuppressesSessionEvents() async throws {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let store = SuppressionStore()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            defaults: store.defaults,
            directory: store.directory,
            lifecycle: lifecycle
        ))

        AttriKit.setSessionTrackingEnabled(false)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)

        let queued = try await store.queuedSessionEndCount()
        XCTAssertEqual(queued, 0, "an opt-out before start must not even QUEUE a session")
        let events = await sessionEvents(in: transport)
        XCTAssertTrue(events.isEmpty)
    }

    func testOptOutStopsAnAlreadyActiveSessionWithoutAnEndEvent() async throws {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let store = SuppressionStore()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            defaults: store.defaults,
            directory: store.directory,
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        AttriKit.setSessionTrackingEnabled(false)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.willResignActive)

        let queued = try await store.queuedSessionEndCount()
        XCTAssertEqual(queued, 0, "an opt-out mid-session must not even QUEUE its session_end")
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

    func testLifecycleNotificationsBeforeStartProduceNoEvents() async throws {
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let store = SuppressionStore()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            defaults: store.defaults,
            directory: store.directory,
            lifecycle: lifecycle
        ))

        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)

        let queued = try await store.queuedSessionEndCount()
        XCTAssertEqual(queued, 0, "a notification before start must not even QUEUE a session")
        let events = await sessionEvents(in: transport)
        let requests = await transport.requests()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(requests.isEmpty)

        // The live control, on this fixture, at this moment. The emptiness above is only a
        // measurement once the same lifecycle, transport and queue are shown to SPEAK; no small
        // mutant of the runtime can make them speak before start, because a nil api key refuses
        // at every site independently, so the instrument is proven by starting instead.
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the same fixture must record a session once start() has run")
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
        let firstEntered = await gate.waitUntilEntered()
        XCTAssertTrue(firstEntered)
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
        let activationEntered = await gate.waitUntilEntered()
        XCTAssertTrue(activationEntered)

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
        let parkedEntered = await gate.waitUntilEntered()
        XCTAssertTrue(parkedEntered)

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
        // The stale activation consumes index 1 only after release. Index 2 is a progress signal;
        // the following actor call is the assignment barrier and the event below is the proof.
        let replayAdvanced = await waitUntil { await storage.currentSessionIndexForTesting() >= 2 }
        XCTAssertTrue(replayAdvanced)
        await runtime.applicationDidBecomeActive()

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
        let parkedEntered = await gate.waitUntilEntered()
        XCTAssertTrue(parkedEntered)

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
        let replayAdvanced = await waitUntil { await storage.currentSessionIndexForTesting() >= 2 }
        XCTAssertTrue(replayAdvanced)
        await runtime.applicationDidBecomeActive()

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

    /// THE ONLY TEST IN THE PACKAGE THAT SUPPLIES A POST INSTANT.
    ///
    /// `applicationDidBecomeActive(occurredAt:)` and `applicationWillResignActive(occurredAt:)`
    /// both do `occurredAt ?? configuration.now()`. On iOS the real observer always passes a
    /// non-nil `Date()` taken when the notification POSTED, while `configuration.now()` reads the
    /// clock when the actor finally SERVICES it -- after the serialized delivery tail. Until this
    /// case existed the whole parameter was driven by nothing: the sole lifecycle fixture in the
    /// package hard-coded nil, so both `?? configuration.now()` expressions could be reduced to
    /// `configuration.now()` with all 120 tests green, re-charging the wait to the user's session.
    ///
    /// The clock is advanced BETWEEN the post instants and the delivery, by more than the session
    /// itself lasts, so the four readings cannot be confused. The instants are t (start posted),
    /// t+0.5s (end posted), t+3s (start serviced) and t+7s (end serviced): honouring both post
    /// instants gives 500ms, taking the delivery clock for both gives 4000ms, and the two mixed
    /// readings give 7000ms and -2500ms. No combination lands back on 500. A test whose delivery
    /// lag is smaller than its session would pass either way.
    ///
    /// MUTATION PIN, both directions, each RUN: `startedAt: occurredAt ?? configuration.now()`
    /// -> `configuration.now()` fails here on the start side, and
    /// `let endedAt = occurredAt ?? configuration.now()` -> `configuration.now()` fails on the end
    /// side. Nothing else in the suite moves for either.
    func testSessionIsMeasuredFromThePostInstantsRatherThanTheDeliveryClock() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let foregroundedAt = clock.now()
        // The notification posted at `foregroundedAt`; the runtime services it 3 seconds later,
        // which is what a busy launch, a serialized delivery tail or a device under load looks
        // like from inside the actor.
        clock.advance(by: 3.0)
        await runtime.applicationDidBecomeActive(occurredAt: foregroundedAt)

        let backgroundedAt = foregroundedAt.addingTimeInterval(0.5)
        clock.advance(by: 4.0)
        await runtime.applicationWillResignActive(occurredAt: backgroundedAt)

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered, "the session must be emitted")
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        // 500: the foreground period the USER experienced. The delivery-clock edges are four
        // seconds apart, so replacing both post instants with configuration.now() reports 4000.
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 500,
                       "the session must be measured between the two post instants, not the two delivery instants")
        await runtime.shutdown()
    }

    /// The fixture's own default must stay nil-passing, because 30 other uses depend on the
    /// TestDateClock remaining authoritative for them. Without this, a fixture "fix" that started
    /// stamping `Date()` would silently take every other session in the package off the test clock
    /// and onto the wall clock.
    func testTheLifecycleFixtureStillDefaultsToNoPostInstant() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = sessionTransport()
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 2.0)
        await lifecycle.send(.willResignActive)

        let delivered = await waitForSessionEventCount(1, in: transport)
        XCTAssertTrue(delivered)
        let events = await sessionEvents(in: transport)
        let properties = try XCTUnwrap(events.first?["properties"] as? [String: Any])
        XCTAssertEqual((properties["duration_ms"] as? NSNumber)?.intValue, 2_000,
                       "with no post instant supplied the test clock must remain authoritative")
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

private actor LifecycleEventRecorder {
    private var events: [(ApplicationLifecycleEvent, Date?)] = []

    func record(_ event: ApplicationLifecycleEvent, occurredAt: Date?) {
        events.append((event, occurredAt))
    }

    func count() -> Int { events.count }

    func snapshot() -> (count: Int, firstIsDidBecomeActive: Bool, firstOccurredAt: Date?) {
        guard let first = events.first else { return (0, false, nil) }
        let isDidBecomeActive: Bool
        switch first.0 {
        case .didBecomeActive:
            isDidBecomeActive = true
        case .willResignActive, .willTerminate:
            isDidBecomeActive = false
        }
        return (events.count, isDidBecomeActive, first.1)
    }
}

/// The durable event queue the runtime writes, readable without waiting for anything.
///
/// The suppression tests prove an ABSENCE, and the transport alone cannot: the flush is
/// asynchronous, so a fixed sleep only hoped a leaked session had been delivered by the time the
/// assertion ran. `applicationWillResignActive` does not return until the envelope has reached
/// durable storage and `ManualLifecycleObserver.send` awaits the whole handler, so this read
/// needs no wait at all, and the queue/transport pair leaves no window: an event the flush has
/// already drained is in the transport, one it has not is still in the queue.
///
/// Measured rather than assumed: with `sessionTrackingEnabled` deleted from the session guards,
/// this read alone reports the leaked session_end, with no sleep and before the transport
/// assertion is reached.
private struct SuppressionStore {
    let defaults = UserDefaults(suiteName: "AttriKitSuppression.\(UUID())")!
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AttriKitSuppression-\(UUID())")

    /// A second storage over the same suite and directory as the runtime's own, so it reads the
    /// same queue file rather than a copy.
    func queuedSessionEndCount() async throws -> Int {
        let probe = SDKStorage(
            defaults: .init(value: defaults),
            keychain: MemoryKeychain(),
            directory: directory
        )
        return try await probe.queuedEvents().filter { $0.eventName == "session_end" }.count
    }
}

/// Lets a test park a caller inside a suspension point and hold it there.
///
/// Needed because the session-index hop is a plain actor hop over synchronous work: an
/// `async let` pair only overlaps by luck, and measurement showed it never did.
private actor TestGate {
    private var entered = false
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if entered { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    /// Non-blocking observation used when a surrounding test already owns its own bounded poll.
    func hasEntered() -> Bool { entered }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }
}

private func sessionEvents(
    in transport: StubTransport,
    reportMalformed: @Sendable (String) -> Void = { XCTFail($0) }
) async -> [[String: Any]] {
    var events: [[String: Any]] = []
    for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
        guard let compressed = request.httpBody else {
            reportMalformed("events:batch request had a missing body")
            continue
        }
        guard request.value(forHTTPHeaderField: "content-encoding")?.lowercased() == "gzip" else {
            reportMalformed("events:batch request used an unsupported content-encoding")
            continue
        }
        guard let body = try? gunzipStored(compressed) else {
            reportMalformed("events:batch request contained invalid gzip")
            continue
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            reportMalformed("events:batch request contained invalid JSON")
            continue
        }
        guard let batch = json["events"] as? [[String: Any]] else {
            reportMalformed("events:batch request did not contain an events array")
            continue
        }
        events.append(contentsOf: batch.filter { $0["event_name"] as? String == "session_end" })
    }
    return events
}

/// Returns one executable Swift body with comments removed, so source contracts cannot be
/// satisfied by prose elsewhere in the file. The lifecycle source contains no braces in string
/// literals, which keeps this deliberately small scanner sufficient for these scoped assertions.
private func swiftBody(after marker: String, in source: String) -> String? {
    let uncommented = source
        .replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[..<comment.lowerBound])
        }
        .joined(separator: "\n")
    guard let markerRange = uncommented.range(of: marker),
          let openingBrace = uncommented[markerRange.upperBound...].firstIndex(of: "{")
    else { return nil }
    var depth = 0
    for index in uncommented.indices[openingBrace...] {
        switch uncommented[index] {
        case "{": depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return String(uncommented[openingBrace...index])
            }
        default: break
        }
    }
    return nil
}

private final class MalformedDiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

private func storedGzip(_ body: Data) -> Data {
    precondition(body.count <= Int(UInt16.max))
    let length = UInt16(body.count)
    let inverse = ~length
    var result = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x01])
    result.append(UInt8(length & 0xff))
    result.append(UInt8(length >> 8))
    result.append(UInt8(inverse & 0xff))
    result.append(UInt8(inverse >> 8))
    result.append(body)
    let checksum = sessionTestCRC32(body)
    let size = UInt32(body.count)
    for value in [checksum, size] {
        result.append(UInt8(value & 0xff))
        result.append(UInt8((value >> 8) & 0xff))
        result.append(UInt8((value >> 16) & 0xff))
        result.append(UInt8((value >> 24) & 0xff))
    }
    return result
}

private func sessionTestCRC32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0)
        }
    }
    return crc ^ UInt32.max
}
