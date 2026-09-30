import Foundation

public enum AttriKitConsent: String, Codable, Sendable, CaseIterable {
    case unknown
    case measurementGranted = "measurement_granted"
    case trackingGranted = "tracking_granted"
    case denied
    case revoked

    public var allowsMeasurement: Bool {
        self == .measurementGranted || self == .trackingGranted
    }

    public var allowsTracking: Bool { self == .trackingGranted }
}

public enum AttriKitValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) { self = .string(string) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else { throw DecodingError.typeMismatch(Self.self, .init(codingPath: decoder.codingPath, debugDescription: "AttriKit properties must be scalar strings, numbers, or booleans")) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        }
    }
}

extension AttriKitValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AttriKitValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension AttriKitValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension AttriKitValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

public struct AttriKitEvent: Hashable, Sendable {
    public let name: String
    public let version: Int

    public init(_ name: String, version: Int = 1) throws {
        let validNameRange = name.range(
            of: #"^[a-z][a-z0-9_.-]{0,127}$"#,
            options: .regularExpression
        )
        guard validNameRange == name.startIndex..<name.endIndex else {
            throw AttriKitError.invalidEventName
        }
        guard version > 0 else { throw AttriKitError.invalidEventVersion }
        self.name = name
        self.version = version
    }

    public init(name: String, version: Int = 1) throws {
        try self.init(name, version: version)
    }

    public var isProtectedRevenueEvent: Bool {
        name == "purchase" || name == "refund" || name.hasSuffix(".purchase") || name.hasSuffix(".refund")
    }
}

/// An install's attribution as the server answers it.
///
/// Synthesized Decodable on purpose, pinned by apps/link/src/ingestion/attribution-context.test.ts:
/// it ignores keys it does not name, which is what lets the server add keys to this body without
/// breaking the binaries already in apps.
public struct Attribution: Codable, Equatable, Sendable {
    public let method: String
    public let sourceType: String?
    public let network: String?
    /// AttriKit's own campaign id, the one the dashboard and the management API use.
    public let campaignID: String?
    /// `provisional` until the server's finality window closes (72 hours after first open), then
    /// `final`. A provisional answer can still change, and the SDK keeps asking while it is one.
    public let finality: String
    public let policyVersion: Int
    /// The server's verdict (`attributed`, `device_matched`, `organic`, `consent_required`),
    /// absent from servers before 2026-09-30. Read it through `status`.
    let attributionStatus: String?
    public let adsetID: String?
    public let adID: String?
    /// The server's match confidence, 0 to 1, for a device match; nil otherwise.
    public let confidence: Double?
    public let campaignName: String?
    /// The campaign id as the ad network itself names it (a Meta or TikTok campaign id); nil when
    /// the campaign has no network id on file.
    public let networkCampaignID: String?

    enum CodingKeys: String, CodingKey {
        case method, network, finality, confidence
        case sourceType = "source_type"
        case campaignID = "campaign_id"
        case policyVersion = "policy_version"
        case attributionStatus = "attribution_status"
        case adsetID = "adset_id"
        case adID = "ad_id"
        case campaignName = "campaign_name"
        case networkCampaignID = "network_campaign_id"
    }

    init(
        method: String,
        sourceType: String?,
        network: String?,
        campaignID: String?,
        finality: String,
        policyVersion: Int,
        attributionStatus: String? = nil,
        adsetID: String? = nil,
        adID: String? = nil,
        confidence: Double? = nil,
        campaignName: String? = nil,
        networkCampaignID: String? = nil
    ) {
        self.method = method
        self.sourceType = sourceType
        self.network = network
        self.campaignID = campaignID
        self.finality = finality
        self.policyVersion = policyVersion
        self.attributionStatus = attributionStatus
        self.adsetID = adsetID
        self.adID = adID
        self.confidence = confidence
        self.campaignName = campaignName
        self.networkCampaignID = networkCampaignID
    }

