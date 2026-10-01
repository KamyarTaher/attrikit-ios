import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// The server keeps an identify's IDFA only while the occurrence it names is held as
/// `tracking_granted` (apps/link/src/ingestion/repository.ts, upsertIdentifyPlatformIds). An
/// occurrence holds its first-open's consent until a consent receipt changes it (appendConsent), and
/// a first-open answered 409 changes nothing. So a tracking grant reaches the server only as a
/// receipt, and an IDFA only in an identify that ARRIVES after that receipt was applied.
///
/// Each test drives the SDK against `ConsentModelServer`, which applies those rules, and asserts
/// what the server ends up holding rather than which requests went out: a request that carries the
/// IDFA to an occurrence still held as measurement_granted is a request the server discards.
@MainActor
final class TrackingConsentConvergenceTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)
    private let idfa = UUID(uuidString: "6D92078A-8246-4BA4-AE5B-76104861E7DC")!
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

    /// One device: the same defaults, keychain and queue directory across launches.
    private struct Device {
        let defaults: UserDefaults
        let keychain: MemoryKeychain
        let directory: URL

        func storage() -> SDKStorage {
            SDKStorage(defaults: .init(value: defaults), keychain: keychain, directory: directory)
        }
    }

    private func makeDevice() -> Device {
        let name = "AttriKitTrackingConvergence.\(UUID())"
        createdSuiteNames.append(name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        createdDirectories.append(directory)
        return Device(defaults: UserDefaults(suiteName: name)!, keychain: MemoryKeychain(), directory: directory)
    }

    /// The device has an IDFA whatever the consent: ATT authorization is the host's business, and
    /// the SDK's own consent is the only gate under test.
    private func launch(
        _ device: Device,
        server: ConsentModelServer,
        now: @escaping @Sendable () -> Date = { Date() },
        idfa deviceIDFA: (@Sendable () -> UUID?)? = nil,
        lifecycle: ManualLifecycleObserver = ManualLifecycleObserver()
    ) -> (CoreRuntime, SDKStorage) {
        let storage = device.storage()
        let idfa = idfa
        let currentIDFA = deviceIDFA ?? { idfa }
        let runtime = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: server,
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: currentIDFA(), idfv: nil) },
            now: now,
            lifecycle: lifecycle,
            backgroundRetryScheduler: BackgroundRetryScheduler { _ in },
            diagnostic: { _ in }
        ))
        return (runtime, storage)
    }

    private func epoch(_ storage: SDKStorage) async throws -> String {
        try await storage.initializeIdentities().installEpochID.uuidString.lowercased()
    }

    private func expectedIDFA() -> String { idfa.uuidString.lowercased() }

    // MARK: - A consent change between launches

    /// The README's own integration: `requestConsent()` then `start(apiKey:consent:)` on every
    /// launch, with ATT granted after the first launch registered under measurement consent. start
    /// stored the new consent and raised no receipt, so the server held measurement_granted for
    /// the life of the install and discarded every IDFA the app sent afterwards.
    func testATrackingGrantPassedOnlyToStartOnALaterLaunchReachesTheServerWithItsIDFA() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered, "the first launch never registered its first-open")
        await first.shutdown()

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .trackingGranted)

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        let occurrence = await server.occurrence(epoch)
        XCTAssertEqual(occurrence?.consentClass, "tracking_granted", "start raised no tracking receipt for the stored measurement consent")
        XCTAssertTrue(delivered, "the IDFA never reached an occurrence held as tracking_granted")
        XCTAssertEqual(occurrence?.idfa, expectedIDFA())
        await second.shutdown()
    }

    /// The other direction, which is the privacy half: ATT withdrawn in Settings between launches.
    /// The server went on holding tracking_granted, and with it the right to keep an IDFA. A
    /// withdrawal declared only by start is held while the app is in the foreground (a setConsent
    /// re-grant replaces it) and sent when the app leaves it.
    func testATrackingWithdrawalPassedOnlyToStartOnALaterLaunchReachesTheServer() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered, "the first launch's first-open never delivered its IDFA")
        await first.shutdown()
        let firstLaunchRequests = await server.requestCount()

        let (second, _) = launch(device, server: server, idfa: { nil })
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await server.firstOpenCount() == 2 }
        XCTAssertTrue(replayed)
        try await Task.sleep(for: .milliseconds(200))
        let held = await server.consentCount()
        XCTAssertEqual(held, 0, "start's withdrawal was sent while the app was still in the foreground")

        await second.applicationWillResignActive()
        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "the server still holds tracking_granted after the app left the foreground")
        let carriers = await server.idfaCarriersAfter(firstLaunchRequests: firstLaunchRequests)
        XCTAssertEqual(carriers, [], "a request sent under measurement consent carried the IDFA")
        let receipts = await server.receipts()
        XCTAssertEqual(receipts, ["tracking:measurement_granted"], "a withdrawal of tracking is a tracking receipt")
        await second.shutdown()
    }

    /// `start(consent: .unknown)` while the app waits for its consent platform overwrites the stored
    /// consent, so a later `setConsent(.trackingGranted)` reads as a first grant and begins
    /// measurement without a receipt. Only what the server already holds tells the SDK it must send
    /// one.
    func testATrackingGrantAfterAnUnknownStartOnALaterLaunchReachesTheServer() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        await first.shutdown()

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .unknown)
        await second.setConsent(.trackingGranted)

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        let held = await server.occurrence(epoch)?.consentClass
        XCTAssertEqual(held, "tracking_granted")
        XCTAssertTrue(delivered, "the IDFA never reached an occurrence held as tracking_granted")
        await second.shutdown()
    }

    /// The first launch's first-open reached the server but its answer did not reach the device, so
    /// the SDK cannot know which consent the server registered. The next launch rebuilds the body
    /// under the new consent and is answered 409, which proves only that SOME body is stored. A
    /// receipt must settle it.
    func testAGrantAfterAFirstOpenWhoseAnswerWasLostIsStillSentAsAReceipt() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let clock = TestDateClock()
        await server.loseFirstOpenAnswers(1)

        let (first, firstStorage) = launch(device, server: server, now: clock.now)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let stored = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(stored, "the first first-open never reached the server")
        await first.shutdown()
        // Past the first rung of the retry ladder the lost answer scheduled, so the next launch
        // sends its first-open at once.
        clock.advance(by: 60)

        let (second, _) = launch(device, server: server, now: clock.now)
        await second.start(apiKey: apiKey, consent: .trackingGranted)

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        let held = await server.occurrence(epoch)?.consentClass
        XCTAssertEqual(held, "tracking_granted")
        XCTAssertTrue(delivered)
        await second.shutdown()
    }

    /// A device whose server-held consent no build ever recorded: an install that granted tracking
    /// in-process on a build before this record existed, then had ATT withdrawn in Settings. Its
    /// persisted first-open matches the new launch's consent, so it is replayed and answered 200,
    /// which says nothing about the receipt that has since changed the occurrence. Reading that 200
    /// as the server's consent would leave tracking_granted in place.
    func testAReplayedFirstOpenIsNotTakenAsTheServersConsentWhenNoneWasRecorded() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        await first.setConsent(.trackingGranted)
        let granted = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "tracking_granted"
        }
        XCTAssertTrue(granted)
        await first.shutdown()
        // What a 2.6.0 device carries into its first launch on this build: no record of what the
        // server holds.
        device.defaults.removeObject(forKey: SDKStorage.serverConsentKeyForTesting)

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await server.firstOpenCount() == 2 }
        XCTAssertTrue(replayed)
        await second.applicationWillResignActive()

        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "the server kept tracking_granted after ATT was withdrawn")
        await second.shutdown()
    }

    // MARK: - A grant within one launch

    /// `AttriKitTracking.requestConsent()` refreshes the tracking evidence BEFORE it returns, so its
    /// identify leaves while the SDK still holds measurement consent, and the `setConsent` the host
    /// then makes raised a receipt but sent no identify after it. The IDFA did not reach the server
    /// in that launch.
    func testAnInProcessTrackingGrantDeliversTheIDFAAfterItsReceipt() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let (runtime, storage) = launch(device, server: server)
        let epoch = try await epoch(storage)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)

        await runtime.refreshTrackingEvidence()
        await runtime.setConsent(.trackingGranted)

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        let occurrence = await server.occurrence(epoch)
        XCTAssertEqual(occurrence?.consentClass, "tracking_granted")
        XCTAssertTrue(delivered, "the IDFA did not reach the server in the launch that granted tracking")
        XCTAssertEqual(occurrence?.idfa, expectedIDFA())
        // setConsent queued the receipt; the drain must count it rather than raise its own.
        let receipts = await server.consentCount()
        XCTAssertEqual(receipts, 1, "one grant was sent as more than one receipt")
        await runtime.shutdown()
    }

    /// The receipt and an identify race: setUserID's identify carries the IDFA, but the receipt is
    /// still in flight, so the server applies the identify first and discards the IDFA. An identify
    /// must follow the receipt's acknowledgement.
    func testAnIdentifyThatOvertakesTheTrackingReceiptIsFollowedByOneThatDoesNot() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let (runtime, storage) = launch(device, server: server)
        let epoch = try await epoch(storage)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)

        await server.holdConsentReceipts()
        await runtime.setConsent(.trackingGranted)
        await runtime.setUserID("user-1")
        let overtaken = await waitUntil { await server.identifyCount() >= 1 }
        XCTAssertTrue(overtaken, "setUserID sent no identify")
        let overtakenIDFA = await server.occurrence(epoch)?.idfa
        XCTAssertNil(overtakenIDFA, "the identify should have arrived before the receipt")
        await server.releaseConsentReceipts()

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(delivered, "no identify followed the receipt's acknowledgement")
        await runtime.shutdown()
    }

    /// The identify the registration sends for a stored user id arrives before the tracking receipt
    /// is applied, so the server discards its IDFA, but its answer comes back only after the
    /// receipt was acknowledged. Judged by what the SDK knew when it SENT the identify, it is not a
    /// delivery; judged when the answer arrives, it looked like one, and the drain, which waits for
    /// that identify, then sent nothing.
    func testAnIdentifyAnsweredAfterTheReceiptWasAppliedIsNotTakenAsADelivery() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        await first.shutdown()

        await server.holdConsentReceipts()
        await server.holdIdentifies()
        let (second, secondStorage) = launch(device, server: server)
        await second.setUserID("user-1")
        await second.start(apiKey: apiKey, consent: .trackingGranted)
        let bothInFlight = await waitUntil(timeout: .seconds(5)) {
            let receipts = await server.heldReceiptCount()
            let identifies = await server.heldIdentifyCount()
            return receipts == 1 && identifies == 1
        }
        XCTAssertTrue(bothInFlight, "the receipt and the user id's identify were not both in flight")
        let discarded = await server.occurrence(epoch)?.idfa
        XCTAssertNil(discarded, "the identify should have arrived before the receipt was applied")

        await server.releaseConsentReceipts()
        let epochID = try XCTUnwrap(UUID(uuidString: epoch))
        let acknowledged = await waitUntil(timeout: .seconds(5)) {
            await secondStorage.serverConsent(installEpochID: epochID) == .trackingGranted
        }
        XCTAssertTrue(acknowledged, "the receipt was never acknowledged")
        await server.releaseIdentifies()

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(delivered, "an identify answered after the receipt was taken as having delivered the IDFA")
        await second.shutdown()
    }

    /// A receipt raised while the drain is already past its last read of the queue: the drain is
    /// waiting on the IDFA identify it sends at its end, and the user withdraws tracking. Its
    /// request to drain used to be dropped because a drain was running, which left the server at
    /// tracking_granted until the next foreground.
    func testADowngradeRaisedWhileTheDrainSendsTheIDFAIsStillDelivered() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let (runtime, storage) = launch(device, server: server)
        let epoch = try await epoch(storage)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)

        await server.holdIdentifies()
        await runtime.setConsent(.trackingGranted)
        let identifying = await waitUntil(timeout: .seconds(5)) { await server.heldIdentifyCount() == 1 }
        XCTAssertTrue(identifying, "the drain never sent the IDFA identify")
        await runtime.setConsent(.measurementGranted)
        await server.releaseIdentifies()

        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "the downgrade raised during the drain was left queued")
        await runtime.shutdown()
    }

    /// The same epoch continues after a denial (only a revocation rotates it), and the server holds
    /// the delivered `denied` until a receipt says otherwise. A re-grant used to send none, so the
    /// server went on refusing every identify for that install.
    func testAReGrantAfterADenialInTheSameEpochReachesTheServer() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let (runtime, storage) = launch(device, server: server)
        let epoch = try await epoch(storage)
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)

        await runtime.setConsent(.denied)
        let denied = await server.occurrence(epoch)?.consentClass
        XCTAssertEqual(denied, "denied")
        await runtime.setConsent(.measurementGranted)
        let continued = try await self.epoch(storage)
        XCTAssertEqual(continued, epoch, "a denial must not rotate the epoch")

        let regranted = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(regranted, "the server still holds denied after the re-grant")
        let receipts = await server.receipts()
        XCTAssertEqual(receipts, ["measurement:denied", "measurement:measurement_granted"])
        await runtime.shutdown()
    }

    /// A denial whose receipt could not be delivered stays queued, and the next launch started
    /// under that denial delivers it before measurement starts, with no identity loaded. The
    /// server then holds `denied`, and a later grant must still undo it.
    func testAWithdrawalDeliveredWhileMeasurementIsOffIsUndoneByALaterGrant() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        await server.failConsentReceipts(true)
        await first.setConsent(.denied)
        await first.shutdown()
        let queued = try await firstStorage.pendingConsentReceipts().count
        XCTAssertEqual(queued, 1, "the withdrawal was not left queued")
        await server.failConsentReceipts(false)

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .denied)
        let denied = await server.occurrence(epoch)?.consentClass
        XCTAssertEqual(denied, "denied", "the queued withdrawal was not delivered at the next start")
        await second.shutdown()

        let (third, _) = launch(device, server: server)
        await third.start(apiKey: apiKey, consent: .measurementGranted)
        let regranted = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(regranted, "the server still holds denied after the grant")
        await third.shutdown()
    }

    /// The IDFA identify waits for the server to hold the epoch as tracking_granted, not only for
    /// the drain to reach its end. Here the server holds it revoked, a state the SDK never grants
    /// over, and the device's IDFA changed since first-open delivered the old one.
    func testTheIDFAIsNotSentToAnOccurrenceTheServerDoesNotHoldAsTrackingGranted() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let currentIDFA = LockedIDFA(idfa)
        let (runtime, storage) = launch(device, server: server, idfa: { currentIDFA.value })
        let identity = try await storage.initializeIdentities()
        let epoch = identity.installEpochID.uuidString.lowercased()
        await runtime.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        try await Task.sleep(for: .milliseconds(200))

        try await storage.enqueueConsentReceipt(StoredConsentReceipt(
            idempotencyKey: UUID(),
            installationID: identity.installationID,
            installEpochID: identity.installEpochID,
            scope: "measurement",
            state: .revoked,
            occurredAt: Date()
        ))
        currentIDFA.value = UUID()
        await runtime.applicationDidBecomeActive()
        let revoked = await waitUntil { await server.occurrence(epoch)?.consentClass == "revoked" }
        XCTAssertTrue(revoked)
        try await Task.sleep(for: .milliseconds(300))

        let identifies = await server.identifyCount()
        XCTAssertEqual(identifies, 0, "the new IDFA was sent to an occurrence held as revoked")
        await runtime.shutdown()
    }

    /// What the device records about the server is not kept past what the user withdrew: the IDFA
    /// digest goes with a denial even when its receipt cannot be delivered, and both records go
    /// with an erasure.
    func testNoRecordOfTheIDFAOutlivesADenialOrAnErasure() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let (runtime, storage) = launch(device, server: server)
        let identity = try await storage.initializeIdentities()
        let epoch = identity.installEpochID
        await runtime.start(apiKey: apiKey, consent: .trackingGranted)
        let recorded = await waitUntil { await storage.deliveredIDFADigest(installEpochID: epoch) != nil }
        XCTAssertTrue(recorded, "the first-open's IDFA was not recorded as delivered")

        await server.failConsentReceipts(true)
        await runtime.setConsent(.denied)
        let afterDenial = await storage.deliveredIDFADigest(installEpochID: epoch)
        XCTAssertNil(afterDenial, "the IDFA digest outlived a denial whose receipt was not delivered")
        await server.failConsentReceipts(false)

        await runtime.setConsent(.trackingGranted)
        let regranted = await waitUntil(timeout: .seconds(5)) {
            await storage.deliveredIDFADigest(installEpochID: epoch) != nil
        }
        XCTAssertTrue(regranted, "the re-grant did not deliver the IDFA again")
        try await runtime.deleteData()
        let consentAfterErasure = await storage.serverConsent(installEpochID: epoch)
        let digestAfterErasure = await storage.deliveredIDFADigest(installEpochID: epoch)
        XCTAssertNil(consentAfterErasure, "the server consent record outlived an erasure")
        XCTAssertNil(digestAfterErasure, "the IDFA digest outlived an erasure")
        await runtime.shutdown()
    }

    /// An app that starts every launch with `.measurementGranted` and passes the ATT answer to
    /// setConsent once it is running. On an install the server already holds as tracking_granted,
    /// start's measurement must not be sent as a withdrawal that the re-grant then undoes: that was
    /// two receipts and an IDFA identify on every launch, recording a change the user never made.
    func testAMeasurementStartFollowedByATrackingGrantSendsNothing() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        try await Task.sleep(for: .milliseconds(200))
        await first.shutdown()

        for launchNumber in 2...3 {
            let (next, _) = launch(device, server: server)
            await next.start(apiKey: apiKey, consent: .measurementGranted)
            let replayed = await waitUntil { await server.firstOpenCount() == launchNumber }
            XCTAssertTrue(replayed)
            // After registration, so the drain has already compared start's consent with the server.
            try await Task.sleep(for: .milliseconds(200))
            await next.setConsent(.trackingGranted)
            try await Task.sleep(for: .milliseconds(200))
            await next.shutdown()
        }

        let receipts = await server.receipts()
        let identifies = await server.identifyCount()
        let held = await server.occurrence(epoch)?.consentClass
        XCTAssertEqual(receipts, [], "a launch that ended where it began sent receipts")
        XCTAssertEqual(identifies, 0, "an IDFA the server holds was sent again")
        XCTAssertEqual(held, "tracking_granted")
    }

    /// The hold covers only what start declared. A setConsent is the app's answer, and a withdrawal
    /// it makes, here after an unknown start on an install the server holds as tracking_granted,
    /// goes out at once.
    func testAWithdrawalMadeBySetConsentIsNotHeldForTheForeground() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        await first.shutdown()

        let (second, _) = launch(device, server: server, idfa: { nil })
        await second.start(apiKey: apiKey, consent: .unknown)
        await second.setConsent(.measurementGranted)

        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "setConsent's withdrawal waited for the app to leave the foreground")
        await second.shutdown()
    }

    /// The documented integration with ATT turned off in Settings: start with `.measurementGranted`,
    /// then pass requestConsent()'s answer, the same `.measurementGranted`, to setConsent. That
    /// setConsent changes nothing and raises no receipt of its own, so it must release the
    /// withdrawal start's hold kept back; otherwise an app killed after each session never sent it.
    func testASetConsentRepeatingStartsWithdrawalStillSendsIt() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        await first.shutdown()

        let (second, _) = launch(device, server: server, idfa: { nil })
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await server.firstOpenCount() == 2 }
        XCTAssertTrue(replayed)
        // After registration, so the drain has already held start's withdrawal.
        try await Task.sleep(for: .milliseconds(200))
        await second.setConsent(.measurementGranted)

        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "the withdrawal start held was never sent")
        await second.shutdown()
    }

    /// A process that terminates without resigning active first (a background launch, say) also
    /// ends start's hold.
    func testTerminationSendsTheWithdrawalStartHeld() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        await first.shutdown()

        let lifecycle = ManualLifecycleObserver()
        let (second, _) = launch(device, server: server, idfa: { nil }, lifecycle: lifecycle)
        await second.start(apiKey: apiKey, consent: .measurementGranted)
        let replayed = await waitUntil { await server.firstOpenCount() == 2 }
        XCTAssertTrue(replayed)
        try await Task.sleep(for: .milliseconds(200))
        let held = await server.consentCount()
        XCTAssertEqual(held, 0)
        await lifecycle.send(.willTerminate)

        let downgraded = await waitUntil(timeout: .seconds(5)) {
            await server.occurrence(epoch)?.consentClass == "measurement_granted"
        }
        XCTAssertTrue(downgraded, "termination did not send the withdrawal start held")
        await second.shutdown()
    }

    /// The registration sends one identify for a stored user id, and it carries the IDFA. The drain
    /// waits for it rather than sending a second one for the same IDFA.
    func testRegistrationWithAStoredUserIDSendsOneIdentifyForTheIDFA() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let currentIDFA = LockedIDFA(nil)

        // Tracking granted before the IDFA could be read: the first-open carried none.
        let (first, firstStorage) = launch(device, server: server, idfa: { currentIDFA.value })
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        try await Task.sleep(for: .milliseconds(200))
        await first.shutdown()

        currentIDFA.value = idfa
        await server.holdIdentifies()
        let (second, _) = launch(device, server: server, idfa: { currentIDFA.value })
        await second.setUserID("user-1")
        await second.start(apiKey: apiKey, consent: .trackingGranted)
        let identifying = await waitUntil { await server.heldIdentifyCount() == 1 }
        XCTAssertTrue(identifying, "the stored user id's identify was not sent")
        try await Task.sleep(for: .milliseconds(300))
        let whileHeld = await server.identifyCount()
        XCTAssertEqual(whileHeld, 1, "the drain sent a second identify while the first was in flight")
        await server.releaseIdentifies()
        try await Task.sleep(for: .milliseconds(300))

        let identifies = await server.identifyCount()
        let kept = await server.occurrence(epoch)?.idfa
        XCTAssertEqual(identifies, 1)
        XCTAssertEqual(kept, expectedIDFA())
        await second.shutdown()
    }

    /// An identify answered after a denial wiped the device's records must not write the IDFA
    /// digest back.
    func testAnIdentifyAnsweredAfterADenialDoesNotRecordItsIDFA() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()
        let currentIDFA = LockedIDFA(idfa)
        let (runtime, storage) = launch(device, server: server, idfa: { currentIDFA.value })
        let identity = try await storage.initializeIdentities()
        let epoch = identity.installEpochID
        await runtime.start(apiKey: apiKey, consent: .trackingGranted)
        let recorded = await waitUntil { await storage.deliveredIDFADigest(installEpochID: epoch) != nil }
        XCTAssertTrue(recorded)

        // A reset IDFA, so the user id's identify carries one the server does not hold yet.
        currentIDFA.value = UUID()
        await server.holdIdentifies()
        // Not awaited: its identify is held in flight until after the denial.
        let identifying = Task { await runtime.setUserID("user-1") }
        let inFlight = await waitUntil { await server.heldIdentifyCount() == 1 }
        XCTAssertTrue(inFlight)
        await runtime.setConsent(.denied)
        await server.releaseIdentifies()
        await identifying.value

        let digest = await storage.deliveredIDFADigest(installEpochID: epoch)
        XCTAssertNil(digest, "an identify answered after the denial wrote the IDFA digest back")
        await runtime.shutdown()
    }

    /// Both records answer only for the epoch they were written for: after a revocation rotates the
    /// epoch, the old epoch's revoked must not read as the new epoch's server consent.
    func testTheServerRecordsAnswerOnlyForTheirOwnEpoch() async throws {
        let storage = makeDevice().storage()
        let old = UUID()
        let new = UUID()
        await storage.setServerConsent(.revoked, installEpochID: old)
        await storage.setDeliveredIDFADigest("digest", installEpochID: old)
        let consent = await storage.serverConsent(installEpochID: new)
        let digest = await storage.deliveredIDFADigest(installEpochID: new)
        XCTAssertNil(consent)
        XCTAssertNil(digest)
        let own = await storage.serverConsent(installEpochID: old)
        XCTAssertEqual(own, .revoked)
    }

    // MARK: - No extra traffic

    /// A device that never changes consent sends what it always sent: the first-open carries the
    /// IDFA and the server applies it, so neither a receipt nor an identify is owed, on this launch
    /// or the next.
    func testAnInstallThatStartsUnderTrackingConsentSendsNoReceiptAndNoIdentify() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .trackingGranted)
        let registered = await waitUntil { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(registered)
        try await Task.sleep(for: .milliseconds(300))
        await first.shutdown()

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .trackingGranted)
        let replayed = await waitUntil { await server.firstOpenCount() == 2 }
        XCTAssertTrue(replayed)
        try await Task.sleep(for: .milliseconds(300))
        await second.shutdown()

        let receipts = await server.consentCount()
        let identifies = await server.identifyCount()
        XCTAssertEqual(receipts, 0, "a receipt was sent with nothing to change")
        XCTAssertEqual(identifies, 0, "an identify was sent for an IDFA the first-open delivered")
    }

    /// Once the IDFA is delivered it is not sent again on every launch: the next launch replays its
    /// first-open and sends nothing else.
    func testADeliveredIDFAIsNotSentAgainOnTheNextLaunch() async throws {
        let server = ConsentModelServer()
        let device = makeDevice()

        let (first, firstStorage) = launch(device, server: server)
        let epoch = try await epoch(firstStorage)
        await first.start(apiKey: apiKey, consent: .measurementGranted)
        let registered = await waitUntil { await server.occurrence(epoch) != nil }
        XCTAssertTrue(registered)
        await first.setConsent(.trackingGranted)
        let delivered = await waitUntil(timeout: .seconds(5)) { await server.occurrence(epoch)?.idfa != nil }
        XCTAssertTrue(delivered)
        try await Task.sleep(for: .milliseconds(300))
        await first.shutdown()
        let receiptsBefore = await server.consentCount()
        let identifiesBefore = await server.identifyCount()

        let (second, _) = launch(device, server: server)
        await second.start(apiKey: apiKey, consent: .trackingGranted)
        let replayed = await waitUntil { await server.firstOpenCount() >= 2 }
        XCTAssertTrue(replayed)
        try await Task.sleep(for: .milliseconds(300))
        await second.shutdown()

        let receiptsAfter = await server.consentCount()
        let identifiesAfter = await server.identifyCount()
        XCTAssertEqual(receiptsAfter, receiptsBefore, "the next launch sent another receipt")
        XCTAssertEqual(identifiesAfter, identifiesBefore, "the next launch sent the delivered IDFA again")
    }
}

