@_spi(AttrKitLinkToken) import AttrKitCore
import Foundation
#if os(iOS)
import UIKit
#endif

public enum AttrKitLinkToken {
    /// Reads the clipboard only in direct response to this host-app call and only after
    /// `trackingGranted` consent has been supplied to AttrKitCore.
    public static func consumePasteboard() async -> DeepLinkResult {
        guard await AttrKit.canReadLinkTokenPasteboard() else { return .consentRequired }
        #if os(iOS)
        let value = await MainActor.run { UIPasteboard.general.string }
        guard let value else { return .ignored }
        let token: String
        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let queryToken = components.queryItems?.first(where: { $0.name == "attrkit_token" })?.value {
            token = queryToken
        } else {
            token = value
        }
        return await AttrKit.acceptExplicitLinkToken(token, kind: "clipboard")
        #else
        return .ignored
        #endif
    }

    /// Accepts a token already obtained by the host without allowing this module to inspect
    /// any other clipboard content.
    public static func consume(_ token: String) async -> DeepLinkResult {
        guard await AttrKit.canReadLinkTokenPasteboard() else { return .consentRequired }
        return await AttrKit.acceptExplicitLinkToken(token, kind: "clipboard")
    }
}
