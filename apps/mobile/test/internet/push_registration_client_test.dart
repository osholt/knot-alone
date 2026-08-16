import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/push_registration_client.dart';

void main() {
  test(
    'registers and revokes a token outside the ride event payload',
    () async {
      final requests = <http.Request>[];
      final client = HttpPushRegistrationClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: MockClient((request) async {
          requests.add(request);
          return request.method == 'DELETE'
              ? http.Response('', 204)
              : http.Response(
                  jsonEncode({
                    'installationId': 'local-device',
                    'platform': 'android',
                    'provider': 'fcm',
                    'role': 'rider',
                    'preferences': {
                      'safety': true,
                      'status': false,
                      'administrative': true,
                    },
                    'registeredAt': '2026-07-23T12:00:00Z',
                    'updatedAt': '2026-07-23T12:00:00Z',
                  }),
                  200,
                );
        }),
      );

      await client.register(
        session: _session,
        token: const DevicePushToken(
          platform: 'android',
          provider: PushProvider.fcm,
          value: 'fcm-token-1234567890',
        ),
        preferences: const PushPreferences(status: false),
      );
      await client.revoke(_session);

      expect(requests, hasLength(2));
      expect(requests.first.method, 'PUT');
      expect(
        requests.first.url.path,
        contains('/push-registrations/local-device'),
      );
      expect(
        requests.first.headers['authorization'],
        startsWith('Bearer rr1_'),
      );
      expect(requests.first.body, isNot(contains(_session.inviteSecret)));
      final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(body['token'], 'fcm-token-1234567890');
      expect(body['preferences']['status'], isFalse);
      expect(requests.last.method, 'DELETE');
      client.close();
    },
  );

  test('surfaces a bounded safe registration failure', () async {
    final client = HttpPushRegistrationClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/api'),
      ),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'Ride credential rejected'}),
          403,
        ),
      ),
    );

    await expectLater(
      client.register(
        session: _session,
        token: const DevicePushToken(
          platform: 'android',
          provider: PushProvider.fcm,
          value: 'fcm-token-1234567890',
        ),
        preferences: const PushPreferences(),
      ),
      throwsA(
        isA<InternetRelayException>().having(
          (error) => error.unauthorized,
          'unauthorized',
          isTrue,
        ),
      ),
    );
    client.close();
  });
}

final _session = RideSession(
  rideId: 'ride/alpha',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'aTokenWithPlentyOfEntropy',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 23),
);
