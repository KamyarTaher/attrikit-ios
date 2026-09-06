import Foundation
import XCTest
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

/// Evidence whose appTransactionJWS calls suspend one by one, releasable per call index.
/// SuspendedEvidence releases every waiter at once, which cannot order a two-attempt race;
/// this one can.
final class GatedEvidence: PlatformEvidenceProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]

    func appTransactionJWS() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locked {
                calls += 1
                gates[calls] = continuation
            }
        }
        return nil
    }

    func adServicesToken() async -> String? { nil }
    func coarseContext() -> CoarseContext {
        CoarseContext(countryCode: "CH", osMajor: "16.4", deviceClass: "phone", locale: "en-CH")
    }
    func appVersion() -> String { "1.2.3 (42)" }

    func waitForCalls(_ expected: Int, timeout: Duration = .seconds(2)) async -> Bool {
        await waitUntil(timeout: timeout) { [lock] in
            lock.lock()
            defer { lock.unlock() }
            return self.calls >= expected
        }
    }

    func release(_ index: Int) {
        let continuation = locked { gates.removeValue(forKey: index) }
        continuation?.resume()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The server side of first-open idempotency: first body for a key wins, a different body
/// under the same key conflicts. The real check is sha256 over the whole envelope; comparing
/// the decompressed bytes is the same equivalence.
actor FirstOpenServer {
    private var bodies: [String: Data] = [:]
    private var recordedStatuses: [Int] = []

    func register(idempotencyKey: String, body: Data) -> HTTPResult {
        if let previous = bodies[idempotencyKey] {
            if previous == body {
                recordedStatuses.append(200)
                return successResult()
            }
            recordedStatuses.append(409)
            return HTTPResult(statusCode: 409, data: Data(), headers: [:])
        }
        bodies[idempotencyKey] = body
        recordedStatuses.append(200)
        return successResult()
    }

    func statuses() -> [Int] { recordedStatuses }
}

final class ManualLifecycleObserver: ApplicationLifecycleObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (ApplicationLifecycleEvent, Date?) async -> Void)?

    func start(_ handler: @escaping @Sendable (ApplicationLifecycleEvent, Date?) async -> Void) {
        locked { self.handler = handler }
    }

    func stop() {
        locked { handler = nil }
    }

    /// `occurredAt` defaults to nil because most cases drive a TestDateClock, which stays
    /// authoritative and makes the post instant redundant.
    ///
    /// It is a PARAMETER rather than a constant because hard-coding nil deleted every trace of
    /// the plumbing it feeds. This is the only `ApplicationLifecycleObserving` fixture in the
    /// package -- 30 uses across five suites -- and the real `ApplicationLifecycleObserver`
    /// always passes a non-nil `Date()`. With nil hard-coded, no call anywhere supplied the
    /// instant, so `occurredAt ?? configuration.now()` in CoreRuntime could be reduced to
    /// `configuration.now()` on BOTH sides of a session, on iOS, with all 120 tests green --
    /// re-charging the serialized delivery wait to the user's session, which is the exact
    /// "a 100ms foreground reported as 300ms" defect the parameter was added to stop.
    func send(_ event: ApplicationLifecycleEvent, occurredAt: Date? = nil) async {
        let callback = locked { handler }
        await callback?(event, occurredAt)
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
    lifecycle: ApplicationLifecycleObserving = ApplicationLifecycleObserver(),
    diagnostic: @escaping @Sendable (String) -> Void = { _ in }
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
        lifecycle: lifecycle,
        diagnostic: diagnostic
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
    let trailer = data.count - 8
    let expectedCRC = UInt32(data[trailer])
        | (UInt32(data[trailer + 1]) << 8)
        | (UInt32(data[trailer + 2]) << 16)
        | (UInt32(data[trailer + 3]) << 24)
    let expectedSize = UInt32(data[trailer + 4])
        | (UInt32(data[trailer + 5]) << 8)
        | (UInt32(data[trailer + 6]) << 16)
        | (UInt32(data[trailer + 7]) << 24)
    guard expectedCRC == crc32(output), expectedSize == UInt32(truncatingIfNeeded: output.count) else {
        throw URLError(.cannotDecodeContentData)
    }
    return output
}

private func crc32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0)
        }
    }
    return crc ^ UInt32.max
}

final class StoredGzipTestSupportTests: XCTestCase {
    private let valid = Data(base64Encoded: "H4sIAAAAAAAA/wEOAPH/Y2hlY2tzdW0tcHJvYmW+DYZIDgAAAA==")!

    func testGunzipStoredValidatesCRC32Trailer() throws {
        var corrupt = valid
        corrupt[corrupt.count - 8] ^= 0xff
        XCTAssertThrowsError(try gunzipStored(corrupt))
        XCTAssertEqual(try gunzipStored(valid), Data("checksum-probe".utf8))
    }

    func testGunzipStoredValidatesISizeTrailer() {
        var corrupt = valid
        corrupt[corrupt.count - 4] ^= 0xff
        XCTAssertThrowsError(try gunzipStored(corrupt))
    }
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
