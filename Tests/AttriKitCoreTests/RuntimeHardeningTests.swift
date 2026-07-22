import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

@MainActor
final class RuntimeHardeningTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    func testDeleteDataPropagatesTransportFailureAndPreservesRetryTombstone() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitDeleteTransport.\(UUID())")!
        let keychain = MemoryKeychain()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let originalIdentity = try await storage.initializeIdentities()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/privacy/delete") == true {
                throw URLError(.notConnectedToInternet)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        do {
            try await runtime.deleteData()
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        let tombstone = await storage.deletionTombstone()
        XCTAssertEqual(tombstone, DeletionTombstone(
            installationID: originalIdentity.installationID,
            installEpochID: originalIdentity.installEpochID
        ))
        let retryIdentity = try await storage.initializeIdentities()
        XCTAssertEqual(retryIdentity.installationID, originalIdentity.installationID)
        XCTAssertEqual(retryIdentity.installEpochID, originalIdentity.installEpochID)
        await runtime.shutdown()
    }

    func testDeleteDataHTTPFailureRetriesSameTombstoneThenClearsItAfterConfirmation() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitDeleteHTTP.\(UUID())")!
        let keychain = MemoryKeychain()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let identity = try await storage.initializeIdentities()
        let sequence = DeletionRetrySequence()
        let transport = StubTransport { request, _ in
            try await sequence.respond(to: request)
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        do {
            try await runtime.deleteData()
            XCTFail("Expected HTTP deletion failure")
        } catch let error as AttriKitError {
            XCTAssertEqual(error, .deletionFailed(503))
        }
        let pendingTombstone = await storage.deletionTombstone()
        XCTAssertNotNil(pendingTombstone)

        try await runtime.deleteData()

        let requests = await transport.requests().filter {
            $0.url?.path.hasSuffix("/v1/privacy/delete") == true
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") },
            [identity.installEpochID.uuidString.lowercased(), identity.installEpochID.uuidString.lowercased()]
        )
        let bodies = try requests.map { try gunzipStored(XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies[0], bodies[1])
        let clearedTombstone = await storage.deletionTombstone()
        XCTAssertNil(clearedTombstone)
        XCTAssertNil(try keychain.read())
        await runtime.shutdown()
    }

    func testDeleteDataWaitsForInFlightIngestBeforeSendingErasure() async throws {
        let storage = makeStorage(label: "DeleteQuiescence")
        let transport = SuspendedFirstBatchTransport()
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("before_delete"), properties: [:])
        let batchStarted = await waitUntil {
            await transport.requests().contains { $0.url?.path.contains("events:batch") == true }
        }
        XCTAssertTrue(batchStarted)

        let deletion = Task { try await runtime.deleteData() }
        try? await Task.sleep(for: .milliseconds(50))
        let deleteBeforeRelease = await transport.requests().contains {
            $0.url?.path.hasSuffix("/v1/privacy/delete") == true
        }
        XCTAssertFalse(deleteBeforeRelease)

        await transport.releaseBatch(with: successResult(
            body: #"{"status":"accepted","inserted":1,"duplicates":0}"#
        ))
        try await deletion.value

        let writePaths = await transport.requests().compactMap { request -> String? in
            let path = request.url?.path ?? ""
            return path.contains("events:batch") || path.hasSuffix("/v1/privacy/delete") ? path : nil
        }
        XCTAssertEqual(writePaths.count, 2)
        XCTAssertTrue(writePaths[0].contains("events:batch"))
        XCTAssertTrue(writePaths[1].hasSuffix("/v1/privacy/delete"))
        await runtime.shutdown()
    }

    func testRemoteDeletionSuccessWithLocalCleanupFailureKeepsTombstoneForRelaunchRetry() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitDeleteCleanup.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let failingStorage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory,
            queueDirectoryRemover: { _ in throw RuntimeCleanupFailure.simulated }
        )
        let identity = try await failingStorage.initializeIdentities()
        try await failingStorage.enqueue(makeEvent(name: "queued_before_delete", identity: identity))
        let transport = StubTransport { _, _ in successResult(status: 204, body: "") }
        let firstRuntime = makeRuntime(storage: failingStorage, transport: transport)
        await firstRuntime.start(apiKey: apiKey, consent: .measurementGranted)

        do {
            try await firstRuntime.deleteData()
            XCTFail("Expected local cleanup failure")
        } catch RuntimeCleanupFailure.simulated {}

        let retainedTombstone = await failingStorage.deletionTombstone()
        XCTAssertEqual(retainedTombstone, DeletionTombstone(
            installationID: identity.installationID,
            installEpochID: identity.installEpochID
        ))
        await firstRuntime.shutdown()

        let reloadedStorage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let relaunchedRuntime = makeRuntime(storage: reloadedStorage, transport: transport)
        await relaunchedRuntime.start(apiKey: apiKey, consent: .measurementGranted)
        try await relaunchedRuntime.deleteData()
        let clearedTombstone = await reloadedStorage.deletionTombstone()
        XCTAssertNil(clearedTombstone)
        await relaunchedRuntime.shutdown()
    }

    func testDeniedThenGrantedConsentNeverFlushesPreDenialBuffer() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitDeniedBuffer.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)

        await runtime.track(try AttriKitEvent("before_denial"), properties: [:])
        await runtime.start(apiKey: apiKey, consent: .denied)
        await runtime.setConsent(.measurementGranted)
        try? await Task.sleep(for: .milliseconds(100))

        let deliveredEvents = await decodedEvents(in: transport)
        XCTAssertFalse(deliveredEvents.contains {
            $0["event_name"] as? String == "before_denial"
        })
        let queuedAfterGrant = try await storage.queuedEvents()
        XCTAssertTrue(queuedAfterGrant.isEmpty)
        await runtime.shutdown()
    }

    func testRevocationRotatesEpochAndRestartsPersistedSessionSequence() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitRevocation.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        let lifecycle = ManualLifecycleObserver()
        let transport = acceptingEventTransport()
        let runtime = makeRuntime(storage: storage, transport: transport, lifecycle: lifecycle)
        let originalIdentity = try await storage.initializeIdentities()

        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        let firstSessionDelivered = await waitForEvent(named: "session_end", count: 1, in: transport)
        XCTAssertTrue(firstSessionDelivered)

        await runtime.setConsent(.revoked)
        let revokedIdentity = try await storage.initializeIdentities()
        XCTAssertEqual(revokedIdentity.installationID, originalIdentity.installationID)
        XCTAssertNotEqual(revokedIdentity.installEpochID, originalIdentity.installEpochID)

        await runtime.setConsent(.measurementGranted)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)
        let secondSessionDelivered = await waitForEvent(named: "session_end", count: 2, in: transport)
        XCTAssertTrue(secondSessionDelivered)

        let sessions = await decodedEvents(in: transport).filter {
            $0["event_name"] as? String == "session_end"
        }
        XCTAssertEqual(sessions.map { $0["installation_id"] as? String }, [
            originalIdentity.installationID.uuidString.lowercased(),
            originalIdentity.installationID.uuidString.lowercased(),
        ])
        XCTAssertEqual(sessions.map { $0["install_epoch_id"] as? String }, [
            originalIdentity.installEpochID.uuidString.lowercased(),
            revokedIdentity.installEpochID.uuidString.lowercased(),
        ])
        XCTAssertEqual(sessions.compactMap {
            (($0["properties"] as? [String: Any])?["session_index"] as? NSNumber)?.intValue
        }, [1, 1])
        await runtime.shutdown()
    }

    func testPendingRevocationRecoversSameTargetEpochAndSessionResetAfterRelaunch() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitRevocationRecovery.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstStorage = SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        let originalIdentity = try await firstStorage.initializeIdentities()
        _ = await firstStorage.nextSessionIndex()
        _ = await firstStorage.nextSessionIndex()

        try await firstStorage.beginRevocationTransition()

        let relaunchedStorage = SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        try await relaunchedStorage.recoverPendingRevocationIfNeeded()
        let recoveredIdentity = try await relaunchedStorage.initializeIdentities()
        let recoveredConsent = await relaunchedStorage.storedConsent()
        let firstPostRevocationSession = await relaunchedStorage.nextSessionIndex()

        XCTAssertEqual(recoveredIdentity.installationID, originalIdentity.installationID)
        XCTAssertNotEqual(recoveredIdentity.installEpochID, originalIdentity.installEpochID)
        XCTAssertEqual(recoveredConsent, .revoked)
        XCTAssertEqual(firstPostRevocationSession, 1)

        try await relaunchedStorage.recoverPendingRevocationIfNeeded()
        let identityAfterSecondRecovery = try await relaunchedStorage.initializeIdentities()
        XCTAssertEqual(identityAfterSecondRecovery.installEpochID, recoveredIdentity.installEpochID)
    }

    func testPendingBatchIDMembershipAndSentAtPersistAcrossRelaunch() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitBatchPersistence.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstStorage = SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        let identity = try await firstStorage.initializeIdentities()
        let firstEvent = makeEvent(name: "first", identity: identity)
        try await firstStorage.enqueue(firstEvent)
        let firstBatchValue = try await firstStorage.nextEventBatch(
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let firstBatch = try XCTUnwrap(firstBatchValue)

        let secondStorage = SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        let secondEvent = makeEvent(name: "second", identity: identity)
        try await secondStorage.enqueue(secondEvent)
        let retriedBatchValue = try await secondStorage.nextEventBatch(
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
        let retriedBatch = try XCTUnwrap(retriedBatchValue)

        XCTAssertEqual(retriedBatch.batchID, firstBatch.batchID)
        XCTAssertEqual(retriedBatch.events.map(\.eventID), [firstEvent.eventID])
        XCTAssertEqual(retriedBatch.events.map(\.sentAt), firstBatch.events.map(\.sentAt))
        XCTAssertEqual(
            try attriKitJSONEncoder().encode(EventBatch(batchID: firstBatch.batchID, events: firstBatch.events)),
            try attriKitJSONEncoder().encode(EventBatch(batchID: retriedBatch.batchID, events: retriedBatch.events))
        )

        try await secondStorage.acknowledgeEventBatch(batchID: firstBatch.batchID)
        let nextBatchValue = try await secondStorage.nextEventBatch()
        let nextBatch = try XCTUnwrap(nextBatchValue)
        XCTAssertNotEqual(nextBatch.batchID, firstBatch.batchID)
        XCTAssertEqual(nextBatch.events.map(\.eventID), [secondEvent.eventID])
    }

    func testLostBatchResponseReusesExactBodyAndTerminationFlushesRetry() async throws {
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitBatchRetry.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let lifecycle = ManualLifecycleObserver()
        let sequence = BatchCommitThenLostResponseSequence()
        let transport = StubTransport { request, _ in
            try await sequence.respond(to: request)
        }
        let runtime = makeRuntime(storage: storage, transport: transport, lifecycle: lifecycle)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.willResignActive)

        let firstAttempted = await waitUntil {
            await eventBatchRequests(in: transport).count == 1
        }
        XCTAssertTrue(firstAttempted)
        let queuedAfterLostResponse = try await storage.queuedEvents().map(\.eventName)
        XCTAssertEqual(queuedAfterLostResponse, ["session_end"])

        await lifecycle.send(.willTerminate)
        let retried = await waitUntil {
            await eventBatchRequests(in: transport).count == 2
        }
        XCTAssertTrue(retried)
        let requests = await eventBatchRequests(in: transport)
        XCTAssertEqual(
            requests.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }.uniqued().count,
            1
        )
        let bodies = try requests.map { try gunzipStored(XCTUnwrap($0.httpBody)) }
        XCTAssertEqual(bodies[0], bodies[1])
        let queueAfterRetry = try await storage.queuedEvents()
        XCTAssertTrue(queueAfterRetry.isEmpty)
        await runtime.shutdown()
    }

    func testPermanent4xxDropsQueueHeadAndRetryable4xxKeepsIt() async throws {
        let retryableStatuses: Set<Int> = [401, 403, 408, 429]
        for status in 400...499 {
            XCTAssertEqual(
                CoreRuntime.isPermanentClientFailure(status),
                !retryableStatuses.contains(status),
                "Unexpected classification for HTTP \(status)"
            )
        }

        for status in [405, 410, 415, 451] {
            let storage = makeStorage(label: "Permanent\(status)")
            let transport = statusTransport(status)
            let runtime = makeRuntime(storage: storage, transport: transport)
            await runtime.start(apiKey: apiKey, consent: .measurementGranted)
            await runtime.track(try AttriKitEvent("status_\(status)"), properties: [:])
            let attempted = await waitForBatchRequest(in: transport)
            XCTAssertTrue(attempted)
            let removed = await waitUntil { (try? await storage.queuedEvents().isEmpty) == true }
            XCTAssertTrue(removed)
            await runtime.shutdown()
        }

        for status in [401, 403, 408, 429] {
            let storage = makeStorage(label: "Retryable\(status)")
            let transport = statusTransport(status)
            let runtime = makeRuntime(storage: storage, transport: transport)
            await runtime.start(apiKey: apiKey, consent: .measurementGranted)
            await runtime.track(try AttriKitEvent("status_\(status)"), properties: [:])
            let attempted = await waitForBatchRequest(in: transport)
            XCTAssertTrue(attempted)
            await runtime.shutdown()
            let retainedNames = try await storage.queuedEvents().map(\.eventName)
            XCTAssertEqual(retainedNames, ["status_\(status)"])
        }
    }

    func testClipboardTokenCarriesOptInAndPersistentReplaySetRejectsReuse() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitTokenReplay.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let transport = StubTransport { _, _ in successResult() }
        let token = "ak1_" + String(repeating: "R", count: 43)
        let firstRuntime = makeRuntime(storage: storage, transport: transport)
        await firstRuntime.start(apiKey: apiKey, consent: .trackingGranted)
        let firstOpenSent = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(firstOpenSent)

        let firstResult = await firstRuntime.acceptExactToken(token, kind: "clipboard")
        XCTAssertNotEqual(firstResult, .ignored)
        let capturedRequests = await transport.requests()
        let identify = try XCTUnwrap(capturedRequests.last {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        })
        let identifyBody = try gunzipStored(XCTUnwrap(identify.httpBody))
        let identifyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: identifyBody) as? [String: Any]
        )
        let tokenReference = try XCTUnwrap(identifyJSON["exact_token_ref"] as? [String: Any])
        XCTAssertEqual(tokenReference["kind"] as? String, "clipboard")
        XCTAssertEqual(tokenReference["clipboard_opt_in"] as? Bool, true)

        let identifyCount = await transport.requests().filter {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }.count
        let repeatedResult = await firstRuntime.acceptExactToken(token, kind: "clipboard")
        XCTAssertEqual(repeatedResult, .ignored)
        let identifyCountAfterReplay = await transport.requests().filter {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }.count
        XCTAssertEqual(identifyCountAfterReplay, identifyCount)
        await firstRuntime.shutdown()

        let reloadedStorage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let relaunchedRuntime = makeRuntime(storage: reloadedStorage, transport: transport)
        await relaunchedRuntime.start(apiKey: apiKey, consent: .trackingGranted)
        let relaunchedResult = await relaunchedRuntime.acceptExactToken(token, kind: "clipboard")
        XCTAssertEqual(relaunchedResult, .ignored)
        await relaunchedRuntime.shutdown()

        for index in 0..<129 {
            let inserted = await reloadedStorage.consumeExactTokenIfNew("bounded-token-\(index)")
            XCTAssertTrue(inserted)
        }
        let oldestWasEvicted = await reloadedStorage.consumeExactTokenIfNew("bounded-token-0")
        let newestIsStillPresent = await reloadedStorage.consumeExactTokenIfNew("bounded-token-128")
        XCTAssertTrue(oldestWasEvicted)
        XCTAssertFalse(newestIsStillPresent)
    }

    private func makeRuntime(
        storage: SDKStorage,
        transport: HTTPTransport,
        lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver()
    ) -> CoreRuntime {
        CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() },
            lifecycle: lifecycle
        ))
    }

    private func makeStorage(label: String) -> SDKStorage {
        SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKit\(label).\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
    }

    private func acceptingEventTransport() -> StubTransport {
        StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }
    }

    private func statusTransport(_ status: Int) -> StubTransport {
        StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(status: status, body: #"{"error":"status"}"#)
            }
            return successResult()
        }
    }

    private func waitForBatchRequest(in transport: StubTransport) async -> Bool {
        await waitUntil { await eventBatchRequests(in: transport).count >= 1 }
    }
}

