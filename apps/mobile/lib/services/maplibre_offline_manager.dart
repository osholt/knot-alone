import 'dart:async';
import 'dart:math' as math;

import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../domain/imported_route.dart';
import 'basemap_configuration.dart';
import 'offline_tile_cache.dart';
import 'offline_tile_planner.dart';

abstract interface class MapLibreOfflineApi {
  Future<void> setTileCountLimit(int limit);

  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  });

  Future<List<ml.OfflineRegion>> regions();

  Future<void> pause(int regionId);

  Future<void> delete(int regionId);

  Future<void> clearAmbient();
}

class NativeMapLibreOfflineApi implements MapLibreOfflineApi {
  const NativeMapLibreOfflineApi();

  @override
  Future<void> setTileCountLimit(int limit) async {
    await ml.setOfflineTileCountLimit(limit);
  }

  @override
  Future<ml.OfflineRegion> download(
    ml.OfflineRegionDefinition definition, {
    required Map<String, dynamic> metadata,
    required void Function(ml.DownloadRegionStatus status) onEvent,
  }) => ml.downloadOfflineRegion(
    definition,
    metadata: metadata,
    onEvent: onEvent,
  );

  @override
  Future<List<ml.OfflineRegion>> regions() => ml.getListOfRegions();

  @override
  Future<void> pause(int regionId) => ml.pauseOfflineRegionDownload(regionId);

  @override
  Future<void> delete(int regionId) async {
    await ml.deleteOfflineRegion(regionId);
  }

  @override
  Future<void> clearAmbient() => ml.clearAmbientCache();
}

class MapLibreOfflinePlan {
  const MapLibreOfflinePlan({required this.bounds, required this.tileCount});

  final ml.LatLngBounds bounds;
  final int tileCount;
}

class MapLibreOfflinePlanner {
  const MapLibreOfflinePlanner();

  MapLibreOfflinePlan plan(
    ImportedRoute route, {
    required int minimumZoom,
    required int maximumZoom,
    required int maximumTiles,
  }) {
    if (minimumZoom < 0 || maximumZoom > 22 || minimumZoom > maximumZoom) {
      throw ArgumentError('Zoom range must be ordered and within 0..22.');
    }
    final points = route.allPoints.toList(growable: false);
    if (points.isEmpty) {
      throw const OfflineTileConfigurationException(
        'The route has no map points to download.',
      );
    }
    var south = points.first.latitude;
    var north = points.first.latitude;
    var west = points.first.longitude;
    var east = points.first.longitude;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    if (east - west > 180) {
      throw const OfflineTileConfigurationException(
        'Routes crossing the antimeridian must be split before download.',
      );
    }
    final latitudePadding = math.max(0.002, (north - south) * 0.08);
    final longitudePadding = math.max(0.002, (east - west) * 0.08);
    south = (south - latitudePadding).clamp(-85.05112878, 85.05112878);
    north = (north + latitudePadding).clamp(-85.05112878, 85.05112878);
    west = (west - longitudePadding).clamp(-180.0, 180.0);
    east = (east + longitudePadding).clamp(-180.0, 180.0);

    var tileCount = 0;
    for (var zoom = minimumZoom; zoom <= maximumZoom; zoom += 1) {
      final northwest = _project(north, west, zoom);
      final southeast = _project(south, east, zoom);
      tileCount +=
          (southeast.$1 - northwest.$1 + 1).abs() *
          (southeast.$2 - northwest.$2 + 1).abs();
      if (tileCount > maximumTiles) {
        throw OfflineTileLimitException(maximumTiles);
      }
    }
    return MapLibreOfflinePlan(
      bounds: ml.LatLngBounds(
        southwest: ml.LatLng(south, west),
        northeast: ml.LatLng(north, east),
      ),
      tileCount: tileCount,
    );
  }

  (int, int) _project(double latitude, double longitude, int zoom) {
    final count = 1 << zoom;
    final x = ((longitude + 180) / 360 * count).floor().clamp(0, count - 1);
    final radians = latitude * math.pi / 180;
    final y =
        ((1 - math.log(math.tan(radians) + (1 / math.cos(radians))) / math.pi) /
                2 *
                count)
            .floor()
            .clamp(0, count - 1);
    return (x, y);
  }
}

