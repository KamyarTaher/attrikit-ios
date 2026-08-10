import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
#if canImport(OSLog)
import OSLog
#endif
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

    func testSplitPendingBatchBisectsWithFreshIdempotencyKeyAndDropsNothing() async throws {
        let storage = makeStorage(label: "SplitPrimitive")
        let identity = try await storage.initializeIdentities()
        let events = (0..<4).map { makeEvent(name: "e\($0)", identity: identity) }
        for event in events { try await storage.enqueue(event) }

        let batchValue = try await storage.nextEventBatch()
        let batch = try XCTUnwrap(batchValue)
        XCTAssertEqual(batch.events.count, 4)

        try await storage.splitPendingBatch(batchID: batch.batchID)
        let halvedValue = try await storage.nextEventBatch()
        let halved = try XCTUnwrap(halvedValue)
        XCTAssertEqual(halved.events.count, 2, "batch must be bisected")
        XCTAssertNotEqual(halved.batchID, batch.batchID, "changed body needs a fresh idempotency key")
        let queuedCount = try await storage.queuedEvents().count
        XCTAssertEqual(queuedCount, 4, "no event may be dropped by a split")

        // Deliver the first half, then keep bisecting the rest down to the single poison.
        try await storage.acknowledgeEventBatch(batchID: halved.batchID)
        let restValue = try await storage.nextEventBatch()
        let rest = try XCTUnwrap(restValue)
        XCTAssertEqual(rest.events.count, 2)
        try await storage.splitPendingBatch(batchID: rest.batchID)
        let singleValue = try await storage.nextEventBatch()
        let single = try XCTUnwrap(singleValue)
        XCTAssertEqual(single.events.count, 1)
        // Splitting a single-event batch is a no-op: genuine poison stays put to be dropped.
        try await storage.splitPendingBatch(batchID: single.batchID)
        let stillSingleValue = try await storage.nextEventBatch()
        let stillSingle = try XCTUnwrap(stillSingleValue)
        XCTAssertEqual(stillSingle.events.count, 1)
    }

    func testNextEventBatchCapsAccumulatedBytesBelowServerLimit() async throws {
        let storage = makeStorage(label: "ByteCeiling")
        let identity = try await storage.initializeIdentities()
        let filler = String(repeating: "x", count: 900)
        for index in 0..<80 {
            try await storage.enqueue(makeEvent(name: "big_\(index)", identity: identity, properties: ["blob": .string(filler)]))
        }
        let total = try await storage.queuedEvents().count
        XCTAssertEqual(total, 80)

        let batchValue = try await storage.nextEventBatch()
        let batch = try XCTUnwrap(batchValue)
        XCTAssertLessThan(batch.events.count, total, "an oversized queue must not be sent as one batch")
        let encoded = try attriKitJSONEncoder().encode(EventBatch(batchID: batch.batchID, events: batch.events))
        XCTAssertLessThanOrEqual(encoded.count, 56 * 1024, "batch payload must stay under the client ceiling")
    }

    func testPermanentFailureOnMultiEventBatchBisectsAndDeliversAllSiblings() async throws {
        let storage = makeStorage(label: "Bisect413")
        // A 413 for any multi-event batch (an oversized/poison sibling), 2xx for a lone event.
        let transport = StubTransport { request, _ in
            guard request.url?.path.contains("events:batch") == true else { return successResult() }
            let body = try gunzipStored(XCTUnwrap(request.httpBody))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let count = (json?["events"] as? [[String: Any]])?.count ?? 0
            if count > 1 { return successResult(status: 413, body: #"{"error":"payload_too_large"}"#) }
            return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
        }
        let identity = try await storage.initializeIdentities()
        let first = makeEvent(name: "alpha", identity: identity)
        let second = makeEvent(name: "beta", identity: identity)
        try await storage.enqueue(first)
        try await storage.enqueue(second)

        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        // Pre-fix acked the whole 2-event batch on the 413 and silently dropped both valid
        // events. Post-fix bisects, retries, and drains only after every sibling is delivered.
        let drained = await waitUntil(timeout: .seconds(5)) {
            (try? await storage.queuedEvents().isEmpty) == true
        }
        XCTAssertTrue(drained)

        let batches = await batchRequestEventIDs(in: transport)
        XCTAssertTrue(batches.contains { $0.count > 1 }, "the oversized batch must have been attempted")
        let deliveredAsSingle = Set(batches.filter { $0.count == 1 }.flatMap { $0 })
        XCTAssertTrue(deliveredAsSingle.contains(first.eventID), "first sibling must survive and be delivered")
        XCTAssertTrue(deliveredAsSingle.contains(second.eventID), "second sibling must survive and be delivered")
        await runtime.shutdown()
    }

    func testPermanentFailureOnASingleEventBatchReportsTheDrop() async throws {
        #if canImport(OSLog)
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let startPosition = store.position(date: Date())

        let storage = makeStorage(label: "SingleEventDrop")
        let identity = try await storage.initializeIdentities()
        try await storage.enqueue(makeEvent(name: "session_end", identity: identity))

        let runtime = makeRuntime(storage: storage, transport: statusTransport(422))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let drained = await waitUntil(timeout: .seconds(5)) {
            (try? await storage.queuedEvents().isEmpty) == true
        }
        XCTAssertTrue(drained, "a permanent 4xx on a lone event must still drain the queue")

        var reported = false
        for _ in 0..<12 where !reported {
            let entries = try store.getEntries(at: startPosition)
            for entry in entries
            where entry.composedMessage.contains("permanently dropping event 'session_end'") {
                reported = true
                break
            }
            if !reported { try? await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(reported, "the destroyed event must be reported, not lost silently")
        await runtime.shutdown()
        #else
        // Without this the whole test body compiles away and the test PASSES having asserted
        // nothing, which reads as coverage of the drop report on platforms that have none.
        throw XCTSkip("OSLogStore is required to observe the drop report")
        #endif
    }

    /// The customer-reported cold-launch race, modelled against a server that answers TRUTHFULLY:
    /// `events:batch` is 422 `unknown_install_epoch` until `first-open` has registered the epoch,
    /// and 200 afterwards. Before the fix the SDK dispatched the batch concurrently with
    /// first-open, took the permanent-4xx path on the 422 and DELETED the event, so an
    /// `attribution_test` tracked during launch never reached the server at all. Reproduced in
    /// production by proxying a live app's traffic (InkLine, August 2026).
    func testEventsTrackedBeforeFirstOpenRegistersTheEpochAreDeliveredNotDestroyed() async throws {
        let epochGate = EpochRegistrationGate()
        let transport = StubTransport { request, _ in
            guard let path = request.url?.path else { return successResult() }
            if path.contains("first-open") {
                // First-open is a NETWORK ROUND TRIP, and the defect lives entirely inside the
                // window it is open for. A stub that answers instantly cannot reproduce it: both
                // tasks hop the same serial actor, first-open wins every time, and the test then
                // passes against the broken code. Measured — without this delay this test passed
                // against pre-fix HEAD in 0.038s, i.e. it asserted nothing. The customer's proxy
                // log shows both event batches leaving before first-open's 202 came back.
                try? await Task.sleep(for: .milliseconds(300))
                epochGate.register()
                return successResult()
            }
            if path.contains("events:batch") {
                guard epochGate.isRegistered else {
                    return successResult(status: 422, body: #"{"error":"unknown_install_epoch"}"#)
                }
                epochGate.recordAccepted(eventIDs(inGzippedBody: request.httpBody))
                return successResult(status: 200, body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }

        let storage = makeStorage(label: "EpochRace")
        let identity = try await storage.initializeIdentities()
        let tracked = makeEvent(name: "attribution_test", identity: identity)
        try await storage.enqueue(tracked)

        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let drained = await waitUntil(timeout: .seconds(10)) {
            (try? await storage.queuedEvents().isEmpty) == true
        }
        XCTAssertTrue(drained, "the queue must drain once the epoch is registered")

        // The decisive assertion. Draining alone is what the BUG did — it drained by deleting.
        // The event must have been ACCEPTED by the server, not destroyed to make room.
        XCTAssertTrue(
            epochGate.acceptedEventIDs.contains(tracked.eventID),
            "the event tracked before first-open must be delivered and accepted, never dropped"
        )
        await runtime.shutdown()
    }

    /// A consent receipt raised while first-open is still in flight — an ATT prompt answered in
    /// the first seconds of a launch — must survive. It rides the same epoch race, and before the
    /// fix it was fire-and-forget behind a `try?`: the 422 was swallowed with no queue and no log,
    /// so a compliance artifact vanished more quietly than a dropped event.
    func testConsentReceiptRaisedBeforeTheEpochIsRegisteredIsStillDelivered() async throws {
        let epochGate = EpochRegistrationGate()
        let transport = StubTransport { request, _ in
            guard let path = request.url?.path else { return successResult() }
            if path.contains("first-open") {
                try? await Task.sleep(for: .milliseconds(300))
                epochGate.register()
                return successResult()
            }
            if path.contains("ingest/consent") {
                guard epochGate.isRegistered else {
                    return successResult(status: 422, body: #"{"error":"unknown_install_epoch"}"#)
                }
                epochGate.recordAcceptedConsent()
                return successResult(status: 200, body: #"{"status":"accepted"}"#)
            }
            return successResult()
        }

        let storage = makeStorage(label: "ConsentRace")
        _ = try await storage.initializeIdentities()
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        // Inside the first-open window, exactly where an ATT answer lands.
        await runtime.setConsent(.trackingGranted)

        let delivered = await waitUntil(timeout: .seconds(10)) { epochGate.acceptedConsentCount > 0 }
        XCTAssertTrue(delivered, "a consent receipt raised before the epoch existed must still be delivered")
        // Exactly one. `> 0` would also pass if the replay double-posted, and a duplicated consent
        // receipt is its own defect in a ledger.
        XCTAssertEqual(epochGate.acceptedConsentCount, 1, "the deferred receipt must be replayed once, not duplicated")
        await runtime.shutdown()
    }

    /// A receipt must survive process termination after an offline delivery attempt. Replaying it
    /// must use the original idempotency key so a server acknowledgement lost before local cleanup
    /// cannot create a second legal record.
    func testConsentReceiptPersistsBeforeDeliveryAndRelaunchReusesItsIdentity() async throws {
        let defaults = UserDefaults(suiteName: "AttriKitConsentReceipt.\(UUID())")!
        let keychain = MemoryKeychain()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstStorage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let offlineTransport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/consent") == true {
                throw URLError(.notConnectedToInternet)
            }
            return successResult()
        }
        let firstRuntime = makeRuntime(storage: firstStorage, transport: offlineTransport)
        await firstRuntime.start(apiKey: apiKey, consent: .measurementGranted)
        let firstOpenRegistered = await waitUntil {
            await offlineTransport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/first-open") == true
            }
        }
        XCTAssertTrue(firstOpenRegistered)

        await firstRuntime.setConsent(.trackingGranted)
        let attemptedOffline = await waitUntil {
            await offlineTransport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/consent") == true
            }
        }
        XCTAssertTrue(attemptedOffline)
        let pendingBeforeTermination = try await firstStorage.pendingConsentReceipts()
        XCTAssertEqual(pendingBeforeTermination.count, 1, "the receipt must be durable before transport starts")
        await firstRuntime.shutdown()

        let offlineRequests = await offlineTransport.requests()
        let firstKey = try XCTUnwrap(
            offlineRequests.last { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }?
                .value(forHTTPHeaderField: "Idempotency-Key")
        )

        let secondStorage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let onlineTransport = StubTransport { _, _ in successResult() }
        let secondRuntime = makeRuntime(storage: secondStorage, transport: onlineTransport)
        await secondRuntime.start(apiKey: apiKey, consent: .trackingGranted)

        let deliveredAfterRelaunch = await waitUntil {
            await onlineTransport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/consent") == true
            }
        }
        XCTAssertTrue(deliveredAfterRelaunch, "a relaunch must drain the durable receipt queue")
        let onlineRequests = await onlineTransport.requests()
        let secondKey = try XCTUnwrap(
            onlineRequests.last { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }?
                .value(forHTTPHeaderField: "Idempotency-Key")
        )
        XCTAssertEqual(secondKey, firstKey, "replay must preserve the receipt's stable identity")
        let pendingAfterDelivery = try await secondStorage.pendingConsentReceipts()
        XCTAssertTrue(pendingAfterDelivery.isEmpty, "a 2xx acknowledgement must remove the queued receipt")
        await secondRuntime.shutdown()
    }

    func testWithdrawalReceiptIsDeliveredWithPreWithdrawalIdentityBeforeRotation() async throws {
        let storage = makeStorage(label: "WithdrawalDelivery")
        let originalIdentity = try await storage.initializeIdentities()
        let observation = ConsentReceiptObservation()
        let transport = StubTransport { request, _ in
            let path = request.url?.path ?? ""
            if path.contains("events:batch") {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            if path.hasSuffix("/v1/ingest/consent") {
                let compressed = try XCTUnwrap(request.httpBody)
                let body = try gunzipStored(compressed)
                let identityAtDelivery = try await storage.initializeIdentities()
                await observation.record(body: body, identity: identityAtDelivery)
                return successResult(status: 200, body: #"{"status":"accepted","processing_stopped":true}"#)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("before_withdrawal"), properties: [:])
        let registered = await waitForBatchRequest(in: transport)
        XCTAssertTrue(registered, "precondition: the original epoch must be registered")

        await runtime.setConsent(.revoked)

        let delivered = await waitUntil { await observation.count == 1 }
        XCTAssertTrue(delivered, "the withdrawal receipt must be delivered while measurement consent is false")
        guard delivered, let delivery = await observation.first else {
            await runtime.shutdown()
            return
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: delivery.body) as? [String: Any])
        let consent = try XCTUnwrap(json["consent"] as? [String: Any])
        XCTAssertEqual(consent["state"] as? String, AttriKitConsent.revoked.rawValue)
        XCTAssertEqual((json["installation_id"] as? String).flatMap(UUID.init(uuidString:)), originalIdentity.installationID)
        XCTAssertEqual((json["install_epoch_id"] as? String).flatMap(UUID.init(uuidString:)), originalIdentity.installEpochID)
        XCTAssertEqual(delivery.identity.installEpochID, originalIdentity.installEpochID)
        XCTAssertFalse(CoreRuntime.bodyCarriesIdfa(delivery.body), "a withdrawal receipt must never carry IDFA")

        let rotatedIdentity = try await storage.initializeIdentities()
        XCTAssertNotEqual(rotatedIdentity.installEpochID, originalIdentity.installEpochID)
        await runtime.shutdown()
    }

    func testDenialReceiptIsDeliveredWhileMeasurementConsentIsOff() async throws {
        let storage = makeStorage(label: "DenialDelivery")
        let originalIdentity = try await storage.initializeIdentities()
        let observation = ConsentReceiptObservation()
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            if request.url?.path.hasSuffix("/v1/ingest/consent") == true {
                let body = try gunzipStored(XCTUnwrap(request.httpBody))
                let identityAtDelivery = try await storage.initializeIdentities()
                await observation.record(body: body, identity: identityAtDelivery)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("before_denial_receipt"), properties: [:])
        let registered = await waitForBatchRequest(in: transport)
        XCTAssertTrue(registered, "precondition: the original epoch must be registered")

        await runtime.setConsent(.denied)

        let delivered = await waitUntil { await observation.states == [.denied] }
        XCTAssertTrue(delivered, "the denial receipt must be delivered while measurement consent is false")
        guard delivered, let delivery = await observation.first else {
            await runtime.shutdown()
            return
        }
        XCTAssertEqual(delivery.identity.installationID, originalIdentity.installationID)
        XCTAssertEqual(delivery.identity.installEpochID, originalIdentity.installEpochID)
        XCTAssertFalse(CoreRuntime.bodyCarriesIdfa(delivery.body), "a denial receipt must never carry IDFA")
        await runtime.shutdown()
    }

    func testGrantReceiptStaysGatedWhileWithdrawalBypassesItWhenConsentIsOff() async throws {
        let storage = makeStorage(label: "ConsentReceiptKinds")
        let identity = try await storage.initializeIdentities()
        try await storage.enqueueConsentReceipt(StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "tracking",
            state: .trackingGranted,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try await storage.enqueueConsentReceipt(StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "measurement",
            state: .revoked,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        let observation = ConsentReceiptObservation()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/consent") == true {
                let body = try gunzipStored(XCTUnwrap(request.httpBody))
                await observation.record(body: body, identity: identity)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)

        await runtime.start(apiKey: apiKey, consent: .denied)

        let withdrawalDelivered = await waitUntil { await observation.states == [.revoked] }
        XCTAssertTrue(withdrawalDelivered, "the withdrawal must bypass a queued grant while consent is off")
        guard withdrawalDelivered else {
            await runtime.shutdown()
            return
        }
        let pendingWhileDenied = try await storage.pendingConsentReceipts()
        XCTAssertTrue(pendingWhileDenied.isEmpty, "the acknowledged withdrawal must supersede an older same-epoch grant")

        await runtime.setConsent(.measurementGranted)
        try? await Task.sleep(for: .milliseconds(100))
        let statesAfterRegrant = await observation.states
        XCTAssertEqual(statesAfterRegrant, [.revoked], "a stale grant must not restore processing for the withdrawn epoch")
        let pendingAfterGrant = try await storage.pendingConsentReceipts()
        XCTAssertTrue(pendingAfterGrant.isEmpty)
        await runtime.shutdown()
    }

    func testDeletionPendingSuppressesGrantAndWithdrawalReceipts() async throws {
        let storage = makeStorage(label: "DeletionSuppressesConsent")
        let transport = SuspendedDeletionTransport()
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let firstOpenStarted = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(firstOpenStarted)

        let deletion = Task { try await runtime.deleteData() }
        let deletionStarted = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/privacy/delete") == true }
        }
        XCTAssertTrue(deletionStarted)

        await runtime.setConsent(.trackingGranted)
        await runtime.setConsent(.revoked)
        try? await Task.sleep(for: .milliseconds(50))

        let consentRequests = await transport.requests().filter {
            $0.url?.path.hasSuffix("/v1/ingest/consent") == true
        }
        XCTAssertTrue(consentRequests.isEmpty, "deletionPending must suppress every consent receipt")
        let pendingDuringDeletion = try await storage.pendingConsentReceipts()
        XCTAssertTrue(pendingDuringDeletion.isEmpty, "deletionPending must suppress both grant and withdrawal persistence")

        await transport.releaseDeletion()
        try await deletion.value
        await runtime.shutdown()

        let controlStorage = makeStorage(label: "DeletionSuppressionControl")
        let controlIdentity = try await controlStorage.initializeIdentities()
        try await controlStorage.enqueueConsentReceipt(StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: controlIdentity.installationID,
            installEpochID: controlIdentity.installEpochID,
            scope: "measurement",
            state: .denied,
            occurredAt: Date()
        ))
        let controlTransport = StubTransport { _, _ in successResult() }
        let controlRuntime = makeRuntime(storage: controlStorage, transport: controlTransport)
        await controlRuntime.start(apiKey: apiKey, consent: .denied)
        let controlDelivered = await waitUntil {
            await controlTransport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }
        }
        XCTAssertTrue(controlDelivered, "control: the same withdrawal receipt must deliver without deletionPending")
        await controlRuntime.shutdown()
    }

    func testWithdrawalReceiptMakesOneBoundedAttemptAndStaysQueuedWithout2xx() async throws {
        let storage = makeStorage(label: "WithdrawalRetryBound")
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            if request.url?.path.hasSuffix("/v1/ingest/consent") == true {
                return successResult(status: 503, body: #"{"error":"unavailable"}"#)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("before_failed_withdrawal"), properties: [:])
        let registered = await waitForBatchRequest(in: transport)
        XCTAssertTrue(registered, "precondition: the original epoch must be registered")

        await runtime.setConsent(.revoked)
        try? await Task.sleep(for: .milliseconds(100))

        let attempts = await transport.requests().filter {
            $0.url?.path.hasSuffix("/v1/ingest/consent") == true
        }
        XCTAssertEqual(attempts.count, 1, "a consent-off drain must make one bounded attempt, not spin")
        let pending = try await storage.pendingConsentReceipts()
        XCTAssertEqual(pending.map(\.state), [.revoked], "a non-2xx response must leave the receipt stored")
        await runtime.shutdown()
    }

    /// A RELAUNCH must keep delivering events. The SDK rebuilds the first-open envelope with a
    /// fresh occurred_at every launch, so its payload hash differs from launch 1 and the server
    /// answers 409 idempotency_conflict. That 409 proves the epoch EXISTS — it is a registration,
    /// not a refusal — and the queue must flush. Classifying it with the other terminal 4xx parked
    /// every relaunch's events for the life of the install, which is a regression the delivery gate
    /// itself introduced: before the gate, the flush simply proceeded and the events were accepted.
    func testARelaunchAnsweredWithIdempotencyConflictStillDeliversEvents() async throws {
        let accepted = EpochRegistrationGate()
        let transport = StubTransport { request, _ in
            guard let path = request.url?.path else { return successResult() }
            if path.contains("first-open") {
                // The epoch was registered on a previous launch; this launch's differing payload
                // hash conflicts. Exactly what a real second launch receives.
                return successResult(status: 409, body: #"{"error":"idempotency_conflict"}"#)
            }
            if path.contains("events:batch") {
                accepted.recordAccepted(eventIDs(inGzippedBody: request.httpBody))
                return successResult(status: 200, body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            return successResult()
        }

        let storage = makeStorage(label: "RelaunchConflict")
        let identity = try await storage.initializeIdentities()
        let tracked = makeEvent(name: "attribution_test", identity: identity)
        try await storage.enqueue(tracked)

        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let delivered = await waitUntil(timeout: .seconds(10)) {
            accepted.acceptedEventIDs.contains(tracked.eventID)
        }
        XCTAssertTrue(delivered, "a relaunch that conflicts must still deliver: the epoch exists")
        await runtime.shutdown()
    }

    /// A first-open the server REFUSES must not open the delivery gate. Two independent reviewers
    /// caught this in the first version of the fix: it settled on any terminal 4xx, on the
    /// reasoning that the queue would then drain by dropping loudly. That reasoning was wrong,
    /// because the server answers an unregistered epoch with a RETRIABLE status — so releasing the
    /// queue would have retried an impossible request every 60s for the life of the install,
    /// head-of-line blocking every later event, forever, with no telemetry. Refused is not
    /// registered.
    func testAFirstOpenTheServerRefusesNeverOpensTheDeliveryGate() async throws {
        let transport = StubTransport { request, _ in
            guard let path = request.url?.path else { return successResult() }
            if path.contains("first-open") {
                return successResult(status: 400, body: #"{"error":"validation_failed","issues":[]}"#)
            }
            return successResult(status: 503, body: #"{"error":"unknown_install_epoch","retriable":true}"#)
        }

        let storage = makeStorage(label: "RefusedFirstOpen")
        let identity = try await storage.initializeIdentities()
        try await storage.enqueue(makeEvent(name: "attribution_test", identity: identity))

        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        // Give the (incorrect) release every chance to happen before asserting it did not.
        let leaked = await waitUntil(timeout: .seconds(3)) {
            await !eventBatchRequests(in: transport).isEmpty
        }
        XCTAssertFalse(leaked, "no batch may be sent for an epoch the server refused to register")
        let stillQueued = try await storage.queuedEvents()
        XCTAssertEqual(stillQueued.count, 1, "the event is held for a later launch, not destroyed and not sent")
        await runtime.shutdown()
    }

    /// identify is reachable from four public entry points during a cold launch, discards its
    /// response, and mutates an occurrence that does not exist yet — so before the fix a
    /// setUserID() at launch was a silent no-op, taking the RevenueCat join key with it.
    func testIdentifyRaisedBeforeRegistrationIsDeferredAndThenSent() async throws {
        let epochGate = EpochRegistrationGate()
        let transport = StubTransport { request, _ in
            guard let path = request.url?.path else { return successResult() }
            if path.contains("first-open") {
                try? await Task.sleep(for: .milliseconds(300))
                epochGate.register()
                return successResult()
            }
            if path.contains("ingest/identify") {
                guard epochGate.isRegistered else {
                    return successResult(status: 503, body: #"{"error":"unknown_install_epoch","retriable":true}"#)
                }
                epochGate.recordAcceptedConsent()
                return successResult(status: 200, body: #"{"status":"accepted"}"#)
            }
            return successResult()
        }

        let storage = makeStorage(label: "IdentifyRace")
        _ = try await storage.initializeIdentities()
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.setUserID("rc-app-user-id")

        let accepted = await waitUntil(timeout: .seconds(10)) { epochGate.acceptedConsentCount > 0 }
        XCTAssertTrue(accepted, "identify raised during a cold launch must reach the server once the epoch exists")
        await runtime.shutdown()
    }

    /// The discriminator is deliberately narrow, so pin BOTH directions: 422 with this one error
    /// string is a race and retriable, and everything adjacent to it stays permanent. Without the
    /// negative cases this test would pass against a function that simply returned true.
    func testUnknownInstallEpochIsRecognisedWithoutWideningAnyOther422() throws {
        XCTAssertTrue(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 422, body: #"{"error":"unknown_install_epoch"}"#)
        ))
        XCTAssertFalse(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 422, body: #"{"error":"validation_failed","issues":[]}"#)
        ), "a genuine validation failure must stay permanent")
        XCTAssertFalse(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 422, body: #"{"error":"measurement_consent_required"}"#)
        ), "a consent refusal must stay permanent")
        XCTAssertFalse(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 400, body: #"{"error":"unknown_install_epoch"}"#)
        ), "the status is part of the contract, not just the body")
        XCTAssertFalse(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 422, body: "")
        ), "an empty body must never be promoted into an infinite retry")
        XCTAssertFalse(CoreRuntime.isUnknownInstallEpoch(
            successResult(status: 422, body: "<html>gateway</html>")
        ), "an unparseable body must never be promoted into an infinite retry")
    }

    private func batchRequestEventIDs(in transport: StubTransport) async -> [[UUID]] {
        var result: [[UUID]] = []
        for request in await eventBatchRequests(in: transport) {
            guard let body = request.httpBody,
                  let json = try? gunzipStored(body),
                  let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let events = obj["events"] as? [[String: Any]] else { continue }
            result.append(events.compactMap { ($0["event_id"] as? String).flatMap(UUID.init(uuidString:)) })
        }
        return result
    }

    // SCOPE, stated because a codex review caught me overclaiming this one. This pins the
    // PRE-EXISTING 16...512 guard, which had no coverage at all, so nothing distinguished it from a
    // build that accepted any key. It does NOT verify the os_log(.fault) added alongside it: the
    // suite has no diagnostic sink, so that log line is unverified by this or any test here, and
    // this test passes against the code as it stood before that log existed.
    //
    // The valid-key half is what stops the first assertion being vacuous: "no requests were made"
    // passes trivially against a harness that never sends anything under any key.
    func testApiKeyOutsideAcceptedLengthSendsNothingWhileAValidKeyReachesTheTransport() async throws {
        let rejectedTransport = StubTransport { _, _ in successResult() }
        let rejectedRuntime = makeRuntime(storage: makeStorage(label: "ShortKey"), transport: rejectedTransport)
        await rejectedRuntime.start(apiKey: String(repeating: "k", count: 15), consent: .measurementGranted)
        _ = await waitUntil(timeout: .milliseconds(300)) { await !rejectedTransport.requests().isEmpty }
        let rejectedRequests = await rejectedTransport.requests()
        XCTAssertTrue(rejectedRequests.isEmpty, "a 15-byte api key must not start measurement")
        await rejectedRuntime.shutdown()

        let acceptedTransport = StubTransport { _, _ in successResult() }
        let acceptedRuntime = makeRuntime(storage: makeStorage(label: "ValidKey"), transport: acceptedTransport)
        await acceptedRuntime.start(apiKey: apiKey, consent: .measurementGranted)
        let reached = await waitUntil { await !acceptedTransport.requests().isEmpty }
        XCTAssertTrue(reached, "control: a 20-byte api key must reach the transport")
        await acceptedRuntime.shutdown()
    }

    // submitFirstOpen installs its RETRY task into `firstOpenTask`, and its caller then ran
    // `clearFirstOpenTask()` and nilled that slot, orphaning a live task. The slot read as empty, so
    // the foreground re-arm started a second chain beside the first, and each foreground during a
    // retry gap added another. They all wake at the same deadline and burn the ladder together.
    //
    // The wait below is real seconds because firstOpenRetryDelays[0] is 5 and Task.sleep does not
    // honour the injected clock: a second chain is INVISIBLE until it fires, so asserting before
    // then would pass against the bug.
    func testForegroundingDuringARetryGapDoesNotStartASecondFirstOpenChain() async throws {
        let storage = makeStorage(label: "RetrySlot")
        let lifecycle = ManualLifecycleObserver()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                throw URLError(.notConnectedToInternet)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport, lifecycle: lifecycle)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let attempted = await waitUntil { await self.firstOpenRequestCount(in: transport) >= 1 }
        XCTAssertTrue(attempted, "precondition: first-open must be attempted once")
        let scheduled = await waitUntil { await storage.retryState() != nil }
        XCTAssertTrue(scheduled, "precondition: the failure must have scheduled a retry")
        let beforeForeground = await firstOpenRequestCount(in: transport)
        XCTAssertEqual(beforeForeground, 1)

        await lifecycle.send(.didBecomeActive)
        await lifecycle.send(.didBecomeActive)

        // Past the 5s first rung, before the 30s second one.
        _ = await waitUntil(timeout: .seconds(9)) { await self.firstOpenRequestCount(in: transport) >= 2 }
        let total = await firstOpenRequestCount(in: transport)
        XCTAssertEqual(total, 2, "exactly one scheduled retry may fire; extra chains mean the slot was orphaned")
        await runtime.shutdown()
    }

    private func firstOpenRequestCount(in transport: StubTransport) async -> Int {
        await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }.count
    }

    // CONTRACT CHANGED, deliberately, and this test changed with it. It used to assert that a
    // deferred accept left the token .ignored on a second call, which was only true because the
    // token was consumed BEFORE the network call. That ordering meant a process killed mid-flight
    // burned the only deterministic attribution signal the SDK has, with no failure for anything to
    // react to. The token is now spent only on acknowledgement, so staying re-acceptable until then
    // is the fix rather than a regression.
    //
    // What must still hold: an acknowledged token IS spent, so it cannot be delivered twice across
    // relaunches.
    func testATokenIsSpentOnlyOnceTheIdentifyCarryingItIsAcknowledged() async throws {
        let storage = makeStorage(label: "TokenSpendOnAck")
        let transport = StubTransport { _, _ in successResult() }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(registered, "precondition: first-open must register so identify is not deferred")

        let token = "ak1_" + String(repeating: "S", count: 43)
        let startsUnspent = await storage.isExactTokenNew(token)
        XCTAssertTrue(startsUnspent, "precondition: the token starts unspent")

        let accepted = await runtime.acceptExactToken(token, kind: "clipboard")
        XCTAssertNotEqual(accepted, .ignored)
        let delivered = await waitUntil { await self.identifyRequestCount(in: transport) >= 1 }
        XCTAssertTrue(delivered, "the identify carrying the token must have been sent")

        // Acknowledged, so now it is spent and a repeat is refused.
        let stillUnspent = await storage.isExactTokenNew(token)
        XCTAssertFalse(
            stillUnspent,
            "an acknowledged token must be spent, or it could be delivered again after a relaunch",
        )
        let repeated = await runtime.acceptExactToken(token, kind: "clipboard")
        XCTAssertEqual(repeated, .ignored, "a spent token must be refused")
        await runtime.shutdown()
    }

    // The other half of the same contract: while the identify has NOT been acknowledged, the token
    // stays unspent, so a launch that dies before delivery can retry it instead of losing it.
    func testAnUndeliveredTokenStaysUnspent() async throws {
        let storage = makeStorage(label: "TokenUnspentOnFailure")
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/identify") == true {
                throw URLError(.notConnectedToInternet)
            }
            return successResult()
        }
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.start(apiKey: apiKey, consent: .trackingGranted)
        _ = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }

        let token = "ak1_" + String(repeating: "U", count: 43)
        _ = await runtime.acceptExactToken(token, kind: "clipboard")
        _ = await waitUntil { await self.identifyRequestCount(in: transport) >= 1 }

        let unspentAfterFailure = await storage.isExactTokenNew(token)
        XCTAssertTrue(
            unspentAfterFailure,
            "an unacknowledged token must stay unspent so a later attempt can carry it",
        )
        await runtime.shutdown()
    }

    private func identifyRequestCount(in transport: StubTransport) async -> Int {
        await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/identify") == true }.count
    }

    // enqueue() read the queue with `try?`, so a file that EXISTS but cannot be read fell back to
    // an empty queue, and the write at the end of enqueue replaced every stored event with the one
    // being added. On iOS the common cause is not exotic: writeQueue sets
    // NSFileProtectionCompleteUntilFirstUserAuthentication, so a background launch before the first
    // unlock after a reboot cannot read that file.
    //
    // chmod 000 reproduces exactly that condition, an existing file whose bytes are unreadable.
    func testAnUnreadableQueueFileRefusesTheEventInsteadOfDiscardingTheQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitUnreadableQueue.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: directory
        )
        let identity = try await storage.initializeIdentities()
        let survivor = makeEvent(name: "already_queued", identity: identity)
        try await storage.enqueue(survivor)

        let queueURL = directory
            .appendingPathComponent("AttriKit", isDirectory: true)
            .appendingPathComponent("events-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueURL.path), "precondition: the queue file exists")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: queueURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueURL.path) }

        do {
            _ = try await storage.enqueue(makeEvent(name: "arrives_while_unreadable", identity: identity))
            XCTFail("an unreadable queue file must refuse the event rather than silently resetting the queue")
        } catch {
            // Expected: the caller in CoreRuntime already treats a throw as "this event was refused".
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueURL.path)
        let remaining = try await storage.queuedEvents()
        XCTAssertEqual(
            remaining.map(\.eventID),
            [survivor.eventID],
            "the previously queued event must survive a read failure"
        )
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

private actor SuspendedDeletionTransport: HTTPTransport {
    private var captured: [URLRequest] = []
    private var deletionContinuation: CheckedContinuation<HTTPResult, Error>?

    func send(_ request: URLRequest) async throws -> HTTPResult {
        captured.append(request)
        guard request.url?.path.hasSuffix("/v1/privacy/delete") == true else {
            return successResult()
        }
        return try await withCheckedThrowingContinuation { continuation in
            deletionContinuation = continuation
        }
    }

    func requests() -> [URLRequest] { captured }

    func releaseDeletion() {
        let continuation = deletionContinuation
        deletionContinuation = nil
        continuation?.resume(returning: successResult(status: 204, body: ""))
    }
}

private actor ConsentReceiptObservation {
    struct Delivery: Sendable {
        let body: Data
        let identity: InstallationIdentity
    }

    private var deliveries: [Delivery] = []

    var count: Int { deliveries.count }
    var first: Delivery? { deliveries.first }
    var states: [AttriKitConsent] {
        deliveries.compactMap { delivery in
            guard let json = try? JSONSerialization.jsonObject(with: delivery.body) as? [String: Any],
                  let consent = json["consent"] as? [String: Any],
                  let rawState = consent["state"] as? String else { return nil }
            return AttriKitConsent(rawValue: rawState)
        }
    }

    func record(body: Data, identity: InstallationIdentity) {
        deliveries.append(Delivery(body: body, identity: identity))
    }
}

private enum RuntimeCleanupFailure: Error {
    case simulated
}

private func makeEvent(
    name: String,
    identity: InstallationIdentity,
    properties: [String: AttriKitValue] = [:]
) -> EventEnvelope {
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
        properties: properties
    )
}

/// Models the one piece of server state this race turns on: whether `first-open` has registered
/// the epoch yet. The transport responder is `@Sendable` and runs off the test's actor, so the
/// flag and the accepted-id set are lock-guarded rather than actor-isolated.
private final class EpochRegistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var registered = false
    private var accepted: Set<UUID> = []
    private var acceptedConsent = 0

    var isRegistered: Bool {
        lock.lock(); defer { lock.unlock() }
        return registered
    }

    var acceptedEventIDs: Set<UUID> {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }

    func register() {
        lock.lock(); defer { lock.unlock() }
        registered = true
    }

    func recordAccepted(_ ids: [UUID]) {
        lock.lock(); defer { lock.unlock() }
        accepted.formUnion(ids)
    }

    var acceptedConsentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return acceptedConsent
    }

    func recordAcceptedConsent() {
        lock.lock(); defer { lock.unlock() }
        acceptedConsent += 1
    }
}

private func eventIDs(inGzippedBody body: Data?) -> [UUID] {
    guard let body,
          let json = try? gunzipStored(body),
          let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
          let events = object["events"] as? [[String: Any]] else { return [] }
    return events.compactMap { ($0["event_id"] as? String).flatMap(UUID.init(uuidString:)) }
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
