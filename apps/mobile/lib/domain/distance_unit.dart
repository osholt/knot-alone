enum DistanceUnit { miles, kilometres }

extension DistanceUnitLabel on DistanceUnit {
  String get label => switch (this) {
    DistanceUnit.miles => 'Miles',
    DistanceUnit.kilometres => 'Kilometres',
  };
}
