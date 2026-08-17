import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/voyage_role.dart';
import '../domain/sailor_location.dart';
import '../domain/route_alert.dart';
import 'geo_calculations.dart';
import 'skipper_track_exemption.dart';

class SkipperOffCourseAlert {
  const SkipperOffCourseAlert({
    required this.sailorId,
    required this.displayName,
    required this.level,
    this.distanceFromRouteMeters,
  });

  final String sailorId;
  final String displayName;
  final RouteAlertLevel level;
  final double? distanceFromRouteMeters;
}

/// Whether a voyage has a Sweeper, and how usable that TEC's position
/// is. The app is named after the back-marker role, so "nobody is TEC" is a
/// different safety situation from "the TEC has not reported a position yet",
/// and the two must never be conflated.
///
/// Consumers must branch on this rather than infer a state from a null name,
/// distance or age.
enum SweeperAvailability {
  /// No sailor holds the Sweeper role. Every distance-to-TEC surface
  /// is hidden rather than shown empty, dashed or zeroed, and features that
  /// target the TEC (for example rejoin routing for a massively off-course
  /// sailor) must fall back to the voyage skipper instead of a null target.
  none,

  /// A sailor holds the role but has not reported a position yet, so there is
  /// no gap and no age to show. Surfaces show the waiting state anchored by
  /// issue #88. [SkipperVoyageStatus.sweeperName], [SkipperVoyageStatus.sweeperLocationAge],
  /// [SkipperVoyageStatus.distanceToSweeperMeters] and
  /// [SkipperVoyageStatus.estimatedTimeToSweeper] are all null;
  /// [SkipperVoyageStatus.sweeperSailorId] identifies the registered TEC.
  awaitingLocation,

  /// The TEC's last known position is older than
  /// [SkipperVoyageStatusCalculator.staleAfter]. Surfaces show that age honestly
  /// and deliberately withhold a gap that can no longer be trusted, so
  /// [SkipperVoyageStatus.sweeperLocationAge] is set while
  /// [SkipperVoyageStatus.distanceToSweeperMeters] and
  /// [SkipperVoyageStatus.estimatedTimeToSweeper] are null.
  stale,

  /// The TEC's position is fresh. [SkipperVoyageStatus.sweeperLocationAge] is set,
  /// and the gap is present whenever the skipper also has a position of their
  /// own to measure from.
  tracking,
}

/// Who the Sweeper is, how usable their position is, and their last
/// known fix.
///
/// Resolved once by [SkipperVoyageStatusCalculator.resolveSweeperTarget] so the
/// skipper's TEC card and any feature that routes to the back-marker (rejoin
/// routing for a massively off-course sailor, #102) cannot disagree about
/// whether there is a TEC or whether its position can be believed.
class SweeperTarget {
  const SweeperTarget({
    required this.availability,
    this.sailorId,
    this.location,
  });

  final SweeperAvailability availability;

  /// The sailor holding the role, for every registered state including
  /// [SweeperAvailability.awaitingLocation].
  final String? sailorId;

  /// The TEC's newest known fix. Null for [SweeperAvailability.none] and
  /// [SweeperAvailability.awaitingLocation]; deliberately still set for
  /// [SweeperAvailability.stale] so a caller can decide for itself what an ageing
  /// fix is good enough for.
  final SailorLocation? location;

  bool get hasRegisteredSweeper => availability != SweeperAvailability.none;

  /// The fix a feature may navigate to: fresh only.
  ///
  /// A stale position is withheld here for the same reason the skipper's gap is
  /// withheld - it can no longer be trusted to say where the TEC is - so a
  /// caller falls back to the voyage skipper rather than routing a sailor to where
  /// the TEC used to be.
  SailorLocation? get navigableLocation =>
      availability == SweeperAvailability.tracking ? location : null;
}

