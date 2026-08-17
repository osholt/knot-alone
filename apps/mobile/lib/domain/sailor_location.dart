import '../features/map/motorcycle_icon.dart';
import 'geo_point.dart';
import 'voyage_role.dart';
import 'sailor_color.dart';

class LocationSample {
  const LocationSample({
    required this.position,
    required this.recordedAt,
    required this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
  }) : assert(accuracyMeters >= 0),
       assert(speedMetersPerSecond == null || speedMetersPerSecond >= 0),
       assert(
         headingDegrees == null ||
             (headingDegrees >= 0 && headingDegrees < 360),
       );

  final GeoPoint position;
  final DateTime recordedAt;
  final double accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  Duration ageAt(DateTime now) {
    final age = now.difference(recordedAt);
    return age.isNegative ? Duration.zero : age;
  }

  bool isStaleAt(DateTime now, Duration threshold) => ageAt(now) > threshold;

  Map<String, Object?> toJson() => {
    'position': position.toJson(),
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'accuracyMeters': accuracyMeters,
    'speedMetersPerSecond': speedMetersPerSecond,
    'headingDegrees': headingDegrees,
  };

  factory LocationSample.fromJson(Map<String, Object?> json) => LocationSample(
    position: GeoPoint.fromJson(
      Map<String, Object?>.from(json['position']! as Map),
    ),
    recordedAt: DateTime.parse(json['recordedAt']! as String).toLocal(),
    accuracyMeters: (json['accuracyMeters']! as num).toDouble(),
    speedMetersPerSecond: (json['speedMetersPerSecond'] as num?)?.toDouble(),
    headingDegrees: (json['headingDegrees'] as num?)?.toDouble(),
  );
}

class SailorLocation {
  const SailorLocation({
    required this.sailorId,
    required this.displayName,
    required this.role,
    required this.sample,
    required this.receivedAt,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.sailorSymbol = sailorSymbolDefault,
    this.sailorColor = sailorColorDefault,
  });

  final String sailorId;
  final String displayName;
  final VoyageRole role;
  final LocationSample sample;
  final DateTime receivedAt;
  final MotorcycleIconStyle motorcycleStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;

  Map<String, Object?> toJson() => {
    'sailorId': sailorId,
    'displayName': displayName,
    'role': role.name,
    'sample': sample.toJson(),
    'receivedAt': receivedAt.toUtc().toIso8601String(),
    'motorcycleStyle': sailorSymbol.wireValue(motorcycleStyle),
    'sailorColor': sailorColor.name,
  };

  factory SailorLocation.fromJson(Map<String, Object?> json) => SailorLocation(
    sailorId: json['sailorId']! as String,
    displayName: json['displayName']! as String,
    role: VoyageRole.values.byName(json['role']! as String),
    sample: LocationSample.fromJson(
      Map<String, Object?>.from(json['sample']! as Map),
    ),
    receivedAt: DateTime.parse(json['receivedAt']! as String).toLocal(),
    motorcycleStyle: motorcycleIconStyleFromName(
      json['motorcycleStyle'] as String?,
    ),
    sailorSymbol: SailorSymbol.fromWireValue(
      json['motorcycleStyle'] as String?,
    ),
    sailorColor: sailorColorFromName(json['sailorColor'] as String?),
  );
}

class SailorLocationEvidence {
  const SailorLocationEvidence({
    required this.location,
    required this.eventId,
    required this.eventCreatedAt,
    required this.authenticated,
  });

  final SailorLocation location;
  final String eventId;
  final DateTime eventCreatedAt;
  final bool authenticated;
}
