# AttriKit for iOS: changes

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
