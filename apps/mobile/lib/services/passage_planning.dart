/// Passage legs between waypoints, on the water.
///
/// ## What this replaces, and why it had to go
///
/// Destination planning called OSRM's **car driving profile**, and the map's
/// planner additionally fell through to a Valhalla **motorcycle** service. Both
/// are inherited from Tail End Charlie and neither has any concept of water.
/// Asked to plan from Cowes to Cherbourg they do not fail — they confidently
/// return a road route around the coast, through Dover, and present it with
/// turn-by-turn manoeuvres. That is the single most dangerous behaviour a
/// navigation app can have: not missing information, but confident wrong
/// information dressed as a plan (#19).
///
/// ## What this does instead
///
/// Joins the waypoints the sailor chose with rhumb lines: the constant-bearing
/// track that is actually steered on a passage. Great-circle is shorter on long
/// ocean legs, but a coastal passage is planned and helmed as a series of
/// constant courses, and over these distances the difference is metres.
///
/// ## What this deliberately does NOT do
///
/// It does not avoid land, shallows, traffic separation schemes, firing ranges or
/// anything else. It draws the line the sailor asked for and states that plainly
/// through [RoadRouteResult.warnings]. A planner that quietly routed *around* an
/// island would be worse than one that does not pretend to: the sailor would stop
/// checking. Land avoidance needs chart data this build does not have — see
/// `docs/chart-providers.md`.
///
/// It emits **no manoeuvres**. There is no turn-by-turn on a passage, and the
/// guidance surfaces already handle an empty manoeuvre list by saying so.
library;

import 'dart:math' as math;

// GeoPoint deliberately comes from imported_route.dart, which is the one the
// routing interface speaks. The codebase still carries two GeoPoint classes
// (#21); picking the wrong one here fails to compile rather than silently
// converting, which is the only good thing about the duplication.
import '../domain/imported_route.dart' show GeoPoint;
import '../domain/route_preferences.dart';
import 'road_routing.dart' show RoadRouteResult, RoadRoutingService;

/// Metres in a nautical mile.
const _metresPerNauticalMile = 1852.0;

/// Mean Earth radius, matching `GeoCalculations` so distances agree across the
/// app rather than differing in the third decimal depending on who measured.
const _earthRadiusMeters = 6371008.8;

class RhumbLinePassagePlanner implements RoadRoutingService {
  const RhumbLinePassagePlanner({
    this.planningSpeedKnots = defaultPlanningSpeedKnots,
    this.sampleIntervalMeters = _metresPerNauticalMile,
  }) : assert(planningSpeedKnots > 0, 'a passage needs a positive speed'),
       assert(sampleIntervalMeters > 0, 'sampling interval must be positive');

  /// Assumed speed made good, used only to turn distance into a duration.
  ///
  /// Five knots is a defensible cruising average for a small yacht and is
  /// **an assumption, not a measurement**. `PLAN.md` requires an ETA to say
  /// which of its inputs were assumed; the warning this planner returns is where
  /// that is said, and a real ETA needs the sailor's own speed and the tidal
  /// stream (see the tides work).
  static const defaultPlanningSpeedKnots = 5.0;

  final double planningSpeedKnots;

