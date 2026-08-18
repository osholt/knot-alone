/// How distances and speeds are shown.
///
/// [nauticalMiles] is the sailing unit and the default for a marine app: a
/// nautical mile is one minute of latitude, which is why a chart's latitude scale
/// *is* a distance scale and why passage distances are quoted in it. Knots follow
/// from it. The other two are inherited from the road build and kept because a
/// sailor may still want a shore distance in familiar units.
enum DistanceUnit { nauticalMiles, miles, kilometres }

extension DistanceUnitLabel on DistanceUnit {
  String get label => switch (this) {
    DistanceUnit.nauticalMiles => 'Nautical miles',
    DistanceUnit.miles => 'Miles',
    DistanceUnit.kilometres => 'Kilometres',
  };

  /// Whether this unit belongs at sea. Used where a surface should not offer a
  /// road unit for a passage figure.
  bool get isMarine => this == DistanceUnit.nauticalMiles;
}
