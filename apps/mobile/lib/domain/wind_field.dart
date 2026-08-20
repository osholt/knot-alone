import 'marine_data.dart';

class WindVector {
  const WindVector({
    required this.speedKnots,
    required this.fromDegrees,
    this.gustKnots,
  });

  final double speedKnots;

  /// Meteorological convention: the direction the wind comes from.
  final double fromDegrees;
  final double? gustKnots;
}

class WindFieldPoint {
  const WindFieldPoint({
    required this.latitude,
    required this.longitude,
    required this.wind,
  });

  final double latitude;
  final double longitude;
  final MarineDatum<WindVector> wind;
}

class WindField {
  WindField({required List<WindFieldPoint> points})
    : points = List.unmodifiable(points);

  final List<WindFieldPoint> points;

  DateTime? get validAt => points.isEmpty ? null : points.first.wind.validAt;
}

abstract interface class WindFieldProvider {
  MarineDataSource get source;

  Future<WindField> fetch({
    required double south,
    required double west,
    required double north,
    required double east,
    required DateTime validAt,
  });
}
