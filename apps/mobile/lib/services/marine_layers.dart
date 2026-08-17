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

/// Licence text is checked in rather than fetched, because it is a condition of
/// use and must survive being offline.
abstract final class MarineLayers {
  /// Depth shading for European seas, falling back to global GEBCO.
  ///
  /// Survey-derived, so it may say what the seabed is thought to look like. It
  /// is not soundings and it is not a substitute for charted depths.
  static const emodnetBathymetry = ChartSource(
    id: 'emodnet-bathymetry',
    displayName: 'EMODnet Bathymetry',
    authority: ChartAuthority.surveyDerived,
    licence: ChartLicence(
      name: 'EMODnet / GEBCO open terms',
      attribution: 'Depth data © EMODnet Bathymetry and GEBCO',
      url: 'https://emodnet.ec.europa.eu/en/bathymetry',
      permitsOfflineCache: true,
    ),
    coverageNote:
        'European seas at EMODnet resolution, the rest of the world from '
        'GEBCO. Indicative depth only, not charted soundings.',
  );

  /// Wrecks and obstructions. The most directly useful free UKHO data set:
  /// 94,000+ records, global, quarterly, and explicitly free under the Open
  /// Government Licence.
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
    coverageNote:
        'Buoyage, lights and harbour detail contributed by volunteers. '
        'Coverage is uneven and no edition or Notice to Mariners stands '
        'behind it.',
  );

  /// Every layer this build knows about.
  static const all = <ChartSource>[
    emodnetBathymetry,
    ukhoWrecks,
    openSeaMapSeamarks,
  ];

  /// True when no configured layer carries hydrographic authority, which is the
  /// current state and the reason the "not for navigation" position stands.
  static bool get anyOfficial => all.any((source) => source.authority.isChart);

  /// One line summarising what the map is built from, for the map's own
  /// attribution surface. Every licence here requires attribution, so this is
  /// not decoration.
  static String get combinedAttribution =>
      all.map((source) => source.licence.attribution).join(' · ');
}