    /// What this answer says about the install: the server's `attribution_status` when it sent
    /// one, otherwise the same derivation the server makes (packages/shared/src/attribution-context.ts,
    /// `attributionStatus`), so a build talking to an older server reads the same verdict.
    ///
    /// A device match is recognised by EITHER field: the route derives `method` from the winning
    /// evidence row, and a device match may have none, so it can arrive as
    /// `method: "unattributed", source_type: "device_match"`.
    public var status: AttributionStatus {
        if let attributionStatus, let verdict = AttributionStatus(rawValue: attributionStatus),
           verdict != .pending, verdict != .timedOut {
            return verdict
        }
        // Line for line the server's own derivation, so a build talking to a server that predates
        // `attribution_status` reads the verdict that server would have sent. Whether a campaign
        // may reach a paywall is a separate question, answered by `isDeterministic` below.
        if sourceType == "unattributed" { return .organic }
        if sourceType == "device_match" || method == "device_matched" { return .deviceMatched }
        return .attributed
    }

    /// Deterministic campaign context for paywall placement parameters or user attributes.
    /// Device-matched, modeled, organic and consent-blocked answers produce an empty dictionary,
    /// so `isEmpty` still means "no verified campaign". For the reason, use `userAttributes`.
    public var placementParameters: [String: String] {
        AttributionPlacement.campaignParameters(self)
    }

    /// True while the server may still change this answer.
    var isProvisional: Bool { finality == "provisional" }

    /// A grade proven per install. The set stays private: packages/adapters/src/superwall.test.ts
    /// reads its literal from this file and pins it to the backend's AuthenticityGrade union.
    var isDeterministic: Bool { Self.deterministicMethods.contains(method) }

    private static let deterministicMethods: Set<String> = [
        "deterministic",
        "platform_verified",
        "exact_single_use",
        "customer_signed",
    ]
}

/// Why the campaign context is what it is. Sent as `attrkit_status` in `userAttributes`, so a
/// context without campaign keys still says which of these it is. The first five are the
/// server's own `attribution_status` values; `timedOut` is the SDK's.
public enum AttributionStatus: String, Equatable, Sendable, CaseIterable {
    /// A deterministic or platform-verified match (Apple Ads, an exact link token, a signed claim).
    case attributed
    /// Matched to a click by device matching. Its campaign stays out of the context, which
    /// carries verified matches only.
    case deviceMatched = "device_matched"
    /// The server answered, and no campaign claimed this install.
    case organic
    /// No answer yet. The SDK is still asking, or has not started.
    case pending
    /// Consent does not allow measurement, the install's consent was withdrawn, or a data
    /// deletion is in progress.
    case consentRequired = "consent_required"
    /// The SDK stopped asking inside its window without an answer; a later launch asks again.
    case timedOut = "timed_out"
}

/// One state of this install's attribution, as `attributionUpdates()` publishes it.
public struct AttributionUpdate: Equatable, Sendable {
    public let status: AttributionStatus
    /// The server's answer when there is one, whatever its status.
    public let attribution: Attribution?

    public init(status: AttributionStatus, attribution: Attribution?) {
        self.status = status
        self.attribution = attribution
    }

    /// For Superwall `setUserAttributes`: EVERY `attrkit_` key, every time. `attrkit_status` always
    /// has a value, `attrkit_finality` once the server answered, and the deterministic campaign keys
    /// of `placementParameters` when this state has them; every other key is `nil`.
    ///
    /// The `nil` values are the point. Superwall's `setUserAttributes(_ attributes: [String: Any?])`
    /// MERGES: a key it already stores keeps its old value unless the new dictionary names it, and
    /// a `nil` value removes it (https://superwall.com/docs/ios/sdk-reference/setUserAttributes,
    /// read 2026-09-30). A dictionary that only listed present keys left a provisional Meta
    /// answer's `attrkit_adset_id` on a user Apple Ads later claimed, and a withdrawn consent left
    /// the campaign behind.
    public var userAttributes: [String: String?] {
        AttributionPlacement.userAttributes(status: status, attribution: attribution)
    }

