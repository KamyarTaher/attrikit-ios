import Foundation
@testable import AttriKitCore
@testable import AttriKitSuperwall
import XCTest

private final class SuperwallKeychain: InstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?
    func read() throws -> UUID? { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ value: UUID) throws { lock.lock(); self.value = value; lock.unlock() }
    func delete() throws { lock.lock(); value = nil; lock.unlock() }
}

/// Answers first-open as registered and accepts nothing else, so tracked events stay in the queue
/// where the test can read them back.
private actor HoldingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        if request.url?.path.hasSuffix("/v1/ingest/first-open") == true {
            return HTTPResult(statusCode: 202, data: Data(#"{"receipt_id":"r","status":"pending","retry_after_ms":60000}"#.utf8), headers: [:])
        }
        return HTTPResult(statusCode: 503, data: Data(), headers: [:])
    }
}

private struct SuperwallEvidence: PlatformEvidenceProviding {
    func appTransactionJWS() async -> String? { nil }
    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext { CoarseContext(countryCode: "CH", osMajor: "17.0", deviceClass: "phone", locale: "en-CH") }
    func appVersion() -> String { "1.0.0" }
}

private struct SuperwallLifecycle: ApplicationLifecycleObserving {
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) { _ = handler }
    func stop() {}
}

/// Stands in for the app's `extension SuperwallEventInfo: AttriKitSuperwallEventConvertible`.
private struct FakeSuperwallEventInfo: AttriKitSuperwallEventConvertible {
    let attriKitSuperwallEvent: AttriKitSuperwallEvent
}

final class AttriKitSuperwallTests: XCTestCase {
    func testAPaywallOpenBecomesTheCanonicalPaywallViewedEvent() throws {
        let (event, properties) = try XCTUnwrap(AttriKitSuperwall.mapped(
            AttriKitSuperwallEvent(name: "paywall_open", paywallIdentifier: "pw_annual", placement: "onboarding_end")
        ))
        XCTAssertEqual(event.name, "paywall_viewed")
        XCTAssertEqual(properties, ["source": "superwall", "paywall_id": "pw_annual", "placement": "onboarding_end"])
    }

    /// `transaction_complete` is a client-side StoreKit callback. Recording it as a purchase would
    /// count a RevenueCat customer's purchase twice, once here and once from RevenueCat's webhook.
    func testATransactionCompleteIsNeverRecordedAsAPurchase() {
        for name in ["transaction_complete", "transaction_start", "subscription_start", "paywall_close", "app_open", ""] {
            XCTAssertNil(AttriKitSuperwall.mapped(AttriKitSuperwallEvent(name: name)), "\(name) must not be forwarded")
        }
    }

    /// Every key must survive the SDK's own property validation, which refuses the WHOLE event when
    /// a key contains "name" (so Superwall's `paywall_name` cannot be used), and an over-long value
    /// is dropped rather than sent, since one over-long value refuses the event at ingestion.
    func testForwardedPropertiesPassTheSDKsOwnValidation() throws {
        // 1,025 bytes in 513 characters: a character count would let it through.
        let (_, oversized) = try XCTUnwrap(AttriKitSuperwall.mapped(
            AttriKitSuperwallEvent(name: "paywall_open", paywallIdentifier: String(repeating: "é", count: 513), placement: "p")
        ))
        XCTAssertNil(oversized["paywall_id"])
        XCTAssertEqual(oversized["placement"], .string("p"))
        XCTAssertNoThrow(try validateProperties(oversized))

        // A dated identifier reads as a phone number to the SDK's PII guard; the view survives
        // without that one label.
        let (event, dated) = try XCTUnwrap(AttriKitSuperwall.mapped(
            AttriKitSuperwallEvent(name: "paywall_open", paywallIdentifier: "pw_20260930_annual")
        ))
        XCTAssertEqual(event.name, "paywall_viewed")
        XCTAssertNil(dated["paywall_id"])
        XCTAssertNoThrow(try validateProperties(dated))
    }

    func testHandlingAnEventQueuesItThroughTheCore() async throws {
        let storage = SDKStorage(
            defaults: .init(value: try XCTUnwrap(UserDefaults(suiteName: "AttriKitSuperwallTests.\(UUID())"))),
            keychain: SuperwallKeychain(),
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitSuperwallTests-\(UUID())")
        )
        await AttriKit.configureForTesting(AttriKitTestingConfiguration(
            baseURL: try XCTUnwrap(URL(string: "https://unit.test")),
            transport: HoldingTransport(),
            storage: storage,
            evidence: SuperwallEvidence(),
            deviceEvidence: { DeviceEvidence(idfa: nil, idfv: nil) },
            now: { Date() },
            lifecycle: SuperwallLifecycle()
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)

        let forwarded = AttriKitSuperwall.handle(FakeSuperwallEventInfo(attriKitSuperwallEvent: AttriKitSuperwallEvent(
            name: "paywall_open", paywallIdentifier: "pw_1"
        )))
        XCTAssertEqual(forwarded?.name, "paywall_viewed")
        XCTAssertNil(AttriKitSuperwall.handle(AttriKitSuperwallEvent(name: "transaction_complete")))

        // Drain the facade queue, then read what reached the durable queue.
        _ = await AttriKit.attribution(timeout: .zero)
        let queued = try await storage.queuedEvents()
        XCTAssertEqual(queued.map(\.eventName), ["paywall_viewed"])
        XCTAssertEqual(queued.first?.properties["paywall_id"], .string("pw_1"))
    }
}
