import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AttriKitCore

/// The paywall context: every key the server sends reaches the SDK's dictionaries, a context
/// without a campaign always says why, and a provisional answer is watched instead of frozen.
@MainActor
final class AttributionStatusTests: XCTestCase {
    private let apiKey = String(repeating: "k", count: 20)

    private func attributionRequests(_ transport: StubTransport) async -> Int {
        await transport.requests().filter { $0.url?.path.contains("/v1/attribution/") == true }.count
    }

    private func decode(_ body: String) throws -> Attribution {
        try XCTUnwrap(try attriKitJSONDecoder().decode(AttributionResponse.self, from: Data(body.utf8)).attribution)
    }

    // Bodies in the shape apps/link/src/ingestion/routes.ts answers since c10931bb: the original
    // seven keys, then attribution_status and the ad-level context.
    private static let pendingFirstOpen = #"{"receipt_id":"r","status":"pending","retry_after_ms":0}"#
    private static let organicProvisional = #"{"status":"provisional","method":"unattributed","source_type":"unattributed","network":null,"campaign_id":null,"finality":"provisional","policy_version":2,"attribution_status":"organic","adset_id":null,"ad_id":null,"confidence":null,"campaign_name":null,"network_campaign_id":null}"#
    private static let attributedProvisional = #"{"status":"provisional","method":"platform_verified","source_type":"asa_click","network":"apple_ads","campaign_id":"c-1","finality":"provisional","policy_version":2,"attribution_status":"attributed","adset_id":"as-1","ad_id":"ad-1","confidence":null,"campaign_name":"Spring","network_campaign_id":"123"}"#
    private static let attributedFinal = #"{"status":"final","method":"platform_verified","source_type":"asa_click","network":"apple_ads","campaign_id":"c-1","finality":"final","policy_version":2,"attribution_status":"attributed"}"#
    /// A provisional deterministic Meta answer with ad-level context, then the Apple Ads answer that
    /// replaces it and carries none.
    private static let metaProvisional = #"{"status":"provisional","method":"exact_single_use","source_type":"owned_deferred_token","network":"meta","campaign_id":"c-meta","finality":"provisional","policy_version":3,"attribution_status":"attributed","adset_id":"as-meta","ad_id":"ad-meta","confidence":null,"campaign_name":"Meta spring","network_campaign_id":"238"}"#
    private static let appleAdsFinal = #"{"status":"final","method":"platform_verified","source_type":"asa_click","network":"apple_ads","campaign_id":"asa-7","finality":"final","policy_version":3,"attribution_status":"attributed","adset_id":null,"ad_id":null,"confidence":null,"campaign_name":"Brand","network_campaign_id":null}"#

    /// Every key a Superwall update must carry, spelled out here rather than read from the SDK, so
    /// a key the SDK stops sending turns these assertions red instead of vanishing from both sides.
    private static let everyUserAttributeKey = [
        "attrkit_status", "attrkit_finality", "attrkit_method", "attrkit_network", "attrkit_campaign_id",
        "attrkit_source_type", "attrkit_campaign_name", "attrkit_network_campaign_id", "attrkit_adset_id",
        "attrkit_ad_id",
    ]

    /// `present`, with every other AttriKit key carried as the nil that clears it.
    private func everyKey(_ present: [String: String]) -> [String: String?] {
        var expected = Dictionary(uniqueKeysWithValues: Self.everyUserAttributeKey.map { ($0, String?.none) })
        for (key, value) in present { expected.updateValue(value, forKey: key) }
        return expected
    }

    /// Superwall's documented `setUserAttributes(_ attributes: [String: Any?])`
    /// (https://superwall.com/docs/ios/sdk-reference/setUserAttributes, read 2026-09-30): a MERGE.
    /// A named key is overwritten, an unnamed key keeps its old value, and a nil value removes the
    /// key. Taking `[String: Any?]` also proves the README's call compiles without a cast.
    private struct SuperwallAttributes {
        private(set) var stored: [String: String] = [:]

