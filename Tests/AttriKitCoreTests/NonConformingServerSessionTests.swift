import Foundation
import XCTest
@testable import AttriKitCore

/// Reproduction of the InkLine CAPTURE SETUP, not of a product defect.
///
/// The field report was captured with `AttriKitEndpoint` pointed at a local HTTP server that
/// answered EVERY request with `200 {"ok":true}` — a success status carrying a body that
/// conforms to no SDK response schema. These tests ask what that server does to session
/// delivery specifically, across six background/foreground cycles.
@MainActor
final class NonConformingServerSessionTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    /// Every request answered `200 {"ok":true}`, exactly as the report describes.
    private func inkLineTransport() -> StubTransport {
        StubTransport { _, _ in
            HTTPResult(statusCode: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:])
        }
    }

    /// A non-conforming 200 on first-open throws out of `decode(FirstOpenResponse.self)` and
    /// lands in the generic `catch` → `scheduleFirstOpenRetry()`. Two observable consequences,
    /// both of which the report itself recorded or implies:
    ///  * the retry ladder is armed (`retryState().attempt == 1`) → first-open is re-sent with an
    ///    unchanged installation_id, the report's "re-sent four times" observation;
    ///  * `attributionCache` is never written, so attribution answers `.timedOut`, not
    ///    `.unattributed`.
    func testNonConformingFirstOpenTwoHundredArmsTheRetryLadder() async throws {
        let configuration = makeTestConfiguration(transport: inkLineTransport())
        await AttriKit.configureForTesting(configuration)

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let armed = await waitUntil {
            await configuration.storage.retryState() != nil
        }
        XCTAssertTrue(armed, "a non-conforming 200 must arm the first-open retry ladder")
        let result = await AttriKit.attribution(timeout: .zero)
        XCTAssertEqual(result, .timedOut)
        let stored = await configuration.storage.retryState()
        let retry = try XCTUnwrap(stored)
        XCTAssertEqual(retry.attempt, 1)
    }

    /// THE QUESTION. Six background/foreground cycles against the non-conforming server.
    ///
    /// Nothing on the session path reads `attributionCache`, the first-open receipt, or the
    /// poll result, and the batch endpoint's success is decided on STATUS ALONE, so every
    /// session_end is enqueued and POSTed. The capture setup does not suppress a single one.
    func testSixCyclesAgainstTheNonConformingServerStillDeliverSixSessionEnds() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let transport = inkLineTransport()
        await AttriKit.configureForTesting(makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        ))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)

        for cycle in 1...6 {
            await lifecycle.send(.didBecomeActive)
            clock.advance(by: 2)
            await lifecycle.send(.willResignActive)
            let delivered = try await waitUntilPostedSessionEndCount(cycle, in: transport)
            XCTAssertTrue(delivered, "cycle \(cycle) did not deliver its session_end")
            // Past the 30s resume window, so each cycle is a distinct session, as the report's
            // "session_id visibly rotating" describes.
            clock.advance(by: 40)
        }

        let posted = try await postedSessionEnds(in: transport)
        XCTAssertEqual(posted.count, 6)
        XCTAssertEqual(
            posted.compactMap { ($0["properties"] as? [String: Any])?["session_index"] as? NSNumber }
                .map(\.intValue),
            [1, 2, 3, 4, 5, 6]
        )
    }

    /// Why the previous test passes: `flushQueueOnce` decides delivery on the STATUS CODE and
    /// never decodes the batch response, so `{"ok":true}` acknowledges the batch and the
    /// session_end is removed from the queue as delivered.
    func testNonConformingBatchTwoHundredAcknowledgesTheQueue() async throws {
        let clock = TestDateClock()
        let lifecycle = ManualLifecycleObserver()
        let gate = BatchResponseGate()
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                await gate.blockUntilReleased()
            }
            return HTTPResult(statusCode: 200, data: Data(#"{"ok":true}"#.utf8), headers: [:])
        }
        let configuration = makeTestConfiguration(
            transport: transport,
            now: { clock.now() },
            lifecycle: lifecycle
        )
        await AttriKit.configureForTesting(configuration)

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 2)
        await lifecycle.send(.willResignActive)

        let requestBlocked = await gate.waitUntilBlocked()
        XCTAssertTrue(requestBlocked, "the batch request never reached the transport")
        let queuedBeforeResponse = try await configuration.storage.queuedEvents(now: clock.now())
        XCTAssertTrue(
            queuedBeforeResponse.contains { $0.eventName == "session_end" },
            "the queue must contain the session_end before a response can drain it"
        )

        await gate.release()
        let drained = try await waitUntilQueueIsEmpty(configuration.storage, now: { clock.now() })
        XCTAssertTrue(drained, "a non-conforming 200 on events:batch must still drain the queue")
    }

    func testBatchResponseGateReleasesEveryOverlappingWaiter() async {
        let gate = BatchResponseGate()
        let first = Task { await gate.blockUntilReleased() }
        let second = Task { await gate.blockUntilReleased() }

        let bothBlocked = await gate.waitUntilBlocked(count: 2)
        XCTAssertTrue(bothBlocked, "both overlapping batch requests must be retained as waiters")
        await gate.release()
        await first.value
        await second.value
    }

    func testPostedSessionEndsThrowsOnMalformedBatchBody() async throws {
        let transport = inkLineTransport()
        var malformed = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/v1/events:batch")))
        malformed.httpBody = Data("not-gzip".utf8)
        _ = try await transport.send(malformed)

        do {
            _ = try await postedSessionEnds(in: transport)
            XCTFail("a malformed captured batch must not be interpreted as zero session_end events")
        } catch let error as URLError {
            // The refusal has to be the gzip decode of the captured body. The only assertion here
            // used to be XCTAssertFalse(String(describing: error).isEmpty), which no Error can
            // fail, so a transport fault, a request with no body at all, or the JSON refusal below
            // all satisfied this arm and the test could not tell the intended failure mode from an
            // accidental one. Measured: replacing the malformed body with none at all makes
            // postedSessionEnds throw CocoaError(.fileReadCorruptFile) and the old arm stayed green.
            XCTAssertEqual(
                error.code,
                .cannotDecodeContentData,
                "expected the gunzip refusal, got URLError \(error.code.rawValue)"
            )
        } catch {
            XCTFail("expected a gzip decode refusal from the captured body, got \(error)")
        }
    }
}

private actor BatchResponseGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func blockUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilBlocked(count: Int = 1) async -> Bool {
        await waitUntil { await self.waiters.count >= count }
    }

    func release() {
        released = true
        let blocked = waiters
        waiters.removeAll()
        for continuation in blocked { continuation.resume() }
    }
}

private func waitUntilQueueIsEmpty(
    _ storage: SDKStorage,
    now: @escaping @Sendable () -> Date
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if try await storage.queuedEvents(now: now()).isEmpty { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await storage.queuedEvents(now: now()).isEmpty
}

private func waitUntilPostedSessionEndCount(
    _ expected: Int,
    in transport: StubTransport
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if try await postedSessionEnds(in: transport).count == expected { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await postedSessionEnds(in: transport).count == expected
}

private func postedSessionEnds(in transport: StubTransport) async throws -> [[String: Any]] {
    var events: [[String: Any]] = []
    for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
        guard let compressed = request.httpBody else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "captured events:batch request has no body"])
        }
        let body = try gunzipStored(compressed)
        guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let batch = json["events"] as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt, userInfo: [NSLocalizedDescriptionKey: "captured events:batch body has no event array"])
        }
        events.append(contentsOf: batch.filter { $0["event_name"] as? String == "session_end" })
    }
    return events
}
