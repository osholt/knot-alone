import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/services/marine_layers.dart';
import 'package:tide_and_seek/services/marine_tile_layer.dart';

/// The endpoints in `MarineLayers` were verified live before being checked in:
/// the EMODnet WMTS capabilities document lists `web_mercator` among its tile
/// matrix sets, `v12/mean_atlas_land` serves PNG tiles and `v13` returns 404.
///
/// These tests cannot re-verify that without a network, so they guard the
/// things that break silently instead: template shape, zoom bounds, draw order,
/// and the fact that a wrong template produces blank water rather than an error.
void main() {
  group('templates are the shape a tile client needs', () {
    test('every configured layer is usable', () {
      for (final layer in MarineLayers.tileLayers) {
        expect(layer.isConfigured, isTrue, reason: layer.source.id);
      }
    });

    test('a template missing a coordinate placeholder is refused', () {
      // The failure this catches is silent: a template without {y} yields the
      // same tile everywhere, which looks like real data.
      final broken = MarineTileLayer(
        source: MarineLayers.emodnetBathymetry,
        urlTemplate: 'https://tiles.example.invalid/{z}/{x}.png',
        placement: MarineLayerPlacement.beneathBasemap,
      );
      expect(broken.isConfigured, isFalse);
    });

    test('a plain-http template is refused', () {
      final insecure = MarineTileLayer(
        source: MarineLayers.emodnetBathymetry,
        urlTemplate: 'http://tiles.example.invalid/{z}/{x}/{y}.png',
        placement: MarineLayerPlacement.beneathBasemap,
      );
      expect(insecure.isConfigured, isFalse);
    });

    test('substitution puts the coordinates where the provider expects', () {
      // EMODnet orders the path as matrix set, then z, x, y.
      expect(
        MarineLayers.bathymetryTiles.tileUrl(z: 6, x: 32, y: 21),
        'https://tiles.emodnet-bathymetry.eu/v12/mean_atlas_land/'
        'web_mercator/6/32/21.png',
      );
    });

    test('the seamark template resolves to OpenSeaMap by default', () {
      expect(
        MarineLayers.seamarkTiles.tileUrl(z: 12, x: 2045, y: 1362),
        'https://tiles.openseamap.org/seamark/12/2045/1362.png',
      );
    });
  });

  group('zoom bounds come from the provider, not from taste', () {
    test('bathymetry stops where EMODnet stops', () {
      // Past the provider's maximum the server 404s, and to a sailor that reads
      // as the chart simply stopping. Retained for whenever a usable depth
      // product replaces it.
      expect(MarineLayers.bathymetryTiles.maxZoom, 12);
    });

    test('seamarks do not draw at ocean-basin zooms', () {
      // Buoyage at z3 would be a smear of unreadable symbols.
      expect(MarineLayers.seamarkTiles.minZoom, greaterThanOrEqualTo(9));
    });

    test('bounds are ordered and within slippy-map limits', () {
      for (final layer in MarineLayers.tileLayers) {
        expect(layer.minZoom, lessThanOrEqualTo(layer.maxZoom));
        expect(layer.maxZoom, lessThanOrEqualTo(22));
      }
    });
  });

  group('draw order reflects what each layer is for', () {
    test('depth is ground and goes under the basemap', () {
      expect(
        MarineLayers.bathymetryTiles.placement,
        MarineLayerPlacement.beneathBasemap,
      );
    });

    test('seamarks are the point and go over it', () {
      expect(
        MarineLayers.seamarkTiles.placement,
        MarineLayerPlacement.overBasemap,
      );
    });

    test('bathymetry is configured but not drawn', () {
      // EMODnet renders shelf water white, so it added land hill-shading to a
      // sailing app and nothing to the sea. Kept configured so the research is
      // not lost, kept out of tileLayers so it does not draw.
      expect(MarineLayers.bathymetryTiles.isConfigured, isTrue);
      expect(
        MarineLayers.tileLayers,
        isNot(contains(MarineLayers.bathymetryTiles)),
      );
    });

    test('everything actually drawn is an overlay over the basemap', () {
      for (final layer in MarineLayers.tileLayers) {
        expect(layer.placement, MarineLayerPlacement.overBasemap);
      }
    });
  });

  group('provenance survives being attached to a renderer', () {
    test('cache namespace is the source id, so providers cannot mix', () {
      for (final layer in MarineLayers.tileLayers) {
        expect(layer.cacheNamespace, layer.source.id);
      }
      expect(
        MarineLayers.bathymetryTiles.cacheNamespace,
        isNot(MarineLayers.seamarkTiles.cacheNamespace),
      );
    });

    test('bathymetry carries the release it actually serves', () {
      expect(MarineLayers.emodnetBathymetry.edition, contains('2024'));
      expect(
        MarineLayers.emodnetBathymetry.vintage,
        MarineLayers.emodnetRelease,
      );
      expect(MarineLayers.emodnetBathymetry.vintageUnknown, isFalse);
    });

    test('seamarks are judged on fetch time, not on a missing vintage', () {
      // OSM has no release date. Demanding a vintage would make the layer
      // permanently "unknown"; fetch time is the honest substitute.
      expect(MarineLayers.openSeaMapSeamarks.continuouslyUpdated, isTrue);
      expect(MarineLayers.openSeaMapSeamarks.vintage, isNull);
      expect(MarineLayers.openSeaMapSeamarks.vintageUnknown, isFalse);
    });

    test('neither tile layer claims hydrographic authority', () {
      for (final layer in MarineLayers.tileLayers) {
        expect(
          layer.source.authority.isChart,
          isFalse,
          reason: layer.source.id,
        );
      }
    });
  });
}
