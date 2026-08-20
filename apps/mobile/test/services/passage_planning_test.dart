import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/passage_planning.dart';

/// #19. Destination planning used to call OSRM's car driving profile, with a
/// Valhalla motorcycle service behind it. Asked to plan across water neither
/// fails — they return a confident road route around the coast. These tests pin
/// the replacement, and in particular the two properties that make it honest:
/// it draws the course asked for rather than inventing one, and it says what it
/// has not checked.
void main() {
  // Real marks, so the expected figures below are checkable against a chart.
  const needles = GeoPoint(latitude: 50.6620, longitude: -1.5900);
  const cherbourg = GeoPoint(latitude: 49.6600, longitude: -1.6200);
  const nab = GeoPoint(latitude: 50.6700, longitude: -0.9500);

  group('rhumb-line geometry', () {
    test('a due-south leg bears 180 and measures its latitude difference', () {
      const from = GeoPoint(latitude: 51, longitude: -1);
      const to = GeoPoint(latitude: 50, longitude: -1);

      expect(rhumbBearingDegrees(from, to), closeTo(180, 0.001));
      // One degree of latitude is 60 nautical miles by definition.
      expect(rhumbDistanceMeters(from, to) / 1852, closeTo(60, 0.2));
    });

    test('a due-north leg bears 000', () {
      expect(
        rhumbBearingDegrees(
          const GeoPoint(latitude: 50, longitude: -1),
          const GeoPoint(latitude: 51, longitude: -1),
        ),
        closeTo(0, 0.001),
      );
    });

    test('a due-east leg bears 090 and shortens with latitude', () {
      const west = GeoPoint(latitude: 50, longitude: -1);
      const east = GeoPoint(latitude: 50, longitude: 0);
      expect(rhumbBearingDegrees(west, east), closeTo(90, 0.001));

      // A degree of longitude at 50N is about cos(50) of one at the equator.
      final atFifty = rhumbDistanceMeters(west, east);
      final atEquator = rhumbDistanceMeters(
        const GeoPoint(latitude: 0, longitude: -1),
        const GeoPoint(latitude: 0, longitude: 0),
      );
      expect(atFifty / atEquator, closeTo(0.643, 0.01));
    });

    test('the cross-Channel leg matches the chart', () {
      // The Needles to Cherbourg is about 60 nautical miles, near enough due
      // south. This is the passage the road router would have sent through the
      // Channel Tunnel.
      final miles = rhumbDistanceMeters(needles, cherbourg) / 1852;
      expect(miles, closeTo(60, 1.5));
      expect(rhumbBearingDegrees(needles, cherbourg), closeTo(181, 1.5));
    });

    test('distance is symmetric and the reciprocal bearing is 180 off', () {
      final there = rhumbBearingDegrees(needles, nab);
      final back = rhumbBearingDegrees(nab, needles);
      expect(
        rhumbDistanceMeters(needles, nab),
        closeTo(rhumbDistanceMeters(nab, needles), 0.001),
      );
      expect((there - back).abs(), closeTo(180, 0.5));
    });

    test('a leg across the antimeridian takes the short way round', () {
      const west = GeoPoint(latitude: 10, longitude: 179.5);
      const east = GeoPoint(latitude: 10, longitude: -179.5);
      // One degree of longitude at 10N, not 359 of them.
      expect(rhumbDistanceMeters(west, east) / 1852, closeTo(59.1, 1));
      expect(rhumbBearingDegrees(west, east), closeTo(90, 0.5));
    });
  });

  group('the planner', () {
    const planner = RhumbLinePassagePlanner();

    test('joins the waypoints given, keeping every one of them', () async {
      final result = await planner.planThrough([needles, cherbourg, nab]);

      expect(result.points.first, needles);
      expect(result.points.last, nab);
      expect(result.points, contains(cherbourg));
      // Sampled along each leg so the drawn line follows the steered course.
      expect(result.points.length, greaterThan(50));
    });

    test('distance is the sum of its legs, not the direct line', () async {
      final result = await planner.planThrough([needles, cherbourg, nab]);
      final legs =
          rhumbDistanceMeters(needles, cherbourg) +
          rhumbDistanceMeters(cherbourg, nab);

      expect(result.distanceMeters, closeTo(legs, 1));
      expect(
        result.distanceMeters,
        greaterThan(rhumbDistanceMeters(needles, nab)),
      );
    });

    test('says it has not checked the course against anything', () async {
      final result = await planner.planThrough([needles, cherbourg]);
      final warnings = result.warnings.join(' ').toLowerCase();

      expect(result.warnings, isNotEmpty);
      expect(warnings, contains('direct courses'));
      expect(warnings, contains('land'));
      expect(warnings, contains('not checked'));
    });

    test('says its timing is an assumption, not an ETA', () async {
      final result = await planner.planThrough([needles, cherbourg]);
      final warnings = result.warnings.join(' ').toLowerCase();

      expect(warnings, contains('assume'));
      expect(warnings, contains('tidal stream'));
      expect(warnings, contains('5 kn'));
    });

    test('duration follows the assumed speed', () async {
      const slow = RhumbLinePassagePlanner(planningSpeedKnots: 5);
      const fast = RhumbLinePassagePlanner(planningSpeedKnots: 10);

      final slowResult = await slow.planThrough([needles, cherbourg]);
      final fastResult = await fast.planThrough([needles, cherbourg]);

      // 60 miles at 5 knots is about 12 hours.
      expect(slowResult.duration.inMinutes / 60, closeTo(12, 0.5));
      expect(
        slowResult.duration.inSeconds,
        closeTo(fastResult.duration.inSeconds * 2, 2),
      );
      expect(fastResult.warnings.join(' '), contains('10 kn'));
    });

    test('a repeated waypoint does not create a zero-length leg', () async {
      final result = await planner.planThrough([needles, needles, cherbourg]);
      expect(
        result.distanceMeters,
        closeTo(rhumbDistanceMeters(needles, cherbourg), 1),
      );
    });

    test('refuses a passage that goes nowhere', () async {
      expect(
        () => planner.planThrough([needles]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => planner.planThrough([needles, needles]),
        throwsA(isA<FormatException>()),
      );
      expect(() => planner.planThrough([]), throwsA(isA<FormatException>()));
    });

    test('a very short leg is not sampled into noise', () async {
      const a = GeoPoint(latitude: 50.7000, longitude: -1.3000);
      const b = GeoPoint(latitude: 50.7010, longitude: -1.3000);
      final result = await planner.planThrough([a, b]);
      expect(result.points, [a, b]);
    });

    test('sampled points stay on the rhumb line', () async {
      final result = await planner.planThrough([needles, cherbourg]);
      final bearing = rhumbBearingDegrees(needles, cherbourg);
      // Every sampled point should lie on the same constant course from the
      // start. A great-circle sampler would drift off it.
      for (final point in result.points.skip(1)) {
        expect(
          rhumbBearingDegrees(needles, point),
          closeTo(bearing, 0.5),
          reason: '$point is off the steered course',
        );
      }
    });
  });
}
