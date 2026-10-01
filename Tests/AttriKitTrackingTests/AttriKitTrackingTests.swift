@testable import AttriKitCore
@testable import AttriKitTracking
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

final class AttriKitTrackingTests: XCTestCase {
    private var defaultsSuiteNames: [String] = []
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        AttriKitTracking.resetTestingConfiguration()
        await AttriKit.configureForTesting(.live)
        for suiteName in defaultsSuiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
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

    func testRequestConsentRefreshesTrackingEvidenceOnTheWire() async {
        let idfa = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        AttriKitTracking.configureForTesting(GrantingTrackingSystem(idfa: idfa))
        let transport = TrackingWireTransport()
        let suiteName = "AttriKitTrackingTests.\(UUID())"
        defaultsSuiteNames.append(suiteName)
        let suite = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttriKitTrackingTests-\(UUID())")
        temporaryDirectories.append(directory)
        await AttriKit.configureForTesting(AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: transport,
            storage: SDKStorage(
                defaults: .init(value: suite),
                keychain: TrackingMemoryKeychain(),
                directory: directory
            ),
            evidence: TrackingEvidence(),
            deviceEvidence: { AttriKit.currentDeviceEvidence() },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            lifecycle: TrackingLifecycle()
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .trackingGranted)
        _ = await AttriKit.attribution(timeout: .seconds(1))
        let before = await transport.identifyCount()

        let consent = await AttriKitTracking.requestConsent()
        XCTAssertEqual(consent, .trackingGranted)
        let refreshed = await waitUntil {
            await transport.identifyCount() > before
        }

        XCTAssertTrue(refreshed, "requestConsent must enqueue a fresh /v1/ingest/identify request")
        let identifyBody = await transport.latestIdentifyBody()
        XCTAssertNotNil(
            identifyBody?.range(of: Data(idfa.uuidString.lowercased().utf8)),
            "the post-ATT identify must carry the IDFA that became available after authorization"
        )
    }

