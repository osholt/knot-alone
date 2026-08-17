import 'dart:math' as math;

import '../domain/geo_point.dart';
import 'geo_calculations.dart';

/// A sailor inside the corridor of the skipper's *actual* recorded track is on
/// route, whatever the planned GPX says. This is the single definition used for
/// alert state, the skipper's off-course count, the roster and the map, so a
/// group following the skipper down a diversion never reads as lost.
///
/// It lives in its own file so the deviation/alert side and the rejoin-routing
/// side can both depend on it without depending on each other.
abstract final class SkipperTrackExemption {
  static const defaultRecentPointLimit = 600;

  /// [skipperTrack] is the skipper's recorded trail. Only the most recent
  /// [recentPointLimit] points are considered: "following the skipper" means
  /// being near where the skipper has recently been, not standing where the
  /// skipper passed two hours ago, and it keeps the check cheap enough to run on
  /// every read.
  static bool isFollowingSkipperTrack({
    required GeoPoint position,
    required List<GeoPoint> skipperTrack,
    double accuracyMeters = 0,
    double corridorMeters = 120,
    int recentPointLimit = defaultRecentPointLimit,
  }) {
    if (skipperTrack.length < 2) return false;
    final recent = skipperTrack.length > recentPointLimit
        ? skipperTrack.sublist(skipperTrack.length - recentPointLimit)
        : skipperTrack;
    final distance = GeoCalculations.distanceToPolylineMeters(position, recent);
    // Give the sailor the benefit of their own GPS error: an uncertain fix
    // beside the skipper's track must not be called off course.
    return math.max(0, distance - accuracyMeters) <= corridorMeters;
  }
}
