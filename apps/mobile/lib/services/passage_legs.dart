/// A passage broken into its legs, the way a navigator reads it.
///
/// The leg table is the working document of a passage plan: for each mark, the
/// course to steer, how far it is, and how long it should take. Everything else
/// on the chart is context for these numbers.
///
/// ## Legs come from waypoints, not from the drawn line
///
/// `ImportedRoute` carries both `waypoints` (the marks chosen) and `paths` (the
/// geometry drawn, densified along each leg by the planner). A leg table built
/// from the path would have hundreds of one-cable "legs" bearing the same course.
/// So legs are derived from waypoints, and a route with fewer than two waypoints
/// has no legs to tabulate rather than a fabricated one — see [PassagePlan.hasLegs].
///
/// That distinction is why an imported GPX *track* often produces no legs: a track
/// is a breadcrumb trail with no marks in it. That is the honest answer, and the
/// total distance is still available from the geometry.
///
/// ## Courses are true, and times are assumptions
///
/// Course is rhumb-line and degrees **true**. Magnetic would need variation, which
/// is chart data this build does not have (#29).
///
/// Times come from a single assumed speed made good. They are not an ETA: no
/// tidal stream, no leeway, no weather. [PassagePlan.planningSpeedKnots] is
/// carried on the plan so a surface can say so next to every figure it shows,
/// which `PLAN.md` requires of anything that looks like an arrival time.
library;

import '../domain/imported_route.dart';
import 'measurement_formatter.dart';
import 'passage_planning.dart';
import 'route_primary_path.dart';

/// One leg, from one mark to the next.
class PassageLeg {
  const PassageLeg({
    required this.number,
    required this.from,
    required this.to,
    required this.courseDegreesTrue,
    required this.distanceMeters,
    required this.duration,
    required this.cumulativeDistanceMeters,
    required this.cumulativeDuration,
  });

  /// One-based, because a navigator counts legs from one.
  final int number;

  final RouteWaypoint from;
  final RouteWaypoint to;

  /// Rhumb-line course to steer, degrees true.
  final double courseDegreesTrue;

  final double distanceMeters;

  /// At the plan's assumed speed. Not an ETA.
  final Duration duration;

  /// Distance and time from the start of the passage to the end of this leg —
  /// "distance to run" at each mark, which is what gets read out loud.
  final double cumulativeDistanceMeters;
  final Duration cumulativeDuration;

  /// The mark's name, or a positional fallback so a row is never blank.
  String get toLabel => _label(to, 'Mark $number');
  String get fromLabel =>
      _label(from, number == 1 ? 'Start' : 'Mark ${number - 1}');

  static String _label(RouteWaypoint waypoint, String fallback) {
    final name = waypoint.name?.trim();
    return name == null || name.isEmpty ? fallback : name;
  }
}

/// Every leg of a passage, with its totals.
class PassagePlan {
  const PassagePlan({
    required this.legs,
    required this.totalDistanceMeters,
    required this.totalDuration,
    required this.planningSpeedKnots,
    required this.waypointCount,
  });

  final List<PassageLeg> legs;
  final double totalDistanceMeters;
  final Duration totalDuration;

  /// The assumption every duration here rests on.
  final double planningSpeedKnots;

  /// How many marks the route carried, so a surface can distinguish "no legs
  /// because there are no marks" from "no legs because there is no route".
  final int waypointCount;

  bool get hasLegs => legs.isNotEmpty;

  /// True when there is geometry but not enough marks to tabulate — an imported
  /// track, typically. The distance is still real; the legs are not available.
  bool get isUntabulatedTrack => legs.isEmpty && totalDistanceMeters > 0;

  static const empty = PassagePlan(
    legs: [],
    totalDistanceMeters: 0,
    totalDuration: Duration.zero,
    planningSpeedKnots: RhumbLinePassagePlanner.defaultPlanningSpeedKnots,
    waypointCount: 0,
  );

  /// Breaks [route] into legs between its waypoints.
  factory PassagePlan.of(
    ImportedRoute route, {
    double planningSpeedKnots =
        RhumbLinePassagePlanner.defaultPlanningSpeedKnots,
  }) {
    assert(planningSpeedKnots > 0, 'a passage needs a positive speed');
    final marks = route.waypoints;
    if (marks.length < 2) {
      // No marks to tabulate. Report the geometry's own length so the surface can
      // still say how far it is.
      final geometry = routePrimaryPath(route);
      var meters = 0.0;
      for (var index = 0; index < geometry.length - 1; index += 1) {
        meters += rhumbDistanceMeters(geometry[index], geometry[index + 1]);
      }
      return PassagePlan(
        legs: const [],
        totalDistanceMeters: meters,
        totalDuration: _durationFor(meters, planningSpeedKnots),
        planningSpeedKnots: planningSpeedKnots,
        waypointCount: marks.length,
      );
    }

    final legs = <PassageLeg>[];
    var cumulative = 0.0;
    for (var index = 0; index < marks.length - 1; index += 1) {
      final from = marks[index];
      final to = marks[index + 1];
      final meters = rhumbDistanceMeters(from.point, to.point);
      cumulative += meters;
      legs.add(
        PassageLeg(
          number: index + 1,
          from: from,
          to: to,
          courseDegreesTrue: rhumbBearingDegrees(from.point, to.point),
          distanceMeters: meters,
          duration: _durationFor(meters, planningSpeedKnots),
          cumulativeDistanceMeters: cumulative,
          cumulativeDuration: _durationFor(cumulative, planningSpeedKnots),
        ),
      );
    }

    return PassagePlan(
      legs: List.unmodifiable(legs),
      totalDistanceMeters: cumulative,
      totalDuration: _durationFor(cumulative, planningSpeedKnots),
      planningSpeedKnots: planningSpeedKnots,
      waypointCount: marks.length,
    );
  }

  static Duration _durationFor(double meters, double knots) {
    final hours = meters / MeasurementFormatter.metresPerNauticalMile / knots;
    return Duration(seconds: (hours * 3600).round());
  }
}
