@_spi(AttriKitTracking) import AttriKitCore
import Foundation

#if os(iOS)
import AdSupport
import AppTrackingTransparency
import UIKit
#endif

/// Optional ATT, IDFA, and IDFV support for AttriKit.
///
/// The host app must provide a non-empty `NSUserTrackingUsageDescription` in its
/// Info.plist before requesting authorization. Calling Apple's ATT API without
/// that exact key can terminate the host process. A safe declaration is:
///
/// ```xml
/// <key>NSUserTrackingUsageDescription</key>
/// <string>We use your device identifier to measure advertising performance.</string>
/// ```
///
/// Because the ingest endpoint is configured by the host at runtime, this module cannot
/// name that endpoint in its own privacy manifest. A host that sends IDFA to AttriKit must
/// add its actual ingest domain to `NSPrivacyTrackingDomains` in the host app's privacy
/// manifest. Hosts that require a module-owned declaration can instead ship a fixed ingest
/// endpoint and declare that fixed domain in a customized tracking-module manifest.
public enum AttriKitTracking {
    private static let systems = TrackingSystemRegistry()

    /// Requests Apple's App Tracking Transparency authorization on iOS.
    ///
    /// Returns `.unknown` on platforms without ATT, while authorization is not
    /// determined, or when the host omitted `NSUserTrackingUsageDescription`.
    public static func requestConsent() async -> AttriKitConsent {
        registerEvidenceProvider()
        #if os(iOS)
        guard let usageDescription = Bundle.main.object(
            forInfoDictionaryKey: "NSUserTrackingUsageDescription"
        ) as? String, !usageDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            AttriKit.refreshTrackingEvidence()
            return .unknown
        }
        #endif
        let consent = Self.consent(for: await systems.current().requestAuthorization())
        AttriKit.refreshTrackingEvidence()
        return consent
    }

    /// The IDFA only while ATT is authorized. The all-zero sentinel is never returned.
    public static var advertisingIdentifier: UUID? {
        registerEvidenceProvider()
        let system = systems.current()
        guard system.authorizationStatus == .authorized,
              let identifier = system.advertisingIdentifier,
              identifier != zeroUUID else { return nil }
        return identifier
    }

    /// The app vendor identifier. It does not require ATT consent.
    public static var vendorIdentifier: UUID? {
        registerEvidenceProvider()
        return systems.current().vendorIdentifier
    }

    static func consent(for status: TrackingAuthorizationStatus) -> AttriKitConsent {
        switch status {
        case .authorized: .trackingGranted
        case .denied, .restricted: .denied
        case .notDetermined, .unavailable: .unknown
        }
    }

    static func configureForTesting(_ system: TrackingSystemProviding) {
        systems.install(system)
        registerEvidenceProvider()
    }

    static func resetTestingConfiguration() {
        systems.install(AppleTrackingSystem())
        registerEvidenceProvider()
    }

    private static func registerEvidenceProvider() {
        AttriKit.registerTrackingEvidenceProvider(
            advertisingIdentifier: { AttriKitTracking.advertisingIdentifierWithoutRegistration },
            vendorIdentifier: { AttriKitTracking.vendorIdentifierWithoutRegistration }
        )
    }

    private static var advertisingIdentifierWithoutRegistration: UUID? {
        let system = systems.current()
        guard system.authorizationStatus == .authorized,
              let identifier = system.advertisingIdentifier,
              identifier != zeroUUID else { return nil }
        return identifier
    }

    private static var vendorIdentifierWithoutRegistration: UUID? {
        systems.current().vendorIdentifier
    }
}

enum TrackingAuthorizationStatus: Sendable {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unavailable
}

protocol TrackingSystemProviding: Sendable {
    var authorizationStatus: TrackingAuthorizationStatus { get }
    var advertisingIdentifier: UUID? { get }
    var vendorIdentifier: UUID? { get }
    func requestAuthorization() async -> TrackingAuthorizationStatus
}

private final class TrackingSystemRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var system: TrackingSystemProviding = AppleTrackingSystem()

    func install(_ system: TrackingSystemProviding) {
        lock.lock()
        self.system = system
        lock.unlock()
    }

    func current() -> TrackingSystemProviding {
        lock.lock()
        defer { lock.unlock() }
        return system
    }
}

private struct AppleTrackingSystem: TrackingSystemProviding {
    var authorizationStatus: TrackingAuthorizationStatus {
        #if os(iOS)
        Self.map(ATTrackingManager.trackingAuthorizationStatus)
        #else
        .unavailable
        #endif
    }

    var advertisingIdentifier: UUID? {
        #if os(iOS)
        ASIdentifierManager.shared().advertisingIdentifier
        #else
        nil
        #endif
    }

    var vendorIdentifier: UUID? {
        #if os(iOS)
        onMainThread { UIDevice.current.identifierForVendor }
        #else
        nil
        #endif
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        #if os(iOS)
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                ATTrackingManager.requestTrackingAuthorization { status in
                    continuation.resume(returning: Self.map(status))
                }
            }
        }
        #else
        return .unavailable
        #endif
    }

    #if os(iOS)
    private static func map(_ status: ATTrackingManager.AuthorizationStatus) -> TrackingAuthorizationStatus {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable
        }
    }
    #endif
}

private let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

#if os(iOS)
private func onMainThread<T: Sendable>(_ operation: @escaping @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { operation() }
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated { operation() }
    }
}
#endif
