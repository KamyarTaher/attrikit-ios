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
    private let legacyKeychain: InstallationIDStoring?
    private let queueURL: URL?
    private let queueDirectoryRemover: @Sendable (URL) throws -> Void
    private let maxEvents: Int
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private var inMemoryQueue: [EventEnvelope] = []

    private struct MigratingKey {
        let current: String
        let legacy: String
    }

    private enum Key {
        static let consent = MigratingKey(current: "io.attrikit.consent", legacy: "io.attrkit.consent")
        static let installEpoch = MigratingKey(current: "io.attrikit.install-epoch", legacy: "io.attrkit.install-epoch")
        static let retry = MigratingKey(current: "io.attrikit.first-open-retry", legacy: "io.attrkit.first-open-retry")
        static let userID = MigratingKey(current: "io.attrikit.user-id", legacy: "io.attrkit.user-id")
        static let fallbackInstallation = MigratingKey(current: "io.attrikit.fallback-installation-id", legacy: "io.attrkit.fallback-installation-id")
    }

    init(
        defaults: Defaults = .standard,
        keychain: InstallationIDStoring? = nil,
        legacyKeychain: InstallationIDStoring? = nil,
        directory: URL? = nil,
        directoryProvider: @escaping @Sendable (FileManager.SearchPathDirectory) -> URL? = {
            FileManager.default.urls(for: $0, in: .userDomainMask).first
        },
        queueDirectoryRemover: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        maxEvents: Int = 100,
        maxBytes: Int = 1_048_576,
        maxAge: TimeInterval = 72 * 60 * 60
    ) {
        self.defaultsBox = defaults
        if let keychain {
            self.keychain = keychain
            self.legacyKeychain = legacyKeychain
        } else {
            let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
            self.keychain = KeychainInstallationIDStore(service: "io.attrikit.core.\(bundleID)")
            self.legacyKeychain = KeychainInstallationIDStore(service: "io.attrkit.core.\(bundleID)")
        }
        let base = directory
            ?? directoryProvider(.applicationSupportDirectory)
            ?? directoryProvider(.cachesDirectory)
        self.queueURL = base?
            .appendingPathComponent("AttriKit", isDirectory: true)
            .appendingPathComponent("events-v1.json")
        self.queueDirectoryRemover = queueDirectoryRemover
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    func storeConsent(_ consent: AttriKitConsent) {
        defaultsBox.value.set(consent.rawValue, forKey: Key.consent.current)
    }

    func storedConsent() -> AttriKitConsent {
        migratedString(for: Key.consent).flatMap(AttriKitConsent.init(rawValue:)) ?? .unknown
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
            } else if let legacy = try legacyKeychain?.read() {
                installationID = legacy
                try? keychain.write(legacy)
                lineagePresent = true
            } else {
                installationID = UUID()
                try keychain.write(installationID)
                lineagePresent = false
            }
        } catch {
            let fallback = migratedString(for: Key.fallbackInstallation).flatMap(UUID.init(uuidString:))
            installationID = fallback ?? UUID()
            if fallback == nil {
                defaultsBox.value.set(installationID.uuidString.lowercased(), forKey: Key.fallbackInstallation.current)
            }
            lineagePresent = false
        }

        let existingEpoch = migratedString(for: Key.installEpoch).flatMap(UUID.init(uuidString:))
        let epoch = existingEpoch ?? UUID()
        if existingEpoch == nil { defaultsBox.value.set(epoch.uuidString.lowercased(), forKey: Key.installEpoch.current) }
        return InstallationIdentity(
            installationID: installationID,
            installEpochID: epoch,
            localLineagePresent: lineagePresent,
            localEpochPresent: existingEpoch != nil
        )
    }

    func setUserID(_ userID: String?) {
        if let userID {
            defaultsBox.value.set(userID, forKey: Key.userID.current)
        } else {
            removeValues(for: Key.userID)
        }
    }

    func storedUserID() -> String? {
        migratedString(for: Key.userID)
    }

    func setRetryState(_ state: RetryState?) throws {
        if let state { defaultsBox.value.set(try JSONEncoder().encode(state), forKey: Key.retry.current) }
        else { removeValues(for: Key.retry) }
    }

    func retryState() -> RetryState? {
        guard let data = migratedData(for: Key.retry) else { return nil }
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
        guard let queueURL else {
            inMemoryQueue.removeAll()
            return
        }
        let queueDirectory = queueURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: queueDirectory.path) else { return }
        try queueDirectoryRemover(queueDirectory)
    }

    func deleteAll() throws {
        var firstError: Error?
        do { try wipeQueue() } catch { firstError = error }
        do { try keychain.delete() } catch {
            if firstError == nil { firstError = error }
        }
        do { try legacyKeychain?.delete() } catch {
            if firstError == nil { firstError = error }
        }
        removeValues(for: Key.consent)
        removeValues(for: Key.installEpoch)
        removeValues(for: Key.fallbackInstallation)
        removeValues(for: Key.retry)
        removeValues(for: Key.userID)
        if let firstError { throw firstError }
    }

    private func migratedString(for key: MigratingKey) -> String? {
        if let value = defaultsBox.value.string(forKey: key.current) { return value }
        guard let legacy = defaultsBox.value.string(forKey: key.legacy) else { return nil }
        defaultsBox.value.set(legacy, forKey: key.current)
        return legacy
    }

    private func migratedData(for key: MigratingKey) -> Data? {
        if let value = defaultsBox.value.data(forKey: key.current) { return value }
        guard let legacy = defaultsBox.value.data(forKey: key.legacy) else { return nil }
        defaultsBox.value.set(legacy, forKey: key.current)
        return legacy
    }

    private func removeValues(for key: MigratingKey) {
        defaultsBox.value.removeObject(forKey: key.current)
        defaultsBox.value.removeObject(forKey: key.legacy)
    }

    private func isProtected(_ event: EventEnvelope) -> Bool {
        event.eventName == "purchase" || event.eventName == "refund" || event.eventName.hasSuffix(".purchase") || event.eventName.hasSuffix(".refund")
    }

    private func encodedSize(_ events: [EventEnvelope]) -> Int {
        (try? attriKitJSONEncoder().encode(QueueFile(events: events)).count) ?? .max
    }

    private func readQueue() throws -> [EventEnvelope] {
        guard let queueURL else { return inMemoryQueue }
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        let data = try Data(contentsOf: queueURL)
        do {
            return try attriKitJSONDecoder().decode(QueueFile.self, from: data).events
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let quarantineURL = queueURL.appendingPathExtension("corrupted-\(timestamp)")
            try? FileManager.default.moveItem(at: queueURL, to: quarantineURL)
            return []
        }
    }

    private func writeQueue(_ events: [EventEnvelope]) throws {
        guard let queueURL else {
            inMemoryQueue = events
            return
        }
        var directory = queueURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        let data = try attriKitJSONEncoder().encode(QueueFile(events: events))
        try data.write(to: queueURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes(
            [FileAttributeKey("NSFileProtectionKey"): "NSFileProtectionCompleteUntilFirstUserAuthentication"],
            ofItemAtPath: queueURL.path
        )
        #endif
    }
}

func validateProperties(_ properties: [String: AttriKitValue]) throws {
    let forbiddenKey = try NSRegularExpression(pattern: "email|e-mail|phone|mobile|address|name", options: .caseInsensitive)
    let email = try NSRegularExpression(pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, options: .caseInsensitive)
    let phone = try NSRegularExpression(pattern: #"(?:^|\D)(?:\+?\d[\d\s().-]{7,}\d)(?:$|\D)"#)
    for (key, value) in properties {
        guard !key.isEmpty, key.utf8.count <= 64 else { throw AttriKitError.invalidProperty }
        let keyRange = NSRange(key.startIndex..., in: key)
        guard forbiddenKey.firstMatch(in: key, range: keyRange) == nil else { throw AttriKitError.invalidProperty }
        if case .string(let string) = value {
            guard string.utf8.count <= 1_024 else { throw AttriKitError.invalidProperty }
            let range = NSRange(string.startIndex..., in: string)
            guard email.firstMatch(in: string, range: range) == nil,
                  phone.firstMatch(in: string, range: range) == nil else { throw AttriKitError.invalidProperty }
        }
        if case .number(let number) = value, !number.isFinite { throw AttriKitError.invalidProperty }
    }
}
