import Foundation
@testable import AttriKitCore
@testable import AttriKitLinkToken
import XCTest

private final class LinkTokenKeychain: InstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    func read() throws -> UUID? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: UUID) throws { lock.lock(); self.value = value; lock.unlock() }
    func delete() throws { lock.lock(); value = nil; lock.unlock() }
}

private actor LinkTokenTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        _ = request
        return HTTPResult(statusCode: 200, data: Data(#"{"receipt_id":"r","status":"matched","attribution":{"method":"deterministic","network":"apple_ads","campaign_id":"c1","finality":"provisional","policy_version":1}}"#.utf8), headers: [:])
    }
}

private struct LinkTokenEvidence: PlatformEvidenceProviding {
    func appTransactionJWS() async -> String? { nil }
    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext { CoarseContext(countryCode: "CH", osMajor: "16.4", deviceClass: "phone", locale: "en-CH") }
    func appVersion() -> String { "1.0.0" }
}

private struct LinkTokenLifecycle: ApplicationLifecycleObserving {
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) { _ = handler }
    func stop() {}
}

/// The directories configureCore hands to SDKStorage, remembered for the whole class rather than
/// one test.
///
/// SDKStorage creates its directory on the first queue write, and the write that lands is the one
/// AttriKitFacade.replace performs when it shuts the PREVIOUS runtime down -- which happens inside
/// the NEXT test's configureForTesting, after the configuring test's own teardown has already run.
/// A per-instance list therefore removes a directory that is then recreated with nobody left
/// holding its URL. The list is never cleared, so each teardown also collects what the previous
/// test's runtime recreated.
private final class TemporaryStorageDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []

    func track(_ directory: URL) {
        lock.lock()
        directories.append(directory)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        let tracked = directories
        lock.unlock()
        for directory in tracked { try? FileManager.default.removeItem(at: directory) }
    }
}

final class AttriKitLinkTokenTests: XCTestCase {
    /// Measured before this teardown existed: 3 directories survived every run of this suite. The
    /// removal cannot be a `defer` inside configureCore -- the storage that directory backs is
    /// still the subject of the test when the helper returns.
    private static let temporaryStorageDirectories = TemporaryStorageDirectories()

    override func tearDown() async throws {
        // attribution() goes through AttriKitFacade.withRuntime, which awaits the facade's
        // operation tail: it is how this teardown orders itself AFTER the queue write the test
        // enqueued, instead of removing a directory the runtime is about to recreate.
        _ = await AttriKit.attribution(timeout: .zero)
        Self.temporaryStorageDirectories.removeAll()
        try await super.tearDown()
    }

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

    func testConsumePasteboardPinsExactTokenPrefixLengthAndAlphabet() async {
        let invalid = [
            "ak1_" + String(repeating: "A", count: 42),
            "ak1_" + String(repeating: "A", count: 44),
            "ak2_" + String(repeating: "A", count: 43),
            "ak1_" + String(repeating: "A", count: 42) + "+",
        ]
        for token in invalid {
            let spy = TokenAcceptanceSpy()
            let result = await AttriKitLinkToken.consumePasteboardValue(token) { token, kind in
                await spy.accept(token, kind: kind)
            }
            XCTAssertEqual(result, .ignored)
            let accepted = await spy.acceptedTokens()
            XCTAssertTrue(accepted.isEmpty)
        }
    }

    func testExplicitClipboardTokenRequiresTrackingConsent() async {
        let token = "ak1_" + String(repeating: "Z", count: 43)
        await configureCore(consent: .measurementGranted)
        let measurementResult = await AttriKitLinkToken.consume(token)
        XCTAssertEqual(measurementResult, .consentRequired)
        await configureCore(consent: .trackingGranted)
        let trackingResult = await AttriKitLinkToken.consume(token)
        XCTAssertEqual(trackingResult, .handled(URL(string: "attrikit://token/consumed")!))
    }

