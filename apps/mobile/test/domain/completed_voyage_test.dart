import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/completed_voyage.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';

void main() {
  test('completed voyage round-trips summary and route geometry', () {
    final voyage = _voyage();

    final restored = CompletedVoyage.fromJson(voyage.toJson());

    expect(restored.voyageId, voyage.voyageId);
    expect(restored.localRole, VoyageRole.sweeper);
    expect(restored.traveledRoute?.pathPointCount, 2);
    expect(restored.mapPoints, hasLength(2));
  });

  test('damaged optional geometry does not discard summary metadata', () {
    final json = _voyage().toJson()
      ..['traveledRoute'] = {
        'schemaVersion': 1,
        'id': 'broken',
        'paths': 'not-a-list',
      };

    final restored = CompletedVoyage.fromJson(json);

    expect(restored.title, 'Voyage 123456');
    expect(restored.traveledRoute, isNull);
    expect(restored.sailorCount, 4);
  });
}

CompletedVoyage _voyage() => CompletedVoyage(
  voyageId: 'voyage-1',
  voyageCode: '123456',
  voyageName: null,
  localDisplayName: 'Oliver',
  localRole: VoyageRole.sweeper,
  startedAt: DateTime.utc(2026, 7, 23, 12),
  endedAt: DateTime.utc(2026, 7, 23, 14),
  archivedAt: DateTime.utc(2026, 7, 23, 14),
  sailorCount: 4,
  eventCount: 12,
  totalDistanceMeters: 42000,
  markerSessions: const [],
  plannedRoute: null,
  traveledRoute: ImportedRoute(
    id: 'trail',
    name: 'Recorded trail',
    importedAt: DateTime.utc(2026, 7, 23, 14),
    sourceFileName: 'voyage.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.track,
        points: [
          GeoPoint(latitude: 53, longitude: -1),
          GeoPoint(latitude: 54, longitude: -2),
        ],
      ),
    ],
    waypoints: const [],
  ),
);
