import '../domain/geo_point.dart';
import '../domain/marker_assistance.dart';
import '../domain/ride_role.dart';
import '../domain/rider_location.dart';
import 'geo_calculations.dart';

class MarkerSuggestionConfig {
  const MarkerSuggestionConfig({
    this.decisionRadiusMeters = 35,
    this.stoppedEnterSpeedMetersPerSecond = 0.8,
    this.stoppedExitSpeedMetersPerSecond = 1.8,
    this.stoppedDwell = const Duration(seconds: 12),
    this.minimumGroupLeadMeters = 45,
    this.minimumGroupProgressMeters = 20,
    this.minimumGroupSpeedMetersPerSecond = 3,
    this.maximumGroupRouteDistanceMeters = 80,
    this.minimumProgressingRiders = 1,
    this.maximumLocationAge = const Duration(seconds: 20),
    this.maximumAccuracyMeters = 40,
    this.dismissCooldown = const Duration(minutes: 5),
    this.cancelCooldown = const Duration(minutes: 2),
  });

  final double decisionRadiusMeters;
  final double stoppedEnterSpeedMetersPerSecond;
  final double stoppedExitSpeedMetersPerSecond;
  final Duration stoppedDwell;
  final double minimumGroupLeadMeters;
  final double minimumGroupProgressMeters;
  final double minimumGroupSpeedMetersPerSecond;
  final double maximumGroupRouteDistanceMeters;
  final int minimumProgressingRiders;
  final Duration maximumLocationAge;
  final double maximumAccuracyMeters;
  final Duration dismissCooldown;
  final Duration cancelCooldown;
}

class MarkerDetectorObservation {
  const MarkerDetectorObservation({
    required this.localLocation,
    required this.groupLocations,
    required this.now,
    required this.markerActive,
  });

  final RiderLocation? localLocation;
  final List<RiderLocation> groupLocations;
  final DateTime now;
  final bool markerActive;
}

class MarkerSuggestionDetector {
  MarkerSuggestionDetector({
    required List<GeoPoint> route,
    required List<RouteDecisionPoint> decisionPoints,
    this.config = const MarkerSuggestionConfig(),
  }) : _route = List.unmodifiable(route),
       _decisionPoints = List.unmodifiable(decisionPoints);

  final List<GeoPoint> _route;
  final List<RouteDecisionPoint> _decisionPoints;
  final MarkerSuggestionConfig config;
  final Map<String, double> _previousGroupProgress = {};

  RiderLocation? _previousLocal;
  DateTime? _stoppedSince;
  DateTime? _cooldownUntil;
  MarkerSuggestion? _suggestion;

  MarkerSuggestionEvaluation evaluate(MarkerDetectorObservation observation) {
    if (observation.markerActive) {
      _suggestion = null;
      _stoppedSince = null;
      _remember(observation);
      return const MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.markerActive,
        message: 'Marker mode is active.',
      );
    }

