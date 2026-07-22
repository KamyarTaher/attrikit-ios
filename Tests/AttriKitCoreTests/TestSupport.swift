import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import AttriKitCore

final class MemoryKeychain: InstallationIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UUID?

    func read() throws -> UUID? { locked { value } }
    func write(_ value: UUID) throws { locked { self.value = value } }
    func delete() throws { locked { value = nil } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

actor StubTransport: HTTPTransport {
    typealias Responder = @Sendable (URLRequest, Int) async throws -> HTTPResult
    private var captured: [URLRequest] = []
    private let responder: Responder

    init(responder: @escaping Responder) { self.responder = responder }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        captured.append(request)
        return try await responder(request, captured.count)
    }

    func requests() -> [URLRequest] { captured }
}

struct StubEvidence: PlatformEvidenceProviding {
    var transaction: String?
    var adToken: String?

    func appTransactionJWS() async -> String? { transaction }
    func adServicesToken() async -> String? { adToken }
    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "CH", osMajor: "16.4", deviceClass: "phone", locale: "en-CH")
    }
    func appVersion() -> String { "1.2.3 (42)" }
}

final class SuspendedEvidence: PlatformEvidenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func appTransactionJWS() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
        return nil
    }

    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "CH", osMajor: "16.4", deviceClass: "phone", locale: "en-CH")
    }
    func appVersion() -> String { "1.2.3 (42)" }

    func release() {
        lock.lock()
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

final class ManualLifecycleObserver: ApplicationLifecycleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ApplicationLifecycleEvent) async -> Void)?

    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent) async -> Void) {
        locked { self.handler = handler }
    }

    func stop() {
        locked { handler = nil }
    }

    func send(_ event: ApplicationLifecycleEvent) async {
        let callback = locked { handler }
        await callback?(event)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class TestDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    func now() -> Date { locked { date } }

    func advance(by interval: TimeInterval) {
        locked { date = date.addingTimeInterval(interval) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

func makeTestConfiguration(
    transport: HTTPTransport,
    keychain: InstallationIDStoring = MemoryKeychain(),
    defaults: UserDefaults? = nil,
    directory: URL? = nil,
    evidence: PlatformEvidenceProviding = StubEvidence(transaction: nil, adToken: nil),
    deviceEvidence: DeviceEvidence = DeviceEvidence(idfa: nil, idfv: nil),
    now: @escaping @Sendable () -> Date = { Date() },
    lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver()
) -> AttriKitTestingConfiguration {
    let suite = defaults ?? UserDefaults(suiteName: "AttriKitTests.\(UUID())")!
    let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("AttriKitTests-\(UUID())")
    return AttriKitTestingConfiguration(
        baseURL: URL(string: "https://unit.test")!,
        transport: transport,
        storage: SDKStorage(defaults: .init(value: suite), keychain: keychain, directory: folder),
        evidence: evidence,
        deviceEvidence: { deviceEvidence },
        now: now,
        lifecycle: lifecycle
    )
}

func successResult(status: Int = 200, body: String = #"{"receipt_id":"r","status":"matched","attribution":{"method":"deterministic","network":"apple_ads","campaign_id":"c1","finality":"provisional","policy_version":1}}"#, headers: [String: String] = [:]) -> HTTPResult {
    HTTPResult(statusCode: status, data: Data(body.utf8), headers: headers)
}

func waitUntil(timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

func gunzipStored(_ data: Data) throws -> Data {
    guard data.count >= 18, data[0] == 0x1f, data[1] == 0x8b else { throw URLError(.cannotDecodeContentData) }
    var index = 10
    var output = Data()
    while index < data.count - 8 {
        let header = data[index]
        index += 1
        guard header & 0x06 == 0 else { throw URLError(.cannotDecodeContentData) }
        guard index + 4 <= data.count else { throw URLError(.cannotDecodeContentData) }
        let length = Int(data[index]) | (Int(data[index + 1]) << 8)
        let inverse = Int(data[index + 2]) | (Int(data[index + 3]) << 8)
        guard length ^ inverse == 0xffff else { throw URLError(.cannotDecodeContentData) }
        index += 4
        guard index + length <= data.count - 8 else { throw URLError(.cannotDecodeContentData) }
        output.append(data.subdata(in: index..<(index + length)))
        index += length
        if header & 0x01 == 1 { break }
    }
    return output
}

final class URLProtocolSpy: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var _requests = 0

    static var requests: Int {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func reset() {
        lock.lock(); _requests = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self._requests += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