class SkipperVoyageStatus {
  const SkipperVoyageStatus({
    required this.offCourseAlerts,
    this.sweeperName,
    this.distanceToSweeperMeters,
    this.estimatedTimeToSweeper,
    this.sweeperLocationAge,
    this.sweeperSailorId,
    SweeperAvailability? sweeperAvailability,
  }) : sweeperAvailability =
           sweeperAvailability ??
           (sweeperName == null
               ? SweeperAvailability.none
               : distanceToSweeperMeters == null ||
                     estimatedTimeToSweeper == null
               ? SweeperAvailability.stale
               : SweeperAvailability.tracking);

  /// The single authoritative discriminator for every TEC surface and every
  /// TEC-targeting feature.
  final SweeperAvailability sweeperAvailability;

  /// The sailor holding the TEC role. Non-null for every registered state,
  /// including [SweeperAvailability.awaitingLocation], so a feature that targets
  /// the TEC has a real sailor id instead of a null target.
  final String? sweeperSailorId;

  /// The TEC's display name once a position for them is known. Deliberately
  /// null while [sweeperAvailability] is [SweeperAvailability.awaitingLocation]:
  /// nothing is known about where that TEC is, so a surface must show the
  /// waiting state rather than name a position it does not have.
  final String? sweeperName;
  final double? distanceToSweeperMeters;
  final Duration? estimatedTimeToSweeper;
  final Duration? sweeperLocationAge;
  final List<SkipperOffCourseAlert> offCourseAlerts;

  /// Whether any sailor is the Sweeper. False means the voyage has no
  /// back-marker at all: hide the TEC surfaces and fall back to the skipper.
  bool get hasRegisteredSweeper =>
      sweeperAvailability != SweeperAvailability.none;
}

class SkipperVoyageStatusCalculator {
  const SkipperVoyageStatusCalculator({
    this.defaultMovingSpeedMetersPerSecond = 13.4,
    this.maximumOnRouteDistanceMeters = 250,
    this.staleAfter = const Duration(minutes: 2),
    this.skipperTrackCorridorMeters = 120,
  });

  final double defaultMovingSpeedMetersPerSecond;
  final double maximumOnRouteDistanceMeters;
  final Duration staleAfter;

  /// Corridor around the skipper's own recorded track inside which a sailor is
  /// following the skipper rather than off course. See [SkipperTrackExemption].
  final double skipperTrackCorridorMeters;

