import 'marine_data.dart';

class TideStation {
  const TideStation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.datum,
    required this.source,
    this.timeZone,
    this.qualityNote,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;

  /// Vertical datum named by the upstream station data. Heights from stations
  /// using different datums must not be combined silently.
  final String datum;
  final MarineDataSource source;
  final String? timeZone;
  final String? qualityNote;
}

class TideHeight {
  const TideHeight({required this.meters});

  final double meters;
}

enum TideExtremeKind { high, low }

class TideExtreme {
  const TideExtreme({
    required this.kind,
    required this.height,
    required this.at,
  });

  final TideExtremeKind kind;
  final TideHeight height;
  final DateTime at;
}

class TidePrediction {
  TidePrediction({
    required this.station,
    required List<MarineDatum<TideHeight>> points,
    required List<TideExtreme> extremes,
  }) : points = List.unmodifiable(points),
       extremes = List.unmodifiable(extremes);

  final TideStation station;
  final List<MarineDatum<TideHeight>> points;
  final List<TideExtreme> extremes;

  DateTime? get startsAt => points.isEmpty ? null : points.first.validAt;
  DateTime? get endsAt => points.isEmpty ? null : points.last.validAt;
}

abstract interface class TideProvider {
  MarineDataSource get source;

  Future<List<TideStation>> stationsNear({
    required double latitude,
    required double longitude,
    double limitKilometers = 100,
  });

  Future<TidePrediction> predict({
    required TideStation station,
    required DateTime start,
    required DateTime end,
    Duration interval = const Duration(minutes: 10),
  });
}
