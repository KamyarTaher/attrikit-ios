import CryptoKit
import Foundation

struct DeviceEvidence: Codable, Equatable, Sendable {
    let idfa: UUID?
    let idfv: UUID?
}

struct FunnelIdentity: Equatable, Sendable {
    let emailHash: String?
    let phoneHash: String?

    init(email: String? = nil, phone: String? = nil) {
        emailHash = email.flatMap(Self.normalizedEmail).map(Self.sha256)
        phoneHash = phone.flatMap(Self.normalizedPhone).map(Self.sha256)
    }

    init(emailHash: String?, phoneHash: String?) {
        self.emailHash = emailHash
        self.phoneHash = phoneHash
    }

    var isEmpty: Bool { emailHash == nil && phoneHash == nil }

    static func normalizedEmail(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedPhone(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var digits = ""
        for (offset, scalar) in trimmed.unicodeScalars.enumerated() {
            if scalar.value >= 48, scalar.value <= 57 {
                digits.unicodeScalars.append(scalar)
            } else if scalar == "+" {
                guard offset == 0 else { return nil }
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || "()-./".unicodeScalars.contains(scalar) {
                continue
            } else {
                return nil
            }
        }

        if trimmed.hasPrefix("00") {
            digits.removeFirst(min(2, digits.count))
        }
        guard (8...15).contains(digits.count), digits.first != "0" else { return nil }
        return "+" + digits
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
