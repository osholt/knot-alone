import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/map_geojson.dart';

void main() {
  test(
    'keeps disconnected paths separate and uses GeoJSON coordinate order',
    () {
      final geoJson = MapGeoJson.route(_route());
      final features = geoJson['features']! as List;

      expect(features, hasLength(2));
      final geometry = (features.first as Map)['geometry'] as Map;
      expect(geometry['type'], 'LineString');
      expect(geometry['coordinates'], [
        [-1.0, 51.0],
        [-0.99, 51.01],
      ]);
    },
  );

  test('point feature properties and identity are preserved', () {
    final geoJson = MapGeoJson.points([
      const MapGeoJsonPoint(
        id: 'hazard-1',
        point: GeoPoint(latitude: 51, longitude: -1),
        properties: {'label': 'Roadworks', 'color': '#ffc857'},
      ),
    ]);
    final feature = (geoJson['features']! as List).single as Map;

    expect(feature['id'], 'hazard-1');
    expect((feature['properties'] as Map)['label'], 'Roadworks');
  });
}

ImportedRoute _route() => ImportedRoute(
  id: 'route-1',
  name: 'Test route',
  importedAt: DateTime.utc(2026, 7, 16),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51.01, longitude: -0.99),
      ],
    ),
    RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 52, longitude: -2),
        GeoPoint(latitude: 52.01, longitude: -1.99),
      ],
    ),
  ],
  waypoints: const [],
);
