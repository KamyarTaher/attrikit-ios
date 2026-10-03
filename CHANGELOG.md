# AttriKit for iOS: changes

## 2.7.0 (2026-10-03)

### Added

- The first open now carries `device_signals`: the hardware model (`iPhone15,2`), the IANA time
  zone and the screen in points with its scale. AttriKit compares them with the ad click that came
  before the install, where Facebook's and Instagram's in-app browsers report the same model and a
  landing page reports the same time zone and screen. Before this release an iOS install could be
  matched to a click only on its IP address, timing and language, so a phone that changed network
  between the click and the first open (Wi-Fi to cellular) was rarely matched. Android has sent
  these values, with its OS build and languages, since its first release.

### Changed (read before upgrading)

- The first-open body gains the `device_signals` key. AttriKit has accepted it since July 2026, so no
  server change is needed. A body persisted by an earlier version is re-sent as it
  was, without the key.

### Unchanged

- No IDFA is ever sent without tracking consent.

## 2.6.1 (2026-10-01)

### Fixed

- An IDFA granted after first-open never reached AttriKit, or reached it only on a later launch
  that happened to send an identify. AttriKit keeps an identify's IDFA only for an install it holds
  as tracking-consented, and an install keeps its first-open's consent until a consent receipt
  changes it. Three paths changed the consent without sending a receipt:
  - `start(apiKey:consent:)` with a consent other than the previous launch's, which is what an app
    does when it passes its ATT answer to `start` on every launch and never calls `setConsent`;
  - `start(consent: .unknown)` followed by `setConsent(.trackingGranted)`;
  - a grant after a denial in the same install epoch (only a revocation starts a new epoch).

  The SDK now records the consent AttriKit has acknowledged for the install and sends a receipt
  whenever its own consent differs from it. A revoked epoch is never granted again.
- `setConsent(.trackingGranted)` after `AttriKitTracking.requestConsent()` sent the tracking
  receipt and no identify after it. The identify `requestConsent()` triggers leaves before the app
  passes the answer on, so it carries no IDFA. The SDK now sends the IDFA in an identify once
  AttriKit has acknowledged the tracking receipt, in the same launch, so an identify that reached
  AttriKit before the receipt is followed by one that arrives after it.
- A tracking withdrawal passed only to `start` on a later launch (ATT turned off in Settings) left
  AttriKit holding the install as tracking-consented. The receipt now goes out when the app first
  leaves the foreground. It waits until then because many apps start every launch with
  `.measurementGranted` and pass the ATT answer to `setConsent` once running: a tracking grant made
  in that time replaces the withdrawal, and nothing is sent. A `setConsent` ends the wait: a
  `.measurementGranted` repeating `start`'s goes out at once, as do `.denied` and `.revoked`, while
  `.unknown` sends nothing, as before.
- A receipt raised while the receipt queue was draining could wait for the next foreground: the
  request to drain was dropped because a drain was running. The running drain now runs once more.

### Changed (read before upgrading)

- No request body changed. An install upgraded from an earlier version sends at most one consent
  receipt on its first launch and, under tracking consent, one identify after it carrying the IDFA,
  because no earlier version recorded what AttriKit holds. That also repairs installs the defects
  above already affected. An IDFA already delivered is not sent again on later launches; one the
  user reset is.
- Two small records are kept in the SDK's `UserDefaults`: the consent AttriKit acknowledged for the
  install epoch, and a SHA-256 digest of the IDFA it holds. The digest is kept when tracking is
  withdrawn, because AttriKit keeps the IDFA then too; it is removed by a denial or a revocation,
  and both records are removed by `deleteData()`.

### Unchanged

- No IDFA is ever sent without tracking consent.

## 2.6.0 (2026-10-01)

### Added

- Google's EU consent values for users in the EEA, the UK and Switzerland. AttriKit reads the IAB
  TCF consent a consent management platform stores on the device (`IABTCF_` keys in standard
  `UserDefaults`) and sends Google, with each event and with first-open, whether EU rules apply
  and the user's `ad_user_data` and `ad_personalization` consents, each on its own. Before, both
  followed AttriKit's tracking consent, so an EU user who never granted tracking reached Google
  as `ad_user_data=0`. Nothing is sent when no consent platform has stored `IABTCF_gdprApplies`,
  or when it holds anything but 0 or 1. The publisher's TCF restrictions on Google (vendor 755)
  apply before its consents are read, as the TCF requires of every vendor.
- `AttriKit.setGoogleConsent(eea:adUserData:adPersonalization:)` and
  `AttriKit.clearGoogleConsent()`: set the three answers yourself. They take precedence over TCF
  and are kept across launches until cleared.