    /// Deterministic campaign context only; empty for any other state.
    public var placementParameters: [String: String] {
        guard status == .attributed, let attribution else { return [:] }
        return AttributionPlacement.campaignParameters(attribution)
    }
}

enum AttributionPlacement {
    static func campaignParameters(_ attribution: Attribution) -> [String: String] {
        guard attribution.isDeterministic,
              attribution.status == .attributed else { return [:] }
        let campaign: [(String, String?)] = [
            ("attrkit_method", attribution.method),
            ("attrkit_network", attribution.network),
            ("attrkit_campaign_id", attribution.campaignID),
            ("attrkit_source_type", attribution.sourceType),
            ("attrkit_campaign_name", attribution.campaignName),
            ("attrkit_network_campaign_id", attribution.networkCampaignID),
            ("attrkit_adset_id", attribution.adsetID),
            ("attrkit_ad_id", attribution.adID),
            ("attrkit_finality", attribution.finality),
        ]
        var parameters: [String: String] = [:]
        for (key, value) in campaign {
            if let value, !value.isEmpty { parameters[key] = value }
        }
        return parameters
    }

    /// Every key `userAttributes` can set, so each update can clear the ones it has no value for.
    /// `campaignParameters` must never produce a key missing here.
    static let userAttributeKeys = [
        "attrkit_status",
        "attrkit_finality",
        "attrkit_method",
        "attrkit_network",
        "attrkit_campaign_id",
        "attrkit_source_type",
        "attrkit_campaign_name",
        "attrkit_network_campaign_id",
        "attrkit_adset_id",
        "attrkit_ad_id",
    ]

    static func userAttributes(status: AttributionStatus, attribution: Attribution?) -> [String: String?] {
        var present = ["attrkit_status": status.rawValue]
        if let attribution {
            present["attrkit_finality"] = attribution.finality
            if status == .attributed {
                present.merge(campaignParameters(attribution)) { _, campaign in campaign }
            }
        }
        // Built from pairs: assigning nil through a `[String: String?]` subscript REMOVES the key,
        // which would drop exactly the clearing values this dictionary exists to carry.
        return Dictionary(uniqueKeysWithValues: userAttributeKeys.map { ($0, present[$0]) })
    }
}

/// Where this install's Apple Ads token got to, for support and integration checks.
public struct AppleAdsTokenStatus: Equatable, Sendable {
    /// `collected`, `unavailable` (AdServices returned no token), `unsupported` (no AdServices on
    /// this platform), or `timed_out` (not ready inside the first-open bound).
    public let outcome: String
    public let attempts: Int
    public let latencyMilliseconds: Int
    /// When the token carried by this install's first-open was collected.
    public let tokenCollectedAt: Date?
    /// When the server acknowledged the first-open carrying it.
    public let deliveredAt: Date?

    init(funnel: AppleAdsTokenFunnel) {
        outcome = funnel.outcome.rawValue
        attempts = funnel.attempts
        latencyMilliseconds = funnel.latencyMilliseconds
        tokenCollectedAt = funnel.tokenCollectedAt
        deliveredAt = funnel.acknowledgedAt
    }
}

public enum AttributionResult: Equatable, Sendable {
    case attributed(Attribution)
    case unattributed
    case timedOut
    case notStarted
    case consentRequired
    case failed
}

public enum DeepLinkResult: Equatable, Sendable {
    case handled(URL)
    case ignored
    case consentRequired
    case invalid
}

public enum AttriKitError: Error, Equatable, Sendable {
    case invalidAPIKey
    case invalidEventName
    case invalidEventVersion
    case invalidProperty
    case queueFullForProtectedEvent
    case notStarted
    case consentRequired
    case deletionFailed(Int)
}
