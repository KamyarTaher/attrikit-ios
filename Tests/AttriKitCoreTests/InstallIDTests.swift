import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// `AttriKit.installID` is the id a customer hands to RevenueCat, Stripe or its own backend. It is
/// the id the SDK's own initialization established, and each case pins that it is never anything
/// else: nil before measurement, the measured id after, cleared by a wipe, and equal to the id on
/// every request the SDK sends.
@MainActor
final class InstallIDTests: XCTestCase {
    private static let lowercaseUUID = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
    private let apiKey = String(repeating: "k", count: 20)

    private func firstOpenJSON(_ transport: StubTransport) async throws -> [String: Any] {
        let arrived = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(arrived, "first-open was never sent")
        let request = await transport.requests().first { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func bodyText(_ request: URLRequest) -> String {
        guard let data = request.httpBody else { return "" }
        return String(decoding: (try? gunzipStored(data)) ?? data, as: UTF8.self)
    }

    private static func installationIDs(_ body: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #""installation_id"\s*:\s*"([0-9a-fA-F-]{36})""#)
        let range = NSRange(body.startIndex..., in: body)
        return pattern.matches(in: body, range: range).compactMap { match in
            Range(match.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// Nothing is established before `start` runs, and the accessor says so instead of inventing an
    /// id. `start` returns before it has run, so the async accessor is the one to read after it.
    func testNilBeforeStartThenTheIdInitializationEstablished() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let keychain = MemoryKeychain()
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, keychain: keychain))
        XCTAssertNil(AttriKit.installID)
        let beforeStart = await AttriKit.installID()
        XCTAssertNil(beforeStart)

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let afterStart = await AttriKit.installID()
        let established = try XCTUnwrap(afterStart, "start ran and the accessor still had no id")
        XCTAssertNotNil(established.range(of: Self.lowercaseUUID, options: .regularExpression), "installID must be lowercase: \(established)")
        XCTAssertEqual(AttriKit.installID, established, "the property and the async accessor disagreed")
        XCTAssertEqual(try keychain.read()?.uuidString.lowercased(), established, "not the id initialization stored")

        let json = try await firstOpenJSON(transport)
        XCTAssertEqual(json["installation_id"] as? String, established)
        XCTAssertEqual(json["local_lineage_present"] as? Bool, false)
    }

    /// A reinstall that kept the Keychain: initialization reads the previous id, and so does the
    /// accessor.
    func testAReinstallThatKeptTheKeychainReportsThatId() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let keychain = MemoryKeychain()
        let previous = UUID()
        try keychain.write(previous)
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, keychain: keychain))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let established = await AttriKit.installID()
        XCTAssertEqual(established, previous.uuidString.lowercased())
        let json = try await firstOpenJSON(transport)
        XCTAssertEqual(json["installation_id"] as? String, previous.uuidString.lowercased())
        XCTAssertEqual(json["local_lineage_present"] as? Bool, true)
    }

    /// Without measurement consent the SDK initializes nothing, so there is no id to hand out; the
    /// grant establishes it, and it is the one first-open then carries.
    func testNilWithoutMeasurementConsentUntilItIsGranted() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))

        AttriKit.start(apiKey: apiKey, consent: .unknown)
        let withoutConsent = await AttriKit.installID()
        XCTAssertNil(withoutConsent, "an id was handed out that the SDK is not measuring under")

        AttriKit.setConsent(.measurementGranted)
        let granted = await AttriKit.installID()
        let established = try XCTUnwrap(granted)
        let json = try await firstOpenJSON(transport)
        XCTAssertEqual(json["installation_id"] as? String, established)
    }

    /// The contract itself: every captured request that carries an installation id carries this
    /// one, first-open and events alike.
    func testEqualsTheIdOnEveryOutgoingRequest() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        AttriKit.track(try AttriKitEvent("trial_started"))
        let delivered = await waitUntil {
            let paths = await transport.requests().compactMap { $0.url?.path }
            return paths.contains { $0.hasSuffix("/v1/ingest/first-open") } && paths.contains { $0.contains("events:batch") }
        }
        XCTAssertTrue(delivered)
        let established = await AttriKit.installID()
        let onTheWire = Set(await transport.requests().map(Self.bodyText).flatMap(Self.installationIDs))
        XCTAssertFalse(onTheWire.isEmpty, "precondition: the requests carry an installation id")
        XCTAssertEqual(onTheWire, [try XCTUnwrap(established)], "a request carried an id other than installID")
    }

    /// While a deletion is pending that id is being erased, and handing it out would let the app
    /// re-link its backend to data the user asked to delete; once it completes the SDK measures
    /// under no id at all.
    func testNilWhileADeletionIsPendingAndClearedAfterIt() async throws {
        let release = RequestGate()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/privacy/delete") == true { await release.wait() }
            return successResult()
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let established = await AttriKit.installID()
        XCTAssertNotNil(established)

        let deletion = Task { try await AttriKit.deleteData() }
        let inFlight = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/privacy/delete") == true }
        }
        XCTAssertTrue(inFlight)
        XCTAssertNil(AttriKit.installID, "the id being erased was handed out")

        await release.open()
        try await deletion.value
        XCTAssertNil(AttriKit.installID)
        let afterDeletion = await AttriKit.installID()
        XCTAssertNil(afterDeletion)
    }

    /// Revoking consent wipes measurement, and the id with it.
    func testClearedWhenConsentIsRevoked() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let established = await AttriKit.installID()
        XCTAssertNotNil(established)

        AttriKit.setConsent(.revoked)
        let afterRevocation = await AttriKit.installID()
        XCTAssertNil(afterRevocation, "an id outlived the consent wipe")
        XCTAssertNil(AttriKit.installID)
    }

    /// `.unknown` after `start` stops measurement without wiping the identity, so the id must stop
    /// being readable anyway; a grant then republishes the same established id.
    func testNilOnceConsentIsUnknownAgainAndTheSameIdAfterARegrant() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let afterStart = await AttriKit.installID()
        let established = try XCTUnwrap(afterStart)

        AttriKit.setConsent(.unknown)
        let whileUnknown = await AttriKit.installID()
        XCTAssertNil(whileUnknown, "the id stayed readable without measurement consent")
        XCTAssertNil(AttriKit.installID)

        AttriKit.setConsent(.measurementGranted)
        let regranted = await AttriKit.installID()
        XCTAssertEqual(regranted, established)
    }

    /// A denial or a revocation sends its withdrawal receipt before the wipe. The id must already
    /// read nil while that receipt is in flight, not only once the wipe has run.
    func testNilWhileAWithdrawalReceiptIsInFlight() async throws {
        for withdrawal in [AttriKitConsent.denied, .revoked] {
            let hold = RequestGate()
            let transport = StubTransport { request, _ in
                if request.url?.path.hasSuffix("/v1/ingest/consent") == true { await hold.wait() }
                return successResult()
            }
            await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
            AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
            let afterStart = await AttriKit.installID()
            XCTAssertNotNil(afterStart)

            AttriKit.setConsent(withdrawal)
            let inFlight = await waitUntil {
                await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }
            }
            XCTAssertTrue(inFlight, "precondition: the \(withdrawal) receipt is being delivered")
            XCTAssertNil(AttriKit.installID, "the id was readable while the \(withdrawal) receipt was in flight")

            await hold.open()
            let afterWipe = await AttriKit.installID()
            XCTAssertNil(afterWipe)
        }
    }

    /// A caller that is already cancelled asked for nothing it can use; the documented answer to a
    /// cancelled wait is nil, whether or not anything was queued.
    func testACancelledCallerIsGivenNoId() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let afterStart = await AttriKit.installID()
        XCTAssertNotNil(afterStart)

        let proceed = RequestGate()
        let reader = Task { () -> String? in
            await proceed.wait()
            return await AttriKit.installID()
        }
        reader.cancel()
        await proceed.open()
        let read = await reader.value
        XCTAssertNil(read, "a cancelled caller was given the id")
    }

    /// Cancelling a caller that waits behind a queued operation releases that caller at once, and
    /// only it: the queued operation belongs to the app and still runs to its end.
    func testCancellationReleasesAWaitWithoutCancellingTheQueuedOperation() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let afterStart = await AttriKit.installID()
        XCTAssertNotNil(afterStart)

        let hold = RequestGate()
        let queuedFinished = TestFlag()
        // RequestGate.wait() ignores cancellation, so reaching the end proves nothing on its own:
        // the operation also records whether its own task was cancelled.
        let queuedSawCancellation = TestFlag()
        AttriKit.enqueueForTesting { _ in
            await hold.wait()
            if Task.isCancelled { queuedSawCancellation.set() }
            queuedFinished.set()
        }
        let readerReturned = TestFlag()
        let reader = Task { () -> String? in
            let read = await AttriKit.installID()
            readerReturned.set()
            return read
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(readerReturned.isSet, "precondition: the reader waits behind the queued operation")

        reader.cancel()
        let released = await waitUntil(timeout: .seconds(2)) { readerReturned.isSet }
        let queuedStillRunning = !queuedFinished.isSet
        // Opened before anything awaits the reader: a reader still stuck behind the queue must
        // turn into a failed assertion below, never into a test that hangs.
        await hold.open()
        let read = await reader.value
        XCTAssertTrue(released, "cancellation did not release the wait")
        XCTAssertNil(read, "a cancelled wait answered with an id")
        XCTAssertTrue(queuedStillRunning, "precondition: the queued operation was still running when the caller was released")
        let completed = await waitUntil { queuedFinished.isSet }
        XCTAssertTrue(completed, "the queued operation was cancelled along with the caller")
        XCTAssertFalse(queuedSawCancellation.isSet, "the queued operation's task was cancelled along with the caller")
    }
}

/// Holds whatever awaits it (a request, a queued operation) until the test has looked.
private actor RequestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