- `AttriKit.setTCFDataCollectionEnabled(_:)`: pass `false` before `start` to stop reading the TCF
  keys.

### Changed (read before upgrading)

- Events and first-open may carry an optional `consent.dma` object. The AttriKit server accepts it
  from the release that ships with this version; no field was removed or renamed.

### Unchanged

- `AttriKit.setConsent` and everything it governs: the Google answers only go to Google.
- The privacy manifests: reading the TCF keys collects no new data type.

## 2.5.0 (2026-09-30)

### Added

- `AttriKit.installID` and `await AttriKit.installID()`: the installation id the SDK is measuring
  under, in the lowercase spelling it sends. Pass it to RevenueCat as the app user id (AttriKit
  joins a webhook whose `app_user_id` equals it directly), to Stripe checkout metadata, or to your
  backend. It is the id AttriKit's own `start` established, never one read or created on the
  side, so it always matches the SDK's requests: `nil` until `start` has run with measurement
  consent (`start` returns before it has run, so read `await AttriKit.installID()` after it),
  `nil` while a deletion is pending, and `nil` whenever consent does not allow measurement
  (unknown, denied or revoked), from the moment consent changes.
- `AttriKit.userAttributes(timeout:)` and `AttriKit.attributionUpdates()`: attribution as Superwall
  user attributes with an always-present `attrkit_status` (`attributed`, `device_matched`,
  `organic`, `pending`, `consent_required`, `timed_out`) and `attrkit_finality`, published again
  whenever the answer changes. The dictionary is `[String: String?]` and names every `attrkit_` key
  each time, `nil` for the ones the current answer has no value for, because Superwall's
  `setUserAttributes` merges and only a `nil` removes a key an earlier answer set.
- `Attribution` gains `adsetID`, `adID`, `confidence`, `campaignName`, `networkCampaignID` and a
  typed `status`, read from the server's new `attribution_status` and ad-level fields; all optional,
  so this build still works against a server without them.
- `placementParameters` adds `attrkit_campaign_name`, `attrkit_network_campaign_id`,
  `attrkit_adset_id`, `attrkit_ad_id` and `attrkit_finality` for deterministic matches. It stays
  empty for anything else, as before.
- `AttriKitSuperwall`, an optional product: forwards Superwall's `paywall_open` as `paywall_viewed`.
  It does not depend on SuperwallKit; the app conforms `SuperwallEventInfo` to
  `AttriKitSuperwallEventConvertible`. Superwall's `transaction_complete` is not recorded as a
  purchase.
- `AttriKit.configureConversionValues(_:)`, `AttriKit.recordConversion(_:)` and
  `AttriKitConversionSchema`: a single writer for SKAdNetwork and AdAttributionKit conversion
  values from a versioned schema (install, activation, trial, ordered revenue buckets; coarse
  low/medium/high).
- `AttriKit.appleAdsTokenStatus()` and the `X-AttriKit-ASA-Token` first-open header: how the Apple
  Ads token collection ended and whether it was delivered.

### Changed (read before upgrading)

- `attribution(timeout:)` answers an organic install with `.unattributed`. It used to return
  `.attributed` with `method == "unattributed"`, so `if case .attributed = result` treated organic
  installs as paid. An install whose consent the server records as withdrawn answers
  `.consentRequired`.
- The first answer is no longer cached for the life of the process. While the server marks it
  `provisional` the SDK keeps polling on the 5s, 30s, 5m, 1h, 3h, 6h rungs (the fast ramp is only
  for the wait for a first answer), and `attribution(timeout:)`
  returns the latest answer; a settled answer ends the poll.
- A first-open that the server has not received and whose Apple Ads token is older than 23 hours
  is sent with a fresh token and its original `occurred_at`.
- A relaunch that replays a stored first-open no longer calls AdServices or AppTransaction.
- A caller of `attribution(timeout:)`, `placementParameters(timeout:)`, `userAttributes(timeout:)`
  or `installID()` with no `queueTimeout` that is cancelled stops waiting at once and gets the
  documented cancelled answer. It used to wait out every queued call and then answer as if it had
  not been cancelled. Queued calls themselves are never cancelled.

### Unchanged

- Installation identity: how the installation id and install epoch are created, read from the
  Keychain and UserDefaults, and recovered after a Keychain failure is exactly 2.4.1's.
- The wire contract: no request body gained, lost or renamed a field. The new header is ignored by
  servers that do not read it.
- The privacy manifests of AttriKitCore, AttriKitTracking and AttriKitLinkToken. AttriKitSuperwall
  ships its own, declaring the Product Interaction Core already declares.