  /// How finely each leg is sampled when drawing.
  ///
  /// A rhumb line is straight on a Mercator chart but curved on the globe the
  /// map actually renders, so a two-point leg would draw visibly off its own
  /// course on a long passage. One nautical mile keeps the drawn line on the
  /// steered course without producing thousands of points.
  final double sampleIntervalMeters;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    // Irrelevant on the water: a rhumb line leaves the first waypoint on the
    // course to the second whichever way the boat happens to be lying.
    double? originBearingDegrees,
  }) async {
    final distinct = _withoutConsecutiveDuplicates(waypoints);
    if (distinct.length < 2) {
      throw const FormatException(
        'A passage needs at least two distinct waypoints.',
      );
    }

    final points = <GeoPoint>[distinct.first];
    var totalMeters = 0.0;
    for (var index = 0; index < distinct.length - 1; index += 1) {
      final from = distinct[index];
      final to = distinct[index + 1];
      final legMeters = rhumbDistanceMeters(from, to);
      totalMeters += legMeters;
      points
        ..addAll(_sampleLeg(from, to, legMeters))
        ..add(to);
    }

    final hours = totalMeters / _metresPerNauticalMile / planningSpeedKnots;
    return RoadRouteResult(
      points: points,
      distanceMeters: totalMeters,
      duration: Duration(seconds: (hours * 3600).round()),
      // No turn-by-turn on a passage. Intentionally empty.
      maneuvers: const [],
      preferences: preferences,
      warnings: warningsFor(planningSpeedKnots),
    );
  }

  /// What any passage planned this way has not accounted for.
  ///
  /// Shared with the leg table rather than restated there: the caveats belong to
  /// how the passage was planned, so a surface showing the figures and the
  /// planner producing them must not be able to disagree about them.
  static List<String> warningsFor(double planningSpeedKnots) => [
    'Legs are direct courses between your waypoints. They are not checked '
        'against land, depth, hazards or traffic schemes — read the chart '
        'and plan the passage yourself.',
    'Times assume ${_formatSpeed(planningSpeedKnots)} made good and ignore '
        'tidal stream, leeway and weather.',
  ];

  /// Points strictly between [from] and [to], excluding both ends.
  List<GeoPoint> _sampleLeg(GeoPoint from, GeoPoint to, double legMeters) {
    final steps = (legMeters / sampleIntervalMeters).floor();
    if (steps <= 1) return const [];
    // Guard against a pathological number of points on a very long leg.
    final capped = math.min(steps, 2000);
    final bearing = rhumbBearingDegrees(from, to);
    return [
      for (var step = 1; step < capped; step += 1)
        _alongRhumbLine(from, bearing, legMeters * step / capped),
    ];
  }

  static String _formatSpeed(double knots) {
    final rounded = knots.roundToDouble();
    final text = knots == rounded
        ? rounded.toStringAsFixed(0)
        : knots.toStringAsFixed(1);
    return '$text kn';
  }

  static List<GeoPoint> _withoutConsecutiveDuplicates(List<GeoPoint> points) {
    final result = <GeoPoint>[];
    for (final point in points) {
      final last = result.isEmpty ? null : result.last;
      if (last != null && rhumbDistanceMeters(last, point) < 0.5) continue;
      result.add(point);
    }
    return result;
  }
}

/// Distance along the constant-bearing track between two points, in metres.
double rhumbDistanceMeters(GeoPoint from, GeoPoint to) {
  final lat1 = _radians(from.latitude);
  final lat2 = _radians(to.latitude);
  final deltaLat = lat2 - lat1;
  final deltaLon = _radians(
    _normaliseLongitudeDelta(to.longitude - from.longitude),
  );
  final deltaPsi = _stretchedLatitudeDelta(lat1, lat2);
  // q is the ratio of northing to stretched northing. On an east-west leg the
  // stretched delta collapses to zero, so fall back to the parallel's cosine.
  final q = deltaPsi.abs() > 1e-12 ? deltaLat / deltaPsi : math.cos(lat1);
  return math.sqrt(deltaLat * deltaLat + q * q * deltaLon * deltaLon) *
      _earthRadiusMeters;
}

/// Constant bearing to steer from [from] to [to], degrees true, `[0, 360)`.
double rhumbBearingDegrees(GeoPoint from, GeoPoint to) {
  final lat1 = _radians(from.latitude);
  final lat2 = _radians(to.latitude);
  final deltaLon = _radians(
    _normaliseLongitudeDelta(to.longitude - from.longitude),
  );
  final deltaPsi = _stretchedLatitudeDelta(lat1, lat2);
  final degrees = math.atan2(deltaLon, deltaPsi) * 180 / math.pi;
  return (degrees + 360) % 360;
}

/// The point reached by steering [bearingDegrees] from [from] for [meters].
GeoPoint _alongRhumbLine(GeoPoint from, double bearingDegrees, double meters) {
  final lat1 = _radians(from.latitude);
  final lon1 = _radians(from.longitude);
  final bearing = _radians(bearingDegrees);
  final angular = meters / _earthRadiusMeters;

  final deltaLat = angular * math.cos(bearing);
  var lat2 = lat1 + deltaLat;
  // Clamp at the poles rather than wrapping over them.
  if (lat2.abs() > math.pi / 2) {
    lat2 = lat2 > 0 ? math.pi - lat2 : -math.pi - lat2;
  }
  final deltaPsi = _stretchedLatitudeDelta(lat1, lat2);
  final q = deltaPsi.abs() > 1e-12 ? deltaLat / deltaPsi : math.cos(lat1);
  final deltaLon = angular * math.sin(bearing) / q;
  final lon2 = lon1 + deltaLon;

  return GeoPoint(
    latitude: lat2 * 180 / math.pi,
    longitude: ((lon2 * 180 / math.pi) + 540) % 360 - 180,
  );
}

/// Difference in Mercator-stretched latitude, which is what makes a
/// constant-bearing track a straight line.
double _stretchedLatitudeDelta(double lat1, double lat2) => math.log(
  math.tan(math.pi / 4 + lat2 / 2) / math.tan(math.pi / 4 + lat1 / 2),
);

double _radians(double degrees) => degrees * math.pi / 180;

double _normaliseLongitudeDelta(double delta) {
  var normalised = delta;
  while (normalised > 180) {
    normalised -= 360;
  }
  while (normalised < -180) {
    normalised += 360;
  }
  return normalised;
}
