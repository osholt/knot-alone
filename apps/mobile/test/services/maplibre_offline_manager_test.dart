import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/maplibre_offline_manager.dart';

void main() {
  const configuration = BasemapConfiguration(
    styleUrl: 'https://maps.example.test/styles/ride-relay/style.json',
    attribution: '© OpenStreetMap contributors',
    cacheNamespace: 'open-map-v1',
    persistentCachingAllowed: true,
  );

  test('plans bounded native regions and completes a download', () async {
    final api = _FakeOfflineApi();
    final manager = MapLibreOfflineManager(
      configuration: configuration,
      api: api,
    );

    final summary = await manager.downloadRouteRegion(_route());

    expect(summary.cancelled, isFalse);
    expect(summary.downloadedTiles, 12);
    expect(summary.totalTiles, 12);
    expect(api.tileLimit, 2500);
    expect(api.lastDefinition?.mapStyleUrl, configuration.styleUrl);
  });

  test('clear removes only this provider namespace', () async {
    final api = _FakeOfflineApi()
      ..storedRegions.addAll([
        _region(1, 'open-map-v1'),
        _region(2, 'other-map'),
      ]);
    final manager = MapLibreOfflineManager(
      configuration: configuration,
      api: api,
    );

    await manager.clear();

    expect(api.deleted, [1]);
    expect(api.ambientCleared, isTrue);
  });

  test('clear is still allowed after download permission is revoked', () async {
    final api = _FakeOfflineApi()..storedRegions.add(_region(1, 'open-map-v1'));
    final manager = MapLibreOfflineManager(
      configuration: const BasemapConfiguration(
        styleUrl: 'https://maps.example.test/styles/ride-relay/style.json',
        attribution: '© OpenStreetMap contributors',
        cacheNamespace: 'open-map-v1',
        persistentCachingAllowed: false,
      ),
      api: api,
    );

    await manager.clear();

    expect(api.deleted, [1]);
  });

  test('rejects a region that exceeds its tile safety cap', () {
    expect(
      () => const MapLibreOfflinePlanner().plan(
        _route(),
        minimumZoom: 10,
        maximumZoom: 15,
        maximumTiles: 1,
      ),
      throwsA(isA<Exception>()),
    );
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
        GeoPoint(latitude: 51.002, longitude: -0.998),
      ],
    ),
  ],
  waypoints: const [],
);

ml.OfflineRegion _region(int id, String namespace) => ml.OfflineRegion(
  id: id,
  definition: ml.OfflineRegionDefinition(
    bounds: ml.LatLngBounds(
      southwest: const ml.LatLng(51, -1),
      northeast: const ml.LatLng(51.1, -0.9),
    ),
    mapStyleUrl: 'https://maps.example.test/style.json',
    minZoom: 10,
    maxZoom: 15,
  ),
  metadata: {'rideRelayNamespace': namespace},
);

class _FakeOfflineApi implements MapLibreOfflineApi {
  int? tileLimit;
  ml.OfflineRegionDefinition? lastDefinition;
  final storedRegions = <ml.OfflineRegion>[];
  final deleted = <int>[];
  bool ambientCleared = false;

  @override
  Future<void> setTileCountLimit(int limit) async => tileLimit = limit;

  @override
  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  }) async {
    lastDefinition = definition;
    onEvent(
      ml.InProgress(
        1,
        completedResourceCount: 12,
        requiredResourceCount: 12,
        completedResourceSize: 2048,
      ),
    );
    onEvent(ml.Success());
    return ml.OfflineRegion(id: 3, definition: definition, metadata: metadata);
  }

  @override
  Future<List<ml.OfflineRegion>> regions() async => storedRegions;

  @override
  Future<void> pause(int regionId) async {}

  @override
  Future<void> delete(int regionId) async => deleted.add(regionId);

  @override
  Future<void> clearAmbient() async => ambientCleared = true;
}