        mutating func setUserAttributes(_ attributes: [String: Any?]) {
            for (key, value) in attributes {
                if let string = value as? String { stored[key] = string } else { stored.removeValue(forKey: key) }
            }
        }
    }

    // MARK: - decoding and dictionaries

    func testEveryNewResponseFieldReachesBothDictionaries() throws {
        let attribution = try decode(Self.attributedProvisional)
        let campaign: [String: String] = [
            "attrkit_method": "platform_verified",
            "attrkit_network": "apple_ads",
            "attrkit_campaign_id": "c-1",
            "attrkit_source_type": "asa_click",
            "attrkit_campaign_name": "Spring",
            "attrkit_network_campaign_id": "123",
            "attrkit_adset_id": "as-1",
            "attrkit_ad_id": "ad-1",
            "attrkit_finality": "provisional",
        ]
        XCTAssertEqual(attribution.placementParameters, campaign)
        var withStatus = campaign
        withStatus["attrkit_status"] = "attributed"
        XCTAssertEqual(AttributionUpdate(status: attribution.status, attribution: attribution).userAttributes, everyKey(withStatus))
    }

    /// The server live before 2026-09-30 sends none of the new keys. The SDK must decode it and
    /// derive the verdict the way the server now does.
    func testAServerWithoutTheNewKeysStillDecodesAndIsJudgedTheSameWay() throws {
        let deterministic = try decode(#"{"status":"final","method":"exact_single_use","source_type":"owned_deferred_token","network":"meta","campaign_id":"c-9","finality":"final","policy_version":1}"#)
        XCTAssertEqual(deterministic.status, .attributed)
        XCTAssertEqual(deterministic.placementParameters["attrkit_campaign_id"], "c-9")
        XCTAssertNil(deterministic.placementParameters["attrkit_adset_id"])

        // No winning evidence row, so method is "unattributed"; the source type is what says device
        // match. Reading method alone would call it organic.
        let deviceMatch = try decode(#"{"status":"provisional","method":"unattributed","source_type":"device_match","network":"meta","campaign_id":"c-2","finality":"provisional","policy_version":2}"#)
        XCTAssertEqual(deviceMatch.status, .deviceMatched)

        let organic = try decode(#"{"status":"provisional","method":"unattributed","source_type":"unattributed","network":null,"campaign_id":null,"finality":"provisional","policy_version":1}"#)
        XCTAssertEqual(organic.status, .organic)
    }

    /// A device match is labelled, with its confidence, and its campaign stays out of both
    /// dictionaries: the published contract is that only verified context reaches a paywall.
    func testADeviceMatchIsLabelledButItsCampaignStaysOut() throws {
        let attribution = try decode(#"{"status":"provisional","method":"device_matched","source_type":"device_match","network":"meta","campaign_id":"c-2","finality":"provisional","policy_version":3,"attribution_status":"device_matched","adset_id":"as-2","ad_id":"ad-2","confidence":0.82,"campaign_name":"Spring prospecting","network_campaign_id":"2385"}"#)
        XCTAssertEqual(attribution.status, .deviceMatched)
        XCTAssertEqual(attribution.confidence, 0.82)
        XCTAssertEqual(attribution.campaignName, "Spring prospecting")
        XCTAssertEqual(attribution.placementParameters, [:])
        XCTAssertEqual(
            AttributionUpdate(status: attribution.status, attribution: attribution).userAttributes,
            everyKey(["attrkit_status": "device_matched", "attrkit_finality": "provisional"])
        )
    }

    /// The server's verdict wins over the local derivation: an install whose consent the server
    /// records as withdrawn must not hand a paywall its campaign, however deterministic the method.
    func testTheServersVerdictOverridesTheLocalDerivation() throws {
        let attribution = try decode(#"{"status":"final","method":"exact_single_use","source_type":"owned_deferred_token","network":"meta","campaign_id":"c-3","finality":"final","policy_version":2,"attribution_status":"consent_required"}"#)
        XCTAssertEqual(attribution.status, .consentRequired)
        XCTAssertEqual(attribution.placementParameters, [:])
        XCTAssertEqual(CoreRuntime.publicResult(.attributed(attribution)), .consentRequired)
    }

    /// Behaviour change of this release: an organic answer is `.unattributed`, not `.attributed`
    /// with method "unattributed", which an `if case .attributed` in an app read as a paid install.
    func testAnOrganicAnswerIsReportedAsUnattributed() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 200, body: Self.organicProvisional)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let result = await runtime.attribution(timeout: .seconds(2))
        XCTAssertEqual(result, .unattributed)
        let update = await runtime.currentAttributionUpdate()
        XCTAssertEqual(update.userAttributes, everyKey(["attrkit_status": "organic", "attrkit_finality": "provisional"]))
        XCTAssertEqual(update.placementParameters, [:])
        await runtime.shutdown()
    }

    /// A 200 that says pending is not an answer: recording it as organic would misreport a
    /// still-matching install.
    func testAPendingTwoHundredIsNotRecordedAsOrganic() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 200, body: #"{"status":"pending","attribution_status":"pending"}"#)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let polled = await waitUntil { await self.attributionRequests(transport) >= 2 }
        XCTAssertTrue(polled)

        let update = await runtime.currentAttributionUpdate()
        XCTAssertEqual(update.status, .pending)
        XCTAssertEqual(update.userAttributes, everyKey(["attrkit_status": "pending"]))
        await runtime.shutdown()
    }

    func testUserAttributesSayWhyForEveryStateWithoutACampaign() async {
        let pending = StubTransport { _, _ in successResult(status: 202, body: #"{"receipt_id":"r","status":"pending","retry_after_ms":500}"#) }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: pending))
        let notStarted = await AttriKit.userAttributes(timeout: .milliseconds(10))
        XCTAssertEqual(notStarted, everyKey(["attrkit_status": "pending"]), "not started")

        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let stillMatching = await AttriKit.userAttributes(timeout: .milliseconds(10))
        XCTAssertEqual(stillMatching, everyKey(["attrkit_status": "pending"]), "still matching")
        let stillEmpty = await AttriKit.placementParameters(timeout: .milliseconds(10))
        XCTAssertEqual(stillEmpty, [:], "placementParameters keeps its empty-unless-deterministic contract")

        await AttriKit.configureForTesting(makeTestConfiguration(transport: pending))
        AttriKit.start(apiKey: apiKey, consent: .denied)
        let denied = await AttriKit.userAttributes(timeout: .milliseconds(10))
        XCTAssertEqual(denied, everyKey(["attrkit_status": "consent_required"]), "denied consent")

        let refused = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 400, body: #"{"error":"invalid_install_epoch_id"}"#)
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: refused))
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        _ = await AttriKit.attribution(timeout: .seconds(2))
        let failed = await AttriKit.userAttributes(timeout: .milliseconds(10))
        XCTAssertEqual(failed, everyKey(["attrkit_status": "timed_out"]), "an answer that will never come says timed_out, not pending")
    }

    // MARK: - polling while provisional

    /// The first answer is organic and provisional; the server matches the install moments later.
    /// The first answer used to be cached for the life of the process and the poll stopped on it.
    func testAProvisionalOrganicAnswerIsReplacedWhenTheServerMatchesTheInstall() async throws {
        let transport = StubTransport { request, count in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            // Request 1 is first-open; the first poll answers organic, every later one attributed.
            return successResult(status: 200, body: count <= 2 ? Self.organicProvisional : Self.attributedProvisional)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let sawOrganic = await waitUntil { await runtime.currentAttributionUpdate().status == .organic }
        XCTAssertTrue(sawOrganic)
        // The next rung after a provisional answer is 5s plus up to 25% jitter.
        let upgraded = await waitUntil(timeout: .seconds(8)) { await runtime.currentAttributionUpdate().status == .attributed }
        XCTAssertTrue(upgraded, "the provisional organic answer was frozen")
        let answer = await runtime.attribution(timeout: .milliseconds(1))
        guard case .attributed(let attribution) = answer else { return XCTFail("expected the replaced answer, got \(answer)") }
        XCTAssertEqual(attribution.networkCampaignID, "123")
        await runtime.shutdown()
    }

    /// A match returned inline by first-open is provisional too, and nothing polled after a 200.
    func testAnInlineProvisionalMatchIsStillWatched() async throws {
        let inline = #"{"receipt_id":"r","status":"matched","attribution":{"method":"deterministic","network":"meta","campaign_id":"c-1","finality":"provisional","policy_version":2,"attribution_status":"attributed"}}"#
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 200, body: inline)
            }
            return successResult(status: 200, body: Self.attributedFinal)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)

        let settled = await waitUntil(timeout: .seconds(3)) {
            await runtime.currentAttributionUpdate().attribution?.finality == "final"
        }
        XCTAssertTrue(settled, "an inline provisional match was never re-read")
        await runtime.shutdown()
    }

