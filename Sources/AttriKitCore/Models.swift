import Foundation

let attriKitSDKVersion = "2.3.2"

struct ConsentPayload: Codable, Sendable {
    let state: AttriKitConsent
    let policyVersion: Int

    enum CodingKeys: String, CodingKey {
        case state
        case policyVersion = "policy_version"
    }
}

struct CoarseContext: Codable, Sendable {
    let countryCode: String?
    let osMajor: String
    let deviceClass: String
    /// Optional because it is optional on the wire, and because a locale we cannot render as a
    /// valid BCP-47 tag within the server's 35-character cap is better omitted than sent wrong:
    /// the envelope is `.strict()`, so one over-long value 422s the whole first-open, and a 422 is
    /// permanent. Swift synthesizes `encodeIfPresent` for optionals, so nil is omitted rather than
    /// encoded as null, which `z.string().optional()` would reject.
    let locale: String?

    /// The server's own cap (`coarseContextSchema`, packages/shared/src/ingestion.ts). Named here
    /// so the producer and the length test read the same number rather than two copies of it.
    static let localeMaxLength = 35

    enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case osMajor = "os_major"
        case deviceClass = "device_class"
        case locale
    }
}

struct ExactTokenReference: Codable, Sendable {
    let token: String
    let kind: String
    let clipboardOptIn: Bool?

    enum CodingKeys: String, CodingKey {
        case token, kind
        case clipboardOptIn = "clipboard_opt_in"
    }
}

struct WebFirstPartyIdentity: Codable, Equatable, Sendable {
    let emailHash: String?
    let phoneHash: String?

    init(_ identity: FunnelIdentity) {
        emailHash = identity.emailHash
        phoneHash = identity.phoneHash
    }

    enum CodingKeys: String, CodingKey {
        case emailHash = "email_hash"
        case phoneHash = "phone_hash"
    }
}

/// Wire contract: UUIDs serialize lowercase (server HMAC derivation + idempotency keys
/// are lowercase; Swift's UUID.uuidString is uppercase).
@propertyWrapper
struct LowercaseUUID: Codable, Sendable, Equatable, Hashable {
    var wrappedValue: UUID
    init(wrappedValue: UUID) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = UUID(uuidString: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid uuid"))
        }
        wrappedValue = id
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue.uuidString.lowercased())
    }
}

struct FirstOpenEnvelope: Codable, Sendable {
    let schemaVersion = 1
    @LowercaseUUID var installationID: UUID
    @LowercaseUUID var installEpochID: UUID
    let occurredAt: Date
    let appVersion: String
    let coarseContext: CoarseContext
    let consent: ConsentPayload
    let appTransactionJWS: String?
    let asaToken: String?
    let exactTokenReference: ExactTokenReference?
    let webFirstParty: WebFirstPartyIdentity?
    let idfa: LowercaseUUID?
    let idfv: LowercaseUUID?
    let localLineagePresent: Bool
    let localEpochPresent: Bool
    /// Constant by construction, and that is a gap rather than a decision. `let` with an
    /// initializer is excluded from the synthesized memberwise initializer, so no call site can
    /// set it and `local_signals_conflict` is `false` in every envelope this SDK will ever send --
    /// which makes the server's `upgrade_or_restore` classification unreachable from iOS and makes
    /// "no conflict" indistinguishable from "the SDK cannot tell". Nothing in this SDK computes a
    /// conflict today (Storage derives only lineage and epoch presence) and Android never passes a
    /// non-default value either, so the field is currently inert on both platforms. Making it
    /// settable without a producer would only move the silence; giving iOS a real conflict signal
    /// is a product decision about the wire, not a repair.
    let localSignalsConflict = false

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
        case occurredAt = "occurred_at"
        case appVersion = "app_version"
        case coarseContext = "coarse_context"
        case consent
        case appTransactionJWS = "app_transaction_jws"
        case asaToken = "asa_token"
        case exactTokenReference = "exact_token_ref"
        case webFirstParty = "web_first_party"
        case idfa, idfv
        case localLineagePresent = "local_lineage_present"
        case localEpochPresent = "local_epoch_present"
        case localSignalsConflict = "local_signals_conflict"
    }
}

