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

struct DeletionTombstone: Codable, Equatable, Sendable {
    let installationID: UUID
    let installEpochID: UUID

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
    }
}

struct StoredEventBatch: Sendable {
    let batchID: String
    let events: [EventEnvelope]
}

private struct PendingEventBatch: Codable {
    let batchID: String
    let eventIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case eventIDs = "event_ids"
    }
}

private struct PendingRevocation: Codable {
    let targetInstallEpochID: UUID

    enum CodingKeys: String, CodingKey {
        case targetInstallEpochID = "target_install_epoch_id"
    }
}

private struct QueueFile: Codable {
    var events: [EventEnvelope]
    var pendingBatch: PendingEventBatch?

    init(events: [EventEnvelope] = [], pendingBatch: PendingEventBatch? = nil) {
        self.events = events
        self.pendingBatch = pendingBatch
    }

    enum CodingKeys: String, CodingKey {
        case events
        case pendingBatch = "pending_batch"
    }
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
    private var inMemoryQueue = QueueFile()

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
        static let sessionIndex = "io.attrikit.session-index"
        static let deletionTombstone = "io.attrikit.deletion-tombstone"
        static let consumedTokens = "io.attrikit.consumed-link-tokens"
        static let pendingRevocation = "io.attrikit.pending-revocation"
    }

    private static let maxConsumedTokens = 128

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

    func beginRevocationTransition() throws {
        guard pendingRevocation() == nil else { return }
        _ = try initializeIdentities()
        let transition = PendingRevocation(targetInstallEpochID: UUID())
        defaultsBox.value.set(
            try attriKitJSONEncoder().encode(transition),
            forKey: Key.pendingRevocation
        )
    }

    @discardableResult
    func finishRevocationTransition() throws -> InstallationIdentity {
        let current = try initializeIdentities()
        guard let transition = pendingRevocation() else {
            storeConsent(.revoked)
            return current
        }
        defaultsBox.value.set(
            transition.targetInstallEpochID.uuidString.lowercased(),
            forKey: Key.installEpoch.current
        )
        defaultsBox.value.removeObject(forKey: Key.installEpoch.legacy)
        defaultsBox.value.removeObject(forKey: Key.sessionIndex)
        storeConsent(.revoked)
        defaultsBox.value.removeObject(forKey: Key.pendingRevocation)
        return InstallationIdentity(
            installationID: current.installationID,
            installEpochID: transition.targetInstallEpochID,
            localLineagePresent: current.localLineagePresent,
            localEpochPresent: false
        )
    }

    func recoverPendingRevocationIfNeeded() throws {
        guard pendingRevocation() != nil else { return }
        _ = try finishRevocationTransition()
    }

    func deletionTombstone() -> DeletionTombstone? {
        guard let data = defaultsBox.value.data(forKey: Key.deletionTombstone) else { return nil }
        return try? attriKitJSONDecoder().decode(DeletionTombstone.self, from: data)
    }

    func storeDeletionTombstone(_ tombstone: DeletionTombstone) throws {
        defaultsBox.value.set(try attriKitJSONEncoder().encode(tombstone), forKey: Key.deletionTombstone)
    }

    func consumeExactTokenIfNew(_ token: String) -> Bool {
        var tokens = defaultsBox.value.stringArray(forKey: Key.consumedTokens) ?? []
        guard !tokens.contains(token) else { return false }
        tokens.append(token)
        if tokens.count > Self.maxConsumedTokens {
            tokens.removeFirst(tokens.count - Self.maxConsumedTokens)
        }
        defaultsBox.value.set(tokens, forKey: Key.consumedTokens)
        return true
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

    func nextSessionIndex() -> Int {
        let current = max(0, defaultsBox.value.integer(forKey: Key.sessionIndex))
        let next = current == Int.max ? Int.max : current + 1
        defaultsBox.value.set(next, forKey: Key.sessionIndex)
        return next
    }

    func retryState() -> RetryState? {
        guard let data = migratedData(for: Key.retry) else { return nil }
        return try? JSONDecoder().decode(RetryState.self, from: data)
    }

    @discardableResult
    func enqueue(_ event: EventEnvelope, now: Date = Date()) throws -> Bool {
        var queue = (try? readQueue()) ?? QueueFile()
        let pendingEventIDs = Set(queue.pendingBatch?.eventIDs ?? [])
        queue.events.removeAll {
            !pendingEventIDs.contains($0.eventID) && now.timeIntervalSince($0.occurredAt) > maxAge
        }
        queue.events.append(event)

        while queue.events.count > maxEvents || encodedSize(queue.events) > maxBytes {
            guard let removable = queue.events.firstIndex(where: {
                !pendingEventIDs.contains($0.eventID) && !isProtected($0)
            }) else {
                if event.eventID == queue.events.last?.eventID {
                    queue.events.removeLast()
                    try writeQueue(queue)
                    throw StorageError.queueFullForProtectedEvent
                }
                break
            }
            queue.events.remove(at: removable)
        }
        try writeQueue(queue)
        return queue.events.contains { $0.eventID == event.eventID }
    }

    func queuedEvents(now: Date = Date()) throws -> [EventEnvelope] {
        var queue = (try? readQueue()) ?? QueueFile()
        let originalCount = queue.events.count
        let pendingEventIDs = Set(queue.pendingBatch?.eventIDs ?? [])
        queue.events.removeAll {
            !pendingEventIDs.contains($0.eventID) && now.timeIntervalSince($0.occurredAt) > maxAge
        }
        if queue.events.count != originalCount { try writeQueue(queue) }
        return queue.events
    }

    func nextEventBatch(now: Date = Date()) throws -> StoredEventBatch? {
        var queue = try readQueue()
        let pendingEventIDs = Set(queue.pendingBatch?.eventIDs ?? [])
        queue.events.removeAll {
            !pendingEventIDs.contains($0.eventID) && now.timeIntervalSince($0.occurredAt) > maxAge
        }

        if let pending = queue.pendingBatch {
            let eventsByID = Dictionary(uniqueKeysWithValues: queue.events.map { ($0.eventID, $0) })
            let events = pending.eventIDs.compactMap { eventsByID[$0] }
            if events.count == pending.eventIDs.count {
                try writeQueue(queue)
                return StoredEventBatch(batchID: pending.batchID, events: events)
            }
            // A manually altered/corrupt queue cannot safely reuse an idempotency key
            // for a different request body. Start a new batch for the surviving rows.
            queue.pendingBatch = nil
        }

        guard !queue.events.isEmpty else {
            try writeQueue(queue)
            return nil
        }
        for index in queue.events.indices { queue.events[index].sentAt = now }
        let pending = PendingEventBatch(
            batchID: UUID().uuidString.lowercased(),
            eventIDs: queue.events.map(\.eventID)
        )
        queue.pendingBatch = pending
        try writeQueue(queue)
        return StoredEventBatch(batchID: pending.batchID, events: queue.events)
    }

    func acknowledgeEventBatch(batchID: String) throws {
        var queue = try readQueue()
        guard let pending = queue.pendingBatch, pending.batchID == batchID else { return }
        let acknowledgedIDs = Set(pending.eventIDs)
        queue.events.removeAll { acknowledgedIDs.contains($0.eventID) }
        queue.pendingBatch = nil
        try writeQueue(queue)
    }

    func removeEvents(ids: Set<UUID>) throws {
        var queue = try readQueue()
        queue.events.removeAll { ids.contains($0.eventID) }
        if let pending = queue.pendingBatch, !ids.isDisjoint(with: pending.eventIDs) {
            queue.pendingBatch = nil
        }
        try writeQueue(queue)
    }

    func wipeQueue() throws {
        guard let queueURL else {
            inMemoryQueue = QueueFile()
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
        defaultsBox.value.removeObject(forKey: Key.sessionIndex)
        defaultsBox.value.removeObject(forKey: Key.consumedTokens)
        defaultsBox.value.removeObject(forKey: Key.pendingRevocation)
        if let firstError { throw firstError }
    }

    func completeDeletion() throws {
        try deleteAll()
        defaultsBox.value.removeObject(forKey: Key.deletionTombstone)
    }

    private func pendingRevocation() -> PendingRevocation? {
        guard let data = defaultsBox.value.data(forKey: Key.pendingRevocation) else { return nil }
        return try? attriKitJSONDecoder().decode(PendingRevocation.self, from: data)
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

    private func readQueue() throws -> QueueFile {
        guard let queueURL else { return inMemoryQueue }
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return QueueFile() }
        let data = try Data(contentsOf: queueURL)
        do {
            return try attriKitJSONDecoder().decode(QueueFile.self, from: data)
        } catch {
            let timestamp = Int(Date().timeIntervalSince1970)
            let quarantineURL = queueURL.appendingPathExtension("corrupted-\(timestamp)")
            try? FileManager.default.moveItem(at: queueURL, to: quarantineURL)
            return QueueFile()
        }
    }

    private func writeQueue(_ queue: QueueFile) throws {
        guard let queueURL else {
            inMemoryQueue = queue
            return
        }
        var directory = queueURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directory.setResourceValues(resourceValues)
        let data = try attriKitJSONEncoder().encode(queue)
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
