/// The marine data layers this build can draw, and the terms they come under.
///
/// None of these is a chart. That is not a hedge — it is the finding in
/// `docs/chart-providers.md`: official charts for UK and Mediterranean waters
/// are commercial without exception, and the free sources below are bathymetry,
/// hazard databases and crowd-sourced seamarks. Together they make a legitimate
/// passage-planning aid; they do not make a chart plotter.
///
/// Each layer carries its own licence and vintage so `ChartCoverage` can refuse
/// to call an area usable offline when it should not, and so attribution stays
/// visible offline as every one of these licences requires.
library;

import '../domain/chart_source.dart';
import 'marine_tile_layer.dart';

/// Licence text is checked in rather than fetched, because it is a condition of
/// use and must survive being offline.
abstract final class MarineLayers {
  /// Depth shading for European seas, falling back to global GEBCO.
  ///
  /// Survey-derived, so it may say what the seabed is thought to look like. It
  /// is not soundings and it is not a substitute for charted depths.
  static final emodnetBathymetry = ChartSource(
    id: 'emodnet-bathymetry',
    displayName: 'EMODnet Bathymetry',
    authority: ChartAuthority.surveyDerived,
    licence: ChartLicence(
      name: 'EMODnet / GEBCO open terms',
      attribution: 'Depth data © EMODnet Bathymetry and GEBCO',
      url: 'https://emodnet.ec.europa.eu/en/bathymetry',
      permitsOfflineCache: true,
    ),
    // The served product is the 2024 release (v12 of mean_atlas_land). The
    // year is the edition; the day is not meaningful.
    vintage: emodnetRelease,
    edition: 'mean_atlas_land 2024',
    coverageNote:
        'European seas at EMODnet resolution, the rest of the world from '
        'GEBCO. Indicative depth only, not charted soundings.',
  );

  /// Wrecks and obstructions. The most directly useful free UKHO data set:
  /// 94,000+ records, global, quarterly, and free of charge under the Open
  /// Government Licence.
  ///
  /// **Not cleared for use here.** The access page says OGL, but UKHO has also
  /// published, as a term on top of the OGL, that its data sets "must not be
  /// used for navigation or in the creation of navigational products". This app
  /// is a navigational product on any reading, so that term — if it governs —
  /// blocks this layer however the UI is captioned. The INSPIRE metadata for the
  /// bathymetry product instead carries only a fitness warning ("not suitable
  /// for use in marine navigation"), which would not block it, and the current
  /// portal does not publish its terms inline. The two readings differ on
  /// whether this is usable at all.
  ///
  /// So this stays modelled and undrawn until UKHO answers in writing. See
  /// `docs/chart-providers.md` for the quotes, the sources and the question to
  /// put to them.
  static const ukhoWrecks = ChartSource(
    id: 'ukho-wrecks-obstructions',
    displayName: 'UKHO wrecks and obstructions',
    authority: ChartAuthority.surveyDerived,
    licence: ChartLicence(
      name: 'Open Government Licence v3.0',
      attribution: 'Contains UKHO data © Crown copyright and database right',
      url: 'https://www.admiralty.co.uk/access-data/marine-data',
      permitsOfflineCache: true,
    ),
    coverageNote:
        'Charted, uncharted, live and dead wrecks and obstructions. A hazard '
        'database, not a chart: absence of a record is not evidence of clear '
        'water.',
  );

  /// Seamarks, buoyage and lights from OpenStreetMap.
  ///
  /// Two things to keep in view. The rendered tiles are CC-BY-SA, so anything
  /// derived from them inherits share-alike. And OpenSeaMap publishes no usage
  /// policy, rate limit or availability guarantee at all, which is why this
  /// entry exists as data to render rather than as a tile server to lean on.
  static const openSeaMapSeamarks = ChartSource(
    id: 'openseamap-seamarks',
    displayName: 'OpenSeaMap seamarks',
    authority: ChartAuthority.crowdSourced,
    licence: ChartLicence(
      name: 'ODbL (data) / CC-BY-SA 2.0 (rendered tiles)',
      attribution: '© OpenStreetMap contributors, OpenSeaMap (CC-BY-SA)',
      url: 'https://www.openseamap.org/',
      permitsOfflineCache: true,
      shareAlike: true,
    ),
    // Volunteers edit continuously; there is no release to date. Freshness is
    // therefore judged on when this device last fetched a tile.
    continuouslyUpdated: true,
    coverageNote:
        'Buoyage, lights and harbour detail contributed by volunteers. '
        'Coverage is uneven and no edition or Notice to Mariners stands '
        'behind it.',
  );

  /// Release year of the EMODnet product actually served by [bathymetryTiles].
  static final emodnetRelease = DateTime.utc(2024);