    /*
      A review read `consume(_:)` as forwarding its argument to the core without the host whitelist
      or the format check that `token(fromPasteboardValue:)` applies, so that a raw pasteboard URL
      or a token from an unapproved host would be accepted. The format check is not skipped, it
      lives in the callee: CoreRuntime.acceptExactToken guards on `isVersionedLinkToken` and
      answers `.invalid`. A URL is not a 47-byte `ak1_` token, so it is refused rather than
      forwarded, and a bare token handed over by the host app carries no host to whitelist. That
      refusal had no test, which is what let the reading stand; this is the pin.

      Mutation watched red: drop `Self.isVersionedLinkToken(token)` from the guard in
      CoreRuntime.acceptExactToken.
    */
    func testExplicitConsumeRefusesRawURLsAndMalformedTokens() async {
        await configureCore(consent: .trackingGranted)
        let token = "ak1_" + String(repeating: "Q", count: 43)
        let refused = [
            "https://attrikit.io/install?attrkit_token=\(token)",
            "https://example.com/install?attrkit_token=\(token)",
            String(repeating: "A", count: 47),
            "ak1_" + String(repeating: "A", count: 42),
        ]
        for value in refused {
            let result = await AttriKitLinkToken.consume(value)
            XCTAssertEqual(result, .invalid, "consume accepted \(value)")
        }

        // Non-vacuity: the same call with the bare token succeeds, so the refusals above are the
        // format guard rather than a runtime that refuses everything it is handed.
        let accepted = await AttriKitLinkToken.consume(token)
        XCTAssertEqual(accepted, .handled(URL(string: "attrikit://token/consumed")!))
    }

    func testPasteboardReadItselfRequiresTrackingConsent() async {
        await configureCore(consent: .measurementGranted)
        let denied = await AttriKitLinkToken.consumePasteboard()
        XCTAssertEqual(denied, .consentRequired)

        await configureCore(consent: .trackingGranted)
        #if os(iOS)
        // The authorized iOS branch is allowed to inspect UIPasteboard; its content is deliberately
        // not asserted because this test pins the gate, not the process-global clipboard.
        _ = await AttriKitLinkToken.consumePasteboard()
        #else
        let allowed = await AttriKitLinkToken.consumePasteboard()
        XCTAssertEqual(allowed, .ignored)
        #endif
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

        // This module reads the pasteboard only when consent.allowsTracking is already true
        // (CoreRuntime.canReadLinkTokenPasteboard), and the token it recovers links an install to
        // a click that happened on another company's property. That is Apple's definition of
        // tracking, so the manifest declares it. The DOMAIN, however, stays out of it:
        // MUST be empty. iOS blocks every request to a domain listed here when App Tracking
        // Transparency is not authorized, and attrikit.io is the single ingest host for first-open,
        // events, identify, consent receipts and /v1/privacy/delete — so naming it disables
        // measurement and erasure for every user who declines the prompt. The host configures the
        // endpoint at runtime and declares its own domain. Listing it here shipped in 2.2.0 and was
        // reverted in 2.2.1; this assertion is what stops it coming back.
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, true)
        XCTAssertEqual(plist["NSPrivacyTrackingDomains"] as? [String], [])
        let types = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let other = try XCTUnwrap(types.first { ($0["NSPrivacyCollectedDataType"] as? String) == "NSPrivacyCollectedDataTypeOtherDataTypes" })
        // The link token itself is the value that crosses the property boundary.
        XCTAssertEqual(other["NSPrivacyCollectedDataTypeTracking"] as? Bool, true)
        let interaction = try XCTUnwrap(types.first { ($0["NSPrivacyCollectedDataType"] as? String) == "NSPrivacyCollectedDataTypeProductInteraction" })
        // In-app interaction does not cross it, and must not be over-declared.
        XCTAssertEqual(interaction["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
    }

    func testConfiguringTheCoreLeavesNoStorageDirectoryBehind() async throws {
        let directory = await configureCore(consent: .measurementGranted)
        // SDKStorage creates this lazily, on its first queue write, so create it here: a removal
        // measured on a directory that happens not to exist yet measures nothing.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        // The same call tearDown makes, so this pins the removal rather than a copy of it.
        Self.temporaryStorageDirectories.removeAll()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.path),
            "the directory configureCore handed to SDKStorage outlived the test"
        )
    }

    @discardableResult
    private func configureCore(consent: AttriKitConsent) async -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        Self.temporaryStorageDirectories.track(directory)
        let storage = SDKStorage(
            defaults: .init(value: UserDefaults(suiteName: "AttriKitLinkTokenTests.\(UUID())")!),
            keychain: LinkTokenKeychain(),
            directory: directory
        )
        await AttriKit.configureForTesting(AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: LinkTokenTransport(),
            storage: storage,
            evidence: LinkTokenEvidence(),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            lifecycle: LinkTokenLifecycle()
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: consent)
        _ = await AttriKit.attribution(timeout: .zero)
        return directory
    }
}
