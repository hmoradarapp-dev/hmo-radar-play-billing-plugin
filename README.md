# HMO Radar Google Play Billing extension

An unofficial project-specific extension of Flutter's open-source in-app purchase
packages. This repository is not an official Google or Flutter distribution.

## Packages

- `packages/in_app_purchase`: canonical parent package 3.3.1; purchasing runtime unchanged.
- `packages/in_app_purchase_android`: canonical Android implementation 0.5.5 using
  Google Play Billing Library 9.1.0, with an additive strict subscription query.

The extension reuses the existing BillingClient, connection manager and purchase
listener. It requests suspended subscriptions when the native feature is supported,
returns native response codes, retains pending purchase evidence and bounds completion.
It does not launch checkout, acknowledge/consume a transaction, grant an entitlement,
or allocate an allowance as a consequence of querying.

## Strict query

Obtain the existing `InAppPurchaseAndroidPlatformAddition` from the application's
existing `InAppPurchase` instance. Do not create another BillingClient or listener.

```dart
Future<StrictSubscriptionQueryResult> querySubscriptionsStrict({
  required String requestId,
  required int sessionGeneration,
  required bool Function() isCurrentSession,
  Duration timeout = const Duration(seconds: 10),
})
```

Outcomes distinguish completion, native error, unsupported capability, unavailable
service, timeout, overlapping query, malformed response and stale session. Preserve
the actual native response codes. Errors must never become successful empty queries.
Tokens are ephemeral: never persist or log them or generated wire objects containing
them. The application must discard results after UID/session-generation changes.

`hasCompletedCoverage` is native query evidence, not proof of subscription absence
under another Google account, checkout permission or entitlement. Suspended evidence
does not independently diagnose the precise pause/account-hold lifecycle reason.
Trusted server verification and application purchase controls remain the authority.

Timeouts do not prove cancellation. A timed-out operation remains quarantined until
its native callback settles, because BillingClient provides no query cancellation API.

## Dependencies and development

The Android package requires Flutter >=3.44 and Dart ^3.12; native minSdk is23.
Consumers should pin full immutable Git commit references consistently in the root,
parent and parent-example declarations. Do not mix hosted/Git Android sources or refs.

The source preparation initially uses relative package paths. Parent metadata must
be pinned to an actually published Android commit before declaring a Git distribution
ready for consumers. Never substitute a floating main ref for an immutable pin.

Package tests use synthetic/mock Billing responses. They do not establish real Play
purchase, lifecycle, account ownership or production service behaviour. No billing
activation or entitlement backend is included in these packages.

See `UPSTREAM.md`, package READMEs and package licence files for provenance/attribution.
