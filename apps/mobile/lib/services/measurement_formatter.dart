import '../domain/distance_unit.dart';

class MeasurementFormatter {
  const MeasurementFormatter(this.unit);

  final DistanceUnit unit;

  String distance(double meters) => switch (unit) {
    DistanceUnit.nauticalMiles => _nauticalDistance(meters),
    DistanceUnit.miles => _imperialDistance(meters),
    DistanceUnit.kilometres => _metricDistance(meters),
  };

  String speed(double metersPerSecond) => switch (unit) {
    DistanceUnit.nauticalMiles => '${_knots(metersPerSecond)} kn',
    DistanceUnit.miles => '${(metersPerSecond * 2.236936).round()} mph',
    DistanceUnit.kilometres => '${(metersPerSecond * 3.6).round()} km/h',
  };

  /// Metres in a nautical mile, by definition.
  static const metresPerNauticalMile = 1852.0;

  /// Cables below a mile, which is how close-quarters distances are given at
  /// sea: "two cables off" rather than "0.2 miles". A cable is a tenth of a
  /// nautical mile.
  static String _nauticalDistance(double meters) {
    final miles = meters / metresPerNauticalMile;
    if (miles < 1) {
      final cables = miles * 10;
      return cables < 1
          ? '${meters.round()} m'
          : '${cables.toStringAsFixed(cables < 3 ? 1 : 0)} cables';
    }
    // Passage distances are quoted to a tenth; more is spurious given the speed
    // and stream assumptions behind any time derived from them.
    return '${miles.toStringAsFixed(1)} NM';
  }

  /// Speeds under ten knots get a decimal, because the difference between 4.5
  /// and 5.4 matters over a twelve-hour passage.
  static String _knots(double metersPerSecond) {
    final knots = metersPerSecond * 3600 / metresPerNauticalMile;
    return knots < 10 ? knots.toStringAsFixed(1) : knots.round().toString();
  }

  static String _metricDistance(double meters) => meters < 1000
      ? '${_naturalShortDistance(meters)} m'
      : '${(meters / 1000).toStringAsFixed(1)} km';

  static String _imperialDistance(double meters) {
    final miles = meters / 1609.344;
    if (miles < 0.1) {
      return '${_naturalShortDistance(meters * 1.093613)} yd';
    }
    return '${miles.toStringAsFixed(1)} mi';
  }

  /// Navigation-grade short distances, without exposing unit conversion noise.
  ///
  /// A sailor can use "150 yards" or "20 metres" at a glance; 151 or 22 is
  /// spurious precision from converting the same route geometry. Below ten,
  /// whole-unit precision still matters and prevents four becoming zero.
  static int _naturalShortDistance(double value) {
    if (value < 10) return value.round();
    return (value / 10).round() * 10;
  }
}
