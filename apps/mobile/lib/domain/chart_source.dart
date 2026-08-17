/// Where a marine data layer came from, and what may honestly be claimed of it.
///
/// Written before any layer was drawn, deliberately. The risk with marine data
/// is not that the map looks wrong — it is that the map looks *right*, and a
/// crowd-sourced seamark layer with a two-year-old vintage gets read as a
/// surveyed chart. Every layer therefore has to carry its own provenance, and
/// the UI has to be able to state it without asking the layer nicely.
library;

/// Who stands behind a layer.
///
/// This is the distinction that decides what wording a surface may use. Only
/// [official] may be called a chart without qualification.
enum ChartAuthority {
  /// Issued by a national hydrographic office, with a chart edition and
  /// Notices to Mariners behind it. What SOLAS carriage requirements mean.
  official,

  /// Survey-derived and citable — a bathymetric grid, a wrecks database — but
  /// not a navigational chart and carrying no edition.
  surveyDerived,

  /// Crowd-sourced. Useful context, no authority, no edition, and no promise
  /// that anything is where it appears to be.
  crowdSourced;

  /// Whether a surface may use the bare word "chart" for this layer.
  bool get isChart => this == ChartAuthority.official;

  /// One line the UI can show verbatim. Deliberately blunt.
  String get caveat => switch (this) {
    ChartAuthority.official => 'Official chart data.',
    ChartAuthority.surveyDerived =>
      'Survey data, not a navigational chart. Depths are indicative.',
    ChartAuthority.crowdSourced =>
      'Crowd-sourced. Not surveyed, not official, and may be wrong or missing.',
  };
}

/// The licence a layer is used under.
///
/// Attribution is not optional metadata: for every open source considered it is
/// a condition of use, and `PLAN.md` requires it to stay visible offline. A
/// source with no attribution text is treated as misconfigured rather than as
/// unencumbered.
class ChartLicence {
  const ChartLicence({
    required this.name,
    required this.attribution,
    this.url,
    this.permitsOfflineCache = false,
    this.shareAlike = false,
  });

  final String name;

  /// Shown on the map, offline included. Must be non-empty.
  final String attribution;
  final String? url;

  /// Whether the licence permits storing tiles or cells on the device. False
  /// is the safe default: caching without permission is the failure mode that
  /// looks like a feature.
  final bool permitsOfflineCache;

  /// Whether derived tiles must be released under the same terms. True for
  /// OpenSeaMap's rendered tiles, which matters if this app ever ships its own
  /// rendering of them.
  final bool shareAlike;

  bool get isUsable => name.trim().isNotEmpty && attribution.trim().isNotEmpty;
}

/// A marine data layer and everything needed to describe it truthfully.
class ChartSource {
  const ChartSource({
    required this.id,
    required this.displayName,
    required this.authority,
    required this.licence,
    this.vintage,
    this.edition,
    this.coverageNote,
  });

  /// Stable identifier. Used as a cache namespace, so it must not move when the
  /// display name is reworded.
  final String id;
  final String displayName;
  final ChartAuthority authority;
  final ChartLicence licence;

  /// When the data was published or last updated at source, if the provider
  /// states it. Null means the provider does not say — which is itself worth
  /// showing, rather than quietly presenting the data as current.
  final DateTime? vintage;

  /// Chart edition, where the concept exists. Only [ChartAuthority.official]
  /// sources have one.
  final String? edition;

  /// What this layer does and does not cover, in the provider's own terms.
  final String? coverageNote;

  bool get isConfigured => id.trim().isNotEmpty && licence.isUsable;

  /// Whether this layer may be stored on the device for offline use.
  bool get cacheable => licence.permitsOfflineCache;

  /// True when the provider states no vintage, so freshness cannot be judged.
  bool get vintageUnknown => vintage == null;

  /// How old the data is at [now], or null when the provider states no vintage.
  Duration? ageAt(DateTime now) {
    final published = vintage;
    if (published == null) return null;
    final age = now.difference(published);
    return age.isNegative ? Duration.zero : age;
  }
}
