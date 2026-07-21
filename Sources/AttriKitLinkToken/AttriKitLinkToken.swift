@_spi(AttriKitLinkToken) import AttriKitCore
import Foundation
#if os(iOS)
import UIKit
#endif

public enum AttriKitLinkToken {
    private static let approvedLinkHosts: Set<String> = [
        "atk-l.bonega.ai",
        "localhost",
    ]

    /// Reads the clipboard only in direct response to this host-app call and only after
    /// `trackingGranted` consent has been supplied to AttriKitCore.
    public static func consumePasteboard() async -> DeepLinkResult {
        guard await AttriKit.canReadLinkTokenPasteboard() else { return .consentRequired }
        #if os(iOS)
        let value = await MainActor.run { UIPasteboard.general.string }
        return await consumePasteboardValue(value) { token in
            await AttriKit.acceptExplicitLinkToken(token, kind: "clipboard")
        }
        #else
        return .ignored
        #endif
    }

    /// Accepts a token already obtained by the host without allowing this module to inspect
    /// any other clipboard content.
    public static func consume(_ token: String) async -> DeepLinkResult {
        guard await AttriKit.canReadLinkTokenPasteboard() else { return .consentRequired }
        return await AttriKit.acceptExplicitLinkToken(token, kind: "clipboard")
    }

    static func consumePasteboardValue(
        _ value: String?,
        accepting acceptToken: @escaping @Sendable (String) async -> DeepLinkResult
    ) async -> DeepLinkResult {
        guard let value, let token = token(fromPasteboardValue: value) else { return .ignored }
        return await acceptToken(token)
    }

    private static func token(fromPasteboardValue value: String) -> String? {
        if isVersionedToken(value) { return value }

        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              approvedLinkHosts.contains(host),
              let token = components.queryItems?.first(where: { $0.name == "attrkit_token" })?.value,
              isVersionedToken(token) else {
            return nil
        }
        return token
    }

    private static func isVersionedToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard bytes.count == 47, token.hasPrefix("ak1_") else { return false }
        return bytes.dropFirst(4).allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 95
        }
    }
}
