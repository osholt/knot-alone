/// Whether a layer can be trusted offline for a given area, and why not.
///
/// `PLAN.md` states the rule this file exists to enforce: *the app refuses to
/// call an area cached when required tiles or cells are missing or outside
/// their permitted validity*. The failure it guards against is the quiet one —
/// a sailor drops out of signal believing an area was downloaded, and the map
/// silently thins out.
///
/// So [ChartCoverage.usableOffline] is deliberately pessimistic: every reason to
/// doubt makes it false, and each reason is named so the UI can say which.
library;

import '../domain/chart_source.dart';

/// Why an area is not usable offline. Ordered most to least severe.
enum CoverageShortfall {
  /// The source is not configured, or has no attribution, so it must not draw.
  misconfigured,

  /// The licence does not permit storing this data on the device.
  cachingNotPermitted,

  /// Some required tiles or cells were never fetched.
  incomplete,

  /// The data is older than the freshness bound for its kind.
  outsideValidity,

  /// The provider states no vintage, so freshness cannot be established.
  vintageUnknown;

  String get message => switch (this) {
    CoverageShortfall.misconfigured =>
      'This layer is not configured and will not be drawn.',
    CoverageShortfall.cachingNotPermitted =>
      'This layer may not be stored for offline use, so it needs a connection.',
    CoverageShortfall.incomplete =>
      'Some of this area was never downloaded. Do not rely on it offline.',
    CoverageShortfall.outsideValidity =>
      'This data is older than its usable life. Refresh before relying on it.',
    CoverageShortfall.vintageUnknown =>
      'The provider does not say when this data was last updated.',
  };
}

/// How long each kind of data stays usable before it must be refreshed.
///
/// These are judgement calls, not standards, and they are deliberately short.
/// An official chart has Notices to Mariners behind it and a real edition
/// cycle; a crowd-sourced layer has neither, so its age matters more rather
/// than less.
class ChartValidityPolicy {
  const ChartValidityPolicy({
    this.official = const Duration(days: 28),
    this.surveyDerived = const Duration(days: 365),
    this.crowdSourced = const Duration(days: 90),
  });

  final Duration official;
  final Duration surveyDerived;
  final Duration crowdSourced;

  Duration limitFor(ChartAuthority authority) => switch (authority) {
    ChartAuthority.official => official,
    ChartAuthority.surveyDerived => surveyDerived,
    ChartAuthority.crowdSourced => crowdSourced,
  };
}

/// The verdict on one layer over one area.
class ChartCoverage {
  const ChartCoverage({
    required this.source,
    required this.requiredTiles,
    required this.presentTiles,
    required this.shortfalls,
    this.fetchedAt,
  });

  final ChartSource source;

  /// Tiles or cells the area needs, and how many of those are on the device.
  final int requiredTiles;
  final int presentTiles;

  /// When this area was last fetched, or null if never.
  final DateTime? fetchedAt;

  /// Every reason this area is not usable offline. Empty means it is.
  final List<CoverageShortfall> shortfalls;

  /// The single honest answer to "is this area downloaded?".
  ///
  /// Note what this is *not*: a tile count ratio. A 99%-complete area is not
  /// "downloaded", because the missing 1% is exactly where the sailor will be
  /// when they need it.
  bool get usableOffline => shortfalls.isEmpty;

  /// True when tiles are missing, whatever else is wrong.
  bool get isComplete => requiredTiles > 0 && presentTiles >= requiredTiles;

  /// The most severe shortfall, for a one-line UI summary.
  CoverageShortfall? get primaryShortfall =>
      shortfalls.isEmpty ? null : shortfalls.first;

  /// Assesses [source] over an area, naming every reason to doubt it.
  static ChartCoverage assess({
    required ChartSource source,
    required int requiredTiles,
    required int presentTiles,
    required DateTime now,
    DateTime? fetchedAt,
    ChartValidityPolicy policy = const ChartValidityPolicy(),
  }) {
    final shortfalls = <CoverageShortfall>[];

    if (!source.isConfigured) {
      shortfalls.add(CoverageShortfall.misconfigured);
    }
    if (!source.cacheable) {
      shortfalls.add(CoverageShortfall.cachingNotPermitted);
    }
    // An area with nothing required has not been "covered" - it has not been
    // asked for. Treated as incomplete rather than as trivially complete.
    if (requiredTiles <= 0 || presentTiles < requiredTiles) {
      shortfalls.add(CoverageShortfall.incomplete);
    }

    final age = source.ageAt(now);
    if (age == null) {
      shortfalls.add(CoverageShortfall.vintageUnknown);
    } else if (age > policy.limitFor(source.authority)) {
      shortfalls.add(CoverageShortfall.outsideValidity);
    }

    return ChartCoverage(
      source: source,
      requiredTiles: requiredTiles,
      presentTiles: presentTiles,
      fetchedAt: fetchedAt,
      shortfalls: List.unmodifiable(shortfalls),
    );
  }
}
