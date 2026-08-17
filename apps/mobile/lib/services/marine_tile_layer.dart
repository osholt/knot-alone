/// A marine data layer that draws as raster tiles, and where its tiles live.
///
/// Kept separate from [ChartSource] because provenance and rendering are
/// different concerns: the UKHO wrecks database is a real source with a real
/// licence and is not a tile layer at all.
library;

import '../domain/chart_source.dart';

/// How a layer sits relative to the basemap.
enum MarineLayerPlacement {
  /// Drawn beneath the basemap's own features, so land and labels stay on top.
  /// Depth shading belongs here — it is ground, not annotation.
  beneathBasemap,

  /// Drawn over everything. Seamarks and buoyage belong here; they are the
  /// point, and must not be buried under a road casing.
  overBasemap,
}

/// A raster tile layer with its provenance attached.
class MarineTileLayer {
  const MarineTileLayer({
    required this.source,
    required this.urlTemplate,
    required this.placement,
    this.minZoom = 0,
    this.maxZoom = 18,
    this.opacity = 1.0,
    this.tileSize = 256,
  });

  final ChartSource source;

  /// XYZ template with `{z}`, `{x}` and `{y}`. Both configured providers serve
  /// XYZ directly, so no WMTS request building is needed.
  final String urlTemplate;
  final MarineLayerPlacement placement;

  /// Beyond these the provider has no data. Asking anyway returns 404s, which
  /// look to a sailor like the chart simply stopping.
  final int minZoom;
  final int maxZoom;

  final double opacity;
  final int tileSize;

  /// Cache namespace. Tied to the source id so a provider change cannot serve
  /// the previous provider's tiles out of the old cache.
  String get cacheNamespace => source.id;

  bool get isConfigured =>
      source.isConfigured &&
      urlTemplate.contains('{z}') &&
      urlTemplate.contains('{x}') &&
      urlTemplate.contains('{y}') &&
      Uri.tryParse(urlTemplate.replaceAll(RegExp(r'\{[zxy]\}'), '0'))?.scheme ==
          'https' &&
      minZoom >= 0 &&
      maxZoom >= minZoom &&
      maxZoom <= 22;

  /// The template with tile coordinates substituted.
  String tileUrl({required int z, required int x, required int y}) =>
      urlTemplate
          .replaceAll('{z}', '$z')
          .replaceAll('{x}', '$x')
          .replaceAll('{y}', '$y');
}
