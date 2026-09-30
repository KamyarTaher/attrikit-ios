import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// Google's DMA values (`consent.dma`): derived from the IAB TCF keys by Google's own mapping, or
/// set explicitly, and carried on every event and on first-open.
@MainActor
final class GoogleConsentTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    // MARK: - The TCF mapping

    /// A TCF binary string with exactly `ids` set, index n standing for id n+1.
    private static func bits(_ ids: Set<Int>, length: Int = 800) -> String {
        String((1...length).map { ids.contains($0) ? "1" : "0" })
    }

    private func defaults(
        gdprApplies: Any? = 1,
        purposes: Set<Int> = [],
        purposeInterests: Set<Int> = [],
        vendors: Set<Int> = [],
        vendorInterests: Set<Int> = [],
        restrictions: [Int: String] = [:]
    ) throws -> UserDefaults {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "AttriKitTests.tcf.\(UUID())"))
        if let gdprApplies { suite.set(gdprApplies, forKey: "IABTCF_gdprApplies") }
        suite.set(Self.bits(purposes, length: 11), forKey: "IABTCF_PurposeConsents")
        suite.set(Self.bits(purposeInterests, length: 11), forKey: "IABTCF_PurposeLegitimateInterests")
        suite.set(Self.bits(vendors), forKey: "IABTCF_VendorConsents")
        suite.set(Self.bits(vendorInterests), forKey: "IABTCF_VendorLegitimateInterests")
        for (purpose, restriction) in restrictions {
            suite.set(restriction, forKey: "IABTCF_PublisherRestrictions\(purpose)")
        }
        return suite
    }

    func testNoGdprAppliesDerivesNothing() throws {
        XCTAssertNil(TCFConsent.dmaConsent(from: try defaults(gdprApplies: nil, purposes: [1, 3, 4, 7], vendors: [755])))
        XCTAssertNil(TCFConsent.dmaConsent(from: try defaults(gdprApplies: 2, purposes: [1, 3, 4, 7], vendors: [755])))
    }

    func testGdprNotApplyingIsSentAloneAsOutsideTheEEA() throws {
        XCTAssertEqual(
            TCFConsent.dmaConsent(from: try defaults(gdprApplies: 0, purposes: [1, 3, 4, 7], vendors: [755])),
            DMAConsent(eea: false, adUserData: nil, adPersonalization: nil, source: .tcf)
        )
    }

    func testFullConsentGrantsBoth() throws {
        XCTAssertEqual(
            TCFConsent.dmaConsent(from: try defaults(purposes: [1, 2, 3, 4], purposeInterests: [7], vendors: [755], vendorInterests: [755])),
            DMAConsent(eea: true, adUserData: true, adPersonalization: true, source: .tcf)
        )
    }

    /// The coordinator's case: an EU user whose choices grant data use but not personalization.
    func testDataGrantedButPersonalizationDenied() throws {
        XCTAssertEqual(
            TCFConsent.dmaConsent(from: try defaults(purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755])),
            DMAConsent(eea: true, adUserData: true, adPersonalization: false, source: .tcf)
        )
        // Purpose 3 alone is not enough: Google needs 3 and 4.
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(purposes: [1, 3], purposeInterests: [7], vendors: [755], vendorInterests: [755]))?.adPersonalization, false)
    }

    func testEachPurposeGoogleNamesIsRequired() throws {
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(purposes: [3, 4], purposeInterests: [7], vendors: [755], vendorInterests: [755]))?.adUserData, false, "purpose 1")
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(purposes: [1, 3, 4], vendors: [755], vendorInterests: [755]))?.adUserData, false, "purpose 7")
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(purposes: [1, 3], purposeInterests: [7], vendors: [755], vendorInterests: [755]))?.adPersonalization, false, "purpose 4")
    }

    func testGoogleAsVendorMustBeAllowed() throws {
        XCTAssertEqual(
            TCFConsent.dmaConsent(from: try defaults(purposes: [1, 3, 4, 7], vendors: [754, 756])),
            DMAConsent(eea: true, adUserData: false, adPersonalization: false, source: .tcf)
        )
    }

    /// Google declares Purpose 7 on legitimate interest, with flexibility. With no publisher
    /// restriction a flexible vendor uses its declared basis, so consent to Purpose 7 does not
    /// stand in for it.
    func testPurposeSevenRestsOnGooglesLegitimateInterest() throws {
        let interest = try defaults(purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755])
        XCTAssertEqual(TCFConsent.dmaConsent(from: interest)?.adUserData, true)
        let noVendorInterest = try defaults(purposes: [1], purposeInterests: [7], vendors: [755])
        XCTAssertEqual(TCFConsent.dmaConsent(from: noVendorInterest)?.adUserData, false, "the purpose's interest without Google's")
        let noPurposeInterest = try defaults(purposes: [1], vendors: [755], vendorInterests: [755])
        XCTAssertEqual(TCFConsent.dmaConsent(from: noPurposeInterest)?.adUserData, false, "Google's interest without the purpose's")
        let consentOnly = try defaults(purposes: [1, 7], vendors: [755])
        XCTAssertEqual(TCFConsent.dmaConsent(from: consentOnly)?.adUserData, false, "consent to Purpose 7 in place of legitimate interest")
    }

    func testGdprAppliesWrittenAsAStringIsRead() throws {
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(gdprApplies: "1", purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755]))?.adUserData, true)
    }

    func testAGdprAppliesThatIsNotExactlyZeroOrOneIsMalformed() throws {
        // intValue would truncate each of these to 0 or 1 and send a region the platform never stated.
        for value: Any in [0.5, 0.9999, 1.5, -0.5, "0.5"] {
            XCTAssertNil(TCFConsent.dmaConsent(from: try defaults(gdprApplies: value, purposes: [1, 3, 4, 7], vendors: [755])), "\(value)")
        }
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(gdprApplies: 1.0, purposes: [1, 7], vendors: [755]))?.eea, true)
        XCTAssertEqual(TCFConsent.dmaConsent(from: try defaults(gdprApplies: 0.0, purposes: [1, 7], vendors: [755]))?.eea, false)
    }

    // MARK: - The publisher's restrictions on Google

    /// `IABTCF_PublisherRestrictions{purpose}`: `type` at each vendor in `vendors`, '_' (none) elsewhere.
    private static func restriction(_ type: Character, vendors: Set<Int> = [755], length: Int = 800) -> String {
        String((1...length).map { vendors.contains($0) ? type : "_" })
    }

    /// Every purpose granted by consent, and Purpose 7 by legitimate interest too, so only a
    /// restriction can take a value away.
    private func everythingGranted(restrictions: [Int: String]) throws -> DMAConsent? {
        TCFConsent.dmaConsent(from: try defaults(
            purposes: [1, 3, 4, 7], purposeInterests: [7], vendors: [755], vendorInterests: [755], restrictions: restrictions
        ))
    }

    func testNotAllowedForbidsThePurpose() throws {
        XCTAssertEqual(
            try everythingGranted(restrictions: [1: Self.restriction("0")]),
            DMAConsent(eea: true, adUserData: false, adPersonalization: true, source: .tcf)
        )
        XCTAssertEqual(try everythingGranted(restrictions: [7: Self.restriction("0")])?.adUserData, false, "purpose 7, though both legal bases are there")
        XCTAssertEqual(
            try everythingGranted(restrictions: [3: Self.restriction("0")]),
            DMAConsent(eea: true, adUserData: true, adPersonalization: false, source: .tcf)
        )
        XCTAssertEqual(try everythingGranted(restrictions: [4: Self.restriction("0")])?.adPersonalization, false, "purpose 4")
    }

    /// Google registered Purposes 1, 3 and 4 on consent without flexibility: requiring legitimate
    /// interest forbids them, requiring consent changes nothing.
    func testALegalBasisRestrictionOnGooglesConsentPurposes() throws {
        XCTAssertEqual(
            try everythingGranted(restrictions: [1: Self.restriction("2"), 3: Self.restriction("2")]),
            DMAConsent(eea: true, adUserData: false, adPersonalization: false, source: .tcf)
        )
        XCTAssertEqual(try everythingGranted(restrictions: [4: Self.restriction("2")])?.adPersonalization, false, "purpose 4")
        XCTAssertEqual(
            try everythingGranted(restrictions: [1: Self.restriction("1"), 3: Self.restriction("1"), 4: Self.restriction("1")]),
            DMAConsent(eea: true, adUserData: true, adPersonalization: true, source: .tcf)
        )
    }

    /// Google registered Purpose 7 on legitimate interest with flexibility: requiring consent makes
    /// consent the basis, requiring legitimate interest or no restriction at all leaves legitimate
    /// interest.
    func testPurposeSevenFollowsTheRequiredLegalBasis() throws {
        let requireConsent = [7: Self.restriction("1")]
        let requireInterest = [7: Self.restriction("2")]
        let onInterest = { (restrictions: [Int: String]) in
            TCFConsent.dmaConsent(from: try self.defaults(purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755], restrictions: restrictions))?.adUserData
        }
        let onConsent = { (restrictions: [Int: String]) in
            TCFConsent.dmaConsent(from: try self.defaults(purposes: [1, 7], vendors: [755], restrictions: restrictions))?.adUserData
        }
        XCTAssertEqual(try onInterest(requireConsent), false, "legitimate interest no longer suffices")
        XCTAssertEqual(try onConsent(requireConsent), true)
        XCTAssertEqual(try onConsent(requireInterest), false, "consent no longer suffices")
        XCTAssertEqual(try onInterest(requireInterest), true)
        for unrestricted in [[:], [7: Self.restriction("_")], [7: String(repeating: "1", count: 754)]] {
            XCTAssertEqual(try onInterest(unrestricted), true, "\(unrestricted.mapValues(\.count))")
            XCTAssertEqual(try onConsent(unrestricted), false, "\(unrestricted.mapValues(\.count))")
        }
    }

    /// A restriction character the CMP API does not define is not a restriction lifted: it
    /// forbids the purpose.
    func testAnInvalidRestrictionForbidsThePurpose() throws {
        for invalid: Character in ["3", "x"] {
            XCTAssertEqual(
                try everythingGranted(restrictions: [1: Self.restriction(invalid)]),
                DMAConsent(eea: true, adUserData: false, adPersonalization: true, source: .tcf), "purpose 1, \(invalid)"
            )
            XCTAssertEqual(try everythingGranted(restrictions: [7: Self.restriction(invalid)])?.adUserData, false, "purpose 7, \(invalid)")
            XCTAssertEqual(
                try everythingGranted(restrictions: [3: Self.restriction(invalid)]),
                DMAConsent(eea: true, adUserData: true, adPersonalization: false, source: .tcf), "purpose 3, \(invalid)"
            )
            XCTAssertEqual(try everythingGranted(restrictions: [4: Self.restriction(invalid)])?.adPersonalization, false, "purpose 4, \(invalid)")
        }
    }

    func testOnlyGooglesOwnPositionIsARestrictionOnGoogle() throws {
        // Index n is vendor n+1: a restriction on the vendors either side of 755 is not on Google.
        let neighbours = Self.restriction("0", vendors: [754, 756])
        XCTAssertEqual(
            try everythingGranted(restrictions: [1: neighbours, 3: neighbours, 4: neighbours, 7: neighbours]),
            DMAConsent(eea: true, adUserData: true, adPersonalization: true, source: .tcf)
        )
        // '_' restricts nothing, nor does a string that ends before vendor 755.
        XCTAssertEqual(
            try everythingGranted(restrictions: [1: Self.restriction("_"), 7: String(repeating: "0", count: 754)]),
            DMAConsent(eea: true, adUserData: true, adPersonalization: true, source: .tcf)
        )
    }

    // MARK: - Through the SDK

    private func eventConsents(_ transport: StubTransport) async throws -> [[String: Any]] {
        var consents: [[String: Any]] = []
        for request in await transport.requests() where request.url?.path.contains("events:batch") == true {
            let body = try gunzipStored(XCTUnwrap(request.httpBody))
            let batch = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            for event in try XCTUnwrap(batch["events"] as? [[String: Any]]) {
                consents.append(try XCTUnwrap(event["consent"] as? [String: Any]))
            }
        }
        return consents
    }

    private func trackAndCollect(_ transport: StubTransport, name: String, expecting count: Int) async throws -> [[String: Any]] {
        AttriKit.track(try AttriKitEvent(name))
        let sent = await waitUntil { ((try? await self.eventConsents(transport).count) ?? 0) >= count }
        XCTAssertTrue(sent, "\(name) never reached events:batch")
        return try await eventConsents(transport)
    }

    private func dma(_ consent: [String: Any]) -> [String: Any]? {
        consent["dma"] as? [String: Any]
    }

    func testEventsCarryTheTCFValuesAndAChangedChoiceAppliesToTheNextEvent() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let tcf = try defaults(purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755])
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, tcfDefaults: tcf))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)

        let first = try await trackAndCollect(transport, name: "trial_started", expecting: 1)
        XCTAssertEqual(dma(first[0])?["eea"] as? Bool, true)
        XCTAssertEqual(dma(first[0])?["ad_user_data"] as? Bool, true)
        XCTAssertEqual(dma(first[0])?["ad_personalization"] as? Bool, false)
        XCTAssertEqual(dma(first[0])?["source"] as? String, "tcf")

        tcf.set(Self.bits([1, 3, 4], length: 11), forKey: "IABTCF_PurposeConsents")
        let second = try await trackAndCollect(transport, name: "trial_converted", expecting: 2)
        XCTAssertEqual(dma(second[1])?["ad_personalization"] as? Bool, true, "the changed choice was not read")
    }

    func testTheManualValuesWinOverTCFUntilCleared() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let tcf = try defaults(purposes: [1, 7], vendors: [755])
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, tcfDefaults: tcf))
        AttriKit.setGoogleConsent(eea: true, adUserData: false, adPersonalization: true)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)

        let manual = try await trackAndCollect(transport, name: "trial_started", expecting: 1)
        XCTAssertEqual(dma(manual[0])?["ad_user_data"] as? Bool, false)
        XCTAssertEqual(dma(manual[0])?["ad_personalization"] as? Bool, true)
        XCTAssertEqual(dma(manual[0])?["source"] as? String, "manual")

        AttriKit.clearGoogleConsent()
        let cleared = try await trackAndCollect(transport, name: "trial_converted", expecting: 2)
        XCTAssertEqual(dma(cleared[1])?["source"] as? String, "tcf")
    }

    func testTheManualValuesAreKeptAcrossALaunch() async throws {
        let transport = StubTransport { _, _ in successResult() }
        let suite = try XCTUnwrap(UserDefaults(suiteName: "AttriKitTests.\(UUID())"))
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, defaults: suite))
        AttriKit.setGoogleConsent(eea: true, adUserData: true, adPersonalization: false)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = try await trackAndCollect(transport, name: "trial_started", expecting: 1)

        let relaunched = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: relaunched, defaults: suite))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let after = try await trackAndCollect(relaunched, name: "trial_converted", expecting: 1)
        XCTAssertEqual(dma(after[0])?["source"] as? String, "manual")
        XCTAssertEqual(dma(after[0])?["ad_personalization"] as? Bool, false)
    }

    func testTurningTCFReadingOffSendsNoDMAValues() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, tcfDefaults: try defaults(purposes: [1, 7], vendors: [755])))
        AttriKit.setTCFDataCollectionEnabled(false)
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let consents = try await trackAndCollect(transport, name: "trial_started", expecting: 1)
        XCTAssertNil(consents[0]["dma"])
    }

    func testNoConsentPlatformMeansNoDMAKeyAtAll() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let consents = try await trackAndCollect(transport, name: "trial_started", expecting: 1)
        XCTAssertNil(consents[0]["dma"], "an app without a consent platform must send exactly what it sent before")
    }

    func testFirstOpenCarriesTheDMAValues() async throws {
        let transport = StubTransport { _, _ in successResult() }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport, tcfDefaults: try defaults(purposes: [1], purposeInterests: [7], vendors: [755], vendorInterests: [755])))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let arrived = await waitUntil {
            await transport.requests().contains { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        }
        XCTAssertTrue(arrived)
        let request = await transport.requests().first { $0.url?.path.hasSuffix("/v1/ingest/first-open") == true }
        let body = try gunzipStored(XCTUnwrap(request?.httpBody))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let consent = try XCTUnwrap(json["consent"] as? [String: Any])
        XCTAssertEqual(dma(consent)?["ad_user_data"] as? Bool, true)
        XCTAssertEqual(dma(consent)?["source"] as? String, "tcf")
    }

    func testADeletionForgetsTheManualValues() async throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "AttriKitTests.\(UUID())"))
        let storage = SDKStorage(defaults: .init(value: suite), keychain: MemoryKeychain(), directory: FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitTests-\(UUID())"))
        try await storage.setManualDMAConsent(DMAConsent(eea: true, adUserData: true, adPersonalization: true, source: .manual))
        let stored = await storage.manualDMAConsent()
        XCTAssertNotNil(stored)
        try await storage.deleteAll()
        let afterDeletion = await storage.manualDMAConsent()
        XCTAssertNil(afterDeletion)
    }
}
