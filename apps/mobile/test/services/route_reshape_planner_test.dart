import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/passage_planning_service.dart';
import 'package:tide_and_seek/services/route_reshape_planner.dart';

void main() {
  test('a dragged point is assigned to the named-stop leg it shapes', () {
    final route = _route();
    final points = insertRouteShapingPoint(
      route,
      const [],
      const GeoPoint(latitude: 51.012, longitude: -2.012),
      id: 'shape-b',
    );

    expect(points.single.legIndex, 1);
    expect(route.waypoints, hasLength(3));
    expect(points.single.point, isNot(route.waypoints[1].point));
  });

  test(
    'controls retain named stops and shaping order without adding stops',
    () {
      final route = _route();
      final controls = routeShapingControls(route, const [
        RouteShapingPoint(
          id: 'shape-a',
          legIndex: 0,
          point: GeoPoint(latitude: 51.004, longitude: -2.004),
        ),
        RouteShapingPoint(
          id: 'shape-b',
          legIndex: 1,
          point: GeoPoint(latitude: 51.014, longitude: -2.014),
        ),
      ]);

      expect(controls, [
        route.waypoints[0].point,
        const GeoPoint(latitude: 51.004, longitude: -2.004),
        route.waypoints[1].point,
        const GeoPoint(latitude: 51.014, longitude: -2.014),
        route.waypoints[2].point,
      ]);
    },
  );

  test(
    'recalculation is an immutable preview through the shaping controls',
    () async {
      final planner = _RecordingPassagePlanner();
      final original = _route();
      const shapes = [
        RouteShapingPoint(
          id: 'shape-a',
          legIndex: 0,
          point: GeoPoint(latitude: 51.006, longitude: -2.002),
        ),
      ];

      final result = await RouteReshapePlanner(
        passagePlanner: planner,
      ).reshape(original, shapes);

      expect(planner.controls, routeShapingControls(original, shapes));
      expect(result.route.waypoints, same(original.waypoints));
      expect(result.route.shapingPoints, shapes);
      expect(result.route.paths.single.points, planner.result.points);
      expect(result.route.plannedDuration, planner.result.duration);
      expect(original.shapingPoints, isEmpty);
    },
  );

  test('shaping points survive route JSON save and reload', () {
    final route = _route().withShapingPoints(const [
      RouteShapingPoint(
        id: 'shape-a',
        legIndex: 1,
        point: GeoPoint(latitude: 51.012, longitude: -2.012),
      ),
    ]);

    final restored = ImportedRoute.fromJsonString(route.toJsonString());

    expect(restored.shapingPoints.single.id, 'shape-a');
    expect(restored.shapingPoints.single.legIndex, 1);
    expect(restored.shapingPoints.single.point.latitude, 51.012);
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route',
  name: 'Three stop route',
  importedAt: DateTime.utc(2026, 7, 29),
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
      name: 'Cafe',
      point: GeoPoint(latitude: 51.01, longitude: -2.01),
    ),
    RouteWaypoint(
      name: 'Finish',
      point: GeoPoint(latitude: 51.02, longitude: -2.02),
    ),
  ],
);

class _RecordingPassagePlanner implements PassagePlanningService {
  List<GeoPoint> controls = const [];

  final result = const PassagePlanResult(
    points: [
      GeoPoint(latitude: 51, longitude: -2),
      GeoPoint(latitude: 51.006, longitude: -2.002),
      GeoPoint(latitude: 51.02, longitude: -2.02),
    ],
    distanceMeters: 3200,
    duration: Duration(minutes: 8),
  );

  @override
  Future<PassagePlanResult> planThrough(List<GeoPoint> waypoints) async {
    controls = List.unmodifiable(waypoints);
    return result;
  }
}
