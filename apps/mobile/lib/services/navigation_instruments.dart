/// The numbers a navigator steers by, and what each of them rests on.
///
/// ## Why every value carries a basis
///
/// `PLAN.md` requires that measured, calculated, assumed and unknown values stay
/// distinguishable, and that a stale or inaccurate fix visibly degrades
/// everything derived from it. That is not presentation polish. A frozen SOG
/// still reading 5.2 kn because the last fix was four minutes ago is the failure
/// mode: the number looks exactly as trustworthy as it did when it was true.
///
/// So each instrument is an [Instrument] that knows whether it was measured by
/// the GNSS receiver, calculated from the plan, or assumed — and the whole set
/// knows how old the fix is. Nothing here silently substitutes one for another.
///
/// ## COG, not heading
///
/// This app has no compass input and no log. Every direction here is **course
/// over ground** from successive GNSS fixes, and every speed is **speed over
/// ground**. Heading (where the bow points) and speed through water are
/// different quantities that differ from these by the tidal stream and leeway —
/// which is exactly the difference a sailor cares about — so they are not
/// claimed. When instrument input arrives (#16) they belong in separate fields,
/// never merged into these.
///
/// ## What is deliberately absent
///
/// No recommended course. Cross-track error says which side of the track the
/// vessel is on; it does not say what to steer, because that depends on the
/// stream, the wind and what the sailor can see.
library;

import 'dart:math' as math;

import '../domain/imported_route.dart' show GeoPoint;
import 'passage_legs.dart';
import 'passage_planning.dart';

/// Where a displayed value came from.
enum InstrumentBasis {
  /// Reported by the GNSS receiver.
  measured,

  /// Derived from measured values and the plan.
  calculated,

  /// Rests on a stated assumption, such as a planning speed.
  assumed,

  /// Not available, with a reason.
  unavailable,
}

/// One displayed value, with its provenance.
class Instrument {
  const Instrument.measured(double this.value)
    : basis = InstrumentBasis.measured,
      reason = null;
  const Instrument.calculated(double this.value)
    : basis = InstrumentBasis.calculated,
      reason = null;
  const Instrument.assumed(double this.value)
    : basis = InstrumentBasis.assumed,
      reason = null;
  const Instrument.unavailable(this.reason)
    : basis = InstrumentBasis.unavailable,
      value = null;

  final double? value;
  final InstrumentBasis basis;

  /// Why there is no value. Shown instead of the value, never in place of one.
  final String? reason;

  bool get isAvailable => value != null;
}

/// Which side of the planned track the vessel is on.
enum TrackSide {
  port,
  starboard;

  /// The side to steer toward to close the error, which is the other one.
  TrackSide get opposite =>
      this == TrackSide.port ? TrackSide.starboard : TrackSide.port;

  String get label => this == TrackSide.port ? 'port' : 'starboard';
}

/// A GNSS fix, as the instruments need it.
class NavigationFix {
  const NavigationFix({
    required this.point,
    required this.recordedAt,
    this.courseOverGroundDegrees,
    this.speedOverGroundMetersPerSecond,
    this.accuracyMeters,
  });

  final GeoPoint point;
  final DateTime recordedAt;

  /// Course over ground, degrees true. Null when the receiver cannot say —
  /// typically because the vessel is not moving, when COG is meaningless.
  final double? courseOverGroundDegrees;

  final double? speedOverGroundMetersPerSecond;
  final double? accuracyMeters;

  Duration ageAt(DateTime now) {
    final age = now.difference(recordedAt);
    return age.isNegative ? Duration.zero : age;
  }
}

/// How old or inaccurate a fix may be before what depends on it is suspect.
class NavigationFixPolicy {
  const NavigationFixPolicy({
    this.staleAfter = const Duration(seconds: 12),
    this.poorAccuracyMeters = 50,
  });

  /// Twelve seconds. A yacht at 6 knots moves 37 metres in that time, which is
  /// about the width of the corridor the deviation detector works in - so past
  /// this point a cross-track error is arguing about a position the vessel has
  /// already left.
  final Duration staleAfter;

