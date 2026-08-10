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
        let result = await AttriKit.attribution(timeout: .zero)

        XCTAssertEqual(result, .timedOut)
        let armed = await waitUntil {
            await configuration.storage.retryState() != nil
        }
        XCTAssertTrue(armed, "a non-conforming 200 must arm the first-open retry ladder")
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
            let delivered = await waitUntil {
                await postedSessionEnds(in: transport).count == cycle
            }
            XCTAssertTrue(delivered, "cycle \(cycle) did not deliver its session_end")
            // Past the 30s resume window, so each cycle is a distinct session, as the report's
            // "session_id visibly rotating" describes.
            clock.advance(by: 40)
        }

        let posted = await postedSessionEnds(in: transport)
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
        let configuration = makeTestConfiguration(
            transport: inkLineTransport(),
            now: { clock.now() },
            lifecycle: lifecycle
        )
        await AttriKit.configureForTesting(configuration)

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .zero)
        await lifecycle.send(.didBecomeActive)
        clock.advance(by: 2)
        await lifecycle.send(.willResignActive)

        let drained = await waitUntil {
            ((try? await configuration.storage.queuedEvents(now: clock.now())) ?? [EventEnvelope]()).isEmpty
        }
        XCTAssertTrue(drained, "a non-conforming 200 on events:batch must still drain the queue")
    }
}

private func postedSessionEnds(in transport: StubTransport) async -> [[String: Any]] {
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
