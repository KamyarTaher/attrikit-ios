import AttrKitCore
import AttrKitLinkToken
import XCTest

final class AttrKitLinkTokenTests: XCTestCase {
    func testCoreTypesWorkWithoutLinkTokenRuntimeInitialization() throws {
        XCTAssertEqual(try AttrKitEvent("app_opened").name, "app_opened")
        XCTAssertFalse(AttrKitConsent.measurementGranted.allowsTracking)
    }
}