  /// Beyond this, a fix is too coarse to derive a cross-track error from.
  final double poorAccuracyMeters;
}

/// Everything the instrument panel shows, computed once per fix.
class NavigationInstruments {
  const NavigationInstruments({
    required this.courseOverGround,
    required this.speedOverGround,
    required this.bearingToMark,
    required this.distanceToMark,
    required this.crossTrackError,
    required this.velocityMadeGood,
    required this.fixAge,
    required this.fixIsStale,
    required this.accuracyIsPoor,
    this.activeLeg,
    this.offTrackSide,
    this.timeToMark,
    this.timeToDestination,
    this.distanceToDestination,
  });

  final Instrument courseOverGround;
  final Instrument speedOverGround;

  /// Rhumb-line bearing and distance to the next mark.
  final Instrument bearingToMark;
  final Instrument distanceToMark;

  /// Distance from the planned track, always positive. [offTrackSide] says which
  /// side of it the vessel is on.
  final Instrument crossTrackError;
  final TrackSide? offTrackSide;

  /// Speed of closing the next mark, which is SOG only when steering straight at
  /// it. Negative when the vessel is opening the mark rather than closing it.
  final Instrument velocityMadeGood;

  final Duration fixAge;

  /// True when the fix is older than the policy allows. Every calculated value
  /// here is suspect when this is true, and the panel says so once rather than
  /// per row.
  final bool fixIsStale;

  final bool accuracyIsPoor;

  final PassageLeg? activeLeg;

  /// Time to the next mark and to the end, at the *measured* closing speed - not
  /// at the plan's assumed speed. Absent when not closing.
  final Duration? timeToMark;
  final Duration? timeToDestination;
  final Instrument? distanceToDestination;

  bool get hasActiveLeg => activeLeg != null;

  /// Computes the instruments for [fix] against [plan].
  ///
  /// [plan] with no legs yields position-only instruments: a sailor with no
  /// passage still wants COG and SOG.
  static NavigationInstruments compute({
    required NavigationFix fix,
    required PassagePlan plan,
    required DateTime now,
    NavigationFixPolicy policy = const NavigationFixPolicy(),
  }) {
    final age = fix.ageAt(now);
    final stale = age > policy.staleAfter;
    final poorAccuracy = (fix.accuracyMeters ?? 0) > policy.poorAccuracyMeters;

    final cog = fix.courseOverGroundDegrees == null
        ? const Instrument.unavailable('No course while stopped')
        : Instrument.measured(fix.courseOverGroundDegrees!);
    final sog = fix.speedOverGroundMetersPerSecond == null
        ? const Instrument.unavailable('Receiver reports no speed')
        : Instrument.measured(fix.speedOverGroundMetersPerSecond!);

    final leg = _activeLeg(fix.point, plan);
    if (leg == null) {
      return NavigationInstruments(
        courseOverGround: cog,
        speedOverGround: sog,
        bearingToMark: const Instrument.unavailable('No passage'),
        distanceToMark: const Instrument.unavailable('No passage'),
        crossTrackError: const Instrument.unavailable('No passage'),
        velocityMadeGood: const Instrument.unavailable('No passage'),
        fixAge: age,
        fixIsStale: stale,
        accuracyIsPoor: poorAccuracy,
      );
    }

    final bearing = rhumbBearingDegrees(fix.point, leg.to.point);
    final distance = rhumbDistanceMeters(fix.point, leg.to.point);

    // Cross-track error needs a fix good enough to be worth measuring against a
    // line. A 200 m fix cannot tell a sailor they are 80 m off track.
    final (crossTrack, side) = poorAccuracy
        ? (
            Instrument.unavailable(
              'Fix accurate to ${fix.accuracyMeters!.round()} m',
            ),
            null,
          )
        : _crossTrack(fix.point, leg);

    final vmg = _velocityMadeGood(fix, bearing);

    // Time to run at the *measured* closing speed. Absent when the vessel is not
    // closing the mark, because "arriving in -3 minutes" is not a time.
    final closing = vmg.value;
    final toMark = closing == null || closing <= 0.05
        ? null
        : Duration(seconds: (distance / closing).round());

    final remaining =
        plan.totalDistanceMeters -
        (leg.cumulativeDistanceMeters - leg.distanceMeters);
    final toDestination = closing == null || closing <= 0.05
        ? null
        : Duration(
            seconds:
                ((distance +
                            (remaining - leg.distanceMeters).clamp(
                              0,
                              double.infinity,
                            )) /
                        closing)
                    .round(),
          );

    return NavigationInstruments(
      courseOverGround: cog,
      speedOverGround: sog,
      bearingToMark: Instrument.calculated(bearing),
      distanceToMark: Instrument.calculated(distance),
      crossTrackError: crossTrack,
      offTrackSide: side,
      velocityMadeGood: vmg,
      fixAge: age,
      fixIsStale: stale,
      accuracyIsPoor: poorAccuracy,
      activeLeg: leg,
      timeToMark: toMark,
      timeToDestination: toDestination,
      distanceToDestination: Instrument.calculated(
        distance + (remaining - leg.distanceMeters).clamp(0, double.infinity),
      ),
    );
  }

