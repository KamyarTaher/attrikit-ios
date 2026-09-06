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
/// The reordered cases below characterize the manual seam only. They are not regression tests for
/// shipped UIKit observation: that observer serializes notifications and synthesizes a launch
/// activation missed before subscription, while ManualLifecycleObserver deliberately does neither.
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

        let count = await settledSessionEndCount(in: transport)
        XCTAssertEqual(count, cycles, "control failed: the harness cannot observe every session_end")
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
        let count = await settledSessionEndCount(in: transport)
        XCTAssertEqual(count, expected, "expected \(expected) session_end from \(cycles) reordered cycles")
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
        let count = await settledSessionEndCount(in: transport)
        XCTAssertEqual(count, expected)
    }

    /// The manual seam has no subscription-time active-state synthesis, so an activation sent
    /// before start() is intentionally lost here. The shipped UIKit observer DOES synthesize that
    /// state; this case documents the test-double boundary and must not be cited as its reproduction.
    ///
    /// It also shows why the report's supporting observation proves nothing: a custom event in
    /// each launch carries a DIFFERENT session_id, because `sessionID` is a fresh per-process
    /// UUID that is initialized whether or not a session is ever tracked. "session_id visibly
    /// rotating across launches" is evidence of process restarts, not of session tracking.
    func testManualObserverWithoutUIKitSynthesisDropsPreSubscriptionActivations() async throws {
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
            // test's assertion is a ZERO, so sampling here would let a session_end batched a moment
            // later slip past and turn a real failure into a pass. A bounded wait followed by ONE
            // read still counts nothing that lands after the wait expires, so take the settled read
            // the three cases above this one already use: it polls for the whole window AND refuses
            // a count still moving at the deadline, which is the transport quiescence this zero
            // needs.
            totalSessionEnds += await settledSessionEndCount(in: transport)

            let events = await symptomEvents(in: transport)
            if let probe = events.first(where: { $0.name == "probe_\(launch)" }) {
                sessionIDs.append(probe.sessionID)
            }
        }

        XCTAssertEqual(totalSessionEnds, 0, "reproduction failed: some launch closed a session")
        XCTAssertEqual(sessionIDs.count, cycles)
        XCTAssertEqual(Set(sessionIDs).count, cycles,
                       "session_id must rotate per launch even though zero sessions were tracked")
    }

    func testUIKitLifecycleSourceUsesGenerationDuringInstallationAndPerSubscriptionDeliveryChains() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: package.appendingPathComponent("Sources/AttriKitCore/SessionLifecycle.swift"),
            encoding: .utf8
        )
        let executableSource = swiftExecutableSource(source)
        let startScope = try XCTUnwrap(swiftScope(openedAfter: "func start(", in: executableSource))

        XCTAssertFalse(startScope.contains("subscriptionGeneration == installGen && !tokens.isEmpty"))
        XCTAssertFalse(startScope.contains("Task { @MainActor in Self.deliveryTail = nil }"))
        let generation = try XCTUnwrap(startScope.range(of: "let installGen = locked"))
        let chain = try XCTUnwrap(startScope.range(of: "let deliveryChain = DeliveryChain()"))
        let installation = try XCTUnwrap(startScope.range(of: "let installed = ["))
        XCTAssertLessThan(generation.lowerBound, installation.lowerBound)
        XCTAssertLessThan(chain.lowerBound, installation.lowerBound)

        for notification in [
            "forName: UIApplication.didBecomeActiveNotification",
            "forName: UIApplication.willResignActiveNotification",
            "forName: UIApplication.willTerminateNotification",
        ] {
            let closure = try XCTUnwrap(swiftScope(openedAfter: notification, in: startScope))
            let guardRange = try XCTUnwrap(
                closure.range(of: "guard let self, self.isCurrentSubscription(installGen) else { return }")
            )
            let deliveryRange = try XCTUnwrap(closure.range(of: "through: deliveryChain"))
            XCTAssertLessThan(
                guardRange.lowerBound,
                deliveryRange.lowerBound,
                "\(notification) must reject a stale subscription before scheduling delivery"
            )
        }

        let synthesized = try XCTUnwrap(
            swiftScope(openedAfter: "deliveryChain.deliver { [weak self] in", in: startScope)
        )
        XCTAssertTrue(synthesized.contains("self.currentActivationGeneration() == captured"))
        XCTAssertTrue(synthesized.contains("self.isCurrentSubscription(installGen) else { return }"))

        let deadFixture = swiftExecutableSource(#"""
            let decoy = "self.isCurrentSubscription(installGen) else { return }"
            func unreachableDecoy() {
                guard let self, self.isCurrentSubscription(installGen) else { return }
            }
            center.addObserver(forName: UIApplication.didBecomeActiveNotification) { _ in
                deliver(through: deliveryChain)
            }
            """#)
        let deadClosure = try XCTUnwrap(
            swiftScope(openedAfter: "forName: UIApplication.didBecomeActiveNotification", in: deadFixture)
        )
        XCTAssertFalse(deadClosure.contains("self.isCurrentSubscription(installGen) else { return }"))
    }

    /// Guards this file's own PROSE, not product behaviour, and is named so it cannot be counted as
    /// coverage of either. Three claims were retracted from this file and each has a way back in:
    /// calling itself the one true reproduction, saying the count fell out with no second defect
    /// needed, and counting session_end from a single sampled read instead of a settled one. The
    /// three guards used to sit at the end of the UIKit-source test above, written with string
    /// concatenation so the guard lines cannot match themselves -- which also made them unable to
    /// fail for a second reason nobody had checked: an empty or wrong `testSource` satisfies every
    /// absence below just as well as a clean file. So the read is ANCHORED first, and the predicate
    /// is required to see each phrase in a fixture that carries it before its silence on the real
    /// file is worth anything.
    func testThisFileDoesNotReintroduceItsRetractedClaims() throws {
        let retracted = [
            "THE " + "REPRODUCTION",
            "with no second defect " + "required",
            "symptomSessionEnds(in: transport).count " + "== expected",
        ]
        let testSource = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        XCTAssertTrue(
            testSource.contains("final class ReportedSymptomTests: " + "XCTestCase"),
            "#filePath did not yield this file's source, so every absence below is vacuous"
        )
        for phrase in retracted {
            XCTAssertEqual(
                firstRetractedClaim(in: "prologue \(phrase) epilogue", among: retracted),
                phrase,
                "the guard cannot see the phrase it exists to refuse"
            )
        }
        XCTAssertNil(
            firstRetractedClaim(in: testSource, among: retracted),
            "a retracted claim came back into this file"
        )
    }

    func testSettledCountObservesDuplicateAfterTheFormerQuarterSecondWindow() async {
        let counter = SymptomCounter(1)
        let start = ContinuousClock().now
        let count = await settledCount(for: .milliseconds(600)) {
            await counter.incrementOnFirstSample(atLeast: .milliseconds(250), since: start)
        }

        XCTAssertEqual(count, 2, "a duplicate after 250 ms must still be observed")
        let delay = await counter.incrementDelay
        let observed = try? XCTUnwrap(delay, "the duplicate was never released inside the budget")
        XCTAssertGreaterThanOrEqual(
            observed ?? .zero,
            .milliseconds(250),
            "the duplicate must land past the quarter-second window this test is named for"
        )
    }

    func testSwiftSourceLexerBlanksRawAndMultilineStringsAndNestedComments() throws {
        let fixture = ##"""
            let raw = #"decoy func target() { } \#(value)"#
            let multiline = """
                decoy func target() { }
                \(value)
                """
            /* outer decoy { /* nested decoy } */ still comment } */
            func target() {
                if true { print("kept") }
            }
            """##

        let executable = swiftExecutableSource(fixture)
        XCTAssertEqual(executable.components(separatedBy: "func target()").count - 1, 1)
        let scope = try XCTUnwrap(swiftScope(openedAfter: "func target()", in: executable))
        XCTAssertTrue(scope.contains("if true"))
    }

    func testSettledCountActuallyPollsInsteadOfTakingOneDelayedSample() async {
        let samples = SymptomCounter(0)
        _ = await settledCount(for: .milliseconds(60)) { await samples.sample() }
        let sampleCount = await samples.sampleCount
        XCTAssertGreaterThanOrEqual(sampleCount, 2, "settling must re-read before accepting a plateau")
    }

    func testSymptomCounterSampleReturnsCurrentValueWithoutMutatingIt() async {
        let counter = SymptomCounter(6)
        let first = await counter.sample()
        let second = await counter.sample()
        XCTAssertEqual(first, 6)
        XCTAssertEqual(second, 6, "sampling must not change the counter being observed")
        let value = await counter.value
        XCTAssertEqual(value, 6)
    }

    func testSymptomDecoderRejectsAnUncompressedBatchInsteadOfReturningNoEvents() throws {
        var request = URLRequest(url: URL(string: "https://attrikit.io/v1/ingest/events:batch")!)
        request.httpBody = Data(#"{"events":[]}"#.utf8)
        XCTAssertThrowsError(try decodeSymptomEvents(from: request))
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

private actor SymptomCounter {
    private(set) var value: Int
    private(set) var sampleCount = 0
    private(set) var incrementDelay: Duration?

    init(_ value: Int) {
        self.value = value
    }

    func increment() {
        value += 1
    }

    /// Releases the duplicate from inside the READ, on the first sample taken at least `after`
    /// from `start`, and records how late it actually landed. Timing that release with a
    /// fire-and-forget `Task.sleep` instead makes the observation depend on wall clock: the sleep
    /// has to land inside the settling budget with enough budget left for two equal samples, and
    /// on a loaded runner it can overshoot and report the pre-increment value with nothing wrong.
    /// Driven from the poll, the release cannot fall outside the window, and `incrementDelay`
    /// measures the distance this test's name claims instead of assuming it.
    func incrementOnFirstSample(atLeast after: Duration, since start: ContinuousClock.Instant) -> Int {
        guard incrementDelay == nil else { return value }
        let elapsed = start.duration(to: ContinuousClock().now)
        guard elapsed >= after else { return value }
        value += 1
        incrementDelay = elapsed
        return value
    }

    func sample() -> Int {
        sampleCount += 1
        return value
    }
}

private func swiftExecutableSource(_ source: String) -> String {
    var output = ""
    var index = source.startIndex

    func advanced(_ start: String.Index, by count: Int) -> String.Index {
        source.index(start, offsetBy: count, limitedBy: source.endIndex) ?? source.endIndex
    }
    func blank(_ range: Range<String.Index>) {
        for character in source[range] {
            output.append(character == "\n" ? "\n" : " ")
        }
    }
    func rawStringOpening(at start: String.Index) -> (pounds: Int, quotes: Int, end: String.Index)? {
        var cursor = start
        var pounds = 0
        while cursor < source.endIndex, source[cursor] == "#" {
            pounds += 1
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex, source[cursor] == "\"" else { return nil }
        let triple = source[cursor...].hasPrefix("\"\"\"")
        return (pounds, triple ? 3 : 1, advanced(cursor, by: triple ? 3 : 1))
    }
    func isEscapedQuote(at quote: String.Index, pounds: Int) -> Bool {
        if pounds == 0 {
            var cursor = quote
            var backslashes = 0
            while cursor > source.startIndex {
                let previous = source.index(before: cursor)
                guard source[previous] == "\\" else { break }
                backslashes += 1
                cursor = previous
            }
            return backslashes.isMultiple(of: 2) == false
        }
        var cursor = quote
        for _ in 0..<pounds {
            guard cursor > source.startIndex else { return false }
            cursor = source.index(before: cursor)
            guard source[cursor] == "#" else { return false }
        }
        guard cursor > source.startIndex else { return false }
        return source[source.index(before: cursor)] == "\\"
    }

    while index < source.endIndex {
        if source[index...].hasPrefix("//") {
            let start = index
            while index < source.endIndex, source[index] != "\n" {
                index = source.index(after: index)
            }
            blank(start..<index)
            continue
        }
        if source[index...].hasPrefix("/*") {
            let start = index
            var depth = 1
            index = advanced(index, by: 2)
            while index < source.endIndex, depth > 0 {
                if source[index...].hasPrefix("/*") {
                    depth += 1
                    index = advanced(index, by: 2)
                } else if source[index...].hasPrefix("*/") {
                    depth -= 1
                    index = advanced(index, by: 2)
                } else {
                    index = source.index(after: index)
                }
            }
            blank(start..<index)
            continue
        }
        if let opening = rawStringOpening(at: index) {
            let start = index
            index = opening.end
            let closingQuotes = String(repeating: "\"", count: opening.quotes)
            let closingPounds = String(repeating: "#", count: opening.pounds)
            let closing = closingQuotes + closingPounds
            while index < source.endIndex {
                if source[index...].hasPrefix(closing),
                   !isEscapedQuote(at: index, pounds: opening.pounds) {
                    index = advanced(index, by: closing.count)
                    break
                }
                index = source.index(after: index)
            }
            blank(start..<index)
            continue
        }
        output.append(source[index])
        index = source.index(after: index)
    }
    return output
}

private func swiftScope(openedAfter marker: String, in source: String) -> String? {
    guard let markerRange = source.range(of: marker),
          let openingBrace = source[markerRange.lowerBound...].firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 { return String(source[openingBrace...index]) }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}

private func symptomEvents(in transport: StubTransport) async -> [SymptomEvent] {
    var events: [SymptomEvent] = []
    for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
        do {
            events.append(contentsOf: try decodeSymptomEvents(from: request))
        } catch {
            XCTFail("events:batch request could not be decoded: \(error)")
        }
    }
    return events
}

private enum SymptomDecodeError: Error {
    case missingBody
    case invalidBatchShape
    case invalidEventShape
}

private func decodeSymptomEvents(from request: URLRequest) throws -> [SymptomEvent] {
    guard let compressed = request.httpBody else { throw SymptomDecodeError.missingBody }
    let body = try gunzipStored(compressed)
    guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
          let batch = json["events"] as? [[String: Any]] else {
        throw SymptomDecodeError.invalidBatchShape
    }
    return try batch.map { event in
        guard let name = event["event_name"] as? String,
              let sessionID = event["session_id"] as? String else {
            throw SymptomDecodeError.invalidEventShape
        }
        return SymptomEvent(name: name, sessionID: sessionID)
    }
}

private func firstRetractedClaim(in source: String, among phrases: [String]) -> String? {
    phrases.first { source.contains($0) }
}

private func symptomSessionEnds(in transport: StubTransport) async -> [SymptomEvent] {
    await symptomEvents(in: transport).filter { $0.name == "session_end" }
}

@MainActor
private func settledSessionEndCount(in transport: StubTransport) async -> Int {
    await settledCount(for: .seconds(2)) {
        await symptomSessionEnds(in: transport).count
    }
}

@MainActor
private func settledCount(for duration: Duration, read: () async -> Int) async -> Int {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    var latest = await read()
    var consecutiveEqualSamples = 1
    while clock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
        let current = await read()
        if current == latest {
            consecutiveEqualSamples += 1
        } else {
            latest = current
            consecutiveEqualSamples = 1
        }
    }
    if consecutiveEqualSamples < 2 {
        XCTFail("count was still moving at the settling deadline")
    }
    return latest
}
