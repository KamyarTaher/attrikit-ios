import Foundation
#if os(iOS)
import StoreKit
#endif

/// A versioned mapping from in-app milestones to SKAdNetwork and AdAttributionKit conversion values.
///
/// Fine values (0 to 63) are reserved in order: 0 install, 1 activation, 2 trial, then one value
/// per revenue bucket from 3 upward. Coarse values follow the same ladder: `low` once the user is
/// engaged (activation), `medium` for a qualified trial, `high` once they paid. A value is only
/// ever raised, and the window is locked when the top revenue bucket is reached, since nothing
/// higher can follow.
///
/// Configure it once with `AttriKit.configureConversionValues(_:)` and let AttriKit be the ONLY
/// writer: an app that also calls SKAdNetwork or AdAttributionKit directly overwrites these values,
/// and the postback then decodes against the wrong schema.
public struct AttriKitConversionSchema: Equatable, Sendable {
    /// Recorded with the install's first write. A schema with another version never writes over
    /// an install that started under this one: the values would mean two different things.
    public let version: Int
    /// Cumulative revenue at which each bucket above the first begins, ascending, in `currency`.
    /// Any positive revenue is bucket 0 (fine value 3); reaching `revenueThresholds[i]` is bucket
    /// `i + 1`. At most 60 thresholds, which is fine value 63.
    public let revenueThresholds: [Double]
    /// ISO 4217 code. Revenue in any other currency is not converted, and does not count.
    public let currency: String
    /// The event name that marks activation, for example `onboarding_completed`. Nil when the app
    /// records activation itself with `AttriKit.recordConversion(.activation)`.
    public let activationEvent: String?

    public init(version: Int, revenueThresholds: [Double], currency: String, activationEvent: String? = nil) throws {
        guard version > 0,
              revenueThresholds.count <= ConversionValuePlan.maximumFine - ConversionValuePlan.firstRevenueFine,
              revenueThresholds.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(revenueThresholds, revenueThresholds.dropFirst()).allSatisfy({ $0 < $1 }),
              currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else {
            throw AttriKitConversionSchemaError.invalid
        }
        self.version = version
        self.revenueThresholds = revenueThresholds
        self.currency = currency
        self.activationEvent = activationEvent
    }
}

/// Thrown by `AttriKitConversionSchema.init` for a version below 1, more than 60 thresholds, a
/// threshold that is not a positive finite number or not strictly ascending, or a currency that is
/// not three uppercase letters.
public enum AttriKitConversionSchemaError: Error, Equatable, Sendable {
    case invalid
}

/// A milestone that can raise the conversion value.
public enum AttriKitConversionMilestone: Equatable, Sendable {
    case activation
    case trialStarted
    /// Revenue in the schema's currency, added to the install's running total.
    case revenue(Double)
}

enum CoarseConversionLevel: Int, Codable, Comparable, Sendable {
    case low = 1, medium, high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What this install has done, and what was last WRITTEN. Only a successful update advances the
/// written half, so a failed update is retried by the next milestone instead of being lost.
struct ConversionValueState: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var activated = false
    var trialStarted = false
    var revenue: Double = 0
    var writtenFine = 0
    var writtenCoarse: CoarseConversionLevel?
    var locked = false
}

struct ConversionValueWrite: Equatable, Sendable {
    let fine: Int
    let coarse: CoarseConversionLevel
    let lock: Bool
}

enum ConversionValuePlan {
    static let firstRevenueFine = 3
    static let maximumFine = 63

    /// The state after `milestone`, and the write it calls for, if any. Pure, so every rung of the
    /// schema is testable without StoreKit.
    static func apply(
        _ milestone: AttriKitConversionMilestone,
        to state: ConversionValueState,
        schema: AttriKitConversionSchema
    ) -> (state: ConversionValueState, write: ConversionValueWrite?) {
        var next = state
        guard next.schemaVersion == schema.version, !next.locked else { return (next, nil) }
        switch milestone {
        case .activation: next.activated = true
        case .trialStarted: next.trialStarted = true
        case .revenue(let amount):
            guard amount.isFinite, amount > 0 else { return (next, nil) }
            next.revenue += amount
        }
        let (fine, coarse) = target(next, schema: schema)
        guard let coarse else { return (next, nil) }
        let raisesFine = fine > next.writtenFine
        let raisesCoarse = next.writtenCoarse.map { coarse > $0 } ?? true
        guard raisesFine || raisesCoarse else { return (next, nil) }
        // Never lowers what an earlier write set, in either value.
        let write = ConversionValueWrite(
            fine: max(fine, next.writtenFine),
            coarse: max(coarse, next.writtenCoarse ?? coarse),
            lock: fine == topFine(schema)
        )
        return (next, write)
    }

    static func topFine(_ schema: AttriKitConversionSchema) -> Int {
        firstRevenueFine + schema.revenueThresholds.count
    }

    private static func target(_ state: ConversionValueState, schema: AttriKitConversionSchema) -> (Int, CoarseConversionLevel?) {
        if state.revenue > 0 {
            let bucket = schema.revenueThresholds.filter { $0 <= state.revenue }.count
            return (firstRevenueFine + bucket, .high)
        }
        if state.trialStarted { return (2, .medium) }
        if state.activated { return (1, .low) }
        return (0, nil)
    }

    /// The milestone a tracked event stands for under `schema`, if any. Revenue counts only in the
    /// schema's own currency and only from a numeric `value`.
    static func milestone(for event: AttriKitEvent, properties: [String: AttriKitValue], schema: AttriKitConversionSchema) -> AttriKitConversionMilestone? {
        if let activation = schema.activationEvent, event.name == activation { return .activation }
        if ["trial_started", "intro_started"].contains(event.name) { return .trialStarted }
        guard ["purchase", "purchase_completed", "subscription_started", "subscription_renewed"].contains(event.name),
              case .number(let value)? = properties["value"],
              case .string(let currency)? = properties["currency"],
              currency.uppercased() == schema.currency else { return nil }
        return .revenue(value)
    }
}

/// The platform call, apart so the writer is testable without StoreKit.
struct ConversionValueUpdater: Sendable {
    let update: @Sendable (ConversionValueWrite) async throws -> Void

    /// SKAdNetwork's update, which Apple mirrors into AdAttributionKit: "When an app calls the
    /// update conversion values APIs in SKAdNetwork ... SKAdNetwork bridges the conversion values
    /// between the two frameworks by mirroring the call into AdAttributionKit"
    /// (https://developer.apple.com/documentation/adattributionkit/adattributionkit-skadnetwork-interoperability,
    /// read 2026-09-30). One call covers both, and it keeps this SDK from linking AdAttributionKit,
    /// a framework that does not exist below iOS 17.4 while this package supports iOS 16.
    static let live = ConversionValueUpdater { write in
        #if os(iOS)
        guard #available(iOS 16.1, *) else { throw ConversionValueUpdateError.unsupported }
        let coarse: SKAdNetwork.CoarseConversionValue
        switch write.coarse {
        case .low: coarse = .low
        case .medium: coarse = .medium
        case .high: coarse = .high
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            SKAdNetwork.updatePostbackConversionValue(write.fine, coarseValue: coarse, lockWindow: write.lock) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        #else
        throw ConversionValueUpdateError.unsupported
        #endif
    }
}

enum ConversionValueUpdateError: Error {
    case unsupported
}
