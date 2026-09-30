import Foundation
#if os(iOS)
import AdServices
import StoreKit
import UIKit
#endif

protocol PlatformEvidenceProviding: Sendable {
    func appTransactionJWS() async -> String?
    func adServicesToken() async -> String?
    /// The same collection, with how it ended. A bare nil could not tell "Apple has no token for
    /// this install" from "the call failed" from "this platform has no AdServices", so a first-open
    /// without `asa_token` said nothing about why, and the Apple Ads funnel could not be measured.
    func adServicesTokenCollection() async -> AdServicesTokenCollection
    func coarseContext() -> CoarseContext
    func appVersion() -> String
}

extension PlatformEvidenceProviding {
    /// Providers that only know the token (test doubles) report a token as collected and its
    /// absence as unavailable.
    func adServicesTokenCollection() async -> AdServicesTokenCollection {
        let token = await adServicesToken()
        return AdServicesTokenCollection(token: token, outcome: token == nil ? .unavailable : .collected, attempts: 1)
    }
}

/// How one AdServices token collection ended.
enum AdServicesTokenOutcome: String, Codable, Sendable {
    /// `AAAttribution.attributionToken()` returned a token.
    case collected
    /// Every attempt threw: no token for this install from Apple, or an AdServices failure.
    case unavailable
    /// The platform has no AdServices framework (macOS, or a build without it).
    case unsupported
    /// The collection did not finish inside the first-open bound.
    case timedOut = "timed_out"
}

struct AdServicesTokenCollection: Sendable {
    let token: String?
    let outcome: AdServicesTokenOutcome
    let attempts: Int
}

struct ApplePlatformEvidenceProvider: PlatformEvidenceProviding {
    #if DEBUG
    nonisolated(unsafe) static var localeOverrideForTesting: Locale?
    #endif

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

    /// Three attempts, and the WHOLE ladder has to finish inside the caller's bound.
    ///
    /// `CoreRuntime.boundedEvidence` gives this 2 seconds and answers nil past them -- deliberately,
    /// because "a slow StoreKit must never delay the first-open envelope" -- while this ladder slept
    /// 5 seconds between attempts. The earliest a retry could produce a token was t=5s, three
    /// seconds after the caller had already answered nil, so attempts 2 and 3 could never contribute
    /// anything. A first-launch failure therefore lost the Apple Search Ads token for the life of
    /// the epoch: the envelope is persisted once and re-sent verbatim on every later launch, so the
    /// asa_click / asa_view deterministic rail was gone for that install.
    ///
    /// 250ms then 500ms is 750ms of sleeping inside a 2s budget, leaving room for three
    /// `AAAttribution.attributionToken()` calls. The bound and this ladder are ONE decision written
    /// in two files: change either and the other has to move (the bound is
    /// `CoreRuntime.collectAdServicesToken`).
    func adServicesTokenCollection() async -> AdServicesTokenCollection {
        #if os(iOS)
        let backoff: [Duration] = [.milliseconds(250), .milliseconds(500)]
        var attempts = 0
        for attempt in 0..<3 {
            guard !Task.isCancelled else { break }
            attempts += 1
            if let token = await Self.attributionToken() {
                return AdServicesTokenCollection(token: token, outcome: .collected, attempts: attempts)
            }
            if attempt < backoff.count {
                do {
                    try await Task.sleep(for: backoff[attempt])
                } catch {
                    break
                }
            }
        }
        return AdServicesTokenCollection(token: nil, outcome: .unavailable, attempts: attempts)
        #else
        return AdServicesTokenCollection(token: nil, outcome: .unsupported, attempts: 0)
        #endif
    }

    func adServicesToken() async -> String? {
        await adServicesTokenCollection().token
    }

    #if os(iOS)
    /// `AAAttribution.attributionToken()` is SYNCHRONOUS and network-backed, and Apple documents it
    /// as a call to keep off the main thread. Called straight from an `async` function it blocks a
    /// Swift-concurrency COOPERATIVE thread instead, and that pool is only as wide as the core
    /// count: three of these in a ladder can hold a large fraction of it for the whole 2s budget at
    /// first open, when the runtime is also draining a queue and racing the bound itself.
    ///
    /// The bound is the part that makes it more than a slow path. `CoreRuntime.boundedEvidence`
    /// answers nil past 2 seconds by racing the work against a `Task.sleep`, and the sleeper needs a
    /// free cooperative thread to resume on -- so a blocking call on the pool can delay the very
    /// timeout that exists to bound it. Blocking belongs on a queue that is allowed to block.
    private static func attributionToken() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: try? AAAttribution.attributionToken())
            }
        }
    }
    #endif

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
        // `Locale.current.identifier` is the ICU form, not a language tag: it carries
        // `@calendar=...;numbers=...` keywords that a `_` -> `-` substitution leaves intact, and
        // `coarseContextSchema` caps this field at 35 characters inside a `.strict()` object.
        // Measured, with substitution applied: `th_TH@calendar=buddhist;numbers=thai` is 36,
        // `zh_Hans_CN@calendar=chinese;numbers=hanidec` 38,
        // `ar_EG@calendar=islamic-umalqura;numbers=arab` 44. Past the cap the whole first-open
        // 422s, and a 422 is permanent: the epoch is never registered, every queued event is held,
        // and the persisted body is re-sent verbatim forever. One long locale cost the install.
        //
        // Extensions such as calendar, numbering system, and region overrides are valid BCP-47,
        // but are not coarse context and can push an otherwise ordinary locale past the wire cap.
        // Emit only the language/script/region identity that attribution actually consumes.
        #if DEBUG
        let activeLocale = Self.localeOverrideForTesting ?? Locale.current
        #else
        let activeLocale = Locale.current
        #endif
        let language = activeLocale.language
        let tag = [
            language.languageCode?.identifier,
            language.script?.identifier,
            language.region?.identifier,
        ].compactMap { $0 }.joined(separator: "-")
        let locale = tag.count <= CoarseContext.localeMaxLength ? tag : nil
        let rawCountry = activeLocale.region?.identifier.uppercased()
        let country = rawCountry.flatMap { value in
            value.utf8.count == 2 && value.utf8.allSatisfy { 65...90 ~= $0 } ? value : nil
        }
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
