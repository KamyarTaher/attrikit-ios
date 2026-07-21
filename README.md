# AttrKit iOS SDK

Privacy-clean web-to-app attribution for iOS. AttrKit connects ad clicks to installs
using the proof Apple allows — Apple-signed install confirmation and exact single-use
link tokens — never an advertising identifier, never a device graph.

- **Deterministic where proof exists.** A match is only called *verified* when it is
  backed by direct evidence: Apple confirmation or an exact AttrKit link token.
- **Honest where it doesn't.** Everything else stays an aggregate, campaign-level
  estimate with its range attached — never a fabricated per-install "match".
- **Privacy-clean by construction.** No IDFA, no fingerprinting, no advertising
  identifiers of any kind. Raw email never leaves the device (SHA-256 on-device only,
  and only when you explicitly provide it).

## Requirements

- iOS 16+ / macOS 13+
- Swift 5.9+
- Xcode 15+

## Installation (Swift Package Manager)

In Xcode: **File → Add Package Dependencies…** and enter:

```
https://github.com/KamyarTaher/attrkit-ios
```

Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/KamyarTaher/attrkit-ios", from: "1.0.0"),
],
// target:
.product(name: "AttrKitCore", package: "attrkit-ios"),
```

The package ships two libraries:

| Library | Use it for |
|---|---|
| `AttrKitCore` | Attribution, first-open + event tracking, consent, deep links. **This is all most apps need.** |
| `AttrKitLinkToken` | Optional. Redeems a deferred deep-link token from the system pasteboard (e.g. after a "copy link" web flow). |

## Quickstart

### 1. Start the SDK

Call `start` as early as possible — typically in your `App.init` or
`application(_:didFinishLaunchingWithOptions:)`. Use the **publishable key** from your
AttrKit dashboard (app settings).

```swift
import AttrKitCore

@main
struct MyApp: App {
    init() {
        AttrKit.start(apiKey: "ak_pub_…", consent: .measurementGranted)
    }

    var body: some Scene { /* … */ }
}
```

The first launch after install reports the first-open automatically — this is what the
attribution pipeline matches against your campaigns.

### 2. Consent

Pass the consent state you already collected (ATT prompt, your own consent flow, or
`.unknown` before either). Update it whenever it changes:

```swift
AttrKit.setConsent(.trackingGranted)   // or .measurementGranted / .denied / .revoked
```

| Consent | Effect |
|---|---|
| `.measurementGranted` | Measurement allowed, no cross-app tracking. The common ATT-declined case. |
| `.trackingGranted` | Full measurement. |
| `.denied` / `.revoked` | Collection is suppressed client-side. |
| `.unknown` | Nothing is sent until you resolve it. |

### 3. Read the attribution

```swift
let result = await AttrKit.attribution()

switch result {
case .attributed(let attribution):
    // attribution.method   — how it was matched (e.g. exact link token, Apple confirmation)
    // attribution.network  — e.g. "meta", "tiktok", "apple_search_ads"
    // attribution.campaignID
    // attribution.finality — "final" or "provisional"
    break
case .unattributed:
    break // organic, or below the evidence bar
case .timedOut, .notStarted, .consentRequired, .failed:
    break
}
```

`attribution(timeout:)` accepts a `Duration` (default 2s) — the SDK never blocks your
launch path longer than that.

### 4. Track conversion and revenue events

```swift
try AttrKit.track(AttrKitEvent("signup_complete"))
try AttrKit.track(AttrKitEvent("purchase"), properties: [
    "value": .number(9.99),
    "currency": .string("USD"),
])
```

Event names must match `^[a-z][a-z0-9_.-]{0,127}$`. `purchase` / `refund` (and
`*.purchase` / `*.refund`) are protected revenue events — they are queued with higher
durability and never silently dropped.

### 5. Deep links

Route incoming universal links through the SDK so AttrKit can resolve deferred
attribution and hand you the destination:

```swift
// SwiftUI
.onOpenURL { url in
    let result = await AttrKit.handle(url)
    if case .handled(let destination) = result {
        // navigate to destination
    }
}
```

### 6. Optional: pasteboard link tokens (`AttrKitLinkToken`)

If your web flow copies a link token to the pasteboard, redeem it on first open:

```swift
import AttrKitLinkToken

if await AttrKit.canReadLinkTokenPasteboard() {
    _ = await AttrKitLinkToken.consumePasteboard()
}
```

### 7. User identity and data deletion

```swift
AttrKit.setUserID("your-opaque-user-id")   // optional, your own stable id; pass nil to clear

try await AttrKit.deleteData()             // GDPR/CCPA erasure — wipes queued + server-side data for this install
```

## Privacy posture

- **No advertising identifiers.** The SDK never reads IDFA or any equivalent.
- **No fingerprinting.** Matching uses Apple-signed install evidence and exact,
  single-use link tokens — not probabilistic device traits.
- **On-device hashing only.** If you provide an email on your own web funnel (web SDK),
  it is SHA-256 hashed in the browser before anything is sent; raw email never transits.
- **Consent-gated.** Nothing is collected while consent is `.denied`, `.revoked`, or
  unresolved `.unknown`.
- **Data deletion built in.** `deleteData()` is a first-class API, not a support ticket.

Disclose the SDK in your App Store privacy nutrition label accordingly (analytics /
product interaction data, not linked to advertising).

## How attribution works (30 seconds)

1. Your ad points to an AttrKit link. The link edge records the click and serves a
   sub-100ms interstitial that captures the exact proof (click id + single-use token),
   then redirects to the App Store.
2. On first open, this SDK reports the install and presents the token.
3. AttrKit redeems the token → **verified, per-install, deterministic attribution**.
   Installs without token/Apple evidence stay aggregate estimates with ranges — labeled
   as such, never dressed up as verified.

## Links

- Dashboard + docs: [attrkit.waiverkit.io](https://attrkit.waiverkit.io) (temporary domain)
- Issues: use this repository's issue tracker.

## License

Proprietary — © AttrKit. Distribution via SPM for integration into host apps;
see the dashboard terms for usage rights.