  /// The leg the vessel is on: the one whose track it is nearest.
  ///
  /// Nearest rather than "first not yet passed", because a sailor who has been
  /// blown back down the passage, or who joins it in the middle, is on the leg
  /// they are actually near - not the one a counter says is next.
  static PassageLeg? _activeLeg(GeoPoint position, PassagePlan plan) {
    if (!plan.hasLegs) return null;
    PassageLeg? nearest;
    var nearestDistance = double.infinity;
    for (final leg in plan.legs) {
      final distance = _distanceToSegmentMeters(
        position,
        leg.from.point,
        leg.to.point,
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearest = leg;
      }
    }
    return nearest;
  }

  static (Instrument, TrackSide?) _crossTrack(
    GeoPoint position,
    PassageLeg leg,
  ) {
    final distance = _distanceToSegmentMeters(
      position,
      leg.from.point,
      leg.to.point,
    );
    // Sign from the cross product of the track and the vessel's offset: positive
    // means the vessel is to starboard of the track.
    final trackBearing = rhumbBearingDegrees(leg.from.point, leg.to.point);
    final toVessel = rhumbBearingDegrees(leg.from.point, position);
    final difference = ((toVessel - trackBearing + 540) % 360) - 180;
    if (distance < 1) return (const Instrument.calculated(0), null);
    return (
      Instrument.calculated(distance),
      difference >= 0 ? TrackSide.starboard : TrackSide.port,
    );
  }

  static Instrument _velocityMadeGood(NavigationFix fix, double bearingToMark) {
    final speed = fix.speedOverGroundMetersPerSecond;
    final course = fix.courseOverGroundDegrees;
    if (speed == null || course == null) {
      return const Instrument.unavailable('Needs course and speed');
    }
    final offset = ((course - bearingToMark + 540) % 360) - 180;
    return Instrument.calculated(speed * math.cos(offset * math.pi / 180));
  }

  static double _distanceToSegmentMeters(
    GeoPoint point,
    GeoPoint start,
    GeoPoint end,
  ) {
    // Local flat approximation: over a single leg the error is far below the
    // precision a cross-track error is read at.
    final latitudeScale = math.cos(
      (start.latitude + end.latitude) / 2 * math.pi / 180,
    );
    final px = (point.longitude - start.longitude) * latitudeScale;
    final py = point.latitude - start.latitude;
    final ex = (end.longitude - start.longitude) * latitudeScale;
    final ey = end.latitude - start.latitude;
    final lengthSquared = ex * ex + ey * ey;
    final t = lengthSquared == 0
        ? 0.0
        : ((px * ex + py * ey) / lengthSquared).clamp(0.0, 1.0);
    final dx = px - ex * t;
    final dy = py - ey * t;
    // One degree of latitude in metres, which is what both axes are now scaled in.
    return math.sqrt(dx * dx + dy * dy) * 111132.0;
  }
}
