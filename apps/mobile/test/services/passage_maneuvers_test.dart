import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/passage_legs.dart';
import 'package:tide_and_seek/services/passage_maneuvers.dart';

/// #63. The inherited manoeuvre list came from OSRM road steps — turn left,
/// third exit, get in lane — and #19 deleted the engine that produced them, so
/// it could only ever say "no turn prompts for this route".
///
/// These pin the nautical replacement, and in particular the three things it
/// refuses to do: invent a side to leave a mark on, issue an instruction a helm
/// cannot follow, or take the long way round a course change.
void main() {
  group('an alteration takes the short way round', () {
    test('a turn to starboard', () {
      final plan = _maneuvers([
        _mark('Lymington', 50.70, -1.50),
        _mark('Mark A', 50.70, -1.40), // due east, 090
        _mark('Mark B', 50.80, -1.30), // north-east, about 040
      ]);

      final maneuver = plan.maneuvers.single;
      expect(maneuver.side, TurnSide.port);
      expect(maneuver.markLabel, 'Mark A');
    });

    test('a course change through north is the short way, not the long way', () {
      // 350 to 010 is 20 to starboard. A helm asked to alter 340 to port would
      // put the wheel the wrong way for most of the turn.
      final plan = _maneuversFromCourses([350, 10]);
      final maneuver = plan.maneuvers.single;

      expect(maneuver.alterationDegrees, closeTo(20, 1.5));
      expect(maneuver.side, TurnSide.starboard);
    });

    test('the same change the other way is to port', () {
      final plan = _maneuversFromCourses([10, 350]);
      final maneuver = plan.maneuvers.single;

      expect(maneuver.alterationDegrees, closeTo(20, 1.5));
      expect(maneuver.side, TurnSide.port);
    });

    test('an alteration never exceeds 180 degrees', () {
      // Every pair here is a near-reversal. `[359, 1]` would not do: that is a
      // 2 degree alteration and the threshold correctly filters it out.
      for (final pair in [
        [0, 179],
        [0, 181],
        [90, 271],
        [350, 170],
      ]) {
        final plan = _maneuversFromCourses(
          pair.map((course) => course.toDouble()).toList(),
        );
        expect(
          plan.maneuvers.single.alterationDegrees,
          lessThanOrEqualTo(180),
          reason: 'from ${pair[0]} to ${pair[1]}',
        );
      }
    });
  });

  group('what is not worth an instruction', () {
    test('a small alteration stays off the list and is counted', () {
      // Three degrees is steering noise. A plan that says "alter 3 degrees to
      // port" teaches its reader to skip lines.
      final plan = _maneuversFromCourses([90, 92]);

      expect(plan.maneuvers, isEmpty);
      expect(plan.markCountWithoutAlteration, 1);
      expect(plan.hasManeuvers, isFalse);
    });

    test('the threshold is stated rather than guessed at', () {
      expect(PassageManeuverPlan.minimumAlterationDegrees, 5.0);
    });

    test('a passage of one leg has no manoeuvre', () {
      // Nothing to alter onto at a departure, nothing after an arrival.
      final plan = _maneuvers([
        _mark('Lymington', 50.75, -1.52),
        _mark('Cowes', 50.76, -1.30),
      ]);

      expect(plan.maneuvers, isEmpty);
      expect(plan.markCountWithoutAlteration, 0);
    });

    test('a route with no marks has no manoeuvres', () {
      expect(PassageManeuverPlan.of(PassagePlan.empty).maneuvers, isEmpty);
    });
  });

  group('what a manoeuvre carries', () {
    test('the courses either side of the mark, and the mark itself', () {
      final plan = _maneuversFromCourses([90, 45]);
      final maneuver = plan.maneuvers.single;

      expect(maneuver.inboundCourseDegreesTrue, closeTo(90, 1.5));
      expect(maneuver.outboundCourseDegreesTrue, closeTo(45, 1.5));
      expect(maneuver.mark.name, 'Mark 2');
    });

    test('the leg into the mark, which is the distance left to run', () {
      final plan = _maneuvers([
        _mark('Start', 50.70, -1.50),
        _mark('Middle', 50.70, -1.40),
        _mark('End', 50.80, -1.30),
      ]);
      final maneuver = plan.maneuvers.single;

      // The leg into Middle, not the one out of it.
      expect(maneuver.distanceFromPreviousMeters, greaterThan(0));
      expect(
        maneuver.cumulativeDistanceMeters,
        closeTo(maneuver.distanceFromPreviousMeters, 1),
        reason: 'the first mark is one leg from the start',
      );
      expect(maneuver.timeFromPrevious, greaterThan(Duration.zero));
    });

    test('the planning speed comes through so a time can be qualified', () {
      final plan = PassageManeuverPlan.of(
        PassagePlan.of(
          _route([
            _mark('A', 50.70, -1.50),
            _mark('B', 50.70, -1.40),
            _mark('C', 50.80, -1.30),
          ]),
          planningSpeedKnots: 6.5,
        ),
      );
      expect(plan.planningSpeedKnots, 6.5);
    });

    test('numbering counts manoeuvres, not marks', () {
      // Middle mark is nearly straight through, so it produces nothing and must
      // not consume a number.
      final plan = _maneuversFromCourses([90, 91, 45]);

      expect(plan.markCountWithoutAlteration, 1);
      expect(plan.maneuvers.map((m) => m.number), [1]);
    });

    test('a big alteration is flagged for a second look', () {
      expect(
        _maneuversFromCourses([0, 90]).maneuvers.single.isMajorAlteration,
        isTrue,
      );
      expect(
        _maneuversFromCourses([0, 20]).maneuvers.single.isMajorAlteration,
        isFalse,
      );
    });
  });

  group('a passage of several alterations', () {
    test('one manoeuvre per mark that needs one, in order', () {
      final plan = _maneuversFromCourses([0, 90, 180, 270]);

      expect(plan.maneuvers.length, 3);
      expect(plan.maneuvers.map((m) => m.side), [
        TurnSide.starboard,
        TurnSide.starboard,
        TurnSide.starboard,
      ]);
      expect(plan.maneuvers.map((m) => m.number), [1, 2, 3]);
      // Distance to run grows along the passage.
      final cumulative = plan.maneuvers
          .map((m) => m.cumulativeDistanceMeters)
          .toList();
      expect(cumulative, orderedEquals(cumulative.toList()..sort()));
    });
  });
}

