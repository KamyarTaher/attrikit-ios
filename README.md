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

Select `AttriKitCore`. Add `AttriKitTracking` only when the app requests ATT,
`AttriKitLinkToken` only when it explicitly consumes a deferred-link token, and
`AttriKitSuperwall` only when it forwards Superwall paywall views.

For a package manifest:

```swift
dependencies: [
    // 2.5.0 adds installID, userAttributes, attributionUpdates and AttriKitSuperwall.
    // Every version from 2.2.1 restores the privacy manifests' empty tracking-domain
    // lists; 2.2.0 could block ingest and erasure when ATT was not authorized.
    .package(url: "https://github.com/KamyarTaher/attrikit-ios", from: "2.5.0"),
]
```

Upgrading from 2.4.x? Read `CHANGELOG.md` first: `attribution(timeout:)` now answers an organic
install with `.unattributed`, and the first answer is no longer frozen for the process.

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

Do not put email addresses or phone numbers in event properties, and note what happens if you do:
the whole event is refused, not the offending property. The key check is a SUBSTRING match on
`email|e-mail|phone|mobile|address|name`, so `product_name`, `campaign_name` and `mobile_os` are
refused too. String values that look like an email or a phone number, or exceed 1024 bytes, refuse
the event the same way. The rejected key is logged; the value never is. When a user supplies
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

Or the other way round: hand AttriKit's own installation id to your backend. `AttriKit.installID`
is the installation id the SDK is measuring under, spelled exactly as AttriKit sends it
(lowercase). A RevenueCat webhook whose `app_user_id` equals it is joined to the install directly,
and the same value works as Stripe checkout metadata or on your own user record. It is the id
AttriKit's own `start` established, never one read or created on the side, so it always matches
what the SDK sends: `nil` until `start` has run with measurement consent, `nil` while a
`deleteData()` request is pending, and `nil` whenever consent does not allow measurement
(unknown, denied or revoked), from the moment consent changes. `start` returns
before it has run, so read it with `await AttriKit.installID()`:

```swift
AttriKit.start(apiKey: "YOUR_PUBLISHABLE_KEY", consent: .measurementGranted)
Task {
    let installID = await AttriKit.installID()
    Purchases.configure(withAPIKey: "appl_…", appUserID: installID)
}
```

It changes only when AttriKit's own measurement does: a reinstall that did not keep the Keychain, a
completed deletion, or a launch whose Keychain could not be read.

Read how the install was attributed (method, network, campaign, finality) to
personalize onboarding or paywall placements:

```swift
let result = await AttriKit.attribution(timeout: .seconds(2))
```

An organic install answers `.unattributed`, and `.attributed` carries the campaign together with
`adsetID`, `adID`, `campaignName`, `networkCampaignID` and, for a device match, `confidence`, as far
as the server has them. The first answer is `provisional` for 72 hours: the SDK keeps asking while
it is (5s, 30s, 5m, 1h, 3h, 6h after it arrives), so an install first answered organic can become
attributed. Subscribe to every change with `AttriKit.attributionUpdates()`.

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
`.timedOut`, never `.unattributed`. Exhaustion means AttriKit stopped asking, not that the install
had no attribution, so claiming the stronger of the two would make a match that had simply not
landed yet wrong until the next launch asks again. A `provisional` answer keeps the poll running on
the ladder rungs (the 250ms ramp is only for the wait for a first answer); a settled one ends it.
Event batches
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

## Campaign-personalized paywalls

Hand attribution to Superwall as user attributes, and refresh them when the answer changes. The
bridge is vendor-neutral, so it works without linking Superwall into AttriKitCore:

```swift
import AttriKitCore
import SuperwallKit

// At launch, after AttriKit.start and Superwall.configure.
Task {
    for await update in AttriKit.attributionUpdates() {
        // Every later placement can target user.attrkit_status, user.attrkit_network, ...
        Superwall.shared.setUserAttributes(update.userAttributes)
    }
}
```

`userAttributes` always carries `attrkit_status`: `attributed`, `device_matched`, `organic`,
`pending`, `consent_required` or `timed_out`, so a context without a campaign still says why.
`attrkit_finality` follows once the server answered. A deterministic match adds
`attrkit_method`, `attrkit_network`, `attrkit_campaign_id`, `attrkit_source_type`, and, when the
server has them, `attrkit_campaign_name`, `attrkit_network_campaign_id`, `attrkit_adset_id` and
`attrkit_ad_id`. Every other `attrkit_` key is present with a `nil` value: Superwall's
`setUserAttributes` merges and removes a key set to `nil`, so a key from an earlier answer (the ad
set of a provisional Meta match that Apple Ads replaced, or a campaign from before consent was
withdrawn) never stays on the user. The dictionary is `[String: String?]` and passes to
`setUserAttributes` as is. The stream publishes only real changes, starting with the current state.
`AttriKit.userAttributes(timeout:)` answers the same dictionary once.

`AttriKit.placementParameters(timeout:)` keeps its contract: those campaign keys for a
deterministic match, and an empty dictionary for anything else, so `isEmpty` still means "no
verified campaign":

```swift
let parameters = await AttriKit.placementParameters(timeout: .seconds(2))
Superwall.shared.register(placement: "onboarding_paywall", params: parameters)
```

Neither dictionary carries a campaign for unresolved, organic, matched, modeled, or otherwise
non-deterministic attribution ("matched" being a device match). AttriKit never turns
a modeled campaign estimate or a probabilistic match into a user-level paywall decision;
`attrkit_status` says `device_matched` so you can still see one arrived.

