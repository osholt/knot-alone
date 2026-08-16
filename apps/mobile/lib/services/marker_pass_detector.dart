import '../domain/geo_point.dart';
import '../domain/marker_assistance.dart';
import '../domain/rider_location.dart';
import 'geo_calculations.dart';

class MarkerPassConfig {
  const MarkerPassConfig({
    this.passRadiusMeters = 30,
    this.approachRadiusMeters = 60,
    this.maximumLocationAge = const Duration(seconds: 20),
    this.maximumAccuracyMeters = 40,
  }) : assert(approachRadiusMeters > passRadiusMeters);

  final double passRadiusMeters;
  final double approachRadiusMeters;
  final Duration maximumLocationAge;
  final double maximumAccuracyMeters;
}

class MarkerPassDetector {
  MarkerPassDetector({this.config = const MarkerPassConfig()});

  final MarkerPassConfig config;
  final Set<String> _approaching = {};
  final Set<String> _passed = {};
  GeoPoint? _markerPosition;

  void start(
    GeoPoint markerPosition,
    Iterable<RiderLocationEvidence> evidence,
    DateTime now,
  ) {
    _markerPosition = markerPosition;
    _approaching.clear();
    _passed.clear();
    for (final item in evidence) {
      if (item.authenticated &&
          item.location.sample.ageAt(now) <= config.maximumLocationAge &&
          item.location.sample.accuracyMeters <= config.maximumAccuracyMeters &&
          _distance(item.location) >= config.approachRadiusMeters) {
        _approaching.add(item.location.riderId);
      }
    }
  }

  void stop() {
    _markerPosition = null;
    _approaching.clear();
    _passed.clear();
  }

  List<MarkerPassEvidence> evaluate(
    Iterable<RiderLocationEvidence> evidence,
    DateTime now,
  ) {
    if (_markerPosition == null) return const [];
    final passes = <MarkerPassEvidence>[];
    for (final item in evidence) {
      final location = item.location;
      if (!item.authenticated ||
          _passed.contains(location.riderId) ||
          location.sample.ageAt(now) > config.maximumLocationAge ||
          location.sample.accuracyMeters > config.maximumAccuracyMeters) {
        continue;
      }
      final distance = _distance(location);
      if (distance >= config.approachRadiusMeters) {
        _approaching.add(location.riderId);
      }
      if (distance <= config.passRadiusMeters &&
          _approaching.remove(location.riderId)) {
        _passed.add(location.riderId);
        passes.add(
          MarkerPassEvidence(
            riderId: location.riderId,
            locationEventId: item.eventId,
            observedAt: location.sample.recordedAt,
            roleName: location.role.name,
          ),
        );
      }
    }
    return List.unmodifiable(passes);
  }

  double _distance(RiderLocation location) => GeoCalculations.distanceMeters(
    _markerPosition!,
    location.sample.position,
  );
}
