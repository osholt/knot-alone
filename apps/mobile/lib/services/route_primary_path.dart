import 'dart:math' as math;

import '../domain/imported_route.dart';

/// The longest path in [route], which is the one actually travelled.
///
/// A route can carry several paths — an imported GPX may hold alternates, a
/// spur, or a return leg — and every length, progress and editing calculation
/// has to agree about which one is the route. The longest is that one; the
/// others are context.
///
/// Lifted out of the junction-marker planner when the road-marker surfaces were
/// removed. The rule is about route geometry, not about markers, so it outlives
/// them.
///
/// Distances are computed here rather than through `GeoCalculations` because
/// that operates on `domain/geo_point.dart`'s `GeoPoint` and a route carries
/// the separate `imported_route.dart` one. Unifying the two is its own change.
List<GeoPoint> routePrimaryPath(ImportedRoute route) {
  var longest = const <GeoPoint>[];
  var longestLength = -1.0;
  for (final path in route.paths) {
    final length = _pathLengthMeters(path.points);
    if (length > longestLength) {
      longestLength = length;
      longest = path.points;
    }
  }
  return longest;
}

const _earthRadiusMeters = 6371008.8;

double _pathLengthMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += _distanceMeters(points[index - 1], points[index]);
  }
  return total;
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  final latitude1 = _radians(first.latitude);
  final latitude2 = _radians(second.latitude);
  final latitudeDelta = latitude2 - latitude1;
  final longitudeDelta = _radians(
    _normaliseLongitudeDelta(second.longitude - first.longitude),
  );
  final a =
      math.pow(math.sin(latitudeDelta / 2), 2) +
      math.cos(latitude1) *
          math.cos(latitude2) *
          math.pow(math.sin(longitudeDelta / 2), 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _normaliseLongitudeDelta(double delta) {
  var value = delta;
  while (value > 180) {
    value -= 360;
  }
  while (value < -180) {
    value += 360;
  }
  return value;
}

double _radians(double degrees) => degrees * math.pi / 180;