To record paywall views, add the `AttriKitSuperwall` product and forward Superwall's events. It
does not depend on SuperwallKit: conform Superwall's event type once, in your own target.

```swift
import AttriKitSuperwall
import SuperwallKit

extension SuperwallEventInfo: AttriKitSuperwallEventConvertible {
    public var attriKitSuperwallEvent: AttriKitSuperwallEvent {
        if case .paywallOpen(let paywall) = event {
            return AttriKitSuperwallEvent(
                name: event.description,
                paywallIdentifier: paywall.identifier,
                placement: paywall.presentedByPlacementWithName
            )
        }
        return AttriKitSuperwallEvent(name: event.description)
    }
}

// In your SuperwallDelegate:
func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
    AttriKitSuperwall.handle(eventInfo)
}
```

A paywall open becomes the canonical `paywall_viewed` event (sent to ad networks as
`ViewContent`). Superwall's `transaction_complete` is deliberately not recorded as a purchase: it
is an unverified client callback, and with RevenueCat connected the purchase would count twice.

## Apple Ads token

The first-open carries Apple's AdServices token when iOS provides one inside the 2-second
first-open bound. `AttriKit.appleAdsTokenStatus()` says how its collection ended (`collected`,
`unavailable`, `unsupported`, `timed_out`) and whether the first-open carrying it was delivered;
the same outcome travels to AttriKit as the `X-AttriKit-ASA-Token` request header. Apple's token
expires after 24 hours, so a first-open that waited that long in the retry schedule is sent with a
fresh one, and a collection that timed out is tried again on the next attempt, both only while the
server has not yet received the first-open.

## Conversion values (SKAdNetwork and AdAttributionKit)

Make AttriKit the single writer of your conversion values:

```swift
let schema = try AttriKitConversionSchema(
    version: 1,
    revenueThresholds: [5, 10, 20, 50],   // cumulative revenue, in `currency`
    currency: "USD",
    activationEvent: "onboarding_completed"
)
AttriKit.configureConversionValues(schema)   // before AttriKit.start
```

Fine values are 0 for an install, 1 for activation, 2 for a trial, then one per revenue bucket
from 3 (any revenue) upward; coarse values are `low` once engaged, `medium` for a trial, `high` once
paid. Tracked events raise the value by themselves: the activation event, `trial_started` or
`intro_started`, and `purchase`, `purchase_completed`, `subscription_started` or
`subscription_renewed` with a numeric `value` and the schema's `currency`. Revenue AttriKit cannot
see on the device can be added with `AttriKit.recordConversion(.revenue(9.99))`. Values only ever
go up, and the window locks at the top bucket. Do not call SKAdNetwork or AdAttributionKit update
APIs yourself: a second writer overwrites these values, and the postback decodes against the wrong
schema. The update goes through SKAdNetwork, which Apple mirrors into AdAttributionKit.

## EU consent for Google (EEA, UK, Switzerland)

Google requires, for every user in the EEA, the UK and Switzerland, whether EU rules apply and the
user's `ad_user_data` and `ad_personalization` consents. From 2.6.0 AttriKit reads them from the
IAB TCF consent your consent management platform stores on the device (the standard `IABTCF_`
keys), with no code, and sends them to Google with each event. To stop reading them, call this
before `start`:

```swift
AttriKit.setTCFDataCollectionEnabled(false)
```

If you collect consent without a TCF platform, set the answers yourself. They take precedence
over TCF and are kept until you clear them:

```swift
AttriKit.setGoogleConsent(eea: true, adUserData: true, adPersonalization: false)
AttriKit.clearGoogleConsent()
```

These answers only go to Google. `AttriKit.setConsent` stays AttriKit's own consent.

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
payloads. On macOS, ATT is unavailable and `requestConsent()` returns `.unknown`.

If measurement already started under `.measurementGranted`, for example when the app asks for
ATT after onboarding, pass the answer to AttriKit once you have it:

```swift
let trackingConsent = await AttriKitTracking.requestConsent()
if trackingConsent == .trackingGranted {
    AttriKit.setConsent(.trackingGranted)
}
```

AttriKit keeps an IDFA only for an install it holds as tracking-consented, so the SDK first sends
a tracking consent receipt and sends the IDFA in an identify payload once AttriKit has accepted
that receipt, in the same launch. Passing the answer only to `start(apiKey:consent:)` on a later
launch works the same way.

On later launches, passing the ATT answer to `start` sends nothing more once AttriKit holds it. An
app that instead starts every launch with `.measurementGranted` and passes the grant to
`setConsent` once running also sends nothing. A `.measurementGranted` given to `start` for an
install AttriKit holds as tracking-consented is held until the app calls `setConsent` or first
leaves the foreground: a tracking grant passed to `setConsent` replaces it, and otherwise it is sent
as a withdrawal, which is also how AttriKit learns that ATT was turned off in Settings. No IDFA is
sent while consent is not `.trackingGranted`.

The tracking and link-token module manifests carry no `NSPrivacyTracking` and no
`NSPrivacyTrackingDomains` key, because the SDK cannot know the runtime `AttriKitEndpoint`
and Apple's TN3181 rejects a manifest that declares tracking with an empty domain list.
Their collected data types still carry the tracking flag. If the host sends IDFA to
AttriKit, the **host app must declare `NSPrivacyTracking` and the actual ingest domain in
its own privacy manifest's `NSPrivacyTrackingDomains`**. As an alternative, a distribution
that fixes the SDK to one ingest endpoint can declare both keys with that fixed domain in
its customized module manifest. AttriKit still gates IDFA access on ATT authorization; the
host declaration is an additional App Store privacy requirement, not a replacement for that
runtime gate.

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