    /// A provisional answer is watched on the 5s/30s/5m ladder, not the 250ms ramp used while
    /// there is no answer at all: every answer is provisional for 72 hours, and ramping on it cost
    /// about twenty requests per launch of every install for three days.
    func testAProvisionalAnswerIsWatchedOnTheSlowLadder() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 200, body: Self.organicProvisional)
        }
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let answered = await waitUntil { await self.attributionRequests(transport) == 1 }
        XCTAssertTrue(answered)
        let rampedAgain = await waitUntil(timeout: .seconds(3)) { await self.attributionRequests(transport) > 1 }
        XCTAssertFalse(rampedAgain, "a provisional answer was re-polled on the fast ramp")
        await runtime.shutdown()
    }

    /// A settled answer ends the poll: watching must stay bounded.
    ///
    /// Watching real time for a second could not tell: after an answer the next rung is 5 s plus
    /// up to 25 % jitter, so a loop that kept polling a final answer passed too. The poll's waits
    /// run on virtual time here, advanced past the ladder's last rung (6 h) on every check, so a
    /// wait registered at any point is passed and any further request would be seen.
    func testAFinalAnswerStopsThePoll() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 200, body: Self.attributedFinal)
        }
        let scheduler = ManualPollScheduler()
        let runtime = CoreRuntime(configuration: makeTestConfiguration(transport: transport, attributionPollSleep: scheduler.sleep))
        await runtime.start(apiKey: apiKey, consent: .measurementGranted)
        let answered = await waitUntil { await self.attributionRequests(transport) == 1 }
        XCTAssertTrue(answered)
        let sleepsAtAnswer = scheduler.requestedSleeps.count

        let polledAgain = await waitUntil(timeout: .seconds(2)) {
            scheduler.advance(by: .seconds(6 * 3_600 + 1))
            return await self.attributionRequests(transport) > 1
        }
        XCTAssertFalse(polledAgain, "a final answer must stop the poll")
        XCTAssertEqual(scheduler.requestedSleeps.count, sleepsAtAnswer, "a final answer scheduled another poll")
        await runtime.shutdown()
    }

    // MARK: - update stream

    /// The stream publishes each real change once, starting with the current state, so an app can
    /// call Superwall's setUserAttributes from it without re-running it on every identical poll.
    func testUpdatesPublishEachChangeOnceFromPendingToAttributed() async throws {
        let inlineOrganic = #"{"receipt_id":"r","status":"matched","attribution":{"method":"unattributed","source_type":"unattributed","network":null,"campaign_id":null,"finality":"provisional","policy_version":2,"attribution_status":"organic"}}"#
        let transport = StubTransport { request, count in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 200, body: inlineOrganic)
            }
            // Organic inline, organic again on the first poll (a repeat must not republish), then
            // attributed on the next rung.
            return successResult(status: 200, body: count <= 2 ? Self.organicProvisional : Self.attributedProvisional)
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        let collector = UpdateCollector()
        // Subscribed BEFORE start, the way an app wires it in didFinishLaunching.
        let updates = AttriKit.attributionUpdates()
        let task = Task {
            for await update in updates {
                await collector.append(update)
                if update.status == .attributed { return }
            }
        }
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let finished = await waitUntil(timeout: .seconds(10)) { await collector.updates.last?.status == .attributed }
        XCTAssertTrue(finished)
        task.cancel()
        let published = await collector.updates
        XCTAssertEqual(published.map(\.status), [.pending, .organic, .attributed])
        XCTAssertEqual(published.last?.userAttributes["attrkit_campaign_name"], "Spring")
    }

    // MARK: - Superwall merges, so every update clears what it does not set

    /// A provisional Meta answer set ad-level keys; the Apple Ads answer that replaced it has none.
    /// Sent to a merging store, only an explicit nil takes Meta's adset and ad off the user.
    func testAnAppleAdsAnswerReplacingAMetaOneClearsTheMetaAdKeys() throws {
        let meta = try decode(Self.metaProvisional)
        let appleAds = try decode(Self.appleAdsFinal)
        var superwall = SuperwallAttributes()

        superwall.setUserAttributes(AttributionUpdate(status: meta.status, attribution: meta).userAttributes)
        XCTAssertEqual(superwall.stored["attrkit_adset_id"], "as-meta", "precondition: the Meta answer set its adset")
        XCTAssertEqual(superwall.stored["attrkit_ad_id"], "ad-meta")

        let replacement = AttributionUpdate(status: appleAds.status, attribution: appleAds).userAttributes
        XCTAssertEqual(replacement.count, Self.everyUserAttributeKey.count)
        XCTAssertEqual(replacement["attrkit_adset_id"], .some(nil), "the clearing value must be sent, not omitted")
        superwall.setUserAttributes(replacement)
        XCTAssertEqual(superwall.stored, [
            "attrkit_status": "attributed",
            "attrkit_finality": "final",
            "attrkit_method": "platform_verified",
            "attrkit_network": "apple_ads",
            "attrkit_campaign_id": "asa-7",
            "attrkit_source_type": "asa_click",
            "attrkit_campaign_name": "Brand",
        ])
    }

    /// Through the stream an app wires to Superwall: an attributed Meta install, then consent is
    /// withdrawn. What Superwall holds afterwards must be the status alone, with no campaign left.
    func testWithdrawingConsentClearsTheCampaignFromSuperwall() async throws {
        let transport = StubTransport { request, _ in
            if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
                return successResult(status: 202, body: Self.pendingFirstOpen)
            }
            return successResult(status: 200, body: Self.metaProvisional)
        }
        await AttriKit.configureForTesting(makeTestConfiguration(transport: transport))
        let collector = UpdateCollector()
        let updates = AttriKit.attributionUpdates()
        let task = Task {
            for await update in updates {
                await collector.append(update)
                if update.status == .consentRequired { return }
            }
        }
        AttriKit.start(apiKey: apiKey, consent: .measurementGranted)
        let attributed = await waitUntil(timeout: .seconds(10)) { await collector.updates.last?.status == .attributed }
        XCTAssertTrue(attributed)
        AttriKit.setConsent(.revoked)
        let withdrawn = await waitUntil(timeout: .seconds(10)) { await collector.updates.last?.status == .consentRequired }
        XCTAssertTrue(withdrawn)
        task.cancel()

        var superwall = SuperwallAttributes()
        for update in await collector.updates { superwall.setUserAttributes(update.userAttributes) }
        XCTAssertEqual(superwall.stored, ["attrkit_status": "consent_required"])
    }
}

private actor UpdateCollector {
    private(set) var updates: [AttributionUpdate] = []
    func append(_ update: AttributionUpdate) { updates.append(update) }
}
