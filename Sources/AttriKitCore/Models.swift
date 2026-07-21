import Foundation

let attriKitSDKVersion = "1.0.0"

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
    let locale: String

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
    let network: String?
    let campaignID: String?
    let finality: String?
    let policyVersion: Int?

    enum CodingKeys: String, CodingKey {
        case status, method, network, finality
        case campaignID = "campaign_id"
        case policyVersion = "policy_version"
    }

    var attribution: Attribution? {
        guard let method, let finality, let policyVersion else { return nil }
        return Attribution(method: method, network: network, campaignID: campaignID, finality: finality, policyVersion: policyVersion)
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

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = custom { date, encoder in
        var container = encoder.singleValueContainer()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try container.encode(formatter.string(from: date))
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 timestamp")
        }
        return date
    }
}
