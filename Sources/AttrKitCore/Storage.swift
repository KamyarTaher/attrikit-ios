import Foundation
#if canImport(Security)
import Security
#endif

struct InstallationIdentity: Sendable {
    let installationID: UUID
    let installEpochID: UUID
    let localLineagePresent: Bool
    let localEpochPresent: Bool
}

protocol InstallationIDStoring: Sendable {
    func read() throws -> UUID?
    func write(_ value: UUID) throws
    func delete() throws
}

final class KeychainInstallationIDStore: InstallationIDStoring, @unchecked Sendable {
    private let service: String
    private let account = "installation-id"

    init(service: String) { self.service = service }

    func read() throws -> UUID? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: string) else { throw StorageError.keychain(status) }
        return uuid
        #else
        return nil
        #endif
    }

    func write(_ value: UUID) throws {
        #if canImport(Security)
        try delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        #endif
    }

    func delete() throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.keychain(status) }
        #endif
    }
}

enum StorageError: Error {
    case keychain(OSStatus)
    case queueFullForProtectedEvent
}

struct RetryState: Codable, Sendable {
    var attempt: Int
    var firstAttemptAt: Date
    var nextAttemptAt: Date
}

private struct QueueFile: Codable {
    var events: [EventEnvelope]
}

actor SDKStorage {
    struct Defaults: @unchecked Sendable {
        let value: UserDefaults
        static let standard = Defaults(value: .standard)
    }

    private let defaultsBox: Defaults
    private let keychain: InstallationIDStoring
    private let queueURL: URL
    private let maxEvents: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval

    private enum Key {
        static let consent = "io.attrkit.consent"
        static let installEpoch = "io.attrkit.install-epoch"
        static let retry = "io.attrkit.first-open-retry"
        static let userID = "io.attrkit.user-id"
        static let fallbackInstallation = "io.attrkit.fallback-installation-id"
    }

    init(
        defaults: Defaults = .standard,
        keychain: InstallationIDStoring? = nil,
        directory: URL? = nil,
        maxEvents: Int = 100,
        maxBytes: Int = 1_048_576,
        maxAge: TimeInterval = 72 * 60 * 60
    ) {
        self.defaultsBox = defaults
        self.keychain = keychain ?? KeychainInstallationIDStore(service: "io.attrkit.core.\(Bundle.main.bundleIdentifier ?? "unknown")")
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.queueURL = base.appendingPathComponent("AttrKit", isDirectory: true).appendingPathComponent("events-v1.json")
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    func storeConsent(_ consent: AttrKitConsent) {
        defaultsBox.value.set(consent.rawValue, forKey: Key.consent)
    }

    func storedConsent() -> AttrKitConsent {
        defaultsBox.value.string(forKey: Key.consent).flatMap(AttrKitConsent.init(rawValue:)) ?? .unknown
    }

    func initializeIdentities() throws -> InstallationIdentity {
        // Keychain persistence is the reinstall-lineage rail, but its failure (missing
        // entitlement, device-locked windows, sandbox quirks) must never zero out
        // measurement: degrade to a defaults-backed identity that truthfully claims NO
        // lineage, so reinstall classification errs toward "fresh install" instead of
        // the SDK failing closed forever.
        var installationID: UUID
        var lineagePresent: Bool
        do {
            if let existing = try keychain.read() {
                installationID = existing
                lineagePresent = true
            } else {
                installationID = UUID()
                try keychain.write(installationID)
                lineagePresent = false
            }
        } catch {
            let fallback = defaultsBox.value.string(forKey: Key.fallbackInstallation).flatMap(UUID.init(uuidString:))
            installationID = fallback ?? UUID()
            if fallback == nil {
                defaultsBox.value.set(installationID.uuidString.lowercased(), forKey: Key.fallbackInstallation)
            }
            lineagePresent = false
        }

        let existingEpoch = defaultsBox.value.string(forKey: Key.installEpoch).flatMap(UUID.init(uuidString:))
        let epoch = existingEpoch ?? UUID()
        if existingEpoch == nil { defaultsBox.value.set(epoch.uuidString.lowercased(), forKey: Key.installEpoch) }
        return InstallationIdentity(
            installationID: installationID,
            installEpochID: epoch,
            localLineagePresent: lineagePresent,
            localEpochPresent: existingEpoch != nil
        )
    }

    func setUserID(_ userID: String?) {
        defaultsBox.value.set(userID, forKey: Key.userID)
    }

    func setRetryState(_ state: RetryState?) throws {
        if let state { defaultsBox.value.set(try JSONEncoder().encode(state), forKey: Key.retry) }
        else { defaultsBox.value.removeObject(forKey: Key.retry) }
    }

    func retryState() -> RetryState? {
        guard let data = defaultsBox.value.data(forKey: Key.retry) else { return nil }
        return try? JSONDecoder().decode(RetryState.self, from: data)
    }

    @discardableResult
    func enqueue(_ event: EventEnvelope, now: Date = Date()) throws -> Bool {
        var events = (try? readQueue()) ?? []
        events.removeAll { now.timeIntervalSince($0.occurredAt) > maxAge }
        events.append(event)

        while events.count > maxEvents || encodedSize(events) > maxBytes {
            guard let removable = events.firstIndex(where: { !isProtected($0) }) else {
                if event.eventID == events.last?.eventID {
                    events.removeLast()
                    try writeQueue(events)
                    throw StorageError.queueFullForProtectedEvent
                }
                break
            }
            events.remove(at: removable)
        }
        try writeQueue(events)
        return events.contains { $0.eventID == event.eventID }
    }

    func queuedEvents(now: Date = Date()) throws -> [EventEnvelope] {
        var events = (try? readQueue()) ?? []
        let originalCount = events.count
        events.removeAll { now.timeIntervalSince($0.occurredAt) > maxAge }
        if events.count != originalCount { try writeQueue(events) }
        return events
    }

    func removeEvents(ids: Set<UUID>) throws {
        let events = try readQueue().filter { !ids.contains($0.eventID) }
        try writeQueue(events)
    }

    func wipeQueue() throws {
        try? FileManager.default.removeItem(at: queueURL)
    }

    func deleteAll() throws {
        try wipeQueue()
        try keychain.delete()
        defaultsBox.value.removeObject(forKey: Key.installEpoch)
        defaultsBox.value.removeObject(forKey: Key.retry)
        defaultsBox.value.removeObject(forKey: Key.userID)
    }

    private func isProtected(_ event: EventEnvelope) -> Bool {
        event.eventName == "purchase" || event.eventName == "refund" || event.eventName.hasSuffix(".purchase") || event.eventName.hasSuffix(".refund")
    }

    private func encodedSize(_ events: [EventEnvelope]) -> Int {
        (try? attrKitJSONEncoder().encode(QueueFile(events: events)).count) ?? .max
    }

    private func readQueue() throws -> [EventEnvelope] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        return try attrKitJSONDecoder().decode(QueueFile.self, from: Data(contentsOf: queueURL)).events
    }

    private func writeQueue(_ events: [EventEnvelope]) throws {
        let directory = queueURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try attrKitJSONEncoder().encode(QueueFile(events: events))
        try data.write(to: queueURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [FileAttributeKey("NSFileProtectionKey"): "NSFileProtectionCompleteUntilFirstUserAuthentication"],
            ofItemAtPath: queueURL.path
        )
        #endif
    }
}

func validateProperties(_ properties: [String: AttrKitValue]) throws {
    let forbiddenKey = try NSRegularExpression(pattern: "email|e-mail|phone|mobile|address|name", options: .caseInsensitive)
    let email = try NSRegularExpression(pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, options: .caseInsensitive)
    let phone = try NSRegularExpression(pattern: #"(?:^|\D)(?:\+?\d[\d\s().-]{7,}\d)(?:$|\D)"#)
    for (key, value) in properties {
        guard !key.isEmpty, key.utf8.count <= 64 else { throw AttrKitError.invalidProperty }
        let keyRange = NSRange(key.startIndex..., in: key)
        guard forbiddenKey.firstMatch(in: key, range: keyRange) == nil else { throw AttrKitError.invalidProperty }
        if case .string(let string) = value {
            guard string.utf8.count <= 1_024 else { throw AttrKitError.invalidProperty }
            let range = NSRange(string.startIndex..., in: string)
            guard email.firstMatch(in: string, range: range) == nil,
                  phone.firstMatch(in: string, range: range) == nil else { throw AttrKitError.invalidProperty }
        }
        if case .number(let number) = value, !number.isFinite { throw AttrKitError.invalidProperty }
    }
}
