import AttriKitCore
@testable import AttriKitTracking
import Foundation
import XCTest

final class AttriKitTrackingTests: XCTestCase {
    override func tearDown() {
        AttriKitTracking.resetTestingConfiguration()
        super.tearDown()
    }

    func testConsentMappingCoversEveryAuthorizationState() {
        XCTAssertEqual(AttriKitTracking.consent(for: .authorized), .trackingGranted)
        XCTAssertEqual(AttriKitTracking.consent(for: .denied), .denied)
        XCTAssertEqual(AttriKitTracking.consent(for: .restricted), .denied)
        XCTAssertEqual(AttriKitTracking.consent(for: .notDetermined), .unknown)
        XCTAssertEqual(AttriKitTracking.consent(for: .unavailable), .unknown)
    }

    func testRequestConsentReturnsMappedSystemStatus() async {
        AttriKitTracking.configureForTesting(StubTrackingSystem(
            status: .authorized,
            idfa: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
            idfv: UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        ))

        let consent = await AttriKitTracking.requestConsent()
        XCTAssertEqual(consent, .trackingGranted)
    }

    func testRequestConsentWaitsUntilApplicationIsActiveBeforeRequestingATT() async {
        let system = CountingTrackingSystem(status: .authorized)
        let applicationActivation = ManualApplicationActivation(active: false)
        AttriKitTracking.configureForTesting(
            system,
            applicationActivation: applicationActivation
        )

        let request = Task { await AttriKitTracking.requestConsent() }
        let waiting = await waitUntil {
            await applicationActivation.waiterCount() == 1
        }
        XCTAssertTrue(waiting, "the inactive request must wait for application activation")
        let callsWhileInactive = system.requestCount
        XCTAssertEqual(callsWhileInactive, 0, "ATT must not be requested while the application is inactive")

        await applicationActivation.activate()
        let consent = await request.value
        XCTAssertEqual(consent, .trackingGranted)
        let callsAfterActivation = system.requestCount
        XCTAssertEqual(callsAfterActivation, 1)
    }

    func testPrivacyManifestDeclaresTrackingDeviceIDWithoutDomains() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: packageRoot.appendingPathComponent(
            "Sources/AttriKitTracking/Resources/PrivacyInfo.xcprivacy"
        ))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let rows = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let deviceID = try XCTUnwrap(rows.first)

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, true)
        // MUST be empty. iOS blocks every request to a domain listed here when App Tracking
        // Transparency is not authorized, and attrikit.io is the single ingest host for first-open,
        // events, identify, consent receipts and /v1/privacy/delete — so naming it disables
        // measurement and erasure for every user who declines the prompt. The host configures the
        // endpoint at runtime and declares its own domain. Listing it here shipped in 2.2.0 and was
        // reverted in 2.2.1; this assertion is what stops it coming back.
        XCTAssertEqual(plist["NSPrivacyTrackingDomains"] as? [String], [])
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataType"] as? String, "NSPrivacyCollectedDataTypeDeviceID")
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataTypeTracking"] as? Bool, true)
        XCTAssertEqual(deviceID["NSPrivacyCollectedDataTypePurposes"] as? [String], [
            "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising",
        ])
    }

    func testAdvertisingIdentifierIsNilWhenDenied() {
        AttriKitTracking.configureForTesting(StubTrackingSystem(
            status: .denied,
            idfa: UUID(uuidString: "11111111-1111-4111-8111-111111111111"),
            idfv: UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        ))

        XCTAssertNil(AttriKitTracking.advertisingIdentifier)
    }

    func testAdvertisingIdentifierNeverReturnsZeroSentinel() {
        AttriKitTracking.configureForTesting(StubTrackingSystem(
            status: .authorized,
            idfa: UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
            idfv: nil
        ))

        XCTAssertNil(AttriKitTracking.advertisingIdentifier)
    }

    func testVendorIdentifierIsAvailableWithoutTrackingConsent() {
        let expected = UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        AttriKitTracking.configureForTesting(StubTrackingSystem(
            status: .denied,
            idfa: nil,
            idfv: expected
        ))

        XCTAssertEqual(AttriKitTracking.vendorIdentifier, expected)
    }
}

private struct StubTrackingSystem: TrackingSystemProviding {
    let status: TrackingAuthorizationStatus
    let idfa: UUID?
    let idfv: UUID?

    var authorizationStatus: TrackingAuthorizationStatus { status }
    var advertisingIdentifier: UUID? { idfa }
    var vendorIdentifier: UUID? { idfv }
    func requestAuthorization() async -> TrackingAuthorizationStatus { status }
}

private final class CountingTrackingSystem: TrackingSystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let status: TrackingAuthorizationStatus
    private var calls = 0

    init(status: TrackingAuthorizationStatus) {
        self.status = status
    }

    var authorizationStatus: TrackingAuthorizationStatus { status }
    var advertisingIdentifier: UUID? { nil }
    var vendorIdentifier: UUID? { nil }
    var requestCount: Int { locked { calls } }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        locked { calls += 1 }
        return status
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor ManualApplicationActivation: ApplicationActivationProviding {
    private var active: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(active: Bool) {
        self.active = active
    }

    func isActive() -> Bool { active }

    func waitUntilActive() async {
        if active { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func activate() {
        active = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waiterCount() -> Int { waiters.count }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
