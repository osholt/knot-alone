import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/sailor_location.dart';

/// Conservative, skipper-owned completion check for a group voyage.
///
/// A voyage only ends after the route has actually been ridden *and* every sailor
/// with a known position has sent a recent fix inside the destination radius.
/// Stale data therefore keeps the voyage open rather than accidentally ending it
/// while somebody has dropped signal.
///
/// The progress gate exists because proximity alone is not arrival (#206). A day
/// tour is normally a loop: it starts and finishes at the same hotel, so every
/// sailor satisfies the radius test at the moment the voyage begins. A tester's
/// Isle of Man tour ended itself twenty minutes in for exactly that reason, and
/// could not be resumed.
///
/// The two failure directions are not symmetric. Ending a voyage early strands the
/// group mid-route and cannot be undone from a sailor's phone; failing to end one
/// automatically costs the skipper a single tap. The gate is therefore set high on
/// purpose.
class VoyageCompletionDetector {
  const VoyageCompletionDetector({
    this.destinationRadiusMeters = 90,
    this.locationFreshness = const Duration(minutes: 2),
    this.minimumRouteProgressFraction = 0.9,
  });

  final double destinationRadiusMeters;
  final Duration locationFreshness;

  /// How much of the route must be behind the group before arrival is even
  /// considered, as a fraction of the primary path's length.
  final double minimumRouteProgressFraction;

  /// Returns the evidence behind a completion suggestion rather than only a
  /// boolean. The skipper sees these counts before deciding whether to end the
  /// voyage, so an automatic detector never hides why it fired (#244).
  VoyageCompletionAssessment assess({
    required GeoPoint destination,
    required Iterable<SailorLocation> sailorLocations,
    required DateTime now,
    required double routeProgressFraction,
  }) {
    final latestBySailor = <String, SailorLocation>{
      for (final location in sailorLocations) location.sailorId: location,
    };
    var freshSailorCount = 0;
    var arrivedSailorCount = 0;
    for (final location in latestBySailor.values) {
      if (location.sample.isStaleAt(now, locationFreshness)) continue;
      freshSailorCount += 1;
      if (_distanceMeters(location.sample.position, destination) <=
          destinationRadiusMeters) {
        arrivedSailorCount += 1;
      }
    }
    return VoyageCompletionAssessment(
      routeProgressFraction: routeProgressFraction,
      minimumRouteProgressFraction: minimumRouteProgressFraction,
      destinationRadiusMeters: destinationRadiusMeters,
      sailorCount: latestBySailor.length,
      freshSailorCount: freshSailorCount,
      arrivedSailorCount: arrivedSailorCount,
    );
  }

  /// [routeProgressFraction] is monotonic progress along the route, 0 to 1, as
  /// tracked by `RouteProgressTracker`. A route with no measurable length must
  /// pass 0 so that a degenerate plan can never end a voyage on its own.
  bool everyoneReachedDestination({
    required GeoPoint destination,
    required Iterable<SailorLocation> sailorLocations,
    required DateTime now,
    required double routeProgressFraction,
  }) {
    return assess(
      destination: destination,
      sailorLocations: sailorLocations,
      now: now,
      routeProgressFraction: routeProgressFraction,
    ).ready;
  }
}

class VoyageCompletionAssessment {
  const VoyageCompletionAssessment({
    required this.routeProgressFraction,
    required this.minimumRouteProgressFraction,
    required this.destinationRadiusMeters,
    required this.sailorCount,
    required this.freshSailorCount,
    required this.arrivedSailorCount,
  });

  final double routeProgressFraction;
  final double minimumRouteProgressFraction;
  final double destinationRadiusMeters;
  final int sailorCount;
  final int freshSailorCount;
  final int arrivedSailorCount;

  bool get routeProgressReached =>
      routeProgressFraction.isFinite &&
      routeProgressFraction >= minimumRouteProgressFraction;

  bool get ready =>
      routeProgressReached &&
      sailorCount > 0 &&
      freshSailorCount == sailorCount &&
      arrivedSailorCount == sailorCount;
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadiusMeters = 6371008.8;
  final latitude1 = first.latitude * math.pi / 180;
  final latitude2 = second.latitude * math.pi / 180;
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
