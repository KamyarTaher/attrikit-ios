# AttriKit for iOS

AttriKit is a consent-aware measurement SDK for first-open attribution, event delivery,
deferred links, and optional App Tracking Transparency evidence.

## Installation

Requires **iOS 16.0** or later (macOS 13.0 for host tooling). A target below that fails to resolve
with `The package product 'AttriKitCore' requires minimum platform version 16.0 for the iOS
platform`, which names the ceiling but not the fix, so it is stated here first.

In Xcode, choose **File > Add Package Dependencies** and enter:

```text
https://github.com/KamyarTaher/attrikit-ios
```

Select `AttriKitCore`. Add `AttriKitTracking` only when the app requests ATT and add
`AttriKitLinkToken` only when it explicitly consumes a deferred-link token.

For a package manifest:

```swift
dependencies: [
    .package(url: "https://github.com/KamyarTaher/attrikit-ios", from: "2.1.0"),
]
```

## Core setup

Configure the HTTPS ingest endpoint in the host app's Info.plist. The value is
`https://attrikit.io` for every workspace — one shared ingest host, and your publishable
key (`pk_…`) routes each event to your app:

```xml
<key>AttriKitEndpoint</key>
<string>https://attrikit.io</string>
```

In DEBUG builds you may point at `http://127.0.0.1:port` for a local capture stack. A
missing or invalid key traps in DEBUG and disables attribution — it never silently
targets another host.

Then start measurement after obtaining the app's measurement consent:

```swift
import AttriKitCore

AttriKit.start(apiKey: "YOUR_PUBLISHABLE_KEY", consent: .measurementGranted)
AttriKit.track(try AttriKitEvent("trial_started"), properties: ["plan": "annual"])
```

Do not put email addresses or phone numbers in event properties. When a user supplies
first-party funnel identity, use the dedicated API. It normalizes and SHA-256 hashes the
values synchronously on-device and never persists the raw input:

```swift
AttriKit.setFunnelIdentity(
    email: "person@example.com",
    phone: "+41 79 123 45 67"
)
```

Phone numbers must include a country calling code (a leading `+` or `00` is accepted).
The hashes are included in the first first-open payload when set before startup and in a
later identify payload when set after startup.

## Custom events, user identity and attribution results

Event names must match `^[a-z][a-z0-9_.-]{0,127}$` (the constructor throws otherwise)
and are versioned with an integer:

```swift
AttriKit.track(try AttriKitEvent("stencil_created", version: 1),
               properties: ["template": .string("sleeve")])
```

Attach your own user id (opaque string, max 256 bytes; strings containing @ are
rejected, so emails are not accepted). This is the join key server-side webhooks
use — with RevenueCat, pass the app user id:

```swift
AttriKit.setUserID(Purchases.shared.appUserID)
```

Read how the install was attributed (method, network, campaign, finality) to
personalize onboarding or paywall placements:

```swift
let result = await AttriKit.attribution(timeout: .seconds(2))
```

Campaign-link tokens (`ak1_…`) make attribution deterministic when they reach the SDK
through a universal link or an explicit, consented pasteboard read. The public token
APIs live in the AttriKitLinkToken module:

```swift
_ = await AttriKit.handle(url)                        // universal links
let result = await AttriKitLinkToken.consumePasteboard()
// .consentRequired until consent is .trackingGranted; the call itself is the opt-in
```

First-open delivery is idempotent on the server (retries of the same install epoch
never double-count; a reinstall is recorded as its own epoch and classified
separately, never billed twice) and retried on a bounded schedule: one initial attempt plus up to six
retries (5s → 30s → 5m → 1h → 3h → 6h, within ~24h of the first failure). When first-open is
accepted but matching is still pending, the attribution poll is bounded the same way: it ramps from
250ms to a 5-second ceiling for the first minute, then follows that same ladder, waits at least as
long as a `Retry-After` header asks (clamped to six hours), and once the schedule is exhausted or the
~24h window closes it stops and leaves the result UNKNOWN: `attribution(timeout:)` answers
`.timedOut`, never `.unattributed`. Exhaustion means AttrKit stopped asking, not that the install
had no attribution, and the answer is cached for the process lifetime, so claiming the stronger of
the two would make a match that had simply not landed yet permanently wrong. Event batches
flush immediately after enqueue, retrying with backoff starting at one second and
capped at one minute. The full wire
contract lives at https://attrikit.io/en/docs/ingest-api.

