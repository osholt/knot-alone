import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';

void main() {
  test(
    'publishes a latest snapshot through the non-event presence endpoint',
    () async {
      final requests = <http.Request>[];
      final now = DateTime.utc(2026, 7, 23, 10);
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/v1/compatibility')) {
          return http.Response(
            jsonEncode({
              'serverProtocol': 1,
              'minimumClientProtocol': 1,
              'maximumClientProtocol': 1,
              'capabilities': RelayProtocolCapabilities.current.toList(),
              'requiredCapabilities': <String>[],
              'cacheSeconds': 300,
              'updateUrls': {'default': 'https://tideandseek.invalid'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'ttlSeconds': 45,
            'positions': [
              {
                'sailorId': 'local',
                'displayName': 'Oliver',
                'role': 'lead',
                'vesselStyle': 'adventure',
                'sailorColor': 'blue',
                'sample': {
                  'position': {'latitude': 51.2, 'longitude': -2.4},
                  'recordedAt': now.toIso8601String(),
                  'accuracyMeters': 4,
                  'speedMetersPerSecond': null,
                  'headingDegrees': null,
                },
                'receivedAt': now.toIso8601String(),
                'expiresAt': now
                    .add(const Duration(seconds: 45))
                    .toIso8601String(),
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = HttpPreStartPresenceClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: client,
        clock: () => now,
      );
      addTearDown(api.close);
      final session = VoyageSession(
        voyageId: 'voyage',
        voyageCode: '123456',
        inviteSecret: '0123456789abcdef0123456789abcdef',
        joinToken: 'test-join-token-0123456789',
        localSailorId: 'local',
        displayName: 'Oliver',
        role: VoyageRole.lead,
        joinedAt: now,
      );
      final position = SailorLocation(
        sailorId: 'local',
        displayName: 'Oliver',
        role: VoyageRole.lead,
        sample: LocationSample(
          position: const GeoPoint(latitude: 51.2, longitude: -2.4),
          recordedAt: now,
          accuracyMeters: 4,
        ),
        receivedAt: now,
      );

      final result = await api.synchronizePreStartPresence(
        session: session,
        position: position,
        clear: false,
      );

      final presenceRequest = requests.last;
      final body = jsonDecode(presenceRequest.body) as Map<String, Object?>;
      expect(presenceRequest.url.path, '/api/v1/voyages/voyage/presence:sync');
      expect(body, isNot(contains('events')));
      expect(body['position'], isA<Map>());
      expect(result.locations.single.sailorId, 'local');
      expect(result.ttl, const Duration(seconds: 45));
    },
  );

  test(
    'does not call an older relay without the presence capability',
    () async {
      var presenceCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/v1/compatibility')) {
          return http.Response(
            jsonEncode({
              'serverProtocol': 1,
              'minimumClientProtocol': 1,
              'maximumClientProtocol': 1,
              'capabilities': ['voyage-start-v1'],
              'requiredCapabilities': <String>[],
              'cacheSeconds': 300,
              'updateUrls': {'default': 'https://tideandseek.invalid'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        presenceCalls += 1;
        return http.Response('{}', 200);
      });
      final api = HttpPreStartPresenceClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: client,
      );
      addTearDown(api.close);
      final session = VoyageSession(
        voyageId: 'voyage',
        voyageCode: '123456',
        inviteSecret: '0123456789abcdef0123456789abcdef',
        joinToken: 'test-join-token-0123456789',
        localSailorId: 'local',
        displayName: 'Oliver',
        role: VoyageRole.lead,
        joinedAt: DateTime.utc(2026, 7, 23),
      );

      await expectLater(
        api.synchronizePreStartPresence(
          session: session,
          position: null,
          clear: false,
        ),
        throwsA(
          isA<InternetRelayException>().having(
            (error) => error.code,
            'code',
            'feature_unsupported',
          ),
        ),
      );
      expect(presenceCalls, 0);
    },
  );
}
