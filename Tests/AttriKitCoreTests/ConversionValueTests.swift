import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// The conversion-value schema and its single writer: every rung, the monotonic rule, the lock,
/// and the serialization that keeps a later milestone from lowering an earlier write.
@MainActor
final class ConversionValueTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    private func schema(_ thresholds: [Double] = [10, 50], activation: String? = "onboarding_completed") throws -> AttriKitConversionSchema {
        try AttriKitConversionSchema(version: 1, revenueThresholds: thresholds, currency: "USD", activationEvent: activation)
    }

    func testTheSchemaRefusesWhatWouldDecodeWrongOrOverflowSixtyThree() {
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 0, revenueThresholds: [], currency: "USD"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: [50, 10], currency: "USD"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: [10, 10], currency: "USD"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: [0, 10], currency: "USD"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: [.infinity], currency: "USD"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: [], currency: "usd"))
        XCTAssertThrowsError(try AttriKitConversionSchema(version: 1, revenueThresholds: (1...61).map(Double.init), currency: "USD"))
        XCTAssertNoThrow(try AttriKitConversionSchema(version: 1, revenueThresholds: (1...60).map(Double.init), currency: "USD"))
    }

    /// 0 install, 1 activation (low), 2 trial (medium), then revenue buckets from 3 (high); the top
    /// bucket locks the window because nothing higher can follow.
    func testEveryRungOfTheLadder() throws {
        let schema = try schema()
        var state = ConversionValueState(schemaVersion: 1)
        func step(_ milestone: AttriKitConversionMilestone) -> ConversionValueWrite? {
            let planned = ConversionValuePlan.apply(milestone, to: state, schema: schema)
            state = planned.state
            if let write = planned.write {
                state.writtenFine = write.fine
                state.writtenCoarse = write.coarse
                state.locked = write.lock
            }
            return planned.write
        }

        XCTAssertEqual(step(.activation), ConversionValueWrite(fine: 1, coarse: .low, lock: false))
        XCTAssertNil(step(.activation), "a repeated milestone writes nothing")
        XCTAssertEqual(step(.trialStarted), ConversionValueWrite(fine: 2, coarse: .medium, lock: false))
        XCTAssertEqual(step(.revenue(4.99)), ConversionValueWrite(fine: 3, coarse: .high, lock: false))
        XCTAssertNil(step(.revenue(4.99)), "9.98 is still under the first threshold")
        XCTAssertEqual(step(.revenue(0.02)), ConversionValueWrite(fine: 4, coarse: .high, lock: false), "10.00 reaches the first threshold")
        XCTAssertEqual(step(.revenue(100)), ConversionValueWrite(fine: 5, coarse: .high, lock: true), "the top bucket locks")
        XCTAssertNil(step(.revenue(1_000)), "nothing is written after the lock")
    }

    /// A value is only ever raised: a trial after a purchase, or activation after a trial, must not
    /// lower what is already written.
    func testALaterLowerMilestoneNeverLowersTheValue() throws {
        let schema = try schema()
        var state = ConversionValueState(schemaVersion: 1)
        state.revenue = 20
        state.writtenFine = 4
        state.writtenCoarse = .high
        XCTAssertNil(ConversionValuePlan.apply(.trialStarted, to: state, schema: schema).write)
        XCTAssertNil(ConversionValuePlan.apply(.activation, to: state, schema: schema).write)
    }

    func testRevenueThatIsNotRevenueCountsForNothing() throws {
        let schema = try schema()
        for amount in [0, -5, .nan, .infinity] {
            let planned = ConversionValuePlan.apply(.revenue(amount), to: ConversionValueState(schemaVersion: 1), schema: schema)
            XCTAssertNil(planned.write, "\(amount)")
            XCTAssertEqual(planned.state.revenue, 0, "\(amount)")
        }
    }

    /// An install that started under another schema version keeps its values: the two decode
    /// differently, and a mixed postback would be read wrong.
    func testAnotherSchemaVersionNeverWritesOverAnInstall() throws {
        let planned = ConversionValuePlan.apply(.trialStarted, to: ConversionValueState(schemaVersion: 2), schema: try schema())
        XCTAssertNil(planned.write)
    }

    func testTrackedEventsMapToMilestones() throws {
        let schema = try schema()
        XCTAssertEqual(ConversionValuePlan.milestone(for: try AttriKitEvent("onboarding_completed"), properties: [:], schema: schema), .activation)
        XCTAssertEqual(ConversionValuePlan.milestone(for: try AttriKitEvent("trial_started"), properties: [:], schema: schema), .trialStarted)
        XCTAssertEqual(
            ConversionValuePlan.milestone(for: try AttriKitEvent("purchase"), properties: ["value": 9.99, "currency": "usd"], schema: schema),
            .revenue(9.99)
        )
        // No conversion between currencies, and no revenue without a numeric value.
        XCTAssertNil(ConversionValuePlan.milestone(for: try AttriKitEvent("purchase"), properties: ["value": 9.99, "currency": "EUR"], schema: schema))
        XCTAssertNil(ConversionValuePlan.milestone(for: try AttriKitEvent("purchase"), properties: ["value": "9.99", "currency": "USD"], schema: schema))
        XCTAssertNil(ConversionValuePlan.milestone(for: try AttriKitEvent("app_opened"), properties: [:], schema: schema))
    }

    // MARK: - the runtime as the single writer

    private func runtime(_ updater: RecordingUpdater, transport: StubTransport = StubTransport { _, _ in successResult() }) -> CoreRuntime {
        CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: SDKStorage(
                defaults: .init(value: UserDefaults(suiteName: "ConversionValueTests.\(UUID())")!),
                keychain: MemoryKeychain(),
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            ),
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() },
            lifecycle: ManualLifecycleObserver(),
            conversionValues: ConversionValueUpdater { write in try await updater.record(write) }
        ))
    }

    func testTrackedEventsRaiseTheValueThroughOneWriter() async throws {
        let updater = RecordingUpdater()
        let core = runtime(updater)
        await core.configureConversionValues(try schema())
        await core.start(apiKey: apiKey, consent: .measurementGranted)
        await core.track(try AttriKitEvent("onboarding_completed"), properties: [:])
        await core.track(try AttriKitEvent("trial_started"), properties: [:])
        await core.track(try AttriKitEvent("purchase"), properties: ["value": 12, "currency": "USD"])
        let writes = await updater.writes
        XCTAssertEqual(writes.map(\.fine), [1, 2, 4])
        XCTAssertEqual(writes.map(\.coarse), [.low, .medium, .high])
        await core.shutdown()
    }

    /// Concurrent milestones each suspend on StoreKit. Without the chain, a trial read the state
    /// before the purchase wrote it and was written AFTER it, lowering 3 back to 2.
    func testConcurrentMilestonesNeverWriteALowerValue() async throws {
        let updater = RecordingUpdater(delay: .milliseconds(30))
        let core = runtime(updater)
        await core.configureConversionValues(try schema())
        await core.start(apiKey: apiKey, consent: .measurementGranted)
        async let purchase: Void = core.recordConversion(.revenue(5))
        async let trial: Void = core.recordConversion(.trialStarted)
        async let activation: Void = core.recordConversion(.activation)
        _ = await (purchase, trial, activation)
        let fines = await updater.writes.map(\.fine)
        XCTAssertEqual(fines, fines.sorted(), "a later write lowered the value: \(fines)")
        XCTAssertEqual(fines.last, 3)
        await core.shutdown()
    }

    /// A refused update is not recorded as written, so the next milestone writes it again.
    func testARefusedUpdateIsRetriedByTheNextMilestone() async throws {
        let updater = RecordingUpdater(failures: 1)
        let core = runtime(updater)
        await core.configureConversionValues(try schema())
        await core.start(apiKey: apiKey, consent: .measurementGranted)
        await core.recordConversion(.trialStarted)
        await core.recordConversion(.activation)
        let writes = await updater.writes
        XCTAssertEqual(writes.map(\.fine), [2], "the refused trial write was never retried")
        await core.shutdown()
    }

    /// A deletion that lands while the update is suspended on StoreKit wipes the state; the resumed
    /// update must not write it back.
    func testADeletionDuringTheUpdateIsNotUndone() async throws {
        let updater = RecordingUpdater(delay: .milliseconds(300))
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "ConversionValueTests.\(UUID())")!),
            keychain: MemoryKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let core = CoreRuntime(configuration: AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: StubTransport { _, _ in successResult() },
            storage: storage,
            evidence: StubEvidence(transaction: nil, adToken: nil),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() },
            lifecycle: ManualLifecycleObserver(),
            conversionValues: ConversionValueUpdater { write in try await updater.record(write) }
        ))
        await core.configureConversionValues(try schema())
        await core.start(apiKey: apiKey, consent: .measurementGranted)
        async let conversion: Void = core.recordConversion(.trialStarted)
        try await Task.sleep(for: .milliseconds(50))
        try await core.deleteData()
        await conversion
        let resurrected = await storage.conversionValueState()
        XCTAssertNil(resurrected, "the conversion state came back after the deletion wiped it")
        await core.shutdown()
    }

    /// Events tracked before `start` are replayed at start; an app told to configure conversion
    /// values first also tracks its first events first, and they count.
    func testEventsTrackedBeforeStartStillRaiseTheValue() async throws {
        let updater = RecordingUpdater()
        let core = runtime(updater)
        await core.configureConversionValues(try schema())
        await core.track(try AttriKitEvent("trial_started"), properties: [:])
        await core.start(apiKey: apiKey, consent: .measurementGranted)
        let writes = await updater.writes
        XCTAssertEqual(writes.map(\.fine), [2])
        await core.shutdown()
    }

    func testNothingIsWrittenWithoutMeasurementConsent() async throws {
        let updater = RecordingUpdater()
        let core = runtime(updater)
        await core.configureConversionValues(try schema())
        await core.start(apiKey: apiKey, consent: .denied)
        await core.recordConversion(.trialStarted)
        let writes = await updater.writes
        XCTAssertEqual(writes, [])
        await core.shutdown()
    }
}

private actor RecordingUpdater {
    private(set) var writes: [ConversionValueWrite] = []
    private var failures: Int
    private let delay: Duration

    init(delay: Duration = .zero, failures: Int = 0) {
        self.delay = delay
        self.failures = failures
    }

    struct Refused: Error {}

    func record(_ write: ConversionValueWrite) async throws {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if failures > 0 {
            failures -= 1
            throw Refused()
        }
        writes.append(write)
    }
}
