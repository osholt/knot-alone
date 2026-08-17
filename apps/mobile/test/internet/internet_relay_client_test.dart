import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';

void main() {
  group('HttpInternetRelayClient', () {
    test('is disabled unless an absolute HTTPS endpoint is configured', () {
      expect(
        const InternetRelayConfiguration(baseUri: null).isConfigured,
        isFalse,
      );
      expect(
        InternetRelayConfiguration(
          baseUri: Uri.parse('http://relay.example'),
        ).isConfigured,
        isFalse,
      );
      expect(
        InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ).isConfigured,
        isTrue,
      );
    });

    test('sends a bounded authenticated idempotent sync request', () async {
      final requests = <http.Request>[];
      final remote = _event(id: 'remote-event', deviceId: 'remote-device');
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'cursor': 'cursor-2',
            'acceptedEventIds': ['local-event'],
            'events': [remote.toJson()],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      final first = await client.synchronize(
        session: _session,
        cursor: 'cursor-1',
        events: [_event(id: 'local-event')],
      );
      await client.synchronize(
        session: _session,
        cursor: 'cursor-1',
        events: [_event(id: 'local-event')],
      );

      expect(first.cursor, 'cursor-2');
      expect(first.acceptedEventIds, {'local-event'});
      expect(first.events.single.id, 'remote-event');
      expect(requests, hasLength(2));
      expect(requests.first.followRedirects, isFalse);
      expect(
        requests.first.url.path,
        '/base/v1/voyages/voyage%2Falpha/events:sync',
      );
      expect(
        requests.first.headers['authorization'],
        startsWith('Bearer rr1_'),
      );
      expect(
        requests.first.headers['authorization'],
        isNot(contains(_session.inviteSecret)),
      );
      expect(
        requests.first.headers['idempotency-key'],
        requests.last.headers['idempotency-key'],
      );
      expect(jsonDecode(requests.first.body)['protocolVersion'], 1);
      client.close();
    });

    test(
      'rejects events for another voyage in a successful response',
      () async {
        final transport = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'cursor': 'cursor-2',
              'acceptedEventIds': <String>[],
              'events': [_event(id: 'foreign', voyageId: 'other').toJson()],
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        final client = HttpInternetRelayClient(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example'),
          ),
          client: transport,
        );

        await expectLater(
          client.synchronize(session: _session, cursor: null, events: const []),
          throwsA(isA<InternetRelayException>()),
        );
        client.close();
      },
    );

    test('rejects an oversized response before decoding it', () async {
      final transport = MockClient(
        (_) async => http.Response(
          'x' * 65,
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
          maximumResponseBytes: 64,
        ),
        client: transport,
      );

      await expectLater(
        client.synchronize(session: _session, cursor: null, events: const []),
        throwsA(
          isA<InternetRelayException>().having(
            (error) => error.message,
            'message',
            contains('size limit'),
          ),
        ),
      );
      client.close();
    });

    test('identifies an expired cursor as a retryable relay state', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
        ),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'Invalid cursor'}),
            400,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await expectLater(
        client.synchronize(
          session: _session,
          cursor: 'stale',
          events: const [],
        ),
        throwsA(
          isA<InternetRelayException>()
              .having((error) => error.code, 'code', 'invalid_cursor')
              .having((error) => error.retryable, 'retryable', isTrue)
              .having((error) => error.message, 'message', 'Invalid cursor'),
        ),
      );
      client.close();
    });

    test('bounds the wait for response headers', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
          headerTimeout: const Duration(milliseconds: 10),
        ),
        client: _NeverRespondingClient(),
      );

      await expectLater(
        client.synchronize(session: _session, cursor: null, events: const []),
        throwsA(
          isA<InternetRelayException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having((error) => error.message, 'message', contains('headers')),
        ),
      );
      client.close();
    });

    test('negotiates current relay capabilities', () async {
      final requests = <http.Request>[];
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: MockClient((request) async {
          requests.add(request);
          return _compatibilityResponse();
        }),
        clientDescriptor: _clientDescriptor,
        clock: () => DateTime.utc(2026, 7, 22),
      );

      final result = await client.checkCompatibility();

      expect(result.disposition, RelayCompatibilityDisposition.compatible);
      expect(result.capabilities, RelayProtocolCapabilities.current);
      expect(requests.single.url.path, '/base/v1/compatibility');
      expect(requests.single.headers['x-tailendcharlie-protocol'], '1');
      expect(
        requests.single.headers['x-tailendcharlie-distribution-track'],
        'alpha',
      );
      expect(
        requests.single.headers['x-tailendcharlie-capabilities'],
        contains(RelayProtocolCapabilities.routeRevisions),
      );
      client.close();
    });

    test(
      'uses a bounded legacy mode when compatibility is unavailable',
      () async {
        final client = HttpInternetRelayClient(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example'),
          ),
          client: MockClient((_) async => http.Response('', 404)),
          clientDescriptor: _clientDescriptor,
          clock: () => DateTime.utc(2026, 7, 22),
        );

        final result = await client.checkCompatibility();

        expect(
          result.disposition,
          RelayCompatibilityDisposition.legacyCompatible,
        );
        expect(result.canSynchronize, isTrue);
        expect(result.capabilities, isEmpty);
        client.close();
      },
    );

    test('requires an update below the server minimum protocol', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
        ),
        client: MockClient(
          (_) async => _compatibilityResponse(minimumClientProtocol: 2),
        ),
        clientDescriptor: _clientDescriptor,
        clock: () => DateTime.utc(2026, 7, 22),
      );

      final result = await client.checkCompatibility();

      expect(result.disposition, RelayCompatibilityDisposition.updateRequired);
      expect(result.canSynchronize, isFalse);
      expect(result.updateUri, Uri.parse('https://tideandseek.invalid/update'));
      client.close();
    });

    test('does not expose a failed relay hostname in diagnostics', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://retired.internal.example'),
        ),
        client: MockClient(
          (_) async => throw http.ClientException(
            'Failed host lookup: retired.internal.example',
          ),
        ),
        clientDescriptor: _clientDescriptor,
      );

      await expectLater(
        client.checkCompatibility(),
        throwsA(
          isA<InternetRelayException>()
              .having(
                (error) => error.message,
                'message',
                isNot(contains('retired.internal.example')),
              )
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
      client.close();
    });
  });

  group('HttpVoyageCodeDirectory', () {
    test(
      'registers and resolves a six-digit code over the configured relay',
      () async {
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/v1/compatibility')) {
            return _compatibilityResponse();
          }
          if (request.method == 'PUT') {
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              'voyageId': _session.voyageId,
              'voyageCode': '123456',
              'inviteSecret': _session.inviteSecret,
              'resolveToken': _session.joinToken,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final directory = HttpVoyageCodeDirectory(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example/base'),
          ),
          client: transport,
        );
        final skipper = _session.copyWith(voyageCode: '123456');

        await directory.register(skipper);
        final resolved = await directory.resolve('123456');

        expect(resolved.voyageId, _session.voyageId);
        expect(resolved.voyageCode, '123456');
        expect(resolved.inviteSecret, _session.inviteSecret);
        expect(resolved.joinToken, _session.joinToken);
        expect(requests, hasLength(3));
        expect(requests.first.url.path, '/base/v1/compatibility');
        expect(requests[1].method, 'PUT');
        expect(requests[1].url.path, '/base/v1/join-codes/123456');
        expect(requests[1].followRedirects, isFalse);
        expect(jsonDecode(requests[1].body), {
          'voyageId': _session.voyageId,
          'inviteSecret': _session.inviteSecret,
          'resolveToken': _session.joinToken,
        });
        expect(requests.last.method, 'GET');
        expect(
          requests.last.headers.containsKey('x-tide-and-seek-join-token'),
          isFalse,
        );
        directory.close();
      },
    );

    test('sends the join token header only when one is supplied', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/v1/compatibility')) {
          return _compatibilityResponse();
        }
        return http.Response(
          jsonEncode({
            'voyageId': _session.voyageId,
            'voyageCode': '123456',
            'inviteSecret': _session.inviteSecret,
            'resolveToken': _session.joinToken,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final directory = HttpVoyageCodeDirectory(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      await directory.resolve('123456', joinToken: 'pastedTokenValue123456');

      expect(
        requests.last.headers['x-tide-and-seek-join-token'],
        'pastedTokenValue123456',
      );
      directory.close();
    });

    // #208. A probe that never answers says nothing about compatibility, and it
    // used to abandon the join: a tester on working 4G could not rejoin her own
    // voyage, and was shown "Voyage service compatibility check timed out".
    test('a timed-out compatibility probe does not block a join', () async {
      final paths = <String>[];
      final transport = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/v1/compatibility')) {
          throw TimeoutException('probe');
        }
        return http.Response(
          jsonEncode({
            'voyageId': _session.voyageId,
            'voyageCode': '123456',
            'inviteSecret': _session.inviteSecret,
            'resolveToken': _session.joinToken,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final directory = HttpVoyageCodeDirectory(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      final resolved = await directory.resolve('123456');

      expect(resolved.voyageId, _session.voyageId);
      // Tried more than once before giving up on an answer, then went ahead.
      expect(
        paths.where((path) => path.endsWith('/v1/compatibility')),
        hasLength(2),
      );
      expect(paths.last, '/base/v1/join-codes/123456');
      directory.close();
    });

    test(
      'an unreachable relay fails on the join call, not the probe',
      () async {
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/v1/compatibility')) {
            throw TimeoutException('probe');
          }
          // What package:http surfaces for a dead socket.
          throw http.ClientException('no route to host', request.url);
        });
        final directory = HttpVoyageCodeDirectory(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example/base'),
          ),
          client: transport,
        );

        await expectLater(
          directory.resolve('123456'),
          throwsA(
            isA<VoyageCodeDirectoryException>()
                .having((error) => error.retryable, 'retryable', isTrue)
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('compatibility')),
                ),
          ),
        );
        directory.close();
      },
    );

    test('a genuine protocol disagreement still refuses the join', () async {
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/v1/compatibility')) {
          return _compatibilityResponse(minimumClientProtocol: 99);
        }
        return http.Response('', 500);
      });
      final directory = HttpVoyageCodeDirectory(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      await expectLater(
        directory.resolve('123456'),
        throwsA(
          isA<VoyageCodeDirectoryException>().having(
            (error) => error.message,
            'message',
            contains('Update Tide and Seek'),
          ),
        ),
      );
      directory.close();
    });
  });
}

