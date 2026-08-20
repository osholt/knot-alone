import '../domain/imported_route.dart' show GeoPoint;

/// Geometry and honest assumptions produced by a passage planner.
class PassagePlanResult {
  const PassagePlanResult({
    required this.points,
    required this.distanceMeters,
    required this.duration,
    this.warnings = const [],
  });

  final List<GeoPoint> points;
  final double distanceMeters;
  final Duration duration;
  final List<String> warnings;
}

/// Plans a passage through the marks chosen by the sailor.
abstract interface class PassagePlanningService {
  Future<PassagePlanResult> planThrough(List<GeoPoint> waypoints);
}
