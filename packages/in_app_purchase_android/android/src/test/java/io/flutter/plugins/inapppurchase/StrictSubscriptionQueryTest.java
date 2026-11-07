// Copyright 2026 HMO Radar contributors. BSD-style licence; see LICENSE.
package io.flutter.plugins.inapppurchase;
import static org.junit.Assert.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;
import com.android.billingclient.api.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Before;
import org.junit.Test;
import org.mockito.ArgumentCaptor;

public class StrictSubscriptionQueryTest {
  BillingClient client;
  Runnable deadline;
  StrictSubscriptionQuery query;
  List<PlatformStrictSubscriptionQueryResult> replies;
  BillingResult code(int code) { return BillingResult.newBuilder().setResponseCode(code).build(); }
  @Before public void setup() {
    client=mock(BillingClient.class); when(client.isReady()).thenReturn(true);
    when(client.isFeatureSupported(BillingClient.FeatureType.INCLUDE_SUSPENDED_SUBSCRIPTIONS)).thenReturn(code(0));
    query=new StrictSubscriptionQuery((task, delay)->{deadline=task;return ()->{};});
    replies=new ArrayList<>();
  }
  Purchase purchase(int state, boolean suspended) {
    Purchase p=mock(Purchase.class); when(p.getPurchaseToken()).thenReturn("synthetic-only");
    when(p.getProducts()).thenReturn(new ArrayList<>(List.of("hmo_investor_pro")));
    when(p.getPurchaseState()).thenReturn(state); when(p.isSuspended()).thenReturn(suspended); return p;
  }
  void answer(int resultCode, List<Purchase> purchases) {
    doAnswer(call->{((PurchasesResponseListener)call.getArgument(1)).onQueryPurchasesResponse(code(resultCode), purchases);return null;})
        .when(client).queryPurchasesAsync(any(QueryPurchasesParams.class),any(PurchasesResponseListener.class));
  }
  PurchasesResponseListener listener() {
    ArgumentCaptor<PurchasesResponseListener> c=ArgumentCaptor.forClass(PurchasesResponseListener.class);
    verify(client).queryPurchasesAsync(any(QueryPurchasesParams.class),c.capture());return c.getValue();
  }
  PlatformStrictSubscriptionQueryResult run() {query.query(client,10000,replies::add);return replies.get(0);}
  @Test public void emptySuccess() {
    answer(0,List.of());var result=run();assertEquals(PlatformStrictQueryOutcome.COMPLETED,result.getOutcome());
    assertEquals(Long.valueOf(0),result.getResponseCode());assertTrue(result.getSuspendedRequested());assertTrue(result.getPurchases().isEmpty());
    verify(client).isFeatureSupported(BillingClient.FeatureType.INCLUDE_SUSPENDED_SUBSCRIPTIONS);
    ArgumentCaptor<QueryPurchasesParams> params = ArgumentCaptor.forClass(QueryPurchasesParams.class);
    verify(client).queryPurchasesAsync(params.capture(),any());
    assertTrue(params.getValue().getIncludeSuspendedSubscriptions());
    verify(client,never()).startConnection(any()); verify(client,never()).endConnection();
    verify(client,never()).acknowledgePurchase(any(),any());verify(client,never()).consumeAsync(any(),any());
  }
  @Test public void purchased() {answer(0,List.of(purchase(1,false)));assertEquals(1,run().getPurchases().get(0).getPurchaseState());}
  @Test public void pending() {answer(0,List.of(purchase(2,false)));assertEquals(2,run().getPurchases().get(0).getPurchaseState());}
  @Test public void suspendedDoesNotInventHoldReason() {answer(0,List.of(purchase(1,true)));assertTrue(run().getPurchases().get(0).getSuspended());}
  @Test public void pendingUpdate() {
    Purchase p=purchase(1,false);Purchase.PendingPurchaseUpdate update=mock(Purchase.PendingPurchaseUpdate.class);
    when(update.getPurchaseToken()).thenReturn("pending-synthetic");when(update.getProducts()).thenReturn(List.of("hmo_investor_pro"));
    when(p.getPendingPurchaseUpdate()).thenReturn(update);answer(0,List.of(p));
    assertEquals("pending-synthetic",run().getPurchases().get(0).getPendingPurchaseToken());
  }
  @Test public void actualErrorCode() {answer(6,List.of(purchase(1,false)));var r=run();assertEquals(PlatformStrictQueryOutcome.BILLING_ERROR,r.getOutcome());assertEquals(Long.valueOf(6),r.getResponseCode());assertTrue(r.getPurchases().isEmpty());}
  @Test public void disconnectionNotRetried() {answer(-1,List.of());assertEquals(Long.valueOf(-1),run().getResponseCode());verify(client,times(1)).queryPurchasesAsync(any(QueryPurchasesParams.class),any());verify(client,never()).startConnection(any());}
  @Test public void unsupported() {when(client.isFeatureSupported(anyString())).thenReturn(code(-2));var r=run();assertEquals(PlatformStrictQueryOutcome.UNSUPPORTED,r.getOutcome());assertEquals(Long.valueOf(-2),r.getFeatureResponseCode());assertNull(r.getResponseCode());verify(client,never()).queryPurchasesAsync(any(QueryPurchasesParams.class),any());}
  @Test public void featureErrorNotMisrepresentedAsUnsupported() {when(client.isFeatureSupported(anyString())).thenReturn(code(3));var r=run();assertEquals(PlatformStrictQueryOutcome.BILLING_ERROR,r.getOutcome());assertEquals(Long.valueOf(3),r.getFeatureResponseCode());assertNull(r.getResponseCode());}
  @Test public void unavailable() {when(client.isReady()).thenReturn(false);assertEquals(PlatformStrictQueryOutcome.UNAVAILABLE,run().getOutcome());}
  @Test public void nullClient() {query.query(null,10000,replies::add);assertEquals(PlatformStrictQueryOutcome.UNAVAILABLE,replies.get(0).getOutcome());}
  @Test public void nativeThrow() {doThrow(new IllegalStateException("synthetic")).when(client).queryPurchasesAsync(any(QueryPurchasesParams.class),any());assertEquals(PlatformStrictQueryOutcome.UNAVAILABLE,run().getOutcome());}
  @Test public void overlapBlocked() {query.query(client,10000,replies::add);query.query(client,10000,replies::add);assertEquals(PlatformStrictQueryOutcome.BUSY,replies.get(0).getOutcome());verify(client,times(1)).queryPurchasesAsync(any(QueryPurchasesParams.class),any());}
  @Test public void timeoutQuarantinesUntilLateCallback() {
    query.query(client,10000,replies::add);var callback=listener();deadline.run();
    assertEquals(PlatformStrictQueryOutcome.TIMEOUT,replies.get(0).getOutcome());assertNull(replies.get(0).getResponseCode());
    query.query(client,10000,replies::add);assertEquals(PlatformStrictQueryOutcome.BUSY,replies.get(1).getOutcome());
    callback.onQueryPurchasesResponse(code(0),List.of(purchase(1,false)));assertEquals(2,replies.size());
    query.query(client,10000,replies::add);verify(client,times(2)).queryPurchasesAsync(any(QueryPurchasesParams.class),any());
  }
  @Test public void duplicateCallbackCompletesOnce() {
    query.query(client,10000,replies::add);var callback=listener();callback.onQueryPurchasesResponse(code(0),List.of());callback.onQueryPurchasesResponse(code(0),List.of());deadline.run();assertEquals(1,replies.size());
  }
  @Test public void oldDuplicateCannotReleaseNewLease() {
    query.query(client,10000,replies::add);var old=listener();old.onQueryPurchasesResponse(code(0),List.of());
    query.query(client,10000,replies::add);old.onQueryPurchasesResponse(code(0),List.of());
    query.query(client,10000,replies::add);assertEquals(PlatformStrictQueryOutcome.BUSY,replies.get(1).getOutcome());
    verify(client,times(2)).queryPurchasesAsync(any(QueryPurchasesParams.class),any());
  }
  @Test public void nullListNotEmptySuccess() {answer(0,null);assertEquals(PlatformStrictQueryOutcome.INVALID_RESPONSE,run().getOutcome());}
  @Test public void missingToken() {Purchase p=purchase(1,false);when(p.getPurchaseToken()).thenReturn("");answer(0,List.of(p));assertEquals(PlatformStrictQueryOutcome.INVALID_RESPONSE,run().getOutcome());}
  @Test public void missingProducts() {Purchase p=purchase(1,false);when(p.getProducts()).thenReturn(new ArrayList<>());answer(0,List.of(p));assertEquals(PlatformStrictQueryOutcome.INVALID_RESPONSE,run().getOutcome());}
  @Test public void unknownPurchaseState() {answer(0,List.of(purchase(0,false)));assertEquals(PlatformStrictQueryOutcome.INVALID_RESPONSE,run().getOutcome());}
  @Test public void invalidTimeoutCannotQuery() {query.query(client,0,replies::add);assertEquals(PlatformStrictQueryOutcome.INVALID_RESPONSE,replies.get(0).getOutcome());verifyNoInteractionsExceptReadySetup();}
  void verifyNoInteractionsExceptReadySetup() {verify(client,never()).queryPurchasesAsync(any(QueryPurchasesParams.class),any());}
}