RouteWaypoint _mark(String name, double latitude, double longitude) =>
    RouteWaypoint(
      name: name,
      point: GeoPoint(latitude: latitude, longitude: longitude),
    );

ImportedRoute _route(List<RouteWaypoint> marks) => ImportedRoute(
  id: 'passage',
  name: 'Passage',
  importedAt: DateTime.utc(2026, 8, 19),
  sourceFileName: 'passage.gpx',
  paths: [
    RoutePath(
      kind: RoutePathKind.route,
      points: marks.map((mark) => mark.point).toList(growable: false),
    ),
  ],
  waypoints: marks,
);

PassageManeuverPlan _maneuvers(List<RouteWaypoint> marks) =>
    PassageManeuverPlan.of(PassagePlan.of(_route(marks)));

/// Builds a passage whose successive legs run on [courses], by walking two miles
/// along each in turn. Lets a test say what it means — "350 then 010" — rather
/// than hand-computing latitudes, and keeps the trigonometry out of the library
/// under test, which has none: courses arrive already computed by `PassagePlan`.
PassageManeuverPlan _maneuversFromCourses(List<double> courses) {
  const degreesPerNauticalMile = 1 / 60;
  // Two miles a leg, so a degree of rounding does not swamp the bearing.
  const legMiles = 2.0;
  var latitude = 50.5;
  var longitude = -1.5;
  final marks = <RouteWaypoint>[_mark('Mark 1', latitude, longitude)];

  for (var index = 0; index < courses.length; index += 1) {
    final radians = courses[index] * math.pi / 180;
    latitude += legMiles * degreesPerNauticalMile * math.cos(radians);
    longitude +=
        legMiles *
        degreesPerNauticalMile *
        math.sin(radians) /
        math.cos(latitude * math.pi / 180);
    marks.add(_mark('Mark ${index + 2}', latitude, longitude));
  }
  return _maneuvers(marks);
}