struct IdentifyEnvelope: Codable, Sendable {
    let schemaVersion = 1
    @LowercaseUUID var installationID: UUID
    @LowercaseUUID var installEpochID: UUID
    let occurredAt: Date
    let customerUserID: String?
    let emailHash: String?
    let phoneHash: String?
    let exactTokenReference: ExactTokenReference?
    let idfa: LowercaseUUID?
    let idfv: LowercaseUUID?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
        case occurredAt = "occurred_at"
        case customerUserID = "customer_user_id"
        case emailHash = "email_hash"
        case phoneHash = "phone_hash"
        case exactTokenReference = "exact_token_ref"
        case idfa, idfv
    }
}

struct EventConsent: Codable, Sendable {
    let measurement: String
    let tracking: String
    let policyVersion: Int

    enum CodingKeys: String, CodingKey {
        case measurement, tracking
        case policyVersion = "policy_version"
    }
}

struct EventEnvelope: Codable, Sendable {
    let schemaVersion = 1
    @LowercaseUUID var eventID: UUID
    let eventName: String
    let eventVersion: Int
    let occurredAt: Date
    var sentAt: Date
    @LowercaseUUID var installationID: UUID
    @LowercaseUUID var installEpochID: UUID
    @LowercaseUUID var sessionID: UUID
    let source = "ios_sdk"
    let consent: EventConsent
    let properties: [String: AttriKitValue]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case eventName = "event_name"
        case eventVersion = "event_version"
        case occurredAt = "occurred_at"
        case sentAt = "sent_at"
        case installationID = "installation_id"
        case installEpochID = "install_epoch_id"
        case sessionID = "session_id"
        case source, consent, properties
    }
}

struct EventBatch: Codable, Sendable {
    let batchID: String
    let events: [EventEnvelope]

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case events
    }
}

struct FirstOpenResponse: Decodable, Sendable {
    let receiptID: String?
    let status: String
    let retryAfterMilliseconds: Int?
    let attribution: Attribution?

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case status
        case retryAfterMilliseconds = "retry_after_ms"
        case attribution
    }
}

struct AttributionResponse: Decodable, Sendable {
    let status: String?
    let method: String?
    let sourceType: String?
    let network: String?
    let campaignID: String?
    let finality: String?
    let policyVersion: Int?

    enum CodingKeys: String, CodingKey {
        case status, method, network, finality
        case sourceType = "source_type"
        case campaignID = "campaign_id"
        case policyVersion = "policy_version"
    }

    var attribution: Attribution? {
        guard let method, let finality, let policyVersion else { return nil }
        return Attribution(method: method, sourceType: sourceType, network: network, campaignID: campaignID, finality: finality, policyVersion: policyVersion)
    }
}

func attriKitJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func attriKitJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
    return decoder
}

/// One ISO-8601 formatter for the process, instead of one per encoded or decoded Date.
///
/// Building an `ISO8601DateFormatter` is what this costs: measured on this machine at 73.6us per
/// build against 0.85us per `string(from:)` on an already-built one, an 86x ratio over 2000 dates,
/// best-of-5. The strategies below run once per Date, so one encode of a full 100-event queue file
/// built 200 formatters, and the flush path re-encodes prefixes of it: that constant is why
/// `nextEventBatch` measured 13.384s at n=100 before the prefix count was bisected.
///
/// The formatter is configured in `init` and never mutated afterwards, and every use is inside the
/// lock. The lock is deliberate rather than a claim about `ISO8601DateFormatter`: Foundation
/// documents `DateFormatter` as thread-safe from iOS 7, and says nothing of the kind for this
/// class, so sharing one across threads without serializing is an assumption this SDK would be
/// making inside somebody else's app. An uncontended `NSLock` is nanoseconds against the 73.6us it
/// removes.
private final class ISO8601FractionalSecondsFormatter: @unchecked Sendable {
    static let shared = ISO8601FractionalSecondsFormatter()

    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    private init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(ISO8601FractionalSecondsFormatter.shared.string(from: date))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let date = ISO8601FractionalSecondsFormatter.shared.date(from: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
        }
        return date
    }
}
