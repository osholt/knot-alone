/// The alterations of course a passage asks for, at the marks they happen at.
///
/// ## Why this is not the manoeuvre list it replaces
///
/// The inherited list came from driving directions: turn left, third exit, get
/// in lane. None of that has a marine equivalent, so it was replaced rather
/// than renamed (#63).
///
/// A nautical manoeuvre differs from a road one in nearly every part. You do not
/// turn, you **alter course**, and by a stated number of degrees. You alter onto
/// a **course**, three figures and true, not onto a named street. You do not
/// arrive at a mark, you **pass** it. And distance is cables inside a mile,
/// because that is what gets said out loud.
///
/// ## Derived, not fetched
///
/// A manoeuvre is what happens *between* two consecutive [PassageLeg]s, so
/// everything needed is already on the plan: the inbound course, the outbound
/// course, the mark between them, and how far and how long to get there. No
/// service is called and nothing can be stale.
///
/// ## What this deliberately does not claim
///
/// **Which side to leave the mark.** That depends on the mark being an object
/// with a side, and this app models a mark as a bare position the track runs
/// *through*. Deriving "leave it to port" from geometry would be inventing
/// information, which is the failure #19 exists to prevent. It needs buoyage
/// data — see #17 and `docs/chart-providers.md`.
///
/// **A wheel-over point.** Starting a turn early enough to settle on the new
/// course needs the vessel's turning circle, which the app does not know.
library;

import '../domain/imported_route.dart';
import 'passage_legs.dart';

/// Which way the helm goes.
enum TurnSide {
  port,
  starboard;

  String get label => switch (this) {
    TurnSide.port => 'port',
    TurnSide.starboard => 'starboard',
  };
}

/// One alteration of course, at the mark where it happens.
class PassageManeuver {
  const PassageManeuver({
    required this.number,
    required this.mark,
    required this.markLabel,
    required this.inboundCourseDegreesTrue,
    required this.outboundCourseDegreesTrue,
    required this.alterationDegrees,
    required this.side,
    required this.distanceFromPreviousMeters,
    required this.timeFromPrevious,
    required this.cumulativeDistanceMeters,
    required this.cumulativeDuration,
  });

  /// One-based, counted over the manoeuvres themselves rather than over the
  /// marks — a mark that needs no alteration does not consume a number.
  final int number;

  final RouteWaypoint mark;

  /// The mark's name, or the leg table's positional fallback, so a row is never
  /// blank.
  final String markLabel;

  final double inboundCourseDegreesTrue;
  final double outboundCourseDegreesTrue;

  /// How far to alter, in degrees, always positive. `0..180`.
  final double alterationDegrees;

  /// Which way to alter. Meaningless when [alterationDegrees] is zero, which
  /// cannot happen here because such a mark produces no manoeuvre at all.
  final TurnSide side;

  /// The leg *into* this mark — "distance to run" before the alteration.
  final double distanceFromPreviousMeters;
  final Duration timeFromPrevious;

  /// From the start of the passage to this mark.
  final double cumulativeDistanceMeters;
  final Duration cumulativeDuration;

  /// True for an alteration big enough to be worth a second look on the chart.
  ///
  /// Sixty degrees is a judgement, not a standard: it is about the point at
  /// which a yacht loses and regains the wind on a new point of sail, and where
  /// a plan is worth checking for what the new course now runs towards.
  bool get isMajorAlteration => alterationDegrees >= 60;
}

/// The manoeuvres of one passage.
class PassageManeuverPlan {
  const PassageManeuverPlan({
    required this.maneuvers,
    required this.markCountWithoutAlteration,
    required this.planningSpeedKnots,
  });

  final List<PassageManeuver> maneuvers;

  /// Marks that fell below [PassageManeuverPlan.minimumAlterationDegrees].
  ///
  /// Reported rather than dropped silently: a passage of eleven marks that
  /// produces three manoeuvres should be able to say why the other six were not
  /// worth an instruction, instead of leaving a navigator to wonder what was
  /// lost.
  final int markCountWithoutAlteration;

  /// Carried through so a surface showing a time can say what it assumed, which
  /// `PLAN.md` requires of anything resembling an arrival time.
  final double planningSpeedKnots;

  /// Below this, an alteration is steering noise rather than an instruction.
  ///
  /// A helm cannot hold a course to within a couple of degrees on a moving boat,
  /// and a plan that says "alter 3° to port" teaches its reader to skip lines.
  /// Those marks stay in the leg table, where the course for each leg is stated
  /// exactly; they just do not become instructions.
  static const minimumAlterationDegrees = 5.0;

  bool get hasManeuvers => maneuvers.isNotEmpty;

  static const empty = PassageManeuverPlan(
    maneuvers: [],
    markCountWithoutAlteration: 0,
    planningSpeedKnots: 0,
  );

  /// Derives the manoeuvres of [plan].
  ///
  /// The first and last marks are not manoeuvres: there is nothing to alter onto
  /// at a departure and nothing after an arrival. So a two-mark passage — one
  /// leg, one course — correctly has none.
  factory PassageManeuverPlan.of(PassagePlan plan) {
    if (plan.legs.length < 2) {
      return PassageManeuverPlan(
        maneuvers: const [],
        markCountWithoutAlteration: 0,
        planningSpeedKnots: plan.planningSpeedKnots,
      );
    }

    final maneuvers = <PassageManeuver>[];
    var skipped = 0;
    for (var index = 0; index < plan.legs.length - 1; index += 1) {
      final inbound = plan.legs[index];
      final outbound = plan.legs[index + 1];
      final alteration = _alteration(
        inbound.courseDegreesTrue,
        outbound.courseDegreesTrue,
      );

      if (alteration.degrees < PassageManeuverPlan.minimumAlterationDegrees) {
        skipped += 1;
        continue;
      }

      maneuvers.add(
        PassageManeuver(
          number: maneuvers.length + 1,
          // The mark between the two legs is the end of the inbound one.
          mark: inbound.to,
          markLabel: inbound.toLabel,
          inboundCourseDegreesTrue: inbound.courseDegreesTrue,
          outboundCourseDegreesTrue: outbound.courseDegreesTrue,
          alterationDegrees: alteration.degrees,
          side: alteration.side,
          distanceFromPreviousMeters: inbound.distanceMeters,
          timeFromPrevious: inbound.duration,
          cumulativeDistanceMeters: inbound.cumulativeDistanceMeters,
          cumulativeDuration: inbound.cumulativeDuration,
        ),
      );
    }

    return PassageManeuverPlan(
      maneuvers: List.unmodifiable(maneuvers),
      markCountWithoutAlteration: skipped,
      planningSpeedKnots: plan.planningSpeedKnots,
    );
  }
}

/// Signed difference between two courses, resolved to a magnitude and a side.
///
/// Taking the short way round is what matters: 350° to 010° is 20° to starboard,
/// not 340° to port. A helm asked to alter 340° would put the wheel the wrong
/// way for most of the turn.
({double degrees, TurnSide side}) _alteration(double inbound, double outbound) {
  final difference = ((outbound - inbound + 540) % 360) - 180;
  return (
    degrees: difference.abs(),
    // Exactly 180° is a reversal, which has no side. Reported as starboard
    // because a helm must be told something, and a passage that doubles back on
    // itself is a plan worth re-reading rather than a turn worth optimising.
    side: difference < 0 ? TurnSide.port : TurnSide.starboard,
  );
}
