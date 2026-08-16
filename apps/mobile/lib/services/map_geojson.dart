import '../domain/imported_route.dart';

class MapGeoJsonPoint {
  const MapGeoJsonPoint({
    required this.id,
    required this.point,
    this.properties = const {},
  });

  final String id;
  final GeoPoint point;
  final Map<String, Object?> properties;
}

class MapGeoJson {
  const MapGeoJson._();

  static Map<String, dynamic> route(ImportedRoute? route) => lines(
    route?.paths.map((path) => path.points) ?? const [],
    idPrefix: 'route-path',
  );

  static Map<String, dynamic> lines(
    Iterable<List<GeoPoint>> lines, {
    String idPrefix = 'line',
  }) => {
    'type': 'FeatureCollection',
    'features': lines.indexed
        .where((entry) => entry.$2.length >= 2)
        .map(
          (entry) => <String, dynamic>{
            'type': 'Feature',
            'id': '$idPrefix-${entry.$1}',
            'properties': const <String, Object?>{},
            'geometry': {
              'type': 'LineString',
              'coordinates': entry.$2
                  .map((point) => [point.longitude, point.latitude])
                  .toList(growable: false),
            },
          },
        )
        .toList(growable: false),
  };

  static Map<String, dynamic> points(Iterable<MapGeoJsonPoint> points) => {
    'type': 'FeatureCollection',
    'features': points
        .map(
          (item) => <String, dynamic>{
            'type': 'Feature',
            'id': item.id,
            'properties': item.properties,
            'geometry': {
              'type': 'Point',
              'coordinates': [item.point.longitude, item.point.latitude],
            },
          },
        )
        .toList(growable: false),
  };
}