To allow the retry ladder to request background execution, the host app must declare the SDK's
public `AttriKit.backgroundRetryTaskIdentifier` in its Info.plist. If this declaration is absent,
iOS rejects the submission and AttriKit reports the failure through the system log:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>io.attrikit.sdk.retry</string>
</array>
```

## Engagement signals

After `AttriKit.start`, core measurement tracks foreground sessions by default. Each
completed session uses the existing event batch transport to send a `session_end` v1
event with `duration_ms` and the install-scoped `session_index`. Background interruptions
of 30 seconds or less retain the current session index; a longer gap starts the next one.

No session event is recorded unless measurement consent allows it. To opt out, disable
session tracking before startup (or at any later point):

```swift
AttriKit.setSessionTrackingEnabled(false)
```

## App Tracking Transparency (optional)

Add the `AttriKitTracking` product only if the app needs IDFA-based advertising
measurement. The host—not the package—must include this exact Info.plist key before
calling `requestConsent()`; Apple's ATT API can terminate an app that calls it without a
usage description:

```xml
<key>NSUserTrackingUsageDescription</key>
<string>We use your device identifier to measure advertising performance.</string>
```

Request ATT from an appropriate UI moment before starting AttriKit when IDFA must be in
the first first-open payload. A denial still starts consent-safe core measurement:

```swift
import AttriKitCore
import AttriKitTracking

Task {
    let trackingConsent = await AttriKitTracking.requestConsent()
    let sdkConsent: AttriKitConsent = trackingConsent == .trackingGranted
        ? .trackingGranted
        : .measurementGranted
    AttriKit.start(apiKey: "YOUR_PUBLISHABLE_KEY", consent: sdkConsent)
}
```

If `requestConsent()` is called while the application is inactive or backgrounded, it waits for
the next active state before invoking Apple's ATT prompt and records that wait in the system log.

`AttriKitTracking.advertisingIdentifier` is non-nil only while ATT is authorized and
never returns Apple's all-zero sentinel. `AttriKitTracking.vendorIdentifier` exposes
IDFV without requiring ATT. Once the tracking module has been used, AttriKit forwards
IDFV and, only when authorized, IDFA in the first-open payload and later identify
payloads. If core measurement was already started, the resolved identifiers are
forwarded in an identify payload instead. On macOS, ATT is unavailable and
`requestConsent()` returns `.unknown`.

The tracking module's privacy manifest has an empty `NSPrivacyTrackingDomains` array
because the SDK cannot know the runtime `AttriKitEndpoint`. If the host sends IDFA to
AttriKit, the **host app must declare the actual ingest domain in its own privacy
manifest's `NSPrivacyTrackingDomains`**. As an alternative, a distribution that fixes the
SDK to one ingest endpoint can declare that fixed domain in its customized module
manifest. AttriKit still gates IDFA access on ATT authorization; the host declaration is
an additional App Store privacy requirement, not a replacement for that runtime gate.

## Revocation and deletion identity

`AttriKit.setConsent(.revoked)` clears queued measurement data, rotates the install epoch,
and resets the persisted session counter so later consent cannot relink activity across
the revocation boundary. The stable `installation_id` remains only as the erasure anchor
for `AttriKit.deleteData()`. A deletion request persists that installation/epoch pair as a
retry tombstone, reports success only after the server confirms deletion, and then removes
the remaining local anchor.

## What your app must declare

App Store Connect answers are app-level and must include AttriKit plus the rest of the
host app. For a host using the SDK exactly as documented above, enter these rows under
**App Privacy > Data Collection**:

### Core only

| App Store Connect data type | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- |
| Identifiers > Device ID | Yes | No | App Functionality; Analytics; Developer's Advertising or Marketing |
| Usage Data > Product Interaction | Yes | No | Analytics |
| Contact Info > Email Address | Yes | No | Analytics; Developer's Advertising or Marketing |
| Contact Info > Phone Number | Yes | No | Analytics; Developer's Advertising or Marketing |

Declare the Email Address row only when the host calls `setFunnelIdentity(email:)` and
the Phone Number row only when it calls `setFunnelIdentity(phone:)`. The values are
hashed, but Apple still treats them as their underlying contact-information types.

### Core + tracking

| App Store Connect data type | Linked to user | Used for tracking | Purposes |
| --- | --- | --- | --- |
| Identifiers > Device ID | Yes | Yes | App Functionality; Analytics; Developer's Advertising or Marketing |
| Usage Data > Product Interaction | Yes | No | Analytics |
| Contact Info > Email Address | Yes | No | Analytics; Developer's Advertising or Marketing |
| Contact Info > Phone Number | Yes | No | Analytics; Developer's Advertising or Marketing |

The same conditional rule applies to the two Contact Info rows. If the host or another
SDK also links Product Interaction or hashed contact information with third-party data
for targeted advertising or advertising measurement, mark those additional rows as
used for tracking too.

If the host sends purchase or subscription events, it must additionally declare
**Purchases > Purchase History**, linked to the user, not used for tracking by AttriKit,
for **Analytics** and **App Functionality**. Reconcile these rows whenever host behavior
or enabled SDK products change; an SDK privacy manifest does not replace the app's
answers in App Store Connect.

## Deferred link tokens (optional)

`AttriKitLinkToken` only accepts the server's versioned `ak1_` token format. The URL
query parameter remains `attrkit_token` for wire compatibility.
