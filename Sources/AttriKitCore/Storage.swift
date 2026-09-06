import Foundation
#if canImport(os)
import os
#endif
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
    case corruptDeletionTombstone
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

struct StoredConsentReceipt: Codable, Equatable, Sendable {
    let idempotencyKey: UUID
    let installationID: UUID
    let installEpochID: UUID
    let scope: String
    let state: AttriKitConsent
    let occurredAt: Date

    enum CodingKeys: String, CodingKey {
        case idempotencyKey = "idempotency_key"
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
        case scope, state
        case occurredAt = "occurred_at"
    }

    var kind: ConsentReceiptKind? {
        switch state {
        case .measurementGranted, .trackingGranted: .grant
        case .denied, .revoked: .withdrawal
        case .unknown: nil
        }
    }
}

enum ConsentReceiptKind: Sendable {
    case grant
    case withdrawal
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
        static let firstOpenBody = "io.attrikit.first-open-body"
        static let installEpoch = MigratingKey(current: "io.attrikit.install-epoch", legacy: "io.attrkit.install-epoch")
        static let retry = MigratingKey(current: "io.attrikit.first-open-retry", legacy: "io.attrkit.first-open-retry")
        static let userID = MigratingKey(current: "io.attrikit.user-id", legacy: "io.attrkit.user-id")
        static let fallbackInstallation = MigratingKey(current: "io.attrikit.fallback-installation-id", legacy: "io.attrkit.fallback-installation-id")
        static let sessionIndex = "io.attrikit.session-index"
        static let deletionTombstone = "io.attrikit.deletion-tombstone"
        static let consumedTokens = "io.attrikit.consumed-link-tokens"
        static let pendingRevocation = "io.attrikit.pending-revocation"
        static let consentReceipts = "io.attrikit.consent-receipts"
    }

    private static let maxConsumedTokens = 128

    /// The two Keychain services the DEFAULT construction uses, in one place because they differ
    /// by a single letter -- `attrikit` now, `attrkit` before the rename -- and a copy that drifts
    /// into equality silently deletes the migration branch in `initializeIdentities()`: both stores
    /// would issue the identical SecItem query, so `keychain.read()` returning nil implies the
    /// legacy read returns nil too, and a pre-rename install loses its lineage with nothing failing.
    /// Returned rather than inlined so a test can assert the difference without touching a real
    /// Keychain.
    static func defaultKeychainServices(bundleID: String) -> (current: String, legacy: String) {
        (current: "io.attrikit.core.\(bundleID)", legacy: "io.attrkit.core.\(bundleID)")
    }

    init(
        defaults: Defaults = .standard,
        keychain: InstallationIDStoring? = nil,
        legacyKeychain: InstallationIDStoring? = nil,
        keychainFactory: @Sendable (String) -> InstallationIDStoring = {
            KeychainInstallationIDStore(service: $0)
        },
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
            let services = Self.defaultKeychainServices(bundleID: Bundle.main.bundleIdentifier ?? "unknown")
            self.keychain = keychainFactory(services.current)
            // An injected legacy store was DISCARDED here and replaced with a default one, so a
            // caller that supplied only `legacyKeychain` had that dependency silently dropped and
            // the migration read went to a store it never chose.
            self.legacyKeychain = legacyKeychain ?? keychainFactory(services.legacy)
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

    /// Keeps the defaults fallback in step with the keychain identity.
    ///
    /// Only writes when the value differs, so a launch that changes nothing does not touch
    /// UserDefaults on every start.
    private func mirrorFallbackInstallation(_ id: UUID) {
        let value = id.uuidString.lowercased()
        if migratedString(for: Key.fallbackInstallation) == value { return }
        defaultsBox.value.set(value, forKey: Key.fallbackInstallation.current)
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
                // Mirror into the defaults fallback so a LATER keychain-unavailable launch reuses
                // this id instead of minting a new one. Without it the fallback was write-only in
                // the failure path and always empty when first needed. Same class of value the
                // failure path already stores there, so this widens no exposure.
                mirrorFallbackInstallation(existing)
            } else if let legacy = try legacyKeychain?.read() {
                installationID = legacy
                try? keychain.write(legacy)
                mirrorFallbackInstallation(legacy)
                lineagePresent = true
            } else if let fallback = migratedString(for: Key.fallbackInstallation)
                .flatMap(UUID.init(uuidString:)) {
                // The preceding launch may have degraded while Keychain was unavailable. Once
                // Keychain recovers it can legitimately be empty, but that must not mint a second
                // installation identity and split attribution across launches.
                installationID = fallback
                try keychain.write(fallback)
                lineagePresent = false
            } else {
                installationID = UUID()
                try keychain.write(installationID)
                lineagePresent = false
                mirrorFallbackInstallation(installationID)
            }
        } catch {
            // The fallback slot is only useful if something ever WROTE to it. Until now nothing did
            // on the success path, so the first keychain-unavailable launch found it empty and
            // minted a NEW UUID: a device locked at launch reported a different installation_id
            // than the launch before and after it, which the server reads as a different install.
            // The mirror below fixes the cause; this branch now reuses it.
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
        guard try pendingRevocation() == nil else { return }
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
        guard let transition = try pendingRevocation() else {
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
        guard try pendingRevocation() != nil else { return }
        _ = try finishRevocationTransition()
    }

    func deletionTombstone() throws -> DeletionTombstone? {
        guard let data = defaultsBox.value.data(forKey: Key.deletionTombstone) else { return nil }
        do {
            return try attriKitJSONDecoder().decode(DeletionTombstone.self, from: data)
        } catch {
            throw StorageError.corruptDeletionTombstone
        }
    }

    func storeDeletionTombstone(_ tombstone: DeletionTombstone) throws {
        defaultsBox.value.set(try attriKitJSONEncoder().encode(tombstone), forKey: Key.deletionTombstone)
    }

    /// Whether this token has not been seen, WITHOUT marking it seen.
    ///
    /// Exists so acceptExactToken can refuse a repeat without spending the token before the
    /// identify that carries it has been acknowledged. Consuming first meant a process killed
    /// mid-flight burned the only deterministic attribution signal the SDK has, with no failure
    /// for anything to react to.
    func isExactTokenNew(_ token: String) -> Bool {
        !(defaultsBox.value.stringArray(forKey: Key.consumedTokens) ?? []).contains(token)
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

    /// Undoes `consumeExactTokenIfNew` when the identify carrying the token was never acknowledged.
    ///
    /// An ak1_ token is the only deterministic attribution signal the SDK has, and it was marked
    /// consumed on disk BEFORE the network call that delivers it, so any failure burned it
    /// permanently and silently downgraded the install to probabilistic matching.
    ///
    /// Releasing is safe against a double send: the server treats a repeat from the SAME occurrence
    /// as valid and reserves "replay" for a DIFFERENT one
    /// (`apps/link/src/ingestion/repository.ts:421`), so re-delivering the token this device already
    /// sent is idempotent by that contract rather than by luck.
    func releaseConsumedToken(_ token: String) {
        var tokens = defaultsBox.value.stringArray(forKey: Key.consumedTokens) ?? []
        guard let index = tokens.lastIndex(of: token) else { return }
        tokens.remove(at: index)
        defaultsBox.value.set(tokens, forKey: Key.consumedTokens)
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

    /// The exact first-open body, persisted so a relaunch sends a byte-identical payload.
    ///
    /// The server hashes the WHOLE envelope (`payloadDigest` = sha256 of the JSON), so "same
    /// install again" is only a clean `duplicate` — rather than a 409 `idempotency_conflict` —
    /// if every byte matches. `submitFirstOpen` used to rebuild the envelope with
    /// `occurredAt: configuration.now()` on every launch, so launch 2 hashed differently from
    /// launch 1 and conflicted; the 409 is handled as a registration, but a persisted body
    /// makes the ordinary relaunch the duplicate it always was. Android already did this.
    ///
    /// The body is scoped to both its epoch and its producing consent. An epoch rotation or any
    /// consent change makes the stored bytes stale, and a stale body is discarded on read.
    private struct PersistedFirstOpenBody: Codable {
        let installEpochID: UUID
        let consent: AttriKitConsent?
        let body: Data
    }

    func setFirstOpenBody(_ body: Data?, installEpochID: UUID?, consent: AttriKitConsent?) throws {
        if let body, let installEpochID, let consent {
            defaultsBox.value.set(
                try JSONEncoder().encode(PersistedFirstOpenBody(
                    installEpochID: installEpochID,
                    consent: consent,
                    body: body
                )),
                forKey: Key.firstOpenBody
            )
        } else {
            defaultsBox.value.removeObject(forKey: Key.firstOpenBody)
        }
    }

    func firstOpenBody(installEpochID: UUID, consent: AttriKitConsent) -> Data? {
        guard let stored = defaultsBox.value.data(forKey: Key.firstOpenBody) else { return nil }
        guard let persisted = try? JSONDecoder().decode(PersistedFirstOpenBody.self, from: stored),
              persisted.installEpochID == installEpochID,
              persisted.consent == consent else {
            defaultsBox.value.removeObject(forKey: Key.firstOpenBody)
            return nil
        }
        return persisted.body
    }

    /// Adds a consent transition to durable storage before any delivery is attempted.
    ///
    /// The stable idempotency key survives a crash after the server accepts the receipt but before
    /// this process can acknowledge it locally. Replaying that record is therefore safe.
    func enqueueConsentReceipt(_ receipt: StoredConsentReceipt) throws {
        var receipts = try consentReceipts()
        receipts.append(receipt)
        defaultsBox.value.set(try attriKitJSONEncoder().encode(receipts), forKey: Key.consentReceipts)
    }

    func nextConsentReceipt(deliverGrants: Bool = true) throws -> StoredConsentReceipt? {
        var receipts = try consentReceipts()
        let next = receipts.first { receipt in
            switch receipt.kind {
            case .grant: deliverGrants
            case .withdrawal: true
            case nil: false
            }
        }
        let originalCount = receipts.count
        receipts.removeAll { $0.kind == nil }
        if receipts.count != originalCount {
            try storeConsentReceipts(receipts)
        }
        return next
    }

    func acknowledgeConsentReceipt(idempotencyKey: UUID) throws {
        var receipts = try consentReceipts()
        guard let index = receipts.firstIndex(where: { $0.idempotencyKey == idempotencyKey }) else { return }
        let acknowledged = receipts[index]
        if acknowledged.kind == .withdrawal {
            // A withdrawal may bypass an older grant while consent is off. Once the server has
            // acknowledged that withdrawal, sending the stale grant on a future regrant would
            // restore processing for the old epoch. Remove only grants the withdrawal supersedes.
            receipts.removeAll { receipt in
                receipt.idempotencyKey == idempotencyKey
                    || (receipt.kind == .grant
                        && receipt.installationID == acknowledged.installationID
                        && receipt.installEpochID == acknowledged.installEpochID
                        && receipt.occurredAt < acknowledged.occurredAt)
            }
        } else {
            receipts.remove(at: index)
        }
        if receipts.isEmpty {
            defaultsBox.value.removeObject(forKey: Key.consentReceipts)
        } else {
            defaultsBox.value.set(try attriKitJSONEncoder().encode(receipts), forKey: Key.consentReceipts)
        }
    }

    func pendingConsentReceipts() throws -> [StoredConsentReceipt] {
        try consentReceipts()
    }

    #if DEBUG
    /// Test-only gate, fired by the FIRST caller only and then cleared.
    ///
    /// `applicationDidBecomeActive` suspends here, between its activation guards and the
    /// assignment of `activeSession`. That window is where duplicate activations and a
    /// concurrent wipe do their damage, and nothing in a test could hold it open: this is a
    /// plain actor hop over synchronous work, so a raced test only overlapped by luck. It did
    /// not: with the duplicate-start guard deleted, the raced test still passed five times out
    /// of five, meaning it asserted nothing about the hazard it was named for. This makes the
    /// window openable on demand so those tests can fail for the right reason.
    private var sessionIndexGate: (@Sendable () async -> Void)?
    func setSessionIndexGate(_ gate: (@Sendable () async -> Void)?) { sessionIndexGate = gate }
    /// Reads the counter WITHOUT consuming an index, unlike `nextSessionIndex()`.
    func currentSessionIndexForTesting() -> Int { max(0, defaultsBox.value.integer(forKey: Key.sessionIndex)) }
    #endif

    func nextSessionIndex() async -> Int {
        #if DEBUG
        if let gate = sessionIndexGate {
            sessionIndexGate = nil
            await gate()
        }
        #endif
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
        // `try?` made an UNREADABLE queue file indistinguishable from an absent one, and the write
        // at the end of this function then replaced every queued event with this single one.
        //
        // readQueue() already returns an empty queue without throwing for both benign cases: a file
        // that does not exist, and one that fails to decode (quarantined first). What is left is
        // `Data(contentsOf:)` failing on a file that DOES exist, which on iOS routinely means the
        // device has not been unlocked since boot: writeQueue sets
        // NSFileProtectionCompleteUntilFirstUserAuthentication, so a background launch before first
        // unlock cannot read it. Dropping one event there is recoverable; dropping the queue is not.
        //
        // nextEventBatch below already calls `try readQueue()`, so this matches the file's own
        // convention. queuedEvents keeps its `try?` deliberately: it writes back only when the
        // event count changed, which the empty fallback cannot trigger, so it loses nothing.
        var queue = try readQueue()
        let pendingEventIDs = Set(queue.pendingBatch?.eventIDs ?? [])
        queue.events.removeAll {
            !pendingEventIDs.contains($0.eventID) && now.timeIntervalSince($0.occurredAt) > maxAge
        }
        queue.events.append(event)

        var evicted = 0
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
            evicted += 1
        }
        if evicted > 0 {
            // These are UNSENT events being destroyed to make room, which is the queue working as
            // designed under pressure - but it happened with no trace at all, so a device dropping
            // events for hours looked identical to one with nothing to send. One line per enqueue
            // that evicts, not per event, so a backlog does not drown the log it needs to appear in.
            #if canImport(os)
            os_log(
                .error,
                "AttriKit: the offline queue evicted %d unsent event(s) to stay within its capacity. They are lost. This means events are being produced faster than they can be delivered, or delivery has been failing for a long time.",
                evicted
            )
            #endif
        }
        try writeQueue(queue)
        return queue.events.contains { $0.eventID == event.eventID }
    }

    func queuedEvents(now: Date = Date()) throws -> [EventEnvelope] {
        var queue = try readQueue()
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
        var uniqueEventIDs = Set<UUID>()
        let containedDuplicateEventIDs = queue.events.contains { event in
            !uniqueEventIDs.insert(event.eventID).inserted
        }
        if containedDuplicateEventIDs {
            uniqueEventIDs.removeAll(keepingCapacity: true)
            queue.events = queue.events.filter { event in
                uniqueEventIDs.insert(event.eventID).inserted
            }
            // The persisted idempotency key described a body containing duplicates. Reusing it
            // after normalization would bind the same key to different bytes.
            queue.pendingBatch = nil
        }
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
        // Cap the batch at a client ceiling safely below the server's 64KB limit so a
        // normal batch never trips a 413. At least one event is always sent (a lone
        // oversized event is genuine poison the flush path isolates and drops).
        let batchCount = Self.batchPrefixCount(within: queue.events)
        for index in queue.events.prefix(batchCount).indices { queue.events[index].sentAt = now }
        let batchEvents = Array(queue.events.prefix(batchCount))
        let pending = PendingEventBatch(
            batchID: UUID().uuidString.lowercased(),
            eventIDs: batchEvents.map(\.eventID)
        )
        queue.pendingBatch = pending
        try writeQueue(queue)
        return StoredEventBatch(batchID: pending.batchID, events: batchEvents)
    }

    func acknowledgeEventBatch(batchID: String) throws {
        var queue = try readQueue()
        guard let pending = queue.pendingBatch, pending.batchID == batchID else { return }
        let acknowledgedIDs = Set(pending.eventIDs)
        queue.events.removeAll { acknowledgedIDs.contains($0.eventID) }
        queue.pendingBatch = nil
        try writeQueue(queue)
    }

    /// Bisect the pending batch after a permanent client failure on a multi-event batch,
    /// so the offending event is progressively isolated instead of dropping valid siblings.
    /// Keeps the first half as a fresh pending batch (a NEW idempotency key, since the
    /// request body changes) and returns the rest to the queue for later batches.
    func splitPendingBatch(batchID: String) throws {
        var queue = try readQueue()
        guard let pending = queue.pendingBatch, pending.batchID == batchID else { return }
        guard pending.eventIDs.count > 1 else { return }
        let half = pending.eventIDs.count / 2
        queue.pendingBatch = PendingEventBatch(
            batchID: UUID().uuidString.lowercased(),
            eventIDs: Array(pending.eventIDs.prefix(half))
        )
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
        defaultsBox.value.removeObject(forKey: Key.consentReceipts)
        // The persisted first-open envelope, which deleteAll did not clear. It is the one stored
        // value that carries the whole first-open body verbatim, so a successful deleteData() left
        // the most identifying artifact the SDK holds sitting in UserDefaults while reporting the
        // erasure complete. It is keyed by install epoch, and the epoch above is gone, so nothing
        // could ever read it again either: it was unreachable data the user had asked us to delete.
        defaultsBox.value.removeObject(forKey: Key.firstOpenBody)
        if let firstError { throw firstError }
    }

    func completeDeletion() throws {
        try deleteAll()
        defaultsBox.value.removeObject(forKey: Key.deletionTombstone)
    }

    private func pendingRevocation() throws -> PendingRevocation? {
        guard let data = defaultsBox.value.data(forKey: Key.pendingRevocation) else { return nil }
        return try attriKitJSONDecoder().decode(PendingRevocation.self, from: data)
    }

    private func consentReceipts() throws -> [StoredConsentReceipt] {
        guard let data = defaultsBox.value.data(forKey: Key.consentReceipts) else { return [] }
        return try attriKitJSONDecoder().decode([StoredConsentReceipt].self, from: data)
    }

    private func storeConsentReceipts(_ receipts: [StoredConsentReceipt]) throws {
        if receipts.isEmpty {
            defaultsBox.value.removeObject(forKey: Key.consentReceipts)
        } else {
            defaultsBox.value.set(try attriKitJSONEncoder().encode(receipts), forKey: Key.consentReceipts)
        }
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

    /// Client-side batch byte ceiling, kept safely below the server's 64KB ingest limit
    /// so a normal batch never round-trips into a 413.
    ///
    /// Internal rather than private so the test that pins the cut reads THIS number instead of
    /// carrying a copy that can drift away from it.
    static let batchByteCeiling = 56 * 1024

    /// Longest leading run of events whose encoded batch payload stays under the ceiling.
    /// Always at least 1 so a single oversized event can still be attempted (and then
    /// isolated + dropped by the flush path) rather than wedging the queue.
    ///
    /// BISECTED, not scanned. An upward scan re-encodes every prefix from 1 to n, so the flush
    /// path pays n whole-batch encodes where the bisection pays log2(n).
    ///
    /// The measurement that forced it -- `nextEventBatch` at 13.384s for n=100 against 2.876s at
    /// n=50, debug build, full default queue (maxEvents = 100) -- was taken while the date
    /// strategy built an ISO8601DateFormatter per Date, 200 of them for one 100-event prefix.
    /// That constant is gone: `ISO8601FractionalSecondsFormatter.shared` (Models.swift) builds one
    /// formatter for the process and serialises use behind an uncontended lock, so a Date now
    /// costs a `string(from:)` rather than a 73.6us build. The numbers above are therefore
    /// historical; what the bisection still removes is the COUNT of encodes, which the shared
    /// formatter made cheaper without making them free.
    ///
    /// The answer is identical because the predicate is monotone: a longer prefix never encodes to
    /// fewer bytes, and a prefix containing an unencodable event stays unencodable (`encodedBatchSize`
    /// answers `.max`), so "fits under the ceiling" is true for a leading run and false after it.
    /// The largest count that satisfies it is exactly where the upward scan stopped, in log2(n)
    /// encodes instead of n.
    private static func batchPrefixCount(within events: [EventEnvelope]) -> Int {
        guard !events.isEmpty else { return 0 }
        var fits = 1
        var upper = events.count
        while fits < upper {
            let candidate = fits + (upper - fits + 1) / 2
            if encodedBatchSize(Array(events.prefix(candidate))) <= batchByteCeiling {
                fits = candidate
            } else {
                upper = candidate - 1
            }
        }
        return fits
    }

    private static func encodedBatchSize(_ events: [EventEnvelope]) -> Int {
        (try? attriKitJSONEncoder().encode(EventBatch(batchID: "", events: events)).count) ?? .max
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
            // Recovery must not depend on the QUARANTINE succeeding. The suffix is a whole second,
            // so a second corruption inside the same second collides with the file already there
            // and `moveItem` throws `NSFileWriteFileExists` -- and that throw used to leave the
            // corrupt file exactly where it was. Every later readQueue re-decoded it, re-failed,
            // re-collided and rethrew: persistence and flushing stayed wedged for the life of the
            // install instead of self-healing, which is the opposite of what this branch exists for.
            // Quarantine when we can, delete when we cannot, and return the empty queue either way;
            // the next writeQueue replaces the file atomically.
            do {
                try FileManager.default.moveItem(at: queueURL, to: quarantineURL)
            } catch {
                try? FileManager.default.removeItem(at: queueURL)
            }
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
    let phoneCandidate = try NSRegularExpression(pattern: #"(?<!\d)\+?\d[\d\s().-]*\d(?!\d)"#)
    for (key, value) in properties {
        guard !key.isEmpty, key.utf8.count <= 64 else { throw AttriKitError.invalidProperty }
        let keyRange = NSRange(key.startIndex..., in: key)
        guard forbiddenKey.firstMatch(in: key, range: keyRange) == nil else { throw AttriKitError.invalidProperty }
        if case .string(let string) = value {
            guard string.utf8.count <= 1_024 else { throw AttriKitError.invalidProperty }
            let range = NSRange(string.startIndex..., in: string)
            let containsPhone = phoneCandidate.matches(in: string, range: range).contains { match in
                guard let candidateRange = Range(match.range, in: string) else { return false }
                return string[candidateRange].filter(\.isNumber).count >= 8
            }
            guard email.firstMatch(in: string, range: range) == nil,
                  !containsPhone else { throw AttriKitError.invalidProperty }
        }
        if case .number(let number) = value, !number.isFinite { throw AttriKitError.invalidProperty }
    }
}
