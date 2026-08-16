import 'dart:math' as math;

class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude})
    : assert(latitude >= -90 && latitude <= 90),
      assert(longitude >= -180 && longitude <= 180);

  final double latitude;
  final double longitude;

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
  };

  factory GeoPoint.fromJson(Map<String, Object?> json) => GeoPoint(
    latitude: (json['latitude']! as num).toDouble(),
    longitude: (json['longitude']! as num).toDouble(),
  );

  bool isNear(GeoPoint other, {double tolerance = 1e-9}) =>
      (latitude - other.latitude).abs() <= tolerance &&
      (longitude - other.longitude).abs() <= tolerance;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      latitude == other.latitude &&
      longitude == other.longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() =>
      'GeoPoint(${latitude.toStringAsFixed(6)}, '
      '${longitude.toStringAsFixed(6)})';
}

class GeoBounds {
  const GeoBounds({required this.southWest, required this.northEast});

  final GeoPoint southWest;
  final GeoPoint northEast;

  bool contains(GeoPoint point) =>
      point.latitude >= southWest.latitude &&
      point.latitude <= northEast.latitude &&
      _containsLongitude(point.longitude);

  bool _containsLongitude(double longitude) {
    if (southWest.longitude <= northEast.longitude) {
      return longitude >= southWest.longitude &&
          longitude <= northEast.longitude;
    }
    return longitude >= southWest.longitude || longitude <= northEast.longitude;
  }

  factory GeoBounds.around(Iterable<GeoPoint> points) {
    final values = points.toList(growable: false);
    if (values.isEmpty) {
      throw ArgumentError.value(points, 'points', 'Must not be empty.');
    }
    return GeoBounds(
      southWest: GeoPoint(
        latitude: values.map((point) => point.latitude).reduce(math.min),
        longitude: values.map((point) => point.longitude).reduce(math.min),
      ),
      northEast: GeoPoint(
        latitude: values.map((point) => point.latitude).reduce(math.max),
        longitude: values.map((point) => point.longitude).reduce(math.max),
      ),
    );
  }
}
