import Foundation
import AttriKitCore
@testable import AttriKitLinkToken
import XCTest

final class AttriKitLinkTokenTests: XCTestCase {
    private actor TokenAcceptanceSpy {
        private var accepted: [(token: String, kind: String)] = []

        func accept(_ token: String, kind: String) -> DeepLinkResult {
            accepted.append((token, kind))
            return .handled(URL(fileURLWithPath: "/accepted-token"))
        }

        func acceptedTokens() -> [String] { accepted.map(\.token) }
        func acceptedKinds() -> [String] { accepted.map(\.kind) }
    }

    func testCoreTypesWorkWithoutLinkTokenRuntimeInitialization() throws {
        XCTAssertEqual(try AttriKitEvent("app_opened").name, "app_opened")
        XCTAssertFalse(AttriKitConsent.measurementGranted.allowsTracking)
    }

    func testConsumePasteboardIgnoresNonTokenWithoutTransmission() async {
        let spy = TokenAcceptanceSpy()

        let result = await AttriKitLinkToken.consumePasteboardValue("password123456789") { token, kind in
            await spy.accept(token, kind: kind)
        }

        XCTAssertEqual(result, .ignored)
        let acceptedTokens = await spy.acceptedTokens()
        XCTAssertEqual(acceptedTokens, [])
    }

    func testConsumePasteboardAcceptsVersionedBareToken() async {
        let spy = TokenAcceptanceSpy()
        let token = "ak1_" + String(repeating: "A", count: 43)

        let result = await AttriKitLinkToken.consumePasteboardValue(token) { token, kind in
            await spy.accept(token, kind: kind)
        }

        XCTAssertEqual(result, .handled(URL(fileURLWithPath: "/accepted-token")))
        let acceptedTokens = await spy.acceptedTokens()
        XCTAssertEqual(acceptedTokens, [token])
        let acceptedKinds = await spy.acceptedKinds()
        XCTAssertEqual(acceptedKinds, ["clipboard"])
    }

    func testConsumePasteboardRejectsUnapprovedURLHostWithoutTransmission() async {
        let spy = TokenAcceptanceSpy()
        let token = "ak1_" + String(repeating: "B", count: 43)
        let url = "https://example.com/install?attrkit_token=\(token)"

        let result = await AttriKitLinkToken.consumePasteboardValue(url) { token, kind in
            await spy.accept(token, kind: kind)
        }

        XCTAssertEqual(result, .ignored)
        let acceptedTokens = await spy.acceptedTokens()
        XCTAssertEqual(acceptedTokens, [])
    }

    func testConsumePasteboardAcceptsApprovedURLHost() async {
        let spy = TokenAcceptanceSpy()
        let token = "ak1_" + String(repeating: "_", count: 43)
        let url = "https://attrikit.io/install?attrkit_token=\(token)"

        let result = await AttriKitLinkToken.consumePasteboardValue(url) { token, kind in
            await spy.accept(token, kind: kind)
        }

        XCTAssertEqual(result, .handled(URL(fileURLWithPath: "/accepted-token")))
        let acceptedTokens = await spy.acceptedTokens()
        XCTAssertEqual(acceptedTokens, [token])
        let acceptedKinds = await spy.acceptedKinds()
        XCTAssertEqual(acceptedKinds, ["clipboard"])
    }

    func testPrivacyManifestParsesWithoutTrackingDomains() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot
            .appendingPathComponent("Sources/AttriKitLinkToken/Resources/PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifestURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(plist["NSPrivacyTrackingDomains"] as? [String], [])
    }
}