const _clientDescriptor = RelayClientDescriptor(
  protocolVersion: 1,
  platform: 'iOS',
  appVersion: '1.0.1',
  appBuild: '22',
  capabilities: RelayProtocolCapabilities.current,
  distributionTrack: 'alpha',
);

http.Response _compatibilityResponse({int minimumClientProtocol = 1}) =>
    http.Response(
      jsonEncode({
        'serverProtocol': 1,
        'minimumClientProtocol': minimumClientProtocol,
        'maximumClientProtocol': 1,
        'capabilities': RelayProtocolCapabilities.current.toList(),
        'requiredCapabilities': <String>[],
        'cacheSeconds': 300,
        'updateUrls': {
          'default': 'https://tideandseek.invalid/update',
          'iOS': 'https://tideandseek.invalid/update',
          'android': 'https://tideandseek.invalid/update',
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

class _NeverRespondingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

final _session = VoyageSession(
  voyageId: 'voyage/alpha',
  voyageCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'aTokenWithPlentyOfEntropy',
  localSailorId: 'local-device',
  displayName: 'Oliver',
  role: VoyageRole.sailor,
  joinedAt: DateTime.utc(2026, 7, 16),
);

VoyageEvent _event({
  required String id,
  String voyageId = 'voyage/alpha',
  String deviceId = 'local-device',
}) => VoyageEvent(
  id: id,
  voyageId: voyageId,
  deviceId: deviceId,
  type: VoyageEventType.statusMessage,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10),
  payload: const {'message': 'OK'},
  signature: 'a' * 64,
);
