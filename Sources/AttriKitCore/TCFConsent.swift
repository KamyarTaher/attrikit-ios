import Foundation

/// Google's DMA values derived from the IAB TCF v2.2 / v2.3 consent a consent management platform
/// stores on the device.
///
/// Where the values are: IAB Tech Lab, "CMP API v2", In-App Details
/// (https://github.com/InteractiveAdvertisingBureau/GDPR-Transparency-and-Consent-Framework/blob/master/TCFv2/IAB%20Tech%20Lab%20-%20CMP%20API%20v2.md,
/// read 2026-09-30): standard UserDefaults, `IABTCF_gdprApplies` a Number (1 applies, 0 does not,
/// unset undetermined), and the purpose and vendor keys binary strings whose character at index n
/// is the status of purpose or vendor n+1. Storing them there is what the standard is for, so they
/// are read by default, as Google's own Firebase SDK reads them.
///
/// What they mean for Google, from Google's own pages (read 2026-09-30):
/// - consent-mode TCF integration
///   (https://developers.google.com/tag-platform/security/guides/implement-TCF-strings, updated
///   2024-10-09): a denied Purpose 1 or Purpose 7 makes ad_user_data denied, and a denied Purpose 3
///   or Purpose 4 makes ad_personalization denied. It does not say on which legal basis each is
///   granted; the vendor list and the IAB rules below do;
/// - Google is TCF vendor 755 and must itself be allowed (Ad Manager, "Troubleshooting IAB EU TCF
///   v2.3 implementation", https://support.google.com/admanager/answer/9999955: error 1.1 is
///   "Google, as a vendor, is not allowed under consent or legitimate interest");
/// - Purpose 7 may rest on legitimate interest, Purposes 3 and 4 need consent to both (AdMob,
///   "Interoperability guidance", https://support.google.com/admob/answer/9461778).
///
/// So: ad_user_data needs Google's vendor consent, Purpose 1 consent, and Purpose 7 on the legal
/// basis that applies to it (below); ad_personalization needs Google's vendor consent and consent
/// to Purposes 3 and 4. gdprApplies 1 is eea; gdprApplies 0 says the rules do
/// not apply, which is sent alone; no gdprApplies means no consent platform has decided anything,
/// and nothing is derived. Any other value, 0.5 included, is malformed and derives nothing.
///
/// The publisher's restrictions on Google come first, because vendors must respect them (IAB Tech
/// Lab, "Consent string and vendor list formats v2", "What are publisher restrictions?" and
/// RestrictionType, read 2026-10-01). `IABTCF_PublisherRestrictions{purpose}` holds, at index n,
/// the restriction on vendor n+1: '0' not allowed, '1' require consent, '2' require legitimate
/// interest, '_' none (CMP API v2). What '1' and '2' mean depends on how the vendor registered the
/// purpose, and Google's registration (Global Vendor List v178, 2026-09-24) is Purposes 1, 3 and 4
/// on consent without flexibility and Purpose 7 on legitimate interest with flexibility. So for
/// Purposes 1, 3 and 4, '0' and '2' forbid the purpose and '1' changes nothing. For Purpose 7, '0'
/// forbids it and '1' makes consent its basis (the purpose's and Google's); otherwise, '2', '_' or
/// no restriction at all, a flexible vendor uses the basis it declared, so Purpose 7 rests on
/// legitimate interest (the purpose's and Google's) and consent does not stand in for it ("What
/// are publisher restrictions?", "For the avoidance of doubt"). A character the CMP API does
/// not define is not read as the absence of a restriction: it forbids the purpose.
enum TCFConsent {
    static let googleVendorID = 755

    static func dmaConsent(from defaults: UserDefaults) -> DMAConsent? {
        guard let gdprApplies = number(defaults.object(forKey: "IABTCF_gdprApplies")) else { return nil }
        switch gdprApplies {
        case 0:
            return DMAConsent(eea: false, adUserData: nil, adPersonalization: nil, source: .tcf)
        case 1:
            let purposes = Bits(defaults.string(forKey: "IABTCF_PurposeConsents"))
            let purposeInterests = Bits(defaults.string(forKey: "IABTCF_PurposeLegitimateInterests"))
            let vendors = Bits(defaults.string(forKey: "IABTCF_VendorConsents"))
            let vendorInterests = Bits(defaults.string(forKey: "IABTCF_VendorLegitimateInterests"))
            func restriction(_ purpose: Int) -> Character? {
                Bits(defaults.string(forKey: "IABTCF_PublisherRestrictions\(purpose)")).character(googleVendorID)
            }
            let google = vendors.isSet(googleVendorID)
            /// A purpose Google registered on consent, without flexibility.
            func consented(_ purpose: Int) -> Bool {
                switch restriction(purpose) {
                case nil, "_", "1": return purposes.isSet(purpose)
                default: return false
                }
            }
            let measurement: Bool
            switch restriction(7) {
            case "1": measurement = purposes.isSet(7) && google
            case nil, "_", "2": measurement = purposeInterests.isSet(7) && vendorInterests.isSet(googleVendorID)
            default: measurement = false
            }
            return DMAConsent(
                eea: true,
                adUserData: google && consented(1) && measurement,
                adPersonalization: google && consented(3) && consented(4),
                source: .tcf
            )
        default:
            return nil
        }
    }

    /// The standard says Number; some platforms write the digit as a String. Both are read, and a
    /// Number counts only when it is exactly 0 or 1: `intValue` would truncate 0.5 to 0, "the rules
    /// do not apply", where Android refuses it as malformed.
    private static func number(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let exact = number.doubleValue
            return exact == 0 || exact == 1 ? Int(exact) : nil
        }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// A TCF string: the character at index n is the status of id n+1.
    private struct Bits {
        let characters: [Character]

        init(_ value: String?) {
            characters = Array(value ?? "")
        }

        func character(_ id: Int) -> Character? {
            id >= 1 && id <= characters.count ? characters[id - 1] : nil
        }

        func isSet(_ id: Int) -> Bool {
            character(id) == "1"
        }
    }
}