private final class LockedIDFA: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?

    init(_ value: UUID?) { current = value }

    var value: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// The ingest rules that decide whether an IDFA is kept, as apps/link/src/ingestion/repository.ts
/// applies them: a first-open registers its epoch under the consent it declares and keeps its IDFA
/// only under tracking_granted; a different body for a stored epoch is a 409 that changes nothing;
/// a receipt sets the occurrence's consent; an identify keeps its IDFA only while that consent is
/// tracking_granted and changes nothing for a denied or revoked occurrence. Anything about an
/// epoch the server does not hold is the retriable `unknown_install_epoch`.
actor ConsentModelServer: HTTPTransport {
    struct Occurrence: Sendable {
        let body: Data
        var consentClass: String
        var idfa: String?
    }

    private var occurrences: [String: Occurrence] = [:]
    private var log: [(path: String, body: Data)] = []
    private var lostFirstOpenAnswers = 0
    private var receiptsHeld = false
    private var heldReceipts: [CheckedContinuation<Void, Never>] = []
    private var receiptsFail = false
    private var identifiesHeld = false
    private var heldIdentifies: [CheckedContinuation<Void, Never>] = []

    func loseFirstOpenAnswers(_ count: Int) { lostFirstOpenAnswers = count }
    func holdConsentReceipts() { receiptsHeld = true }
    func releaseConsentReceipts() {
        receiptsHeld = false
        let waiting = heldReceipts
        heldReceipts.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func failConsentReceipts(_ failing: Bool) { receiptsFail = failing }
    func heldReceiptCount() -> Int { heldReceipts.count }
    func holdIdentifies() { identifiesHeld = true }
    func heldIdentifyCount() -> Int { heldIdentifies.count }
    func releaseIdentifies() {
        identifiesHeld = false
        let waiting = heldIdentifies
        heldIdentifies.removeAll()
        for waiter in waiting { waiter.resume() }
    }

    func occurrence(_ epoch: String) -> Occurrence? { occurrences[epoch] }
    func firstOpenCount() -> Int { count("/v1/ingest/first-open") }
    func consentCount() -> Int { count("/v1/ingest/consent") }
    func identifyCount() -> Int { count("/v1/ingest/identify") }
    func requestCount() -> Int { log.count }

    /// Every receipt sent, as `scope:state`.
    func receipts() -> [String] {
        log.filter { $0.path.hasSuffix("/v1/ingest/consent") }.compactMap { entry in
            guard let json = try? JSONSerialization.jsonObject(with: entry.body) as? [String: Any],
                  let scope = json["scope"] as? String,
                  let state = (json["consent"] as? [String: Any])?["state"] as? String else { return nil }
            return "\(scope):\(state)"
        }
    }

    /// Every request after the first `firstLaunchRequests` that carried an `idfa` key, by path.
    func idfaCarriersAfter(firstLaunchRequests: Int) -> [String] {
        log.dropFirst(firstLaunchRequests).compactMap { entry in
            guard let json = try? JSONSerialization.jsonObject(with: entry.body) as? [String: Any],
                  let value = json["idfa"], !(value is NSNull) else { return nil }
            return entry.path
        }
    }

    private func count(_ suffix: String) -> Int {
        log.filter { $0.path.hasSuffix(suffix) }.count
    }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let path = request.url?.path ?? ""
        let body = request.httpBody.flatMap { try? gunzipStored($0) } ?? Data()
        log.append((path, body))
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let epoch = (json["install_epoch_id"] as? String)?.lowercased() ?? ""
        let state = (json["consent"] as? [String: Any])?["state"] as? String

        if path.hasSuffix("/v1/ingest/first-open") {
            if let existing = occurrences[epoch] {
                if existing.body != body {
                    return HTTPResult(statusCode: 409, data: Data(#"{"error":"idempotency_conflict"}"#.utf8), headers: [:])
                }
                return successResult()
            }
            let declared = state ?? "unknown"
            occurrences[epoch] = Occurrence(
                body: body,
                consentClass: declared,
                idfa: declared == "tracking_granted" ? json["idfa"] as? String : nil
            )
            if lostFirstOpenAnswers > 0 {
                lostFirstOpenAnswers -= 1
                throw URLError(.timedOut)
            }
            return successResult()
        }
        if path.hasSuffix("/v1/ingest/consent") {
            if receiptsHeld {
                await withCheckedContinuation { heldReceipts.append($0) }
            }
            if receiptsFail { throw URLError(.notConnectedToInternet) }
            guard occurrences[epoch] != nil, let state else { return Self.unknownEpoch }
            occurrences[epoch]?.consentClass = state
            return HTTPResult(statusCode: 200, data: Data(#"{"status":"accepted"}"#.utf8), headers: [:])
        }
        if path.hasSuffix("/v1/ingest/identify") {
            guard var occurrence = occurrences[epoch] else { return Self.unknownEpoch }
            if occurrence.consentClass == "tracking_granted", let idfa = json["idfa"] as? String {
                occurrence.idfa = idfa
            }
            occurrences[epoch] = occurrence
            // Applied on arrival; only the answer is held, as a slow network holds it.
            if identifiesHeld {
                await withCheckedContinuation { heldIdentifies.append($0) }
            }
            return HTTPResult(statusCode: 200, data: Data(#"{"status":"accepted"}"#.utf8), headers: [:])
        }
        if path.contains("events:batch") {
            return successResult(body: #"{"status":"accepted","inserted":1,"duplicates":0}"#)
        }
        return successResult()
    }

    private static let unknownEpoch = HTTPResult(
        statusCode: 503,
        data: Data(#"{"error":"unknown_install_epoch"}"#.utf8),
        headers: [:]
    )
}
