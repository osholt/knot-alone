import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_route_reducer.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final start = DateTime.utc(2026, 7, 22, 10);

  test('a complete skipper revision converges from shuffled chunks', () {
    final encoded = const VoyageRouteEncoder(
      maximumChunkCharacters: 24,
    ).encode(_route('Coast route'));
    final events = <VoyageEvent>[
      _event(
        id: 'created',
        deviceId: 'skipper',
        type: VoyageEventType.voyageCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      for (var index = 0; index < encoded.chunks.length; index += 1)
        _event(
          id: 'chunk-${index.toString().padLeft(3, '0')}',
          deviceId: 'skipper',
          type: VoyageEventType.routeRevisionChunk,
          createdAt: start.add(const Duration(minutes: 1)),
          payload: {
            'revisionId': 'revision-a',
            'revisionNumber': 1,
            'skipperSailorId': 'skipper',
            'index': index,
            'data': encoded.chunks[index],
          },
          secret: secret,
        ),
      _event(
        id: 'manifest',
        deviceId: 'skipper',
        type: VoyageEventType.routeRevisionPublished,
        createdAt: start.add(const Duration(minutes: 2)),
        payload: {
          'revisionId': 'revision-a',
          'revisionNumber': 1,
          'skipperSailorId': 'skipper',
          'chunkCount': encoded.chunks.length,
          'compressedBytes': encoded.compressedBytes,
          'sha256': encoded.sha256Digest,
        },
        secret: secret,
      ),
    ];

    final state = const VoyageRouteReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: events.reversed,
    );

    expect(state.hasDecision, isTrue);
    expect(state.revisionId, 'revision-a');
    expect(state.route?.name, 'Coast route');
    expect(state.route?.pathPointCount, 3);
  });

  test('incomplete revisions do not replace the last complete route', () {
    final complete = _publishedRevision(
      route: _route('Original'),
      revisionId: 'original',
      revisionNumber: 1,
      start: start,
      secret: secret,
    );
    final incomplete = _publishedRevision(
      route: _route('Incomplete'),
      revisionId: 'incomplete',
      revisionNumber: 2,
      start: start.add(const Duration(minutes: 5)),
      secret: secret,
    );
    incomplete.removeWhere(
      (event) =>
          event.type == VoyageEventType.routeRevisionChunk &&
          event.payload['index'] == 0,
    );

    final state = const VoyageRouteReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: [
        _event(
          id: 'created',
          deviceId: 'skipper',
          type: VoyageEventType.voyageCreated,
          createdAt: start.subtract(const Duration(minutes: 1)),
          payload: const {'displayName': 'Lead', 'role': 'lead'},
          secret: secret,
        ),
        ...complete,
        ...incomplete,
      ],
    );

    expect(state.route?.name, 'Original');
    expect(state.revisionId, 'original');
  });

  test('a signed skipper clear deterministically removes the route', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'skipper',
        type: VoyageEventType.voyageCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Original'),
        revisionId: 'original',
        revisionNumber: 1,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      _event(
        id: 'clear',
        deviceId: 'skipper',
        type: VoyageEventType.routeCleared,
        createdAt: start.add(const Duration(minutes: 4)),
        payload: const {
          'revisionId': 'clear-a',
          'revisionNumber': 2,
          'skipperSailorId': 'skipper',
        },
        secret: secret,
      ),
    ];

    final state = const VoyageRouteReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: events,
    );

    expect(state.hasDecision, isTrue);
    expect(state.route, isNull);
    expect(state.revisionId, 'clear-a');
  });

  test('a later signed skipper revision wins after offline role handover', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'skipper',
        type: VoyageEventType.voyageCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Original'),
        revisionId: 'original',
        revisionNumber: 1,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      _event(
        id: 'new-skipper-joined',
        deviceId: 'new-skipper',
        type: VoyageEventType.sailorJoined,
        createdAt: start.add(const Duration(minutes: 3)),
        payload: const {'displayName': 'Alex', 'role': 'sailor'},
        secret: secret,
      ),
      _event(
        id: 'new-skipper-promoted',
        deviceId: 'new-skipper',
        type: VoyageEventType.roleChanged,
        createdAt: start.add(const Duration(minutes: 4)),
        payload: const {'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Replacement'),
        revisionId: 'replacement',
        revisionNumber: 2,
        start: start.add(const Duration(minutes: 5)),
        secret: secret,
        deviceId: 'new-skipper',
      ),
    ];

    final state = const VoyageRouteReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: events.reversed,
    );

    expect(state.route?.name, 'Replacement');
    expect(state.revisionNumber, 2);
    expect(state.changedBySailorId, 'new-skipper');
  });

  test('a late stale revision cannot roll back a newer route version', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'skipper',
        type: VoyageEventType.voyageCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Current'),
        revisionId: 'current',
        revisionNumber: 3,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Stale'),
        revisionId: 'stale',
        revisionNumber: 2,
        start: start.add(const Duration(minutes: 5)),
        secret: secret,
      ),
    ];

    final state = const VoyageRouteReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: events,
    );

    expect(state.route?.name, 'Current');
    expect(state.revisionNumber, 3);
  });
}

List<VoyageEvent> _publishedRevision({
  required ImportedRoute route,
  required String revisionId,
  required int revisionNumber,
  required DateTime start,
  required String secret,
  String deviceId = 'skipper',
}) {
  final encoded = const VoyageRouteEncoder(
    maximumChunkCharacters: 60,
  ).encode(route);
  return [
    for (var index = 0; index < encoded.chunks.length; index += 1)
      _event(
        id: '$revisionId-chunk-$index',
        deviceId: deviceId,
        type: VoyageEventType.routeRevisionChunk,
        createdAt: start,
        payload: {
          'revisionId': revisionId,
          'revisionNumber': revisionNumber,
          'skipperSailorId': deviceId,
          'index': index,
          'data': encoded.chunks[index],
        },
        secret: secret,
      ),
    _event(
      id: '$revisionId-manifest',
      deviceId: deviceId,
      type: VoyageEventType.routeRevisionPublished,
      createdAt: start.add(const Duration(minutes: 1)),
      payload: {
        'revisionId': revisionId,
        'revisionNumber': revisionNumber,
        'skipperSailorId': deviceId,
        'chunkCount': encoded.chunks.length,
        'compressedBytes': encoded.compressedBytes,
        'sha256': encoded.sha256Digest,
      },
      secret: secret,
    ),
  ];
}

ImportedRoute _route(String name) => ImportedRoute(
  id: 'route-${name.toLowerCase()}',
  name: name,
  importedAt: DateTime.utc(2026, 7, 22),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.45, longitude: -2.59),
        GeoPoint(latitude: 51.46, longitude: -2.58),
        GeoPoint(latitude: 51.47, longitude: -2.57),
      ],
    ),
  ],
  waypoints: const [],
);

VoyageEvent _event({
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
  required String secret,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: VoyageEventAuthenticator.sign(unsigned, secret),
  );
}
