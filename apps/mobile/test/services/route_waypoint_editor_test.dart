import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/route_waypoint_editor.dart';

void main() {
  test('inserts a POI in route order and preserves shaping controls', () {
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'first-leg',
        legIndex: 0,
        point: GeoPoint(latitude: 51.005, longitude: -2.005),
      ),
      RouteShapingPoint(
        id: 'before-poi',
        legIndex: 1,
        point: GeoPoint(latitude: 51.012, longitude: -2.012),
      ),
      RouteShapingPoint(
        id: 'after-poi',
        legIndex: 1,
        point: GeoPoint(latitude: 51.018, longitude: -2.018),
      ),
    ]);

    final edited = insertRouteWaypoint(
      route,
      const RouteWaypoint(
        name: 'Sailor Cafe',
        point: GeoPoint(latitude: 51.015, longitude: -2.015),
      ),
    );

    expect(edited.waypoints.map((point) => point.name), [
      'Start',
      'Existing stop',
      'Sailor Cafe',
      'Finish',
    ]);
    expect(edited.shapingPoints.map((point) => point.legIndex), [0, 1, 2]);
    expect(edited.maneuvers, isEmpty);
  });

  test('removes an intermediate waypoint and merges its route legs', () {
    final route = insertRouteWaypoint(
      _route().withShapingPoints(const [
        RouteShapingPoint(
          id: 'after-new-stop',
          legIndex: 1,
          point: GeoPoint(latitude: 51.018, longitude: -2.018),
        ),
      ]),
      const RouteWaypoint(
        name: 'Sailor Cafe',
        point: GeoPoint(latitude: 51.015, longitude: -2.015),
      ),
    );

    final edited = removeRouteWaypoint(route, 2);

    expect(edited.waypoints.map((point) => point.name), [
      'Start',
      'Existing stop',
      'Finish',
    ]);
    expect(edited.shapingPoints.single.legIndex, 1);
  });

  group('naming a mark (#43)', () {
    test('sets the name and changes nothing else about the passage', () {
      final route = _route();
      final renamed = renameRouteWaypoint(route, 1, 'Needles Fairway');

      expect(renamed.waypoints[1].name, 'Needles Fairway');
      expect(renamed.waypoints[1].point, route.waypoints[1].point);
      expect(renamed.waypoints.map((mark) => mark.point), [
        for (final mark in route.waypoints) mark.point,
      ]);
      expect(renamed.paths, route.paths);
      // The distinguishing property. Insert and remove clear the manoeuvres
      // because the geometry moved; a rename must not, or the courses and
      // times already on screen would blank out for a typed word.
      expect(renamed.maneuvers, route.maneuvers);
    });

    test('trims the name, and a blank one clears it', () {
      expect(
        renameRouteWaypoint(_route(), 1, '  Nab Tower  ').waypoints[1].name,
        'Nab Tower',
      );
      expect(renameRouteWaypoint(_route(), 1, '   ').waypoints[1].name, isNull);
      expect(renameRouteWaypoint(_route(), 1, null).waypoints[1].name, isNull);
    });

    test('the start and the destination can be named too', () {
      final route = renameRouteWaypoint(_route(), 0, 'Lymington');
      expect(
        renameRouteWaypoint(route, 2, 'Cowes').waypoints.map((m) => m.name),
        ['Lymington', 'Existing stop', 'Cowes'],
      );
    });

    test('refuses an index that is not on the passage', () {
      expect(
        () => renameRouteWaypoint(_route(), 3, 'Nowhere'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => renameRouteWaypoint(_route(), -1, 'Nowhere'),
        throwsA(isA<FormatException>()),
      );
    });

    test('survives a JSON round-trip', () {
      final renamed = renameRouteWaypoint(_route(), 1, 'Needles Fairway');
      final restored = ImportedRoute.fromJsonString(renamed.toJsonString());
      expect(restored.waypoints[1].name, 'Needles Fairway');
    });
  });

  group('naming a new mark (#43)', () {
    test('takes the lowest number no mark is already using', () {
      expect(nextMarkName(_route()), 'Mark 1');

      final withMarks = renameRouteWaypoint(
        renameRouteWaypoint(_route(), 0, 'Mark 1'),
        1,
        'Mark 2',
      );
      expect(nextMarkName(withMarks), 'Mark 3');
    });

    test('fills a gap rather than counting past it', () {
      final gapped = renameRouteWaypoint(
        renameRouteWaypoint(_route(), 0, 'Mark 1'),
        1,
        'Mark 3',
      );
      expect(nextMarkName(gapped), 'Mark 2');
    });

    // The bug this replaces: the old name came from the waypoint count, so
    // removing one mark and adding another produced a duplicate. Two marks
    // answering to "Mark 5" stops "steer for Mark 5" being an instruction.
    test('does not collide after a remove and a re-add', () {
      var route = _route();
      for (var placed = 0; placed < 3; placed += 1) {
        route = insertRouteWaypoint(
          route,
          RouteWaypoint(
            name: nextMarkName(route),
            point: GeoPoint(
              latitude: 51.005 + placed * 0.001,
              longitude: -2.005,
            ),
          ),
        );
      }
      route = removeRouteWaypoint(route, 1);
      route = insertRouteWaypoint(
        route,
        RouteWaypoint(
          name: nextMarkName(route),
          point: const GeoPoint(latitude: 51.017, longitude: -2.017),
        ),
      );

      final names = [for (final mark in route.waypoints) ?mark.name];
      expect(
        names.toSet().length,
        names.length,
        reason: 'two marks must never share a name',
      );
    });

    test('ignores case and surrounding space when checking what is taken', () {
      expect(
        nextMarkName(renameRouteWaypoint(_route(), 0, '  mark 1 ')),
        'Mark 2',
      );
    });
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 8, 4),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51.005, longitude: -2.005),
        GeoPoint(latitude: 51.01, longitude: -2.01),
        GeoPoint(latitude: 51.015, longitude: -2.015),
        GeoPoint(latitude: 51.02, longitude: -2.02),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(name: 'Start', point: GeoPoint(latitude: 51, longitude: -2)),
    RouteWaypoint(
      name: 'Existing stop',
      point: GeoPoint(latitude: 51.01, longitude: -2.01),
    ),
    RouteWaypoint(
      name: 'Finish',
      point: GeoPoint(latitude: 51.02, longitude: -2.02),
    ),
  ],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 51.005, longitude: -2.005),
      type: 'turn',
    ),
  ],
);
