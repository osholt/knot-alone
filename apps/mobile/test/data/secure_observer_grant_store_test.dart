import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/data/secure_observer_grant_store.dart';
import 'package:tide_and_seek/internet/observer_access_client.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('round trips all three credentials through secure storage', () async {
    const store = SecureObserverGrantStore();
    final credentials = ObserverGrantCredentials(
      grant: ObserverGrant(
        id: 'grant-a',
        label: 'Home',
        createdAt: DateTime.utc(2026, 7, 24, 12),
        expiresAt: DateTime.utc(2026, 7, 24, 16),
      ),
      managementToken: 'om1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      publisherToken: 'op1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      observerToken: 'ro1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
    );

    await store.save('voyage-a', [credentials]);
    final reloaded = await store.load('voyage-a');

    expect(reloaded.single.managementToken, credentials.managementToken);
    expect(reloaded.single.publisherToken, credentials.publisherToken);
    expect(reloaded.single.observerToken, credentials.observerToken);
    await store.delete('voyage-a');
    expect(await store.load('voyage-a'), isEmpty);
  });

  test(
    'corrupt secure state is deleted instead of partially trusted',
    () async {
      const store = SecureObserverGrantStore();
      await const FlutterSecureStorage().write(
        key:
            'ride_relay_observer_grants_v1_'
            '2889292830075b00868126d7de25feee3df92afdc08e4d3f2d8bbbb61b5b6863',
        value: '{"schemaVersion":1,"credentials":[{"bad":true}]}',
      );

      expect(await store.load('voyage-a'), isEmpty);
    },
  );

  test('persists local assistance independently from relay events', () async {
    const store = SecureObserverGrantStore();
    final now = DateTime.utc(2026, 7, 24, 12);
    await store.saveLocalAssistance(
      'voyage-a',
      ObserverLocalAssistanceState(
        updatedAt: now,
        assistance: ObserverPublishedAssistance(
          kind: 'assistance',
          reportedAt: now,
        ),
      ),
    );

    final restored = await store.loadLocalAssistance('voyage-a');
    expect(restored?.assistance?.kind, 'assistance');
    expect(restored?.updatedAt.toUtc(), now);
    await store.deleteLocalAssistance('voyage-a');
    expect(await store.loadLocalAssistance('voyage-a'), isNull);
  });
}
