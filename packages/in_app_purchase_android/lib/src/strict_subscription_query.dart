// Copyright 2026 HMO Radar contributors.
// Additive extension to the BSD-licensed Flutter in_app_purchase_android plugin.
import 'dart:async';

import 'billing_client_wrappers/billing_client_manager.dart';
import 'billing_client_wrappers/billing_client_wrapper.dart';
import 'messages.g.dart';

/// Query evidence, never checkout approval or verified entitlement.
enum StrictSubscriptionQueryOutcome {
  completed,
  billingError,
  unsupported,
  unavailable,
  timeout,
  busy,
  invalidResponse,
  staleSession,
}

/// An ephemeral purchase observation. Never persist or log purchase tokens.
class StrictSubscriptionRecord {
  StrictSubscriptionRecord._(PlatformStrictSubscription wire)
    : products = List<String>.unmodifiable(wire.products),
      purchaseToken = wire.purchaseToken,
      purchaseState = wire.purchaseState,
      isSuspended = wire.suspended,
      pendingProducts = List<String>.unmodifiable(wire.pendingProducts),
      pendingPurchaseToken = wire.pendingPurchaseToken;

  final List<String> products;
  final String purchaseToken;

  /// Google's raw PurchaseState: 1 = purchased, 2 = pending.
  final int purchaseState;

  /// Does not distinguish pause from payment/account hold.
  final bool isSuspended;
  final List<String> pendingProducts;
  final String? pendingPurchaseToken;
  @override
  String toString() =>
      'StrictSubscriptionRecord(state: $purchaseState, suspended: $isSuspended)';
}

/// An actual native callback is required for [responseCode] to be present.
class StrictSubscriptionQueryResult {
  StrictSubscriptionQueryResult._(
    this.requestId,
    this.sessionGeneration,
    this.outcome, {
    this.responseCode,
    this.featureResponseCode,
    this.subResponseCode,
    this.suspendedRequested = false,
    List<StrictSubscriptionRecord> purchases =
        const <StrictSubscriptionRecord>[],
  }) : purchases = List<StrictSubscriptionRecord>.unmodifiable(purchases);

  final String requestId;
  final int sessionGeneration;
  final StrictSubscriptionQueryOutcome outcome;
  final int? responseCode;
  final int? featureResponseCode;
  final int? subResponseCode;
  final bool suspendedRequested;
  final List<StrictSubscriptionRecord> purchases;
  bool get hasCompletedCoverage =>
      outcome == StrictSubscriptionQueryOutcome.completed &&
      responseCode == 0 &&
      featureResponseCode == 0 &&
      suspendedRequested;
  @override
  String toString() =>
      'StrictSubscriptionQueryResult($outcome, code: $responseCode, count: ${purchases.length})';
}

/// One operation per existing manager; no retries or extra BillingClient.
/// A connection timeout retains the lease until that wait settles. Native
/// timeouts retain their own lease until the late callback settles. This is
/// conservative because BillingClient has no query cancellation API.
class StrictSubscriptionQueryCoordinator {
  StrictSubscriptionQueryCoordinator(this._manager);
  final BillingClientManager _manager;
  bool _busy = false;

  Future<StrictSubscriptionQueryResult> query({
    required String requestId,
    required int sessionGeneration,
    required bool Function() isCurrentSession,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (requestId.isEmpty ||
        requestId.length > 128 ||
        sessionGeneration < 0 ||
        timeout < const Duration(seconds: 1) ||
        timeout > const Duration(seconds: 30)) {
      throw ArgumentError('Invalid strict-query scope or timeout');
    }
    bool current() {
      try {
        return isCurrentSession();
      } catch (_) {
        return false;
      }
    }

    StrictSubscriptionQueryResult result(
      StrictSubscriptionQueryOutcome outcome,
    ) => StrictSubscriptionQueryResult._(requestId, sessionGeneration, outcome);
    if (!current()) return result(StrictSubscriptionQueryOutcome.staleSession);
    if (_busy) return result(StrictSubscriptionQueryOutcome.busy);
    _busy = true;
    var admitted = true;
    final Future<StrictSubscriptionQueryResult>
    operation = Future<StrictSubscriptionQueryResult>.sync(() async {
      try {
        final PlatformStrictSubscriptionQueryResult? wire = await _manager
            .runWithClientNonRetryable<PlatformStrictSubscriptionQueryResult?>((
              BillingClient client,
            ) {
              if (!admitted || !current())
                return Future<PlatformStrictSubscriptionQueryResult?>.value();
              return client.querySubscriptionsStrict(timeout.inMilliseconds);
            });
        if (!current())
          return result(StrictSubscriptionQueryOutcome.staleSession);
        if (!admitted) return result(StrictSubscriptionQueryOutcome.timeout);
        if (wire == null)
          return result(StrictSubscriptionQueryOutcome.unavailable);
        final StrictSubscriptionQueryOutcome outcome =
            StrictSubscriptionQueryOutcome.values[wire.outcome.index];
        if (outcome != StrictSubscriptionQueryOutcome.completed) {
          return StrictSubscriptionQueryResult._(
            requestId,
            sessionGeneration,
            outcome,
            responseCode: wire.responseCode,
            featureResponseCode: wire.featureResponseCode,
            subResponseCode: wire.subResponseCode,
            suspendedRequested: wire.suspendedRequested,
          );
        }
        final Set<String> tokens = <String>{};
        if (wire.responseCode != 0 ||
            wire.featureResponseCode != 0 ||
            !wire.suspendedRequested ||
            wire.purchases.any(
              (PlatformStrictSubscription p) =>
                  p.products.isEmpty ||
                  p.products.any((String id) => id.trim().isEmpty) ||
                  p.purchaseToken.trim().isEmpty ||
                  !tokens.add(p.purchaseToken) ||
                  (p.purchaseState != 1 && p.purchaseState != 2) ||
                  (p.pendingPurchaseToken != null &&
                      (p.pendingPurchaseToken!.trim().isEmpty ||
                          p.pendingProducts.isEmpty ||
                          p.pendingProducts.any(
                            (String id) => id.trim().isEmpty,
                          ))) ||
                  (p.pendingPurchaseToken == null &&
                      p.pendingProducts.isNotEmpty),
            )) {
          return result(StrictSubscriptionQueryOutcome.invalidResponse);
        }
        return StrictSubscriptionQueryResult._(
          requestId,
          sessionGeneration,
          outcome,
          responseCode: wire.responseCode,
          featureResponseCode: wire.featureResponseCode,
          subResponseCode: wire.subResponseCode,
          suspendedRequested: wire.suspendedRequested,
          purchases: wire.purchases.map(StrictSubscriptionRecord._).toList(),
        );
      } catch (_) {
        return result(
          current()
              ? StrictSubscriptionQueryOutcome.unavailable
              : StrictSubscriptionQueryOutcome.staleSession,
        );
      } finally {
        _busy = false;
      }
    });
    return operation.timeout(
      timeout,
      onTimeout: () {
        admitted = false;
        return result(
          current()
              ? StrictSubscriptionQueryOutcome.timeout
              : StrictSubscriptionQueryOutcome.staleSession,
        );
      },
    );
  }
}
