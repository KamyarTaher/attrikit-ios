@_spi(AttriKitSuperwall) import AttriKitCore
import Foundation

/// Optional Superwall bridge: forwards the paywall views Superwall reports to AttriKit as the
/// canonical `paywall_viewed` event, which ad-network destinations receive as `ViewContent`.
///
/// This module does not depend on SuperwallKit. A SwiftPM dependency on it would make every app that
/// links AttriKit resolve and build Superwall's package, and would pin the two SDKs' release trains to
/// each other. Instead the app conforms Superwall's own event type to one small protocol, in its own
/// target where SuperwallKit is already imported:
///
/// ```swift
/// import AttriKitSuperwall
/// import SuperwallKit
///
/// extension SuperwallEventInfo: AttriKitSuperwallEventConvertible {
///     public var attriKitSuperwallEvent: AttriKitSuperwallEvent {
///         if case .paywallOpen(let paywall) = event {
///             return AttriKitSuperwallEvent(
///                 name: event.description,
///                 paywallIdentifier: paywall.identifier,
///                 placement: paywall.presentedByPlacementWithName
///             )
///         }
///         return AttriKitSuperwallEvent(name: event.description)
///     }
/// }
///
/// // In your SuperwallDelegate:
/// func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
///     AttriKitSuperwall.handle(eventInfo)
/// }
/// ```
///
/// Only `paywall_open` is forwarded. Superwall's `transaction_complete` is deliberately NOT turned
/// into a purchase: it is a client-side StoreKit callback, not a verified transaction, and an app
/// that also connects RevenueCat would count the same purchase twice, once from the device and once
/// from RevenueCat's server webhook, which AttriKit already treats as the owner of revenue.
public enum AttriKitSuperwall {
    /// The canonical event a Superwall paywall view becomes.
    public static let paywallViewedEventName = "paywall_viewed"

    /// Superwall's `SuperwallEvent.description` for a paywall presentation
    /// (https://github.com/superwall/superwall-ios, `_autodocs/api-reference/superwall-event.md`,
    /// read 2026-09-30: "`description` is the event's placement name string (e.g. `"app_launch"`,
    /// `"paywall_open"`)").
    static let superwallPaywallOpen = "paywall_open"

    /// Forwards one Superwall event. Returns the AttriKit event it was mapped to, or nil when the
    /// event is not one AttriKit records.
    @discardableResult
    public static func handle(_ event: some AttriKitSuperwallEventConvertible) -> AttriKitEvent? {
        handle(event.attriKitSuperwallEvent)
    }

    /// Forwards one Superwall event. Returns the AttriKit event it was mapped to, or nil when the
    /// event is not one AttriKit records.
    @discardableResult
    public static func handle(_ event: AttriKitSuperwallEvent) -> AttriKitEvent? {
        guard let (canonical, properties) = mapped(event) else { return nil }
        AttriKit.track(canonical, properties: properties)
        return canonical
    }

    /// The mapping alone, without sending anything.
    static func mapped(_ event: AttriKitSuperwallEvent) -> (AttriKitEvent, [String: AttriKitValue])? {
        guard event.name == superwallPaywallOpen,
              let canonical = try? AttriKitEvent(paywallViewedEventName) else { return nil }
        // `paywall_id` and `placement`, not Superwall's own `paywall_name`: the SDK refuses any
        // property KEY containing "name" as potential personal data (Storage.swift validation), so
        // that key would drop the whole event.
        var properties: [String: AttriKitValue] = ["source": "superwall"]
        for (key, value) in [("paywall_id", event.paywallIdentifier), ("placement", event.placement)] {
            // Checked one by one against the SDK's own rules. `track` refuses the WHOLE event on
            // the first value it rejects -- over 1,024 UTF-8 bytes, or a run of 8+ digits it reads
            // as a phone number, which a dated identifier like `pw_20260930` is -- and the view
            // matters more than any one of its labels.
            guard let value, !value.isEmpty, AttriKit.acceptsProperty(key, .string(value)) else { continue }
            properties[key] = .string(value)
        }
        return (canonical, properties)
    }
}

/// The part of a Superwall event AttriKit reads, in plain types so this module needs no SuperwallKit.
public struct AttriKitSuperwallEvent: Equatable, Sendable {
    /// `SuperwallEventInfo.event.description`, for example `paywall_open`.
    public let name: String
    /// `PaywallInfo.identifier` for paywall events.
    public let paywallIdentifier: String?
    /// `PaywallInfo.presentedByPlacementWithName` for paywall events.
    public let placement: String?

    public init(name: String, paywallIdentifier: String? = nil, placement: String? = nil) {
        self.name = name
        self.paywallIdentifier = paywallIdentifier
        self.placement = placement
    }
}

/// Conform `SuperwallEventInfo` to this in the app (see `AttriKitSuperwall`).
public protocol AttriKitSuperwallEventConvertible {
    var attriKitSuperwallEvent: AttriKitSuperwallEvent { get }
}
