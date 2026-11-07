import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_android/src/messages.g.dart';
import 'package:mockito/mockito.dart';
import 'billing_client_wrappers/billing_client_wrapper_test.mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MockInAppPurchaseApi api;
  late BillingClientManager manager;
  late InAppPurchaseAndroidPlatformAddition addition;
  var current = true;
  var clients = 0;
  PlatformStrictSubscription purchase({
    String token = 'synthetic-only',
    int state = 1,
    bool suspended = false,
    List<String>? products,
    String? pending,
    List<String>? pendingProducts,
  }) => PlatformStrictSubscription(
    products: products ?? <String>['hmo_investor_pro'],
    purchaseToken: token,
    purchaseState: state,
    suspended: suspended,
    pendingPurchaseToken: pending,
    pendingProducts: pendingProducts ?? <String>[],
  );
  PlatformStrictSubscriptionQueryResult wire({
    PlatformStrictQueryOutcome outcome = PlatformStrictQueryOutcome.completed,
    int? code = 0,
    int? feature = 0,
    bool requested = true,
    List<PlatformStrictSubscription>? purchases,
  }) => PlatformStrictSubscriptionQueryResult(
    outcome: outcome,
    suspendedRequested: requested,
    purchases: purchases ?? <PlatformStrictSubscription>[],
    responseCode: code,
    featureResponseCode: feature,
    subResponseCode: 0,
  );
  Future<StrictSubscriptionQueryResult> query({
    String id = 'q1',
    int generation = 1,
    Duration timeout = const Duration(seconds: 10),
  }) => addition.querySubscriptionsStrict(
    requestId: id,
    sessionGeneration: generation,
    isCurrentSession: () => current,
    timeout: timeout,
  );
  setUp(() {
    current = true;
    clients = 0;
    api = MockInAppPurchaseApi();
    when(api.startConnection(any, any, any)).thenAnswer(
      (_) async => PlatformBillingResult(
        responseCode: PlatformBillingResponse.ok,
        debugMessage: '',
      ),
    );
    when(api.endConnection()).thenAnswer((_) async {});
    manager = BillingClientManager(
      billingClientFactory: (listener, alternative) {
        clients++;
        return BillingClient(listener, alternative, api: api);
      },
    );
    addition = InAppPurchaseAndroidPlatformAddition(manager);
  });
  tearDown(() => manager.dispose());
  test(
    'successful empty native query is covered evidence, not entitlement',
    () async {
      when(api.querySubscriptionsStrict(any)).thenAnswer((_) async => wire());
      final result = await query();
      expect(result.hasCompletedCoverage, isTrue);
      expect(result.purchases, isEmpty);
      expect(result.responseCode, 0);
      expect(clients, 1);
      verify(api.querySubscriptionsStrict(10000)).called(1);
      verifyNever(api.launchBillingFlow(any));
      verifyNever(api.consumeAsync(any));
      verifyNever(api.acknowledgePurchase(any));
    },
  );
  for (final state in <int>[1, 2]) {
    test(
      'preserves native state $state without purchase-stream callbacks',
      () async {
        final events = <PurchasesResultWrapper>[];
        manager.purchasesUpdatedStream.listen(events.add);
        when(api.querySubscriptionsStrict(any)).thenAnswer(
          (_) async => wire(
            purchases: <PlatformStrictSubscription>[purchase(state: state)],
          ),
        );
        final result = await query();
        expect(result.purchases.single.purchaseState, state);
        expect(result.purchases.single.products, <String>['hmo_investor_pro']);
        expect(events, isEmpty);
        verifyNever(api.acknowledgePurchase(any));
        verifyNever(api.consumeAsync(any));
      },
    );
  }
  test('suspended is not invented pause/hold classification', () async {
    when(api.querySubscriptionsStrict(any)).thenAnswer(
      (_) async => wire(
        purchases: <PlatformStrictSubscription>[purchase(suspended: true)],
      ),
    );
    final result = await query();
    expect(result.purchases.single.isSuspended, isTrue);
    expect(result.purchases.single.purchaseState, 1);
  });
  test('pending update preserved without granting', () async {
    when(api.querySubscriptionsStrict(any)).thenAnswer(
      (_) async => wire(
        purchases: <PlatformStrictSubscription>[
          purchase(
            pending: 'pending-synthetic',
            pendingProducts: <String>['hmo_investor_pro'],
          ),
        ],
      ),
    );
    final result = await query();
    expect(result.purchases.single.pendingPurchaseToken, 'pending-synthetic');
  });
  for (final entry in <(PlatformStrictQueryOutcome, int?)>[
    (PlatformStrictQueryOutcome.billingError, 6),
    (PlatformStrictQueryOutcome.billingError, -1),
    (PlatformStrictQueryOutcome.unavailable, null),
    (PlatformStrictQueryOutcome.unsupported, null),
    (PlatformStrictQueryOutcome.timeout, null),
    (PlatformStrictQueryOutcome.busy, null),
  ]) {
    test('truthful ${entry.$1} code ${entry.$2}; no auto-retry', () async {
      when(
        api.querySubscriptionsStrict(any),
      ).thenAnswer((_) async => wire(outcome: entry.$1, code: entry.$2));
      final result = await query();
      expect(result.hasCompletedCoverage, isFalse);
      expect(result.responseCode, entry.$2);
      expect(result.purchases, isEmpty);
      verify(api.querySubscriptionsStrict(any)).called(1);
      expect(clients, 1);
    });
  }
  test('native transport failure is unavailable', () async {
    when(api.querySubscriptionsStrict(any)).thenThrow(StateError('synthetic'));
    expect((await query()).outcome, StrictSubscriptionQueryOutcome.unavailable);
  });
  for (final item in <(String, PlatformStrictSubscription)>[
    ('missing token', purchase(token: '')),
    ('missing products', purchase(products: <String>[])),
    ('blank product', purchase(products: <String>[' '])),
    ('unknown state', purchase(state: 0)),
    ('invalid pending update', purchase(pending: '')),
  ]) {
    test('reject ${item.$1}', () async {
      when(api.querySubscriptionsStrict(any)).thenAnswer(
        (_) async => wire(purchases: <PlatformStrictSubscription>[item.$2]),
      );
      final result = await query();
      expect(result.outcome, StrictSubscriptionQueryOutcome.invalidResponse);
      expect(result.purchases, isEmpty);
    });
  }
  test('duplicate token records fail closed', () async {
    when(api.querySubscriptionsStrict(any)).thenAnswer(
      (_) async =>
          wire(purchases: <PlatformStrictSubscription>[purchase(), purchase()]),
    );
    expect(
      (await query()).outcome,
      StrictSubscriptionQueryOutcome.invalidResponse,
    );
  });
  for (final response in <PlatformStrictSubscriptionQueryResult>[
    wire(code: 6),
    wire(feature: -2),
    wire(requested: false),
  ]) {
    test(
      'inconsistent completed coverage rejected ${response.responseCode}/${response.featureResponseCode}/${response.suspendedRequested}',
      () async {
        when(
          api.querySubscriptionsStrict(any),
        ).thenAnswer((_) async => response);
        expect(
          (await query()).outcome,
          StrictSubscriptionQueryOutcome.invalidResponse,
        );
      },
    );
  }
  test('already switched account does not reach native query', () async {
    current = false;
    expect(
      (await query()).outcome,
      StrictSubscriptionQueryOutcome.staleSession,
    );
    verifyNever(api.querySubscriptionsStrict(any));
  });
  test(
    'account switch during query discards returned purchase tokens',
    () async {
      final pending = Completer<PlatformStrictSubscriptionQueryResult>();
      when(api.querySubscriptionsStrict(any)).thenAnswer((_) => pending.future);
      final future = query();
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(
        wire(purchases: <PlatformStrictSubscription>[purchase()]),
      );
      final result = await future;
      expect(result.outcome, StrictSubscriptionQueryOutcome.staleSession);
      expect(result.purchases, isEmpty);
    },
  );
  test('overlapping queries are rejected; one native operation', () async {
    final pending = Completer<PlatformStrictSubscriptionQueryResult>();
    when(api.querySubscriptionsStrict(any)).thenAnswer((_) => pending.future);
    final first = query();
    await Future<void>.delayed(Duration.zero);
    expect(
      (await query(id: 'second')).outcome,
      StrictSubscriptionQueryOutcome.busy,
    );
    pending.complete(wire());
    await first;
    verify(api.querySubscriptionsStrict(any)).called(1);
  });
  testWidgets('timeout keeps lease until late completion; no overlap', (
    tester,
  ) async {
    final pending = Completer<PlatformStrictSubscriptionQueryResult>();
    when(api.querySubscriptionsStrict(any)).thenAnswer((_) => pending.future);
    final first = query(timeout: const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect((await first).outcome, StrictSubscriptionQueryOutcome.timeout);
    expect(
      (await query(id: 'second')).outcome,
      StrictSubscriptionQueryOutcome.busy,
    );
    pending.complete(wire(purchases: <PlatformStrictSubscription>[purchase()]));
    await tester.pump();
    when(api.querySubscriptionsStrict(any)).thenAnswer((_) async => wire());
    expect((await query(id: 'third', generation: 2)).sessionGeneration, 2);
  });
  testWidgets('expired connection wait cannot dispatch a late native query', (
    tester,
  ) async {
    manager.dispose();
    final connecting = Completer<PlatformBillingResult>();
    when(
      api.startConnection(any, any, any),
    ).thenAnswer((_) => connecting.future);
    manager = BillingClientManager(
      billingClientFactory: (listener, alternative) =>
          BillingClient(listener, alternative, api: api),
    );
    addition = InAppPurchaseAndroidPlatformAddition(manager);
    final first = query(timeout: const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect((await first).outcome, StrictSubscriptionQueryOutcome.timeout);
    expect(
      (await query(id: 'second')).outcome,
      StrictSubscriptionQueryOutcome.busy,
    );
    connecting.complete(
      PlatformBillingResult(
        responseCode: PlatformBillingResponse.ok,
        debugMessage: '',
      ),
    );
    await tester.pump();
    verifyNever(api.querySubscriptionsStrict(any));
  });
  test(
    'existing shared manager reconnect is reused without query retry',
    () async {
      when(api.querySubscriptionsStrict(any)).thenAnswer((_) async => wire());
      await query();
      manager.client.hostCallbackHandler.onBillingServiceDisconnected(0);
      await Future<void>.delayed(Duration.zero);
      await query(id: 'q2');
      expect(clients, 1);
      verify(api.startConnection(any, any, any)).called(2);
      verify(api.querySubscriptionsStrict(any)).called(2);
    },
  );
  test('request scope and timeout validated', () async {
    await expectLater(query(id: ''), throwsArgumentError);
    await expectLater(query(timeout: Duration.zero), throwsArgumentError);
    verifyNever(api.querySubscriptionsStrict(any));
  });
  test(
    'tokens omitted from diagnostic strings and records immutable',
    () async {
      when(api.querySubscriptionsStrict(any)).thenAnswer(
        (_) async => wire(purchases: <PlatformStrictSubscription>[purchase()]),
      );
      final result = await query();
      expect(result.toString(), isNot(contains('synthetic-only')));
      expect(
        result.purchases.single.toString(),
        isNot(contains('synthetic-only')),
      );
      expect(() => result.purchases.clear(), throwsUnsupportedError);
      expect(
        () => result.purchases.single.products.clear(),
        throwsUnsupportedError,
      );
    },
  );
}