  /// EMODnet raster tiles, **not enabled**, and the reason is worth keeping.
  ///
  /// The endpoint works: `v12/mean_atlas_land` serves real tiles over
  /// `web_mercator` (v13 is a 404). But its colour ramp is built for ocean
  /// depths, so over a shelf sea it renders near-white. Fetched over the Solent
  /// at z10, all three EMODnet products — `mean_atlas_land`, `baselayer` and
  /// `baselayer_land` — show the water as white with no gradient at all.
  ///
  /// Drawn in the app it therefore contributed land hill-shading to a sailing
  /// app and nothing whatsoever to the water, while washing out the basemap. It
  /// is the wrong tool for the 0–30 m a yacht actually cares about.
  ///
  /// Coastal depth needs survey data at coastal resolution. UKHO bathymetry is
  /// free under an OGL-like licence and has it, but it is a download-and-index
  /// job rather than a tile URL — see the issue tracker.
  static final bathymetryTiles = MarineTileLayer(
    source: emodnetBathymetry,
    urlTemplate:
        'https://tiles.emodnet-bathymetry.eu/v12/mean_atlas_land/web_mercator/{z}/{x}/{y}.png',
    placement: MarineLayerPlacement.beneathBasemap,
    maxZoom: 12,
    opacity: 0.85,
  );

  /// Seamarks, buoyage and lights. A transparent overlay: the tiles carry only
  /// the marks, so whatever is beneath shows through.
  ///
  /// Pointed at OpenSeaMap's public tile server, which publishes no usage
  /// policy or availability guarantee. That is a deliberate first step, not a
  /// resting place — see docs/chart-providers.md. The template is overridable
  /// so a self-hosted renderer can replace it without touching this file.
  static final seamarkTiles = MarineTileLayer(
    source: openSeaMapSeamarks,
    urlTemplate: const String.fromEnvironment(
      'TIDE_AND_SEEK_SEAMARK_TILE_URL',
      defaultValue: 'https://tiles.openseamap.org/seamark/{z}/{x}/{y}.png',
    ),
    placement: MarineLayerPlacement.overBasemap,
    minZoom: 9,
    maxZoom: 18,
  );

  /// The tile layers actually drawn, in draw order: ground first, annotation
  /// last.
  ///
  /// [bathymetryTiles] is deliberately absent. It is configured and correct,
  /// and it is useless here — see its own note.
  static final tileLayers = <MarineTileLayer>[seamarkTiles];

  /// Every layer this build knows about.
  static final all = <ChartSource>[
    emodnetBathymetry,
    ukhoWrecks,
    openSeaMapSeamarks,
  ];

  /// The sources actually on screen.
  static final drawn = <ChartSource>[
    for (final layer in tileLayers)
      if (layer.isConfigured) layer.source,
  ];

  /// Sources this build knows about but does not draw, each with the reason.
  ///
  /// Kept here rather than on [ChartSource] because "not drawn" is a fact about
  /// this build, not about the data. And stated in the UI rather than only in a
  /// doc comment: a sailor who has read that the app carries depth data needs to
  /// be told, on screen, that no depth data is being shown. Silence there is the
  /// same failure mode as a stale layer — the map looks complete.
  static final notInUse = <UnusedChartSource>[
    UnusedChartSource(
      source: emodnetBathymetry,
      reason:
          'Its colour ramp is built for ocean depths, so it renders shelf '
          'water white and adds nothing over a sailing area.',
    ),
    UnusedChartSource(
      source: ukhoWrecks,
      reason:
          'Awaiting written confirmation from the UK Hydrographic Office that '
          'its licence permits use in a navigation app. It also needs a '
          'download-and-index step, as it is published as a bulk data set '
          'rather than tiles.',
    ),
  ];

  /// True when no configured layer carries hydrographic authority, which is the
  /// current state and the reason the "not for navigation" position stands.
  static bool get anyOfficial => all.any((source) => source.authority.isChart);

  /// One line summarising what the map is built from, for the map's own
  /// attribution surface. Every licence here requires attribution, so this is
  /// not decoration.
  ///
  /// Built from [drawn], not from [all]. Attribution is a statement about what
  /// is on screen: crediting EMODnet while no EMODnet tile is drawn would
  /// overstate the map rather than over-comply, and a sailor reading the credits
  /// would reasonably conclude depth data was present.
  static String get combinedAttribution =>
      drawn.map((source) => source.licence.attribution).join(' · ');
}

/// A source this build knows about but does not draw.
class UnusedChartSource {
  const UnusedChartSource({required this.source, required this.reason});

  final ChartSource source;

  /// Why it is not drawn, in terms a sailor can act on.
  final String reason;
}
