import Foundation
#if os(iOS)
import AdServices
import StoreKit
import UIKit
#endif

protocol PlatformEvidenceProviding: Sendable {
    func appTransactionJWS() async -> String?
    func adServicesToken() async -> String?
    func coarseContext() -> CoarseContext
    func appVersion() -> String
}

struct ApplePlatformEvidenceProvider: PlatformEvidenceProviding {
    func appTransactionJWS() async -> String? {
        #if os(iOS)
        do {
            let result = try await AppTransaction.shared
            guard case .verified = result else { return nil }
            return result.jwsRepresentation
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func adServicesToken() async -> String? {
        #if os(iOS)
        for attempt in 0..<3 {
            if let token = try? AAAttribution.attributionToken() { return token }
            if attempt < 2 { try? await Task.sleep(for: .seconds(5)) }
        }
        #endif
        return nil
    }

    func coarseContext() -> CoarseContext {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion)"
        #if os(iOS)
        let deviceClass: String
        switch onMainThread({ UIDevice.current.userInterfaceIdiom }) {
        case .phone: deviceClass = "phone"
        case .pad: deviceClass = "tablet"
        default: deviceClass = "unknown"
        }
        #elseif os(macOS)
        let deviceClass = "desktop"
        #else
        let deviceClass = "unknown"
        #endif
        let locale = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        let country = Locale.current.region?.identifier.uppercased()
        return CoarseContext(countryCode: country, osMajor: os, deviceClass: deviceClass, locale: locale)
    }

    func appVersion() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }
}

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