    final local = observation.localLocation;
    if (_route.length < 2 || _decisionPoints.isEmpty || local == null) {
      _remember(observation);
      return const MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.unavailable,
        message: 'A route, decision point, and current location are required.',
      );
    }
    if (!_isUsable(local, observation.now)) {
      _cancelSuggestion(observation.now);
      _remember(observation);
      return const MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.monitoring,
        message: 'Waiting for a recent, accurate GPS position.',
      );
    }

    final cooldownUntil = _cooldownUntil;
    if (cooldownUntil != null && observation.now.isBefore(cooldownUntil)) {
      _remember(observation);
      return MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.cooldown,
        message: 'Marker suggestions are cooling down.',
        cooldownUntil: cooldownUntil,
      );
    }
    _cooldownUntil = null;

    final nearest = _nearestDecision(local.sample.position);
    final speed = _speed(local);
    final stoppedThreshold = _stoppedSince == null
        ? config.stoppedEnterSpeedMetersPerSecond
        : config.stoppedExitSpeedMetersPerSecond;
    final stopped = speed <= stoppedThreshold;
    final nearDecision =
        nearest != null &&
        nearest.distanceMeters <= config.decisionRadiusMeters;

    if (_suggestion != null) {
      final stillAtSuggestedPoint =
          nearDecision && nearest.point.id == _suggestion!.decisionPoint.id;
      if (!stillAtSuggestedPoint || !stopped) {
        _cancelSuggestion(observation.now);
        _remember(observation);
        return MarkerSuggestionEvaluation(
          state: MarkerSuggestionState.cooldown,
          message: 'Marker suggestion cancelled after movement.',
          cooldownUntil: _cooldownUntil,
        );
      }
      _remember(observation);
      return MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.suggested,
        message: 'Stopped at a decision point while the group continues.',
        suggestion: _suggestion,
      );
    }

    if (!nearDecision || !stopped) {
      _stoppedSince = null;
      _remember(observation);
      return const MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.monitoring,
        message: 'Monitoring route decisions and group progress.',
      );
    }

    _stoppedSince ??= observation.now;
    final progressing = _progressingRiderCount(observation, local);
    final dwellMet =
        observation.now.difference(_stoppedSince!) >= config.stoppedDwell;
    _remember(observation);
    if (!dwellMet || progressing < config.minimumProgressingRiders) {
      return const MarkerSuggestionEvaluation(
        state: MarkerSuggestionState.stoppedNearDecision,
        message: 'Stopped near a decision point; checking group movement.',
      );
    }

    _suggestion = MarkerSuggestion(
      decisionPoint: nearest.point,
      suggestedAt: observation.now,
      distanceMeters: nearest.distanceMeters,
      progressingRiderCount: progressing,
    );
    return MarkerSuggestionEvaluation(
      state: MarkerSuggestionState.suggested,
      message: 'Stopped at a decision point while the group continues.',
      suggestion: _suggestion,
    );
  }

  void dismiss(DateTime now) {
    _suggestion = null;
    _stoppedSince = null;
    _cooldownUntil = now.add(config.dismissCooldown);
  }

  void accept(DateTime now) {
    _suggestion = null;
    _stoppedSince = null;
    _cooldownUntil = now.add(config.dismissCooldown);
  }

  int _progressingRiderCount(
    MarkerDetectorObservation observation,
    RiderLocation local,
  ) {
    final localProgress = GeoCalculations.projectOntoPolyline(
      local.sample.position,
      _route,
    ).distanceAlongRouteMeters;
    var count = 0;
    for (final rider in observation.groupLocations) {
      if (rider.riderId == local.riderId ||
          rider.role == RideRole.marker ||
          !_isUsable(rider, observation.now)) {
        continue;
      }
      final projection = GeoCalculations.projectOntoPolyline(
        rider.sample.position,
        _route,
      );
      if (projection.distanceFromRouteMeters >
          config.maximumGroupRouteDistanceMeters) {
        continue;
      }
      final progress = projection.distanceAlongRouteMeters;
      final previous = _previousGroupProgress[rider.riderId];
      final progressingByDistance =
          previous != null &&
          progress - previous >= config.minimumGroupProgressMeters;
      final progressingBySpeed =
          (rider.sample.speedMetersPerSecond ?? 0) >=
          config.minimumGroupSpeedMetersPerSecond;
      if (progress - localProgress >= config.minimumGroupLeadMeters &&
          (progressingByDistance || progressingBySpeed)) {
        count += 1;
      }
    }
    return count;
  }

  bool _isUsable(RiderLocation location, DateTime now) =>
      location.sample.ageAt(now) <= config.maximumLocationAge &&
      location.sample.accuracyMeters <= config.maximumAccuracyMeters;

  double _speed(RiderLocation current) {
    final reported = current.sample.speedMetersPerSecond;
    if (reported != null) return reported;
    final previous = _previousLocal;
    if (previous == null ||
        current.sample.recordedAt.isAtSameMomentAs(
          previous.sample.recordedAt,
        )) {
      return double.infinity;
    }
    final seconds =
        current.sample.recordedAt
            .difference(previous.sample.recordedAt)
            .inMilliseconds /
        1000;
    if (seconds <= 0) return double.infinity;
    return GeoCalculations.distanceMeters(
          previous.sample.position,
          current.sample.position,
        ) /
        seconds;
  }

  _NearestDecision? _nearestDecision(GeoPoint position) {
    _NearestDecision? nearest;
    for (final point in _decisionPoints) {
      final distance = GeoCalculations.distanceMeters(position, point.position);
      if (nearest == null || distance < nearest.distanceMeters) {
        nearest = _NearestDecision(point: point, distanceMeters: distance);
      }
    }
    return nearest;
  }

  void _remember(MarkerDetectorObservation observation) {
    final local = observation.localLocation;
    if (local != null) _previousLocal = local;
    for (final rider in observation.groupLocations) {
      _previousGroupProgress[rider.riderId] =
          GeoCalculations.projectOntoPolyline(
            rider.sample.position,
            _route,
          ).distanceAlongRouteMeters;
    }
  }

  void _cancelSuggestion(DateTime now) {
    if (_suggestion != null) {
      _cooldownUntil = now.add(config.cancelCooldown);
    }
    _suggestion = null;
    _stoppedSince = null;
  }
}

class _NearestDecision {
  const _NearestDecision({required this.point, required this.distanceMeters});

  final RouteDecisionPoint point;
  final double distanceMeters;
}
