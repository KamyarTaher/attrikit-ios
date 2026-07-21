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
        guard name.range(of: #"^[a-z][a-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else {
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

public struct Attribution: Codable, Equatable, Sendable {
    public let method: String
    public let network: String?
    public let campaignID: String?
    public let finality: String
    public let policyVersion: Int

    enum CodingKeys: String, CodingKey {
        case method, network, finality
        case campaignID = "campaign_id"
        case policyVersion = "policy_version"
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
