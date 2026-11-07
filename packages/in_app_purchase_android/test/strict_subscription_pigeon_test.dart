import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_android/src/messages.g.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = BasicMessageChannel<Object?>(
    'dev.flutter.pigeon.in_app_purchase_android.InAppPurchaseApi.querySubscriptionsStrict',
    InAppPurchaseApi.pigeonChannelCodec,
  );
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockDecodedMessageHandler<Object?>(channel, null),
  );
  test(
    'generated Pigeon codec round-trips strict native query and pending data',
    () async {
      messenger.setMockDecodedMessageHandler<Object?>(channel, (
        Object? message,
      ) async {
        expect(message, <Object?>[10000]);
        return <Object?>[
          PlatformStrictSubscriptionQueryResult(
            outcome: PlatformStrictQueryOutcome.completed,
            suspendedRequested: true,
            responseCode: 0,
            featureResponseCode: 0,
            subResponseCode: 0,
            purchases: <PlatformStrictSubscription>[
              PlatformStrictSubscription(
                products: <String>['hmo_investor_pro'],
                purchaseToken: 'synthetic-only',
                purchaseState: 1,
                suspended: true,
                pendingProducts: <String>['hmo_investor_pro'],
                pendingPurchaseToken: 'pending-synthetic',
              ),
            ],
          ),
        ];
      });
      final result = await InAppPurchaseApi().querySubscriptionsStrict(10000);
      expect(result.purchases.single.suspended, isTrue);
      expect(result.purchases.single.pendingPurchaseToken, 'pending-synthetic');
      expect(result.featureResponseCode, 0);
      expect(result.responseCode, 0);
    },
  );
  test('native Pigeon error propagates, never empty success', () async {
    messenger.setMockDecodedMessageHandler<Object?>(
      channel,
      (_) async => <Object?>['synthetic-error', 'unavailable', null],
    );
    await expectLater(
      InAppPurchaseApi().querySubscriptionsStrict(10000),
      throwsA(isA<PlatformException>()),
    );
  });
}
