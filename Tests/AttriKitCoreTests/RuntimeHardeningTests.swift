import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

@MainActor
final class RuntimeHardeningTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    /// Every case here mints a UUID-named UserDefaults suite and a temp directory, and nothing
    /// removed either: one plist per case accumulated in the host's preferences and one directory
    /// per case in the temp dir, for every run this suite has ever had. They are recorded AT
    /// CREATION because that is the only way the cleanup can exist -- `removePersistentDomain` needs
    /// the exact suite name, and a name generated inline is unrecoverable the moment the case ends.
    private var createdSuiteNames: [String] = []
    private var createdDirectories: [URL] = []

    override func tearDown() async throws {
        for name in createdSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        createdSuiteNames.removeAll()
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories.removeAll()
        try await super.tearDown()
    }

    private func makeSuite(_ label: String) -> UserDefaults {
        let name = "\(label).\(UUID())"
        createdSuiteNames.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        createdDirectories.append(directory)
        return directory
    }

    func testLegacyKeychainMigrationPopulatesTheFallbackOnItsFirstLaunch() async throws {
        let defaults = makeSuite("AttriKitLegacyFallback")
        let current = MemoryKeychain()
        let legacy = MemoryKeychain()
        let legacyIdentity = UUID()
        try legacy.write(legacyIdentity)
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: current,
            legacyKeychain: legacy,
            directory: makeTemporaryDirectory()
        )

        let identity = try await storage.initializeIdentities()

        XCTAssertEqual(identity.installationID, legacyIdentity)
        XCTAssertEqual(try current.read(), legacyIdentity)
        XCTAssertEqual(
            defaults.string(forKey: "io.attrikit.fallback-installation-id"),
            legacyIdentity.uuidString.lowercased()
        )
    }

    func testDeleteDataPropagatesTransportFailureAndPreservesRetryTombstone() async throws {
        let defaults = makeSuite("AttriKitDeleteTransport")
        let keychain = MemoryKeychain()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: makeTemporaryDirectory()
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

        let tombstone = try await storage.deletionTombstone()
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
        let defaults = makeSuite("AttriKitDeleteHTTP")
        let keychain = MemoryKeychain()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: makeTemporaryDirectory()
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
        let pendingTombstone = try await storage.deletionTombstone()
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
        // XCTAssertEqual on the count does not abort, so subscripting right after it TRAPS on a
        // short array instead of reporting the count that was actually seen. XCTUnwrap throws,
        // which fails the case cleanly and says which body was missing.
        let firstBody = try XCTUnwrap(bodies.first, "the first attempt sent no body")
        let secondBody = try XCTUnwrap(bodies.dropFirst().first, "the second attempt sent no body")
        XCTAssertEqual(firstBody, secondBody)
        let clearedTombstone = try await storage.deletionTombstone()
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
        // The batch is SUSPENDED in the transport, so a runtime that waits for quiescence can never
        // send the erasure here however long we look: poll for the whole window instead of sleeping
        // 50 ms once. A dispatch that merely took longer than 50 ms used to pass this, and the
        // ordering assertions below cannot catch it either -- the batch REQUEST was already
        // recorded before this point, so an erasure sent without waiting still lands second.
        let deleteBeforeRelease = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/privacy/delete") == true }
        }
        XCTAssertFalse(deleteBeforeRelease, "the erasure must not be sent while a batch is still in flight")

        await transport.releaseBatch(with: successResult(
            body: #"{"status":"accepted","inserted":1,"duplicates":0}"#
        ))
        try await deletion.value

        let writePaths = await transport.requests().compactMap { request -> String? in
            let path = request.url?.path ?? ""
            return path.contains("events:batch") || path.hasSuffix("/v1/privacy/delete") ? path : nil
        }
        XCTAssertEqual(writePaths.count, 2)
        let firstWrite = try XCTUnwrap(writePaths.first, "no write reached the transport")
        let secondWrite = try XCTUnwrap(writePaths.dropFirst().first, "only one write reached the transport")
        XCTAssertTrue(firstWrite.contains("events:batch"))
        XCTAssertTrue(secondWrite.hasSuffix("/v1/privacy/delete"))
        let overlapping = await transport.overlappingBatchSends
        XCTAssertEqual(overlapping, 0, "a batch send while the first was suspended is a double flush, not a success")
        let latchedReleases = await transport.releasesWithNothingSuspended
        XCTAssertEqual(latchedReleases, 0, "the release must have reached a suspended send rather than been latched")
        await runtime.shutdown()
    }

    func testRemoteDeletionSuccessWithLocalCleanupFailureKeepsTombstoneForRelaunchRetry() async throws {
        let defaults = makeSuite("AttriKitDeleteCleanup")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
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

        let retainedTombstone = try await failingStorage.deletionTombstone()
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
        let clearedTombstone = try await reloadedStorage.deletionTombstone()
        XCTAssertNil(clearedTombstone)
        await relaunchedRuntime.shutdown()
    }

    func testCorruptDeletionTombstoneFailsClosedAndDoesNotCollect() async throws {
        let defaults = makeSuite("AttriKitCorruptTombstone")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        defaults.set(Data(#"{"installation_id":"#.utf8), forKey: "io.attrikit.deletion-tombstone")

        do {
            _ = try await storage.deletionTombstone()
            XCTFail("a truncated tombstone must not decode as absence")
        } catch StorageError.corruptDeletionTombstone {}

        let transport = acceptingEventTransport()
        let runtime = makeRuntime(storage: storage, transport: transport)
        await runtime.track(try AttriKitEvent("before_corrupt_start"), properties: [:])
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("after_corrupt_start"), properties: [:])

        let leaked = await waitUntil {
            await transport.requests().contains {
                ($0.url?.path.contains("events:batch") == true)
                    || ($0.url?.path.hasSuffix("/v1/privacy/delete") == true)
                    || ($0.url?.path.contains("first-open") == true)
            }
        }
        XCTAssertFalse(leaked, "a corrupt tombstone must halt collection, not resume it")
        let queued = try await storage.queuedEvents()
        XCTAssertTrue(queued.isEmpty)

        do {
            try await runtime.deleteData()
            XCTFail("deleteData must not mint a new tombstone over a corrupt payload")
        } catch StorageError.corruptDeletionTombstone {}

        do {
            _ = try await storage.deletionTombstone()
            XCTFail("the corrupt payload must still be stored after the refused delete")
        } catch StorageError.corruptDeletionTombstone {}
        await runtime.shutdown()
    }

    func testDeniedThenGrantedConsentNeverFlushesPreDenialBuffer() async throws {
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitDeniedBuffer")),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
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

        // A fixed 100 ms sleep made the absence hold only inside that window, so a delayed flush of
        // the pre-denial buffer -- exactly the defect this case exists to catch -- passed whenever
        // it landed later. Poll for the whole window instead: it returns the moment the event
        // appears, so a violation is reported rather than slept through.
        let leaked = await waitUntil {
            let delivered = (try? await decodedEvents(in: transport)) ?? []
            return delivered.contains { $0["event_name"] as? String == "before_denial" }
        }
        XCTAssertFalse(leaked, "an event buffered before a denial must never be delivered after a later grant")
        let deliveredEvents = try await decodedEvents(in: transport)
        XCTAssertFalse(deliveredEvents.contains {
            $0["event_name"] as? String == "before_denial"
        })
        let queuedAfterGrant = try await storage.queuedEvents()
        XCTAssertTrue(queuedAfterGrant.isEmpty)
        await runtime.shutdown()
    }

    func testRevocationRotatesEpochAndRestartsPersistedSessionSequence() async throws {
        let defaults = makeSuite("AttriKitRevocation")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
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

        let sessions = try await decodedEvents(in: transport).filter {
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
        let defaults = makeSuite("AttriKitRevocationRecovery")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
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

    func testCorruptPendingRevocationIsReportedAndRetained() async throws {
        let defaults = makeSuite("AttriKitCorruptPendingRevocation")
        let corruptRecord = Data("not a pending revocation".utf8)
        defaults.set(corruptRecord, forKey: "io.attrikit.pending-revocation")
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
        )

        do {
            try await storage.recoverPendingRevocationIfNeeded()
            XCTFail("a corrupt pending revocation must not be treated as absent")
        } catch {
            XCTAssertEqual(defaults.data(forKey: "io.attrikit.pending-revocation"), corruptRecord)
        }
    }

    func testPendingBatchIDMembershipAndSentAtPersistAcrossRelaunch() async throws {
        let defaults = makeSuite("AttriKitBatchPersistence")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
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

    /// The retry observed here is produced by the queue task's own backoff, NOT by
    /// `willTerminate` -- the name said termination flushed it, and nothing in the case
    /// discriminated the two. `assertRetryIsTheBackoffLadderRatherThanTermination` below waits for
    /// the second attempt WITHOUT sending a terminate at all, which settles which mechanism runs.
    func testLostBatchResponseReusesExactBodyAndTheBackoffLadderRetriesIt() async throws {
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitBatchRetry")),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
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

        // No terminate: if the second attempt still arrives, the backoff ladder is what produced
        // it and termination was never the mechanism this case measured.
        let retried = await waitUntil {
            await eventBatchRequests(in: transport).count == 2
        }
        XCTAssertTrue(retried, "the queue task's backoff must retry a batch whose response was lost")
        let requests = await eventBatchRequests(in: transport)
        // `uniqued().count == 1` over `[String?]` alone is satisfied by ANY constant, nil and the
        // empty string included -- it pins "both requests carried the SAME key" while saying
        // nothing about there BEING one. Unwrap first, then compare, so a header the retry stopped
        // sending fails here rather than reading as stability.
        let idempotencyKeys = try requests.map { request in
            try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key"),
                          "every event batch attempt must carry an Idempotency-Key")
        }
        XCTAssertEqual(idempotencyKeys.count, 2)
        for key in idempotencyKeys {
            XCTAssertFalse(key.isEmpty, "an empty Idempotency-Key deduplicates nothing server-side")
        }
        XCTAssertEqual(idempotencyKeys.uniqued().count, 1,
                       "the retry of a lost response must reuse the first attempt's key")
        let bodies = try requests.map { try gunzipStored(XCTUnwrap($0.httpBody)) }
        // XCTAssertEqual on the count does not abort, so subscripting right after it TRAPS on a
        // short array instead of reporting the count that was actually seen. XCTUnwrap throws,
        // which fails the case cleanly and says which body was missing.
        let firstBody = try XCTUnwrap(bodies.first, "the first attempt sent no body")
        let secondBody = try XCTUnwrap(bodies.dropFirst().first, "the second attempt sent no body")
        XCTAssertEqual(firstBody, secondBody)
        let queueAfterRetry = try await storage.queuedEvents()
        XCTAssertTrue(queueAfterRetry.isEmpty)
        await runtime.shutdown()
    }

    /// The invariant the two `bodyCarriesIdfa` assertions were reaching for, expressed so that it
    /// can actually fail.
    ///
    /// `CoreRuntime.bodyCarriesIdfa` looks for an `idfa` key. A consent receipt is encoded from
    /// `ConsentReceipt`, whose CodingKeys are exactly installation_id, install_epoch_id, scope,
    /// consent, occurred_at and source -- there is no `idfa` case, so the function returns false
    /// for EVERY possible consent-receipt body and the assertion could not fail. (The production
    /// guard on the same function three lines below the encode is unreachable for the same reason;
    /// it is left in place as a backstop and recorded as unreachable rather than deleted from a
    /// shipped SDK.)
    ///
    /// Asserting the exact key SET is what makes the property real: adding `idfa` -- or any other
    /// field -- to `ConsentReceipt` reddens this, which is the edit the guard exists to survive.
    private func assertConsentReceiptBodyCarriesOnlyItsOwnKeys(
        _ body: Data,
        _ kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("a \(kind) receipt body must be a JSON object", file: file, line: line)
            return
        }
        XCTAssertEqual(
            Set(object.keys),
            ["installation_id", "install_epoch_id", "scope", "consent", "occurred_at", "source"],
            "a \(kind) receipt must carry exactly its own keys -- any addition here reaches the server",
            file: file,
            line: line
        )
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
        let defaults = makeSuite("AttriKitTokenReplay")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: keychain,
            directory: directory
        )
        let transport = DelayedCaptureTransport(delay: .milliseconds(100))
        let token = "ak1_" + String(repeating: "R", count: 43)
        let firstRuntime = makeRuntime(storage: storage, transport: transport)
        await firstRuntime.start(apiKey: apiKey, consent: .trackingGranted)
        let firstOpenSent = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(firstOpenSent)

        let firstResult = await firstRuntime.acceptExactToken(token, kind: "clipboard")
        XCTAssertNotEqual(firstResult, .ignored)
        let identifyDelivered = await waitUntil {
            await transport.requests().contains {
                $0.url?.path.hasSuffix("/v1/ingest/identify") == true
            }
        }
        XCTAssertTrue(identifyDelivered, "acceptExactToken must deliver identify before its body is inspected")
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
        let diagnostics = DiagnosticRecorder()
        let storage = makeStorage(label: "SingleEventDrop")
        let identity = try await storage.initializeIdentities()
        try await storage.enqueue(makeEvent(name: "session_end", identity: identity))

        let runtime = makeRuntime(
            storage: storage,
            transport: statusTransport(422),
            diagnostic: { diagnostics.record($0) }
        )
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let drained = await waitUntil(timeout: .seconds(5)) {
            (try? await storage.queuedEvents().isEmpty) == true
        }
        XCTAssertTrue(drained, "a permanent 4xx on a lone event must still drain the queue")

        let reported = await waitUntil {
            diagnostics.messages.contains {
                $0.contains("permanently dropping event 'session_end'")
            }
        }
        XCTAssertTrue(reported, "the destroyed event must be reported, not lost silently")
        await runtime.shutdown()
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
        try await Task.sleep(for: .milliseconds(500))
        // Exactly one. `> 0` would also pass if the replay double-posted, and a duplicated consent
        // receipt is its own defect in a ledger. The stability window stays open after the first
        // delivery so a deferred retry cannot be cancelled invisibly by shutdown.
        XCTAssertEqual(epochGate.acceptedConsentCount, 1, "the deferred receipt must be replayed once, not duplicated")
        await runtime.shutdown()
    }

    /// A receipt must survive process termination after an offline delivery attempt. Replaying it
    /// must use the original idempotency key so a server acknowledgement lost before local cleanup
    /// cannot create a second legal record.
    func testConsentReceiptPersistsBeforeDeliveryAndRelaunchReusesItsIdentity() async throws {
        let defaults = makeSuite("AttriKitConsentReceipt")
        let keychain = MemoryKeychain()
        let directory = makeTemporaryDirectory()
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
        let queueDrained = await waitUntil {
            (try? await secondStorage.pendingConsentReceipts().isEmpty) == true
        }
        XCTAssertTrue(queueDrained, "a 2xx acknowledgement must finish removing the queued receipt")
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
        assertConsentReceiptBodyCarriesOnlyItsOwnKeys(delivery.body, "withdrawal")

        let rotationCompleted = await waitUntil {
            guard let identity = try? await storage.initializeIdentities() else { return false }
            return identity.installEpochID != originalIdentity.installEpochID
        }
        XCTAssertTrue(rotationCompleted, "the accepted withdrawal must finish rotating the install epoch")
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
        assertConsentReceiptBodyCarriesOnlyItsOwnKeys(delivery.body, "denial")
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
        // The stub records the body as the request ARRIVES, so the queue is sampled before the
        // runtime has processed the 2xx and deleted the acknowledged receipt: reading it once here
        // raced the drain's own acknowledgement and could fail against correct behaviour. Poll
        // until it is observably empty, which is a bound on the same assertion, not a weaker one.
        let queueDrained = await waitUntil {
            guard let pending = try? await storage.pendingConsentReceipts() else { return false }
            return pending.isEmpty
        }
        XCTAssertTrue(queueDrained, "the acknowledged withdrawal must supersede an older same-epoch grant")

        await runtime.setConsent(.measurementGranted)
        // Same reason as above, in the negative direction: a fixed 100 ms sleep enforced this only
        // inside that window, so a redelivery or a fresh persisted receipt landing later passed.
        let restored = await waitUntil { await observation.states != [.revoked] }
        XCTAssertFalse(restored, "a stale grant must not restore processing for the withdrawn epoch")
        let statesAfterRegrant = await observation.states
        XCTAssertEqual(statesAfterRegrant, [.revoked], "a stale grant must not restore processing for the withdrawn epoch")
        let pendingAfterGrant = try await storage.pendingConsentReceipts()
        XCTAssertTrue(pendingAfterGrant.isEmpty)
        await runtime.shutdown()
    }

    func testUnknownConsentReceiptIsPrunedInsteadOfStrandingTheQueue() async throws {
        let defaults = makeSuite("AttriKitUnknownConsentReceipt")
        let storage = SDKStorage(
            defaults: .init(value: defaults),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
        )
        let identity = try await storage.initializeIdentities()
        let receipt = StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "measurement",
            state: .unknown,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defaults.set(
            try attriKitJSONEncoder().encode([receipt]),
            forKey: "io.attrikit.consent-receipts"
        )

        let next = try await storage.nextConsentReceipt()
        let pending = try await storage.pendingConsentReceipts()

        XCTAssertNil(next)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(defaults.data(forKey: "io.attrikit.consent-receipts"))
    }

    func testWithdrawalAcknowledgementPreservesEqualTimestampRegrant() async throws {
        let storage = makeStorage(label: "EqualTimestampRegrant")
        let identity = try await storage.initializeIdentities()
        let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let withdrawal = StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "measurement",
            state: .revoked,
            occurredAt: occurredAt
        )
        let regrant = StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "measurement",
            state: .measurementGranted,
            occurredAt: occurredAt
        )
        try await storage.enqueueConsentReceipt(withdrawal)
        try await storage.enqueueConsentReceipt(regrant)

        try await storage.acknowledgeConsentReceipt(idempotencyKey: withdrawal.idempotencyKey)
        let pending = try await storage.pendingConsentReceipts()

        XCTAssertEqual(pending, [regrant])
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

        // The suppression was checked after a fixed 50 ms sleep, so it proved nothing past that
        // window: a runtime transmitting or persisting these receipts at t > 50 ms passed green,
        // which is the exact privacy violation this case exists to catch. Poll for the whole
        // window; it returns the instant a receipt appears, so the failure is reported, not slept
        // through, and the persistence check below is then also taken at the end of that window.
        let receiptLeaked = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }
        }
        XCTAssertFalse(receiptLeaked, "deletionPending must suppress every consent receipt")

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

    /// The double that holds a deletion suspended must hold the FIRST one. It stored the second
    /// /v1/privacy/delete continuation over the first, and a stored continuation that is
    /// overwritten is never resumed by anything: releaseDeletion() hands 204 to the newcomer while
    /// the original caller waits for the lifetime of the process. Every assertion below is bounded
    /// by waitUntil so the pre-fix double reports the defect rather than hanging the suite.
    func testASecondDeletionDoesNotTakeTheSuspendedContinuationFromTheFirst() async {
        let transport = SuspendedDeletionTransport()
        let request = URLRequest(url: URL(string: "https://unit.test/v1/privacy/delete")!)
        let settled = SettledDeletions()

        _ = Task { await settled.record(try? await transport.send(request)) }
        let firstArrived = await waitUntil { await transport.requests().count == 1 }
        XCTAssertTrue(firstArrived, "the first deletion never reached the transport")
        let beforeSecond = await settled.recorded()
        XCTAssertEqual(
            beforeSecond, [],
            "the first deletion returned instead of suspending, so this case measures nothing"
        )

        _ = Task { await settled.record(try? await transport.send(request)) }
        let secondAnswered = await waitUntil { await settled.recorded().count == 1 }
        XCTAssertTrue(
            secondAnswered,
            "the second deletion suspended as well, so it overwrote the first continuation"
        )

        await transport.releaseDeletion()
        let bothAnswered = await waitUntil { await settled.recorded().count == 2 }
        XCTAssertTrue(
            bothAnswered,
            "releaseDeletion resumed a continuation that was no longer the first send's"
        )
        // 204 is the released deletion, 200 the second request answered without suspending.
        let statuses = await settled.recorded().sorted()
        XCTAssertEqual(statuses, [200, 204])
    }

    func testWithdrawalReceiptMakesOneBoundedAttemptAndStaysQueuedWithout2xx() async throws {
        let storage = makeStorage(label: "WithdrawalRetryBound")
        let diagnostics = DiagnosticRecorder()
        let transport = StubTransport { request, _ in
            if request.url?.path.contains("events:batch") == true {
                return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
            }
            if request.url?.path.hasSuffix("/v1/ingest/consent") == true {
                return successResult(status: 503, body: #"{"error":"unavailable"}"#)
            }
            return successResult()
        }
        let runtime = makeRuntime(
            storage: storage,
            transport: transport,
            diagnostic: { diagnostics.record($0) }
        )
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        await runtime.track(try AttriKitEvent("before_failed_withdrawal"), properties: [:])
        let registered = await waitForBatchRequest(in: transport)
        XCTAssertTrue(registered, "precondition: the original epoch must be registered")

        await runtime.setConsent(.revoked)
        let withdrawalAttempted = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }
        }
        XCTAssertTrue(withdrawalAttempted, "precondition: the failed withdrawal must reach the transport")
        let attemptSettled = await waitUntil {
            diagnostics.messages.contains { $0.contains("consent receipt") && $0.contains("remains queued") }
        }
        XCTAssertTrue(attemptSettled, "the failed drain must finish before its bounded attempt count is asserted")

        // Read ONCE right after the diagnostic, a retry whose second attempt starts after that
        // diagnostic but before the read still answers 1 and passes -- which is the spin this
        // bound exists to refuse. Sample until the count stops moving, then assert the bound.
        let attemptCount = await settledConsentAttemptCount(in: transport)
        XCTAssertEqual(attemptCount, 1, "a consent-off drain must make one bounded attempt, not spin")
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
        let clock = TestDateClock(Date())
        let lifecycle = ManualLifecycleObserver()
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

        let runtime = makeRuntime(
            storage: storage,
            transport: transport,
            lifecycle: lifecycle,
            now: { clock.now() }
        )
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let refused = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(refused, "precondition: the server must actually refuse first-open")

        // Cross the complete retry window, then provoke both foreground registration and the
        // termination flush. Neither path may release a queue whose epoch was never registered.
        clock.advance(by: CoreRuntime.firstOpenRetryWindow + 1)
        await runtime.track(try AttriKitEvent("after_refused_first_open"), properties: [:])
        await runtime.setSessionTrackingEnabled(false)
        await lifecycle.send(.didBecomeActive)
        let refusedAgain = await waitUntil {
            await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }.count >= 2
        }
        XCTAssertTrue(refusedAgain, "foregrounding after the retry window must exercise registration again")
        await lifecycle.send(.willTerminate)

        let leaked = await eventBatchRequests(in: transport)
        XCTAssertTrue(leaked.isEmpty, "no batch may be sent for an epoch the server refused to register")
        let stillQueued = try await storage.queuedEvents()
        XCTAssertEqual(stillQueued.count, 2, "events are held for a later launch, not destroyed and not sent")
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
        let identifyRequest = await transport.requests().last {
            $0.url?.path.hasSuffix("/v1/ingest/identify") == true
        }
        let identifyBody = try gunzipStored(XCTUnwrap(identifyRequest?.httpBody))
        let identifyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: identifyBody) as? [String: Any]
        )
        XCTAssertEqual(
            identifyJSON["customer_user_id"] as? String,
            "rc-app-user-id",
            "the accepted identify must carry the RevenueCat join key"
        )
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
        let rejectedLifecycle = ManualLifecycleObserver()
        let rejectedRuntime = makeRuntime(
            storage: makeStorage(label: "ShortKey"),
            transport: rejectedTransport,
            lifecycle: rejectedLifecycle
        )
        await rejectedRuntime.start(apiKey: String(repeating: "k", count: 15), consent: .measurementGranted)
        await rejectedRuntime.track(try AttriKitEvent("invalid_short_key"), properties: [:])
        await rejectedRuntime.setUserID("customer-id")
        await rejectedLifecycle.send(.didBecomeActive)
        await rejectedLifecycle.send(.willTerminate)
        // Sampled ONCE, this negative races the dispatch: the control half of this very test proves
        // arrival is asynchronous (it needs waitUntil), so a build with the 16...512 guard removed
        // passes whenever its first request lands after this line -- including during the shutdown
        // below. Poll for the whole window, then re-read after shutdown.
        let rejectedLeaked = await waitUntil { await !rejectedTransport.requests().isEmpty }
        XCTAssertFalse(rejectedLeaked, "a 15-byte api key must not start measurement")
        await rejectedRuntime.shutdown()
        let rejectedAfterShutdown = await rejectedTransport.requests()
        XCTAssertTrue(rejectedAfterShutdown.isEmpty, "a 15-byte api key must not send during shutdown either")

        let oversizedTransport = StubTransport { _, _ in successResult() }
        let oversizedLifecycle = ManualLifecycleObserver()
        let oversizedRuntime = makeRuntime(
            storage: makeStorage(label: "OversizedKey"),
            transport: oversizedTransport,
            lifecycle: oversizedLifecycle
        )
        await oversizedRuntime.start(apiKey: String(repeating: "k", count: 513), consent: .measurementGranted)
        await oversizedRuntime.track(try AttriKitEvent("invalid_oversized_key"), properties: [:])
        await oversizedRuntime.setUserID("customer-id")
        await oversizedLifecycle.send(.didBecomeActive)
        await oversizedLifecycle.send(.willTerminate)
        let oversizedLeaked = await waitUntil { await !oversizedTransport.requests().isEmpty }
        XCTAssertFalse(oversizedLeaked, "a 513-byte api key must not start measurement")
        await oversizedRuntime.shutdown()
        let oversizedAfterShutdown = await oversizedTransport.requests()
        XCTAssertTrue(oversizedAfterShutdown.isEmpty, "a 513-byte api key must not send during shutdown either")

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
        let retryBarrier = FirstOpenRetryBarrier()
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return try await retryBarrier.respond()
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

        // Hold the legitimate retry in the transport. Every orphaned chain was armed against the
        // same 5-second rung, so it must become visible while that response remains suspended.
        let retried = await waitUntil(timeout: .seconds(9)) { await self.firstOpenRequestCount(in: transport) >= 2 }
        XCTAssertTrue(retried, "the one legitimate scheduled retry must fire")
        try? await Task.sleep(for: .seconds(1))
        let total = await firstOpenRequestCount(in: transport)
        XCTAssertEqual(total, 2, "exactly one scheduled retry may fire; extra chains mean the slot was orphaned")
        await retryBarrier.release()
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
        let spendingFinished = await waitUntil { !(await storage.isExactTokenNew(token)) }
        XCTAssertTrue(spendingFinished, "the successful identify response must be processed before storage is asserted")
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
        let registered = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(registered, "precondition: first-open must register before identify can run")

        let token = "ak1_" + String(repeating: "U", count: 43)
        let accepted = await runtime.acceptExactToken(token, kind: "clipboard")
        XCTAssertNotEqual(accepted, .ignored)
        let deliveryAttempted = await waitUntil { await self.identifyRequestCount(in: transport) >= 1 }
        XCTAssertTrue(deliveryAttempted, "precondition: the failing identify must actually be attempted")

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
        let directory = makeTemporaryDirectory()
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitUnreadableQueue")),
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

    func testQueuedEventsReportsAnUnreadableQueueFile() async throws {
        let directory = makeTemporaryDirectory()
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitUnreadableQueueRead")),
            keychain: MemoryKeychain(),
            directory: directory
        )
        let identity = try await storage.initializeIdentities()
        try await storage.enqueue(makeEvent(name: "queued_before_read_failure", identity: identity))
        let queueURL = directory
            .appendingPathComponent("AttriKit", isDirectory: true)
            .appendingPathComponent("events-v1.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: queueURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: queueURL.path) }

        do {
            _ = try await storage.queuedEvents()
            XCTFail("an unreadable queue must not be reported as empty")
        } catch {
            // Expected: callers must be able to distinguish read failure from an idle queue.
        }
    }

    // The two DEFAULT Keychain stores must not share a service string. If they did, the legacy read
    // would issue the identical SecItem query as the current one, so `keychain.read()` returning nil
    // would imply the legacy read returns nil too: the migration branch could only ever fire through
    // an injected double, and a pre-rename install would lose its lineage in production with nothing
    // failing. The recording factory is what lets this be measured without a real Keychain.
    func testTheDefaultConstructionReadsTheLegacyServiceRatherThanTheCurrentOneTwice() async throws {
        let named = SDKStorage.defaultKeychainServices(bundleID: "io.example.app")
        XCTAssertEqual(named.current, "io.attrikit.core.io.example.app")
        XCTAssertEqual(named.legacy, "io.attrkit.core.io.example.app")
        XCTAssertNotEqual(named.current, named.legacy, "one letter is the whole migration")

        let services = SDKStorage.defaultKeychainServices(bundleID: Bundle.main.bundleIdentifier ?? "unknown")
        let stores = KeychainFactoryRecorder()
        let legacyIdentity = UUID()
        stores.seed(service: services.legacy, with: legacyIdentity)
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitDefaultKeychainServices")),
            keychainFactory: { stores.store(for: $0) },
            directory: makeTemporaryDirectory()
        )

        let identity = try await storage.initializeIdentities()

        XCTAssertEqual(
            stores.requestedServices,
            [services.current, services.legacy],
            "the default construction must build the current store and the PRE-RENAME one"
        )
        XCTAssertEqual(
            identity.installationID, legacyIdentity,
            "an identity that exists only under the legacy service must still be adopted"
        )
        XCTAssertTrue(identity.localLineagePresent, "a migrated identity is lineage")
    }

    // A caller that supplies only `legacyKeychain` had it silently replaced by a default store, so
    // the dependency it injected was never consulted.
    func testAnInjectedLegacyKeychainSurvivesWhenTheCurrentStoreIsDefaulted() async throws {
        let stores = KeychainFactoryRecorder()
        let injectedLegacy = MemoryKeychain()
        let legacyIdentity = UUID()
        try injectedLegacy.write(legacyIdentity)
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitInjectedLegacyKeychain")),
            legacyKeychain: injectedLegacy,
            keychainFactory: { stores.store(for: $0) },
            directory: makeTemporaryDirectory()
        )

        let identity = try await storage.initializeIdentities()

        XCTAssertEqual(
            identity.installationID, legacyIdentity,
            "the injected legacy store was discarded, so its identity was never read"
        )
        XCTAssertTrue(identity.localLineagePresent)
        XCTAssertEqual(
            stores.requestedServices.count, 1,
            "only the CURRENT store may be defaulted when a legacy one was supplied"
        )
    }

    // Corruption recovery must not depend on the quarantine succeeding. The quarantine name carries
    // a whole SECOND, so a second corruption inside the same second collides with the file the first
    // one left; `moveItem` then threw out of readQueue with the corrupt file still in place, and
    // every later read repeated it. The queue stayed wedged instead of resetting.
    func testACorruptQueueResetsEvenWhenItsQuarantineNameIsAlreadyTaken() async throws {
        let directory = makeTemporaryDirectory()
        let queueDirectory = directory.appendingPathComponent("AttriKit", isDirectory: true)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let queueURL = queueDirectory.appendingPathComponent("events-v1.json")
        try Data("{ this is not a QueueFile".utf8).write(to: queueURL)
        // Occupy this second and the next two: the collision is then certain however the read is
        // scheduled, rather than depending on landing inside one particular second.
        let second = Int(Date().timeIntervalSince1970)
        for offset in 0...2 {
            try Data().write(to: queueURL.appendingPathExtension("corrupted-\(second + offset)"))
        }

        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitQuarantineCollision")),
            keychain: MemoryKeychain(),
            directory: directory
        )
        let identity = try await storage.initializeIdentities()
        let accepted = try await storage.enqueue(makeEvent(name: "after_corruption", identity: identity))

        XCTAssertTrue(accepted, "a corrupt queue must reset even when it cannot be quarantined")
        let queued = try await storage.queuedEvents()
        XCTAssertEqual(queued.map(\.eventName), ["after_corruption"])
    }

    // The ceiling must cut at the LARGEST prefix that fits, not merely somewhere under it: one
    // event short per batch is a queue that drains slower than it fills. Nothing pinned that cut,
    // so a sizing change could quietly send smaller batches forever.
    func testTheBatchCeilingCutsAtTheLargestPrefixThatFits() async throws {
        let storage = SDKStorage(
            defaults: .init(value: makeSuite("AttriKitBatchCeiling")),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
        )
        let identity = try await storage.initializeIdentities()
        let padding = String(repeating: "p", count: 4_000)
        for index in 0..<24 {
            try await storage.enqueue(makeEvent(
                name: "padded_\(index)",
                identity: identity,
                properties: ["pad": .string(padding)]
            ))
        }
        let queued = try await storage.queuedEvents()

        let nextBatch = try await storage.nextEventBatch()
        let batch = try XCTUnwrap(nextBatch)

        XCTAssertGreaterThan(batch.events.count, 0, "at least one event is always attempted")
        XCTAssertLessThan(
            batch.events.count, queued.count,
            "precondition: the padding must be large enough that the ceiling actually cuts"
        )
        XCTAssertEqual(
            batch.events.map(\.eventID),
            queued.prefix(batch.events.count).map(\.eventID),
            "the batch is the leading run of the queue, in order"
        )
        let measuredBatchSize = try encodedBatchSize(batchID: batch.batchID, events: batch.events)
        XCTAssertEqual(
            measuredBatchSize,
            try attriKitJSONEncoder().encode(EventBatch(batchID: batch.batchID, events: batch.events)).count,
            "the ceiling assertion must measure the exact payload sent by the runtime"
        )
        XCTAssertLessThanOrEqual(
            measuredBatchSize, SDKStorage.batchByteCeiling,
            "the batch that is sent must fit under the client ceiling"
        )
        XCTAssertGreaterThan(
            try encodedBatchSize(
                batchID: batch.batchID,
                events: Array(queued.prefix(batch.events.count + 1))
            ),
            SDKStorage.batchByteCeiling,
            "one more event must NOT have fitted, or the cut was premature"
        )
    }

    private func encodedBatchSize(batchID: String, events: [EventEnvelope]) throws -> Int {
        try attriKitJSONEncoder().encode(EventBatch(batchID: batchID, events: events)).count
    }

    private func makeRuntime(
        storage: SDKStorage,
        transport: HTTPTransport,
        lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver(),
        now: @escaping @Sendable () -> Date = { Date() },
        diagnostic: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CoreRuntime {
        CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: now,
            lifecycle: lifecycle,
            diagnostic: diagnostic
        ))
    }

    private func makeStorage(label: String) -> SDKStorage {
        SDKStorage(
            defaults: .init(value: makeSuite("AttriKit\(label)")),
            keychain: MemoryKeychain(),
            directory: makeTemporaryDirectory()
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

    /// The consent-attempt count once it has stopped moving, so a bound asserted on it cannot be
    /// satisfied by reading between two attempts of a spin. Returns the LAST sample, and reports
    /// the count still changing at the deadline rather than returning a number nobody can trust.
    private func settledConsentAttemptCount(
        in transport: StubTransport,
        settling: Duration = .milliseconds(500)
    ) async -> Int {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settling)
        var latest = await consentAttemptCount(in: transport)
        var equalSamples = 1
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            let current = await consentAttemptCount(in: transport)
            if current == latest {
                equalSamples += 1
            } else {
                latest = current
                equalSamples = 1
            }
        }
        if equalSamples < 2 {
            XCTFail("the consent attempt count was still moving at the settling deadline")
        }
        return latest
    }

    private func consentAttemptCount(in transport: StubTransport) async -> Int {
        await transport.requests().filter { $0.url?.path.hasSuffix("/v1/ingest/consent") == true }.count
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

private actor DelayedCaptureTransport: HTTPTransport {
    private let delay: Duration
    private var captured: [URLRequest] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        Task {
            try? await Task.sleep(for: delay)
            self.capture(request)
        }
        return successResult()
    }

    func requests() -> [URLRequest] { captured }

    private func capture(_ request: URLRequest) {
        captured.append(request)
    }
}