private actor DeletionRetrySequence {
    private var deletionAttempts = 0

    func respond(to request: URLRequest) throws -> HTTPResult {
        guard request.url?.path.hasSuffix("/v1/privacy/delete") == true else {
            return successResult()
        }
        deletionAttempts += 1
        return deletionAttempts == 1
            ? successResult(status: 503, body: #"{"error":"unavailable"}"#)
            : successResult(status: 204, body: "")
    }
}

private actor BatchCommitThenLostResponseSequence {
    private var batchAttempts = 0

    func respond(to request: URLRequest) throws -> HTTPResult {
        guard request.url?.path.contains("events:batch") == true else {
            return successResult()
        }
        batchAttempts += 1
        if batchAttempts == 1 { throw URLError(.networkConnectionLost) }
        return successResult(body: #"{"status":"accepted","inserted":0,"duplicates":1}"#)
    }
}

private actor SuspendedFirstBatchTransport: HTTPTransport {
    private var captured: [URLRequest] = []
    private var batchContinuation: CheckedContinuation<HTTPResult, Error>?

    func send(_ request: URLRequest) async throws -> HTTPResult {
        captured.append(request)
        guard request.url?.path.contains("events:batch") == true,
              batchContinuation == nil else { return successResult(status: 204, body: "") }
        return try await withCheckedThrowingContinuation { continuation in
            batchContinuation = continuation
        }
    }

    func requests() -> [URLRequest] { captured }

    func releaseBatch(with result: HTTPResult) {
        let continuation = batchContinuation
        batchContinuation = nil
        continuation?.resume(returning: result)
    }
}

private enum RuntimeCleanupFailure: Error {
    case simulated
}

private func makeEvent(name: String, identity: InstallationIdentity) -> EventEnvelope {
    EventEnvelope(
        eventID: UUID(),
        eventName: name,
        eventVersion: 1,
        occurredAt: Date(),
        sentAt: Date(),
        installationID: identity.installationID,
        installEpochID: identity.installEpochID,
        sessionID: UUID(),
        consent: EventConsent(measurement: "granted", tracking: "denied", policyVersion: 1),
        properties: [:]
    )
}

private func eventBatchRequests(in transport: StubTransport) async -> [URLRequest] {
    await transport.requests().filter { $0.url?.path.contains("events:batch") == true }
}

private func decodedEvents(in transport: StubTransport) async -> [[String: Any]] {
    var events: [[String: Any]] = []
    for request in await eventBatchRequests(in: transport) {
        guard let compressed = request.httpBody,
              let body = try? gunzipStored(compressed),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let batch = json["events"] as? [[String: Any]] else { continue }
        events.append(contentsOf: batch)
    }
    return events
}

private func waitForEvent(named name: String, count: Int, in transport: StubTransport) async -> Bool {
    await waitUntil {
        await decodedEvents(in: transport).filter { $0["event_name"] as? String == name }.count == count
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