  /// [skipperTrail] is the skipper's own recorded track. A sailor inside its
  /// corridor is following the skipper and is never counted as off course, even
  /// if a deviation alert for them arrived from a device that had not yet seen
  /// the skipper leave the GPX.
  SkipperVoyageStatus? calculate({
    required VoyageRole localRole,
    required String localSailorId,
    required SailorLocation? localLocation,
    required List<SailorLocation> sailorLocations,
    required List<SailorRouteAlert> routeAlerts,
    required List<GeoPoint> route,
    List<GeoPoint> skipperTrail = const [],
    // Sailor ids holding the TEC role in the reconciled membership model
    // (issue #27), which is the authoritative record of who is registered. A
    // TEC who has joined but not yet reported a position appears here and
    // nowhere else, so passing it is what separates
    // SweeperAvailability.awaitingLocation from SweeperAvailability.none. A sailor
    // carrying the TEC role in sailorLocations also counts as registered, so a
    // caller with only a location snapshot still resolves a TEC rather than
    // silently reporting none.
    Iterable<String> registeredSweeperSailorIds = const [],
    // The sailor the skipper's own accepted TEC request names (#128). Breaks a
    // two-sailors-hold-the-role tie deterministically; ignored when that sailor
    // is not registered.
    String? assignedSweeperSailorId,
    DateTime? now,
  }) {
    if (localRole != VoyageRole.lead) return null;
    final evaluatedAt = now ?? DateTime.now();
    final currentSailorIds = sailorLocations
        .map((location) => location.sailorId)
        .toSet();
    final locationsById = {
      for (final location in sailorLocations) location.sailorId: location,
    };
    final currentOffCourseAlerts = <String, SailorRouteAlert>{};
    for (final alert in routeAlerts) {
      if (alert.sailorId == localSailorId ||
          !currentSailorIds.contains(alert.sailorId) ||
          alert.acknowledged ||
          alert.assessment.state != RouteTrackingState.offRoute ||
          !alert.assessment.coordinatorActionRequired) {
        continue;
      }
      final location = locationsById[alert.sailorId];
      if (location != null &&
          SkipperTrackExemption.isFollowingSkipperTrack(
            position: location.sample.position,
            accuracyMeters: location.sample.accuracyMeters,
            skipperTrack: skipperTrail,
            corridorMeters: skipperTrackCorridorMeters,
          )) {
        continue;
      }
      final previous = currentOffCourseAlerts[alert.sailorId];
      if (previous == null ||
          alert.assessment.evaluatedAt.isAfter(
            previous.assessment.evaluatedAt,
          )) {
        currentOffCourseAlerts[alert.sailorId] = alert;
      }
    }
    final offCourseAlerts =
        currentOffCourseAlerts.values
            .map(
              (alert) => SkipperOffCourseAlert(
                sailorId: alert.sailorId,
                displayName: alert.displayName,
                level: alert.assessment.alertLevel,
                distanceFromRouteMeters:
                    alert.assessment.distanceFromRouteMeters,
              ),
            )
            .toList(growable: false)
          ..sort((first, second) {
            final byLevel = second.level.index.compareTo(first.level.index);
            return byLevel != 0
                ? byLevel
                : first.displayName.compareTo(second.displayName);
          });

    final sweeperTarget = resolveSweeperTarget(
      localSailorId: localSailorId,
      sailorLocations: sailorLocations,
      registeredSweeperSailorIds: registeredSweeperSailorIds,
      assignedSweeperSailorId: assignedSweeperSailorId,
      now: evaluatedAt,
    );
    if (!sweeperTarget.hasRegisteredSweeper) {
      // No back-marker at all. Everything TEC-shaped stays null so no surface
      // can render an empty gap and no feature can take a null target.
      return SkipperVoyageStatus(offCourseAlerts: offCourseAlerts);
    }
    final sweeper = sweeperTarget.location;
    if (sweeper == null) {
      return SkipperVoyageStatus(
        sweeperAvailability: SweeperAvailability.awaitingLocation,
        sweeperSailorId: sweeperTarget.sailorId,
        offCourseAlerts: offCourseAlerts,
      );
    }

    final age = sweeper.sample.ageAt(evaluatedAt);
    if (sweeperTarget.availability == SweeperAvailability.stale) {
      return SkipperVoyageStatus(
        sweeperAvailability: SweeperAvailability.stale,
        sweeperSailorId: sweeper.sailorId,
        sweeperName: sweeper.displayName,
        sweeperLocationAge: age,
        offCourseAlerts: offCourseAlerts,
      );
    }
    if (localLocation == null) {
      // The TEC's position is fresh; only the skipper's own fix is missing, so
      // the gap is withheld while the age stays honest.
      return SkipperVoyageStatus(
        sweeperAvailability: SweeperAvailability.tracking,
        sweeperSailorId: sweeper.sailorId,
        sweeperName: sweeper.displayName,
        sweeperLocationAge: age,
        offCourseAlerts: offCourseAlerts,
      );
    }

    final distance = _distanceBetween(localLocation, sweeper, route);
    final movingSpeeds = [
      localLocation.sample.speedMetersPerSecond,
      sweeper.sample.speedMetersPerSecond,
    ].whereType<double>().where((speed) => speed >= 2).toList(growable: false);
    final speed = movingSpeeds.isEmpty
        ? defaultMovingSpeedMetersPerSecond
        : movingSpeeds.reduce((a, b) => a + b) / movingSpeeds.length;
    final seconds = distance < 25 ? 0 : (distance / speed).round();
    return SkipperVoyageStatus(
      sweeperAvailability: SweeperAvailability.tracking,
      sweeperSailorId: sweeper.sailorId,
      sweeperName: sweeper.displayName,
      distanceToSweeperMeters: distance,
      estimatedTimeToSweeper: Duration(seconds: seconds),
      sweeperLocationAge: age,
      offCourseAlerts: offCourseAlerts,
    );
  }