// A release arriving BEFORE anything suspends is already handled: `released` latches, so the next
// attempt reads it and never suspends at all. What was not handled is the request task being
// CANCELLED while suspended here, which resumes nothing and leaves that task unfinished for the
// lifetime of the process. The deadline below is the bound: it cannot make a passing test fail
// (the one caller holds the barrier for about ten seconds) and it turns a wait that can never end
// into one that ends.
private actor FirstOpenRetryBarrier {
    private var attempts = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var deadline: Task<Void, Never>?

    func respond() async throws -> HTTPResult {
        attempts += 1
        if attempts > 1, !released {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                armDeadline()
            }
        }
        throw URLError(.notConnectedToInternet)
    }

    func release() {
        released = true
        resumeWaiters()
    }

    private func armDeadline() {
        guard deadline == nil else { return }
        deadline = Task {
            try? await Task.sleep(for: suspendedStubDeadline)
            self.resumeWaiters()
        }
    }

    private func resumeWaiters() {
        deadline?.cancel()
        deadline = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

// How long a suspended stub waits before it gives up. A stub that can suspend forever takes the
// whole test process down with it and says nothing, which is a worse failure than any defect these
// tests are looking for.
private let suspendedStubDeadline: Duration = .seconds(30)

// Three things this stub used to do quietly, each of which hides the behaviour it exists to expose.
// It answered an OVERLAPPING batch send with a fabricated 204, so a double flush read as one
// accepted batch. It DROPPED a release that arrived before the send suspended, so a misordered test
// hung instead of failing. And a cancelled request task left the send suspended with nothing able
// to resume it. Overlaps are now counted and refused, a release latches for the send that has not
// arrived yet, and the suspension carries a deadline.
private actor SuspendedFirstBatchTransport: HTTPTransport {
    private enum BatchStall: Error { case neverReleased }

    private var captured: [URLRequest] = []
    private var batchContinuation: CheckedContinuation<HTTPResult, Error>?
    private var pendingRelease: HTTPResult?
    private var deadline: Task<Void, Never>?
    private(set) var overlappingBatchSends = 0
    private(set) var releasesWithNothingSuspended = 0

    func send(_ request: URLRequest) async throws -> HTTPResult {
        captured.append(request)
        guard request.url?.path.contains("events:batch") == true else {
            return successResult(status: 204, body: "")
        }
        if let latched = pendingRelease {
            pendingRelease = nil
            return latched
        }
        guard batchContinuation == nil else {
            overlappingBatchSends += 1
            return successResult(status: 500, body: #"{"error":"overlapping batch send"}"#)
        }
        return try await withCheckedThrowingContinuation { continuation in
            batchContinuation = continuation
            armDeadline()
        }
    }

    func requests() -> [URLRequest] { captured }

    func releaseBatch(with result: HTTPResult) {
        deadline?.cancel()
        deadline = nil
        guard let continuation = batchContinuation else {
            releasesWithNothingSuspended += 1
            pendingRelease = result
            return
        }
        batchContinuation = nil
        continuation.resume(returning: result)
    }

    private func armDeadline() {
        deadline = Task {
            try? await Task.sleep(for: suspendedStubDeadline)
            self.failStalledBatch()
        }
    }

    private func failStalledBatch() {
        guard let continuation = batchContinuation else { return }
        batchContinuation = nil
        continuation.resume(throwing: BatchStall.neverReleased)
    }
}

private actor SuspendedDeletionTransport: HTTPTransport {
    private var captured: [URLRequest] = []
    private var deletionContinuation: CheckedContinuation<HTTPResult, Error>?

    // `deletionContinuation == nil` is the same guard SuspendedFirstBatchTransport above already
    // carries, and it is load-bearing rather than defensive: assigning over a stored continuation
    // discards it, so releaseDeletion() resumes the newcomer and the first caller stays suspended
    // for the lifetime of the process. Only one deletion can be held at a time; a second one is
    // answered immediately instead of taking the first one's place.
    func send(_ request: URLRequest) async throws -> HTTPResult {
        captured.append(request)
        guard request.url?.path.hasSuffix("/v1/privacy/delete") == true,
              deletionContinuation == nil else {
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

/// Records what each concurrent deletion send actually returned, so a send that never resumes is
/// a missing entry rather than a suspended test.
private actor SettledDeletions {
    private var statuses: [Int] = []

    func record(_ result: HTTPResult?) { statuses.append(result?.statusCode ?? -1) }
    func recorded() -> [Int] { statuses }
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

/// Stands in for the two Keychain stores the DEFAULT construction builds, so the service strings it
/// asks for can be read back without a real Keychain (which a unit test must never write to).
private final class KeychainFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: MemoryKeychain] = [:]
    private var requested: [String] = []

    var requestedServices: [String] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    func seed(service: String, with identity: UUID) {
        let store = locked { stores[service] ?? register(service) }
        try? store.write(identity)
    }

    func store(for service: String) -> InstallationIDStoring {
        locked {
            requested.append(service)
            return stores[service] ?? register(service)
        }
    }

    private func register(_ service: String) -> MemoryKeychain {
        let store = MemoryKeychain()
        stores[service] = store
        return store
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
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

private enum EventBatchDecodeError: Error {
    case missingBody
    case invalidGzip
    case invalidJSONObject
    case missingEventsArray
}

private func decodedEvents(in transport: StubTransport) async throws -> [[String: Any]] {
    var events: [[String: Any]] = []
    for request in await eventBatchRequests(in: transport) {
        guard let compressed = request.httpBody else {
            throw EventBatchDecodeError.missingBody
        }
        guard let body = try? gunzipStored(compressed) else {
            throw EventBatchDecodeError.invalidGzip
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw EventBatchDecodeError.invalidJSONObject
        }
        guard let batch = json["events"] as? [[String: Any]] else {
            throw EventBatchDecodeError.missingEventsArray
        }
        events.append(contentsOf: batch)
    }
    return events
}

private func waitForEvent(named name: String, count: Int, in transport: StubTransport) async -> Bool {
    await waitUntil {
        guard let events = try? await decodedEvents(in: transport) else { return false }
        return events.filter { $0["event_name"] as? String == name }.count == count
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
