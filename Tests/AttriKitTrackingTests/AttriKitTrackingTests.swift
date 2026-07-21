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