  /// Resolves the Sweeper once, by the rules every TEC surface and
  /// every TEC-targeting feature shares.
  ///
  /// [registeredSweeperSailorIds] is the authoritative membership record, which is
  /// what separates "nobody is TEC" from "the TEC has not reported yet". A
  /// sailor carrying the role in [sailorLocations] also counts, so a caller
  /// holding only a location snapshot still resolves a TEC. [localSailorId] is
  /// excluded throughout: a sailor is never their own back-marker.
  ///
  /// [assignedSweeperSailorId] is the sailor named by the skipper's most recently
  /// accepted TEC request (#128). Two sailors can legitimately hold the role at
  /// once - one self-selected, one asked - and the group needs one answer, so
  /// the skipper's own accepted request wins when that sailor is registered. It is
  /// only a tie-break: it never invents a TEC who is not registered, and with no
  /// assignment the previous newest-fix-then-lowest-id ordering is unchanged.
  SweeperTarget resolveSweeperTarget({
    required String localSailorId,
    required List<SailorLocation> sailorLocations,
    required DateTime now,
    Iterable<String> registeredSweeperSailorIds = const [],
    String? assignedSweeperSailorId,
  }) {
    final candidates =
        sailorLocations
            .where(
              (location) =>
                  location.sailorId != localSailorId &&
                  location.role == VoyageRole.sweeper,
            )
            .toList(growable: false)
          ..sort(
            (first, second) =>
                second.sample.recordedAt.compareTo(first.sample.recordedAt),
          );
    final registeredIds =
        {
              ...registeredSweeperSailorIds,
              ...candidates.map((location) => location.sailorId),
            }
            .where((sailorId) => sailorId != localSailorId)
            .toList(growable: false)
          ..sort();
    if (registeredIds.isEmpty) {
      return const SweeperTarget(availability: SweeperAvailability.none);
    }
    final assigned = assignedSweeperSailorId != localSailorId
        ? assignedSweeperSailorId
        : null;
    final preferred = assigned != null && registeredIds.contains(assigned)
        ? assigned
        : null;
    // An assigned TEC with no position yet stays the TEC and reports
    // awaitingLocation, rather than handing the role to whoever happens to have
    // a fresher fix.
    final sweeper = preferred == null
        ? candidates.firstOrNull
        : candidates
              .where((location) => location.sailorId == preferred)
              .firstOrNull;
    if (sweeper == null) {
      return SweeperTarget(
        availability: SweeperAvailability.awaitingLocation,
        sailorId: preferred ?? registeredIds.first,
      );
    }
    return SweeperTarget(
      availability: sweeper.sample.ageAt(now) > staleAfter
          ? SweeperAvailability.stale
          : SweeperAvailability.tracking,
      sailorId: sweeper.sailorId,
      location: sweeper,
    );
  }

  double _distanceBetween(
    SailorLocation lead,
    SailorLocation sweeper,
    List<GeoPoint> route,
  ) {
    if (route.length >= 2) {
      final leadProjection = GeoCalculations.projectOntoPolyline(
        lead.sample.position,
        route,
      );
      final sweeperProjection = GeoCalculations.projectOntoPolyline(
        sweeper.sample.position,
        route,
      );
      if (leadProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters &&
          sweeperProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters) {
        final alongRouteDistance =
            (leadProjection.distanceAlongRouteMeters -
                    sweeperProjection.distanceAlongRouteMeters)
                .abs();
        if (GeoCalculations.distanceMeters(route.first, route.last) <= 25) {
          var routeDistance = 0.0;
          for (var index = 1; index < route.length; index += 1) {
            routeDistance += GeoCalculations.distanceMeters(
              route[index - 1],
              route[index],
            );
          }
          return math.min(
            alongRouteDistance,
            math.max(0, routeDistance - alongRouteDistance),
          );
        }
        return alongRouteDistance;
      }
    }
    return GeoCalculations.distanceMeters(
      lead.sample.position,
      sweeper.sample.position,
    );
  }
}
