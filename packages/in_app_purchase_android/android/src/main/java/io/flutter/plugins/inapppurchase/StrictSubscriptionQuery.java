// Copyright 2026 HMO Radar contributors. BSD-style licence; see LICENSE.
package io.flutter.plugins.inapppurchase;

import com.android.billingclient.api.BillingClient;
import com.android.billingclient.api.BillingResult;
import com.android.billingclient.api.Purchase;
import com.android.billingclient.api.QueryPurchasesParams;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Consumer;

/** Uses the existing client's read-only API. Never constructs a BillingClient. */
final class StrictSubscriptionQuery {
  interface Scheduler { Runnable schedule(Runnable task, long millis); }
  private final Scheduler scheduler;
  private final AtomicReference<Object> lease = new AtomicReference<>();
  StrictSubscriptionQuery(Scheduler scheduler) { this.scheduler = scheduler; }

  private static PlatformStrictSubscriptionQueryResult result(PlatformStrictQueryOutcome outcome,
      Long code, Long feature, Long sub, boolean requested, List<PlatformStrictSubscription> purchases) {
    // Native debug text is deliberately excluded: it is not necessary for
    // readiness and must not become a token-bearing log/customer message.
    return new PlatformStrictSubscriptionQueryResult(outcome, requested, purchases, code, feature, sub);
  }

  void query(BillingClient client, long timeoutMillis, Consumer<PlatformStrictSubscriptionQueryResult> reply) {
    if (timeoutMillis < 1000 || timeoutMillis > 30000) {
      reply.accept(result(PlatformStrictQueryOutcome.INVALID_RESPONSE, null, null, null, false, Collections.emptyList())); return;
    }
    final Object operation = new Object();
    if (!lease.compareAndSet(null, operation)) {
      reply.accept(result(PlatformStrictQueryOutcome.BUSY, null, null, null, false, Collections.emptyList())); return;
    }
    AtomicBoolean completed = new AtomicBoolean(false);
    AtomicBoolean requested = new AtomicBoolean(false);
    AtomicReference<Runnable> cancel = new AtomicReference<>(() -> {});
    Consumer<PlatformStrictSubscriptionQueryResult> finish = value -> {
      if (completed.compareAndSet(false, true)) { cancel.get().run(); reply.accept(value); }
    };
    try {
      if (client == null || !client.isReady()) {
        lease.compareAndSet(operation, null);
        finish.accept(result(PlatformStrictQueryOutcome.UNAVAILABLE, null, null, null, false, Collections.emptyList())); return;
      }
      BillingResult feature = client.isFeatureSupported(BillingClient.FeatureType.INCLUDE_SUSPENDED_SUBSCRIPTIONS);
      if (feature.getResponseCode() != BillingClient.BillingResponseCode.OK) {
        lease.compareAndSet(operation, null);
        PlatformStrictQueryOutcome outcome = feature.getResponseCode() == BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED
            ? PlatformStrictQueryOutcome.UNSUPPORTED : PlatformStrictQueryOutcome.BILLING_ERROR;
        finish.accept(result(outcome, null, (long) feature.getResponseCode(), null, false, Collections.emptyList())); return;
      }
      cancel.set(scheduler.schedule(() -> finish.accept(result(PlatformStrictQueryOutcome.TIMEOUT,
          null, 0L, null, requested.get(), Collections.emptyList())), timeoutMillis));
      requested.set(true);
      client.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS)
          .includeSuspendedSubscriptions(true).build(), (billing, purchases) -> {
        // Suppress duplicate/late callback payload processing, including tokens.
        if (completed.get()) { lease.compareAndSet(operation, null); return; }
        try {
          if (billing.getResponseCode() != BillingClient.BillingResponseCode.OK) {
            finish.accept(result(PlatformStrictQueryOutcome.BILLING_ERROR, (long) billing.getResponseCode(),
                0L, (long) billing.getOnPurchasesUpdatedSubResponseCode(), true, Collections.emptyList())); return;
          }
          if (purchases == null) throw new IllegalArgumentException();
          List<PlatformStrictSubscription> records = new ArrayList<>();
          for (Purchase purchase : purchases) {
            if (purchase == null || purchase.getProducts().isEmpty() || purchase.getPurchaseToken().trim().isEmpty()
                || (purchase.getPurchaseState() != Purchase.PurchaseState.PURCHASED
                    && purchase.getPurchaseState() != Purchase.PurchaseState.PENDING)) throw new IllegalArgumentException();
            Purchase.PendingPurchaseUpdate pending = purchase.getPendingPurchaseUpdate();
            records.add(new PlatformStrictSubscription(purchase.getProducts(), purchase.getPurchaseToken(),
                (long) purchase.getPurchaseState(), purchase.isSuspended(),
                pending == null ? Collections.emptyList() : pending.getProducts(),
                pending == null ? null : pending.getPurchaseToken()));
          }
          finish.accept(result(PlatformStrictQueryOutcome.COMPLETED, (long) billing.getResponseCode(),
              0L, (long) billing.getOnPurchasesUpdatedSubResponseCode(), true, records));
        } catch (RuntimeException e) {
          finish.accept(result(PlatformStrictQueryOutcome.INVALID_RESPONSE, 0L, 0L, null, true, Collections.emptyList()));
        } finally { lease.compareAndSet(operation, null); }
      });
    } catch (RuntimeException e) {
      lease.compareAndSet(operation, null);
      finish.accept(result(PlatformStrictQueryOutcome.UNAVAILABLE, null, null, null, requested.get(), Collections.emptyList()));
    }
  }
}