    /// The integration the tracking module documents for an app already measuring: ask for ATT,
    /// then pass the answer to setConsent. requestConsent's own identify leaves while the SDK still
    /// holds measurement consent, and the server keeps an IDFA only for an occurrence a tracking
    /// receipt has made tracking_granted, so the IDFA reaches it only in an identify sent after
    /// that receipt was applied. Before, none was sent in that launch.
    func testRequestConsentThenSetConsentDeliversTheIDFAInTheSameLaunch() async {
        let idfa = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        AttriKitTracking.configureForTesting(GrantingTrackingSystem(idfa: idfa))
        let server = TrackingConsentServer()
        let suiteName = "AttriKitTrackingTests.\(UUID())"
        defaultsSuiteNames.append(suiteName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttriKitTrackingTests-\(UUID())")
        temporaryDirectories.append(directory)
        await AttriKit.configureForTesting(AttriKitTestingConfiguration(
            baseURL: URL(string: "https://unit.test")!,
            transport: server,
            storage: SDKStorage(
                defaults: .init(value: UserDefaults(suiteName: suiteName)!),
                keychain: TrackingMemoryKeychain(),
                directory: directory
            ),
            evidence: TrackingEvidence(),
            deviceEvidence: { AttriKit.currentDeviceEvidence() },
            now: { Date() },
            lifecycle: TrackingLifecycle()
        ))
        AttriKit.start(apiKey: String(repeating: "k", count: 20), consent: .measurementGranted)
        let registered = await waitUntil { await server.registered }
        XCTAssertTrue(registered, "first-open never registered")

        let consent = await AttriKitTracking.requestConsent()
        XCTAssertEqual(consent, .trackingGranted)
        AttriKit.setConsent(consent)

        let delivered = await waitUntil(timeout: .seconds(5)) { await server.keptIDFA != nil }
        let kept = await server.keptIDFA
        XCTAssertTrue(delivered, "no identify reached the server after the tracking receipt")
        XCTAssertEqual(kept, idfa.uuidString.lowercased())
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
        XCTAssertEqual(rows.count, 1)
        let deviceID = try XCTUnwrap(rows.first)

        // Neither top-level tracking key. Apple TN3181 lists NSPrivacyTracking=true with an empty
        // NSPrivacyTrackingDomains as an invalid manifest (the shape shipped until 2026-09-15), and
        // the module cannot name a domain: the host configures the endpoint at runtime, and naming
        // attrikit.io makes iOS block every request to it, erasure included, for users who decline
        // ATT (shipped in 2.2.0, reverted in 2.2.1). The DeviceID entry below carries the tracking
        // flag; the host app declares NSPrivacyTracking and its own domain.
        XCTAssertNil(plist["NSPrivacyTracking"])
        XCTAssertNil(plist["NSPrivacyTrackingDomains"])
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

private actor TrackingWireTransport: HTTPTransport {
    private var identifyRequests = 0
    private var latestIdentify: Data?

    func send(_ request: URLRequest) async throws -> HTTPResult {
        if request.url?.path == "/v1/ingest/identify" {
            identifyRequests += 1
            latestIdentify = request.httpBody
        }
        return HTTPResult(
            statusCode: 200,
            data: Data(#"{"receipt_id":"tracking-wire","status":"matched","attribution":{"method":"deterministic","network":"meta","campaign_id":"campaign","finality":"provisional","policy_version":1}}"#.utf8),
            headers: [:]
        )
    }

    func identifyCount() -> Int { identifyRequests }
    func latestIdentifyBody() -> Data? { latestIdentify }
}

/// One install as the server sees it (apps/link/src/ingestion/repository.ts): first-open registers
/// it under the consent it declares, a receipt replaces that consent, and an identify's IDFA is
/// kept only while the consent is tracking_granted.
private actor TrackingConsentServer: HTTPTransport {
    private(set) var registered = false
    private(set) var keptIDFA: String?
    private var consentClass = "unknown"

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let path = request.url?.path ?? ""
        let json = request.httpBody
            .flatMap { try? JSONSerialization.jsonObject(with: Self.gunzip($0)) as? [String: Any] } ?? [:]
        let state = (json["consent"] as? [String: Any])?["state"] as? String
        switch path {
        case "/v1/ingest/first-open":
            if !registered {
                registered = true
                consentClass = state ?? "unknown"
                if consentClass == "tracking_granted" { keptIDFA = json["idfa"] as? String }
            }
        case "/v1/ingest/consent":
            guard registered, let state else { return Self.unknownEpoch }
            consentClass = state
        case "/v1/ingest/identify":
            guard registered else { return Self.unknownEpoch }
            if consentClass == "tracking_granted", let idfa = json["idfa"] as? String { keptIDFA = idfa }
        default:
            break
        }
        return HTTPResult(
            statusCode: 200,
            data: Data(#"{"receipt_id":"tracking-wire","status":"matched","attribution":{"method":"deterministic","network":"meta","campaign_id":"campaign","finality":"final","policy_version":1}}"#.utf8),
            headers: [:]
        )
    }

    private static let unknownEpoch = HTTPResult(
        statusCode: 503,
        data: Data(#"{"error":"unknown_install_epoch"}"#.utf8),
        headers: [:]
    )

    /// The SDK writes one stored-deflate gzip member; this reads exactly that shape.
    private static func gunzip(_ data: Data) -> Data {
        guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else { return data }
        var index = 10
        var output = Data()
        while index < data.count - 8 {
            let final = data[index] & 0x01 == 1
            let length = Int(data[index + 1]) | (Int(data[index + 2]) << 8)
            index += 5
            output.append(data.subdata(in: index..<(index + length)))
            index += length
            if final { break }
        }
        return output
    }
}

private final class GrantingTrackingSystem: TrackingSystemProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let idfa: UUID
    private var authorized = false

    init(idfa: UUID) { self.idfa = idfa }

    var authorizationStatus: TrackingAuthorizationStatus {
        locked { authorized ? .authorized : .notDetermined }
    }

    var advertisingIdentifier: UUID? { locked { authorized ? idfa : nil } }
    var vendorIdentifier: UUID? { nil }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        locked { authorized = true }
        return .authorized
    }

    private func locked<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private final class TrackingMemoryKeychain: InstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func read() throws -> UUID? { locked { value } }
    func write(_ value: UUID) throws { locked { self.value = value } }
    func delete() throws { locked { value = nil } }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private struct TrackingEvidence: PlatformEvidenceProviding {
    func appTransactionJWS() async -> String? { nil }
    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "CH", osMajor: "18", deviceClass: "phone", locale: "en-CH")
    }
    func appVersion() -> String { "1.0 (1)" }
}

private struct TrackingLifecycle: ApplicationLifecycleObserving {
    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) {}
    func stop() {}
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
