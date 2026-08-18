import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/passage_legs.dart';

/// #32. The leg table is the working document of a passage plan, so these tests
/// are mostly about not fabricating figures: legs come from the marks the sailor
/// chose, and every duration is traceable to one stated assumption.
void main() {
  const needles = GeoPoint(latitude: 50.6620, longitude: -1.5900);
  const nab = GeoPoint(latitude: 50.6700, longitude: -0.9500);
  const cherbourg = GeoPoint(latitude: 49.6600, longitude: -1.6200);

  ImportedRoute route({
    List<RouteWaypoint> waypoints = const [],
    List<GeoPoint> path = const [],
  }) => ImportedRoute(
    id: 'passage',
    name: 'Test passage',
    importedAt: DateTime.utc(2026, 8, 18),
    sourceFileName: 'passage.gpx',
    paths: [
      if (path.isNotEmpty) RoutePath(kind: RoutePathKind.track, points: path),
    ],
    waypoints: waypoints,
  );

  group('legs come from the marks', () {
    test('two marks make one leg', () {
      final plan = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles, name: 'Needles'),
            RouteWaypoint(point: nab, name: 'Nab Tower'),
          ],
        ),
      );

      expect(plan.legs, hasLength(1));
      expect(plan.legs.single.number, 1);
      expect(plan.legs.single.fromLabel, 'Needles');
      expect(plan.legs.single.toLabel, 'Nab Tower');
      expect(plan.hasLegs, isTrue);
    });

    test('three marks make two legs, numbered from one', () {
      final plan = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: nab),
            RouteWaypoint(point: cherbourg),
          ],
        ),
      );
      expect(plan.legs.map((leg) => leg.number), [1, 2]);
    });

    // The failure this guards: building legs from the drawn geometry, which the
    // planner densifies to a point every nautical mile. A 60-mile passage would
    // become sixty one-mile "legs" all on the same course.
    test('a densified path does not become dozens of legs', () {
      final dense = [
        for (var step = 0; step <= 40; step += 1)
          GeoPoint(latitude: 50.66 - step * 0.02, longitude: -1.59),
      ];
      final plan = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: cherbourg),
          ],
          path: dense,
        ),
      );
      expect(plan.legs, hasLength(1));
    });
  });

  group('a route with no marks', () {
    test('has no legs but still reports how far it is', () {
      final plan = PassagePlan.of(route(path: const [needles, nab, cherbourg]));

      expect(plan.hasLegs, isFalse);
      expect(plan.isUntabulatedTrack, isTrue);
      expect(plan.waypointCount, 0);
      expect(plan.totalDistanceMeters, greaterThan(0));
    });

    test('one mark is not half a leg', () {
      final plan = PassagePlan.of(
        route(waypoints: const [RouteWaypoint(point: needles)]),
      );
      expect(plan.legs, isEmpty);
      expect(plan.waypointCount, 1);
    });

    test('an empty route is empty rather than zero-length', () {
      final plan = PassagePlan.of(route());
      expect(plan.hasLegs, isFalse);
      expect(plan.isUntabulatedTrack, isFalse);
      expect(plan.totalDistanceMeters, 0);
    });
  });

  group('the figures', () {
    final plan = PassagePlan.of(
      route(
        waypoints: const [
          RouteWaypoint(point: needles, name: 'Needles'),
          RouteWaypoint(point: cherbourg, name: 'Cherbourg'),
        ],
      ),
    );

    test('course is the rhumb-line course, true', () {
      // Checkable against the chart: near enough due south.
      expect(plan.legs.single.courseDegreesTrue, closeTo(181, 1.5));
    });

    test('distance matches the chart', () {
      expect(plan.legs.single.distanceMeters / 1852, closeTo(60, 1.5));
    });

    test('time follows the stated speed and nothing else', () {
      // 60 miles at 5 knots is 12 hours.
      expect(plan.planningSpeedKnots, 5);
      expect(plan.totalDuration.inMinutes / 60, closeTo(12, 0.5));

      final quick = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: cherbourg),
          ],
        ),
        planningSpeedKnots: 10,
      );
      expect(
        quick.totalDuration.inSeconds * 2,
        closeTo(plan.totalDuration.inSeconds, 2),
      );
    });

    test('totals are the sum of the legs', () {
      final threeMarks = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: nab),
            RouteWaypoint(point: cherbourg),
          ],
        ),
      );
      final summed = threeMarks.legs.fold<double>(
        0,
        (total, leg) => total + leg.distanceMeters,
      );
      expect(threeMarks.totalDistanceMeters, closeTo(summed, 0.001));
    });

    test('cumulative distance is distance to run at each mark', () {
      final threeMarks = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: nab),
            RouteWaypoint(point: cherbourg),
          ],
        ),
      );
      expect(
        threeMarks.legs.first.cumulativeDistanceMeters,
        closeTo(threeMarks.legs.first.distanceMeters, 0.001),
      );
      expect(
        threeMarks.legs.last.cumulativeDistanceMeters,
        closeTo(threeMarks.totalDistanceMeters, 0.001),
      );
      expect(threeMarks.legs.last.cumulativeDuration, threeMarks.totalDuration);
    });
  });

  group('labels', () {
    test('an unnamed first mark is called Start, not Mark 0', () {
      final plan = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles),
            RouteWaypoint(point: nab),
          ],
        ),
      );
      expect(plan.legs.single.fromLabel, 'Start');
      expect(plan.legs.single.toLabel, 'Mark 1');
    });

    test('a blank name is treated as no name', () {
      final plan = PassagePlan.of(
        route(
          waypoints: const [
            RouteWaypoint(point: needles, name: '   '),
            RouteWaypoint(point: nab, name: ''),
          ],
        ),
      );
      expect(plan.legs.single.fromLabel, 'Start');
      expect(plan.legs.single.toLabel, 'Mark 1');
    });
  });
}
