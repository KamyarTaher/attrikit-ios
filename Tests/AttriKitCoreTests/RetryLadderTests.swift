import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// Pins the retry/poll numbers PUBLISHED on three surfaces (apps/web/components/marketing/content.ts,
/// packages/sdk-ios/README.md, apps/web/public/llms.txt). Nothing pinned them before, so the docs
/// and the shipped ladder could drift apart silently, and the attribution poll shipped unbounded.
@MainActor
final class RetryLadderTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    private func attributionRequestCount(_ transport: StubTransport) async -> Int {
        await transport.requests().filter { $0.url?.path.contains("/v1/attribution/") == true }.count
    }

    /// A server that answers first-open with `200` and a body that is NOT a `FirstOpenResponse`.
    /// This is the field-reported shape: the status line says success, the decode throws, the
    /// throw is caught, and the delivery is rescheduled. Everything else answers normally so the
    /// event queue cannot add noise to the first-open count.
    private func nonConformingFirstOpenTransport() -> StubTransport {
        StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 200, body: #"{"ok":true}"#)
            }
            return successResult(status: 200, body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
        }
    }

    private func makeSharedStorage(_ label: String) -> SDKStorage {
        SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "\(label).\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    /// One "cold launch" against shared storage. `startOrResumeFirstOpen` submits immediately when
    /// the persisted `nextAttemptAt` has already passed, which is what lets these tests walk the
    /// whole delivery ladder without waiting out its real sleeps.
    private func launchRuntime(
        storage: SDKStorage,
        transport: StubTransport,
        clock: TestDateClock
    ) -> CoreRuntime {
        CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { clock.now() },
            lifecycle: ManualLifecycleObserver()
        ))
    }

    func testAttributionPollStopsWhenItsWindowCloses() async throws {
        let clock = TestDateClock()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: #"{"status":"pending","retry_after_ms":0}"#)
            }
            clock.advance(by: 90_000)
            return successResult(status: 503, body: "")
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport, now: { clock.now() }))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        // Exhaustion must NOT be reported as .unattributed. That is a claim about the
        // install; exhaustion is a fact about our polling. attribution(timeout:) returns the
        // cache forever once set, so a premature .unattributed would make a match that simply
        // had not landed yet permanently wrong. .timedOut is the honest answer.
        let firstPoll = await waitUntil {
            await self.attributionRequestCount(transport) == 1
        }
        XCTAssertTrue(firstPoll, "the first poll must reach the transport")
        // The first post-window ladder delay is 5s plus up to 25% jitter. Waiting beyond that
        // distinguishes the elapsed-window guard from a loop that merely has not woken yet.
        let polledAgain = await waitUntil(timeout: .seconds(7)) {
            await self.attributionRequestCount(transport) > 1
        }
        XCTAssertFalse(polledAgain, "the poll must terminate, not merely sleep, once its window closes")
        let answer = await runtime.attribution(timeout: .milliseconds(1))
        XCTAssertEqual(answer, .timedOut, "an exhausted poll leaves the result unknown, not unattributed")
        let count = await attributionRequestCount(transport)
        XCTAssertEqual(count, 1, "the poll must stop after the window closes")
        await runtime.shutdown()
    }

    /// Losing measurement networking mid-poll must not be silent.
    ///
    /// `.unknown` is the one measurement-off state that does NOT route through `stopAndWipe`, so
    /// the poll task is never cancelled: the loop simply notices `canUseNetwork()` is false and
    /// falls out. Before the fix that exit wrote nothing at all, and `attribution(timeout:)`
    /// answered `.timedOut` forever with no way to tell a lost match from a stopped poll.
    func testLosingMeasurementNetworkingMidPollIsReported() async throws {
        let diagnostics = DiagnosticRecorder()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: #"{"status":"pending","retry_after_ms":0}"#)
            }
            return successResult(status: 503, body: "")
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(
            transport: transport,
            diagnostic: { diagnostics.record($0) }
        ))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let polling = await waitUntil { await self.attributionRequestCount(transport) >= 1 }
        XCTAssertTrue(polling, "the poll must be running before networking is taken away")

        // Not .denied or .revoked: those cancel the task, and a cancelled poll is a deliberate
        // stop that must stay quiet. This is the path that used to die in silence.
        await runtime.setConsent(.unknown)

        let reported = await waitUntil {
            diagnostics.messages.contains {
                $0.contains("attribution poll stopped because measurement networking is unavailable")
            }
        }
        XCTAssertTrue(reported, "a poll that stops for lack of networking must say so")
        // .consentRequired, not .timedOut: with consent back at .unknown the API names the actual
        // reason rather than blaming a timeout. The invariant that matters either way is that a
        // stopped poll never fabricates .unattributed, which is a claim about the INSTALL.
        let answer = await runtime.attribution(timeout: .milliseconds(1))
        XCTAssertEqual(answer, .consentRequired, "a poll stopped by consent must say so, never .unattributed")
        XCTAssertNotEqual(answer, .unattributed, "exhaustion and consent loss are never an attribution verdict")
        await runtime.shutdown()
    }

    // DELIBERATELY ABSENT: a frozen-clock termination test.
    //
    // Termination under a stalled clock rests on the attempt counters
    // (attributionPollFastAttempts, then firstOpenRetryDelays.count), which bound the loop at
    // 27 requests: 20 fast, 6 ladder, then one final poll before the exhausted-ladder guard is
    // checked. That is provable by reading startPolling, but NOT observable in a test, because
    // the ladder sleeps are real: reaching exhaustion takes about ten hours of wall clock.
    //
    // A first attempt at this test waited for the request count to go quiet and asserted a
    // total. It reported 3, because 500ms of quiet happens during the very first long sleep,
    // not at the end. An earlier version was worse still: it returned as soon as it saw one
    // request and a .timedOut answer, both true on the first poll, so it passed against an
    // unbounded loop. Neither observed termination, and a test that cannot fail for the right
    // reason is worse than no test.
    //
    // testAttributionPollStopsWhenItsWindowCloses below IS meaningful: it advances the injected
    // clock past the window and proves the elapsed guard fires. Making the counter bound
    // testable needs an injectable scheduler, which is a production change for testability and
    // belongs in its own decision.

    func testAttributionPollHonoursRetryAfter() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: #"{"status":"pending","retry_after_ms":0}"#)
            }
            return successResult(status: 503, body: "", headers: ["retry-after": "30"])
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        _ = await waitUntil(timeout: .milliseconds(900)) { false }
        let count = await attributionRequestCount(transport)
        XCTAssertEqual(count, 1, "Retry-After 30 must outrank the 250ms local ladder")
        await runtime.shutdown()
    }

    func testRetryAfterParsingIsClampedAndFailsSafe() {
        XCTAssertEqual(CoreRuntime.retryAfterMilliseconds("30"), 30_000)
        XCTAssertEqual(CoreRuntime.retryAfterMilliseconds(" 5 "), 5_000)
        XCTAssertEqual(CoreRuntime.retryAfterMilliseconds("999999"), 21_600_000)
        XCTAssertNil(CoreRuntime.retryAfterMilliseconds(nil))
        XCTAssertNil(CoreRuntime.retryAfterMilliseconds("0"))
        XCTAssertNil(CoreRuntime.retryAfterMilliseconds("-10"))
        XCTAssertNil(CoreRuntime.retryAfterMilliseconds("Wed, 21 Oct 2026 07:28:00 GMT"))
    }

    func testFirstOpenRetryLadderMatchesThePublishedSchedule() throws {
        XCTAssertEqual(CoreRuntime.firstOpenRetryDelays, [5, 30, 300, 3_600, 10_800, 21_600])
        XCTAssertEqual(CoreRuntime.firstOpenRetryDelays.count, 6)
        XCTAssertEqual(CoreRuntime.firstOpenRetryWindow, 86_400)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let llms = try String(
            contentsOf: repositoryRoot.appendingPathComponent("apps/web/public/llms.txt"),
            encoding: .utf8
        )
        let marketing = try String(
            contentsOf: repositoryRoot.appendingPathComponent("apps/web/components/marketing/content.ts"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("5s → 30s → 5m → 1h → 3h → 6h, within ~24h"))
        XCTAssertTrue(llms.contains("one initial attempt + up to six retries, 5s→6h backoff, ~24h window"))
        XCTAssertTrue(marketing.contains("5s → 30s → 5m → 1h → 3h → 6h schedule"))
        XCTAssertTrue(marketing.contains("same 24 hour window closes"))
    }

    func testBackgroundRetrySubmissionFailureIsReportedAndIdentifierIsDocumented() async throws {
        let diagnostics = DiagnosticRecorder()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 503, body: #"{"error":"offline"}"#)
            }
            return successResult()
        }
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: makeSharedStorage("AttriKitBackgroundRetry"),
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() },
            lifecycle: ManualLifecycleObserver(),
            backgroundRetryScheduler: BackgroundRetryScheduler { _ in
                throw BackgroundRetryTestError.rejected
            },
            diagnostic: { diagnostics.record($0) }
        ))

        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let reported = await waitUntil {
            diagnostics.messages.contains {
                $0.contains("background retry submission failed")
                    && $0.contains(AttriKit.backgroundRetryTaskIdentifier)
                    && $0.contains("BGTaskSchedulerPermittedIdentifiers")
            }
        }
        XCTAssertTrue(reported, "a rejected BGTaskScheduler submission must reach the diagnostic path")
        await runtime.shutdown()

        XCTAssertEqual(AttriKit.backgroundRetryTaskIdentifier, "io.attrikit.sdk.retry")
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(
            contentsOf: packageRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        XCTAssertTrue(readme.contains("BGTaskSchedulerPermittedIdentifiers"))
        XCTAssertTrue(readme.contains("io.attrikit.sdk.retry"))
    }

    /// The DELIVERY ladder, driven by the input a field report actually produced.
    ///
    /// Distinct from the poll loop the "DELIBERATELY ABSENT" note above describes: that one keeps
    /// its counters in memory and sleeps for real, so its bound stays unobservable. The delivery
    /// ladder persists `RetryState`, and `startOrResumeFirstOpen` fires immediately once
    /// `nextAttemptAt` has passed, so relaunching at each scheduled instant walks the entire
    /// schedule in milliseconds.
    ///
    /// The trigger is a server answering `200 {"ok":true}` — a NON-CONFORMING body under a success
    /// status. `submitFirstOpen` decodes inside its `do`, the decode throws, the catch reschedules.
    /// Until now only the CONSTANTS were pinned; nothing fed that input and asserted where the
    /// deliveries stop.
    func testNonConformingSuccessBodyStopsFirstOpenDeliveryAtTheDocumentedBound() async throws {
        let storage = makeSharedStorage("AttriKitFirstOpenBound")
        let clock = TestDateClock()
        let transport = nonConformingFirstOpenTransport()

        var deliveries = 0
        var exhausted = false
        var lastRuntime: CoreRuntime?
        // Deliberately far above the documented bound: the chain has to stop on its own, not
        // because this ceiling ran out.
        while deliveries < 20 {
            let attemptBeforeLaunch = await storage.retryState()?.attempt
            let runtime = launchRuntime(storage: storage, transport: transport, clock: clock)
            lastRuntime = runtime
            await runtime.start(apiKey: apiKey, consent: .measurementGranted)
            deliveries += 1

            let expected = deliveries
            let landed = await waitUntil { await firstOpenRequestCount(transport) == expected }
            XCTAssertTrue(landed, "delivery \(deliveries) never reached the transport")
            // The schedule has settled once the persisted attempt moves off the value it had
            // before this launch: to `deliveries` while the ladder has room, to nil the moment
            // the bound is reached. Reading the counter beats sleeping on the answer.
            let settled = await waitUntil { await storage.retryState()?.attempt != attemptBeforeLaunch }
            XCTAssertTrue(settled, "the retry schedule never settled after delivery \(deliveries)")

            guard let state = await storage.retryState() else {
                exhausted = true
                break
            }
            await runtime.shutdown()
            clock.advance(by: state.nextAttemptAt.timeIntervalSince(clock.now()) + 1)
        }

        XCTAssertTrue(exhausted, "the delivery chain must terminate on its own")
        // 7 = the first delivery plus the six published rungs. The whole ladder spans 36_335s,
        // well inside the 24h window, so the ATTEMPT bound is what stops this run.
        XCTAssertEqual(deliveries, 7, "first-open delivery must stop after the initial attempt plus six retries")
        let count = await firstOpenRequestCount(transport)
        XCTAssertEqual(count, 7, "the transport must have seen exactly the bounded number of deliveries")
        XCTAssertEqual(count, CoreRuntime.firstOpenRetryDelays.count + 1)

        // Exhaustion is a fact about our delivery, never a verdict about the install. The cache
        // is answered forever once written, so an `.unattributed` here would permanently label an
        // install we never managed to record as a measured organic one.
        let runtime = try XCTUnwrap(lastRuntime)
        let answer = await runtime.attribution(timeout: .milliseconds(1))
        XCTAssertEqual(answer, .timedOut, "an exhausted delivery leaves attribution UNKNOWN")
        // `XCTAssertNotEqual(answer, .unattributed)` restated the line above it -- distinct enum
        // cases, so it could not fail unless that equality had already failed. The invariant it was
        // reaching for is temporal, and it is the one the comment above states: the cache is
        // answered FOREVER once written, so a verdict written a moment AFTER this sample is exactly
        // as permanent and exactly as wrong. Watch the answer for a window instead of restating it.
        let becameUnattributed = await waitUntil {
            await runtime.attribution(timeout: .zero) == .unattributed
        }
        XCTAssertFalse(becameUnattributed, "exhausting the retry schedule is never an attribution verdict")
        await runtime.shutdown()
    }

    /// The second half of the bound: the 24h window, which cuts the chain off with rungs to spare.
    ///
    /// Same non-conforming `200`. One delivery lands, the retry is scheduled, and the app comes
    /// back a day later. The ladder still has five rungs, so only the window can stop this.
    func testFirstOpenRetryStopsAtTheWindowEvenWithLadderRungsLeft() async throws {
        let storage = makeSharedStorage("AttriKitFirstOpenWindow")
        let clock = TestDateClock()
        let transport = nonConformingFirstOpenTransport()

        let first = launchRuntime(storage: storage, transport: transport, clock: clock)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let firstLanded = await waitUntil { await storage.retryState()?.attempt == 1 }
        XCTAssertTrue(firstLanded, "the first delivery must schedule a retry")
        await first.shutdown()

        clock.advance(by: CoreRuntime.firstOpenRetryWindow + 1)

        let second = launchRuntime(storage: storage, transport: transport, clock: clock)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let secondLanded = await waitUntil { await firstOpenRequestCount(transport) == 2 }
        XCTAssertTrue(secondLanded, "the resumed delivery must still be attempted once")
        let cleared = await waitUntil { await storage.retryState() == nil }
        // Attempt 2 of 6 — the ladder is nowhere near exhausted, so a surviving RetryState here
        // means the window is not being enforced and the install can be retried forever.
        XCTAssertTrue(cleared, "a first-open older than the 24h window must not be rescheduled")

        let count = await firstOpenRequestCount(transport)
        XCTAssertEqual(count, 2, "the window must stop the chain at the delivery that discovered it")
        let answer = await second.attribution(timeout: .milliseconds(1))
        XCTAssertEqual(answer, .timedOut, "a window-expired delivery leaves attribution UNKNOWN")
        // Same substitution as the exhaustion case above: a verdict that appears just after this
        // sample is as permanent as one present at it, and only a window can see it.
        let becameUnattributed = await waitUntil {
            await second.attribution(timeout: .zero) == .unattributed
        }
        XCTAssertFalse(becameUnattributed, "the closed window is never an attribution verdict")
        await second.shutdown()
    }
}

private enum BackgroundRetryTestError: Error {
    case rejected
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ message: String) {
        lock.lock()
        recorded.append(message)
        lock.unlock()
    }
}

/// File-scope so the polling closures below stay free of a main-actor `self` capture.
private func firstOpenRequestCount(_ transport: StubTransport) async -> Int {
    await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }.count
}