class MapLibreOfflineManager {
  const MapLibreOfflineManager({
    required this.configuration,
    this.api = const NativeMapLibreOfflineApi(),
    this.planner = const MapLibreOfflinePlanner(),
  });

  final BasemapConfiguration configuration;
  final MapLibreOfflineApi api;
  final MapLibreOfflinePlanner planner;

  Future<TileDownloadSummary> downloadRouteRegion(
    ImportedRoute route, {
    int minimumZoom = 10,
    int maximumZoom = 15,
    int maximumTiles = 2500,
    TileDownloadProgressCallback? onProgress,
    TileDownloadCancellationToken? cancellationToken,
  }) async {
    if (!configuration.usesMapLibre || !configuration.canDownloadOffline) {
      throw const OfflineTileConfigurationException(
        'A licensed MapLibre style with offline permission is required.',
      );
    }
    if (cancellationToken?.isCancelled ?? false) {
      return const TileDownloadSummary(
        totalTiles: 0,
        downloadedTiles: 0,
        reusedTiles: 0,
        downloadedBytes: 0,
        cancelled: true,
      );
    }
    final plan = planner.plan(
      route,
      minimumZoom: minimumZoom,
      maximumZoom: maximumZoom.clamp(
        minimumZoom,
        configuration.maximumNativeZoom,
      ),
      maximumTiles: maximumTiles,
    );
    await api.setTileCountLimit(maximumTiles);
    final terminal = Completer<void>();
    var completedResources = 0;
    var requiredResources = plan.tileCount;
    var completedBytes = 0;
    Object? downloadError;
    void onEvent(ml.DownloadRegionStatus status) {
      if (status is ml.InProgress) {
        completedResources = status.completedResourceCount;
        if (status.requiredResourceCount > 0) {
          requiredResources = status.requiredResourceCount;
        }
        completedBytes = status.completedResourceSize;
        onProgress?.call(
          TileDownloadProgress(
            completedTiles: completedResources,
            totalTiles: requiredResources,
            downloadedBytes: completedBytes,
          ),
        );
      } else if (status is ml.Success && !terminal.isCompleted) {
        terminal.complete();
      } else if (status is ml.Error && !terminal.isCompleted) {
        downloadError = status.cause;
        terminal.complete();
      }
    }

    final region = await api.download(
      ml.OfflineRegionDefinition(
        bounds: plan.bounds,
        mapStyleUrl: configuration.styleUrl,
        minZoom: minimumZoom.toDouble(),
        maxZoom: maximumZoom
            .clamp(minimumZoom, configuration.maximumNativeZoom)
            .toDouble(),
      ),
      metadata: {
        'rideRelayNamespace': configuration.cacheNamespace,
        'routeId': route.id,
      },
      onEvent: onEvent,
    );

    final cancellation = cancellationToken?.whenCancelled.then((_) => true);
    final cancelled = cancellation == null
        ? false
        : await Future.any<bool>([
            terminal.future.then((_) => false),
            cancellation,
          ]);
    if (cancelled) {
      await api.pause(region.id);
      await api.delete(region.id);
    } else {
      await terminal.future;
    }
    if (!cancelled && downloadError != null) {
      throw OfflineTileDownloadException(
        'MapLibre offline download failed: $downloadError',
      );
    }
    return TileDownloadSummary(
      totalTiles: requiredResources,
      downloadedTiles: completedResources,
      reusedTiles: 0,
      downloadedBytes: completedBytes,
      cancelled: cancelled,
    );
  }

  Future<void> clear() async {
    final regions = await api.regions();
    for (final region in regions) {
      if (region.metadata['rideRelayNamespace'] ==
          configuration.cacheNamespace) {
        await api.delete(region.id);
      }
    }
    await api.clearAmbient();
  }

  Future<void> clearAll() async {
    final regions = await api.regions();
    for (final region in regions) {
      await api.delete(region.id);
    }
    await api.clearAmbient();
  }
}
