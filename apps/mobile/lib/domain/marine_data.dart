/// Provenance and freshness carried by every non-chart marine datum.
///
/// A tide height, wind arrow or AIS target must never become an anonymous dot
/// on the chart. These small value objects keep the source, licence, validity
/// time and receive time beside the value all the way to the UI.
library;

enum MarineDataKind {
  observation,
  forecast,
  prediction,
  calculated,
  communityReport,
  replay;

  String get label => switch (this) {
    MarineDataKind.observation => 'Observed',
    MarineDataKind.forecast => 'Forecast',
    MarineDataKind.prediction => 'Predicted',
    MarineDataKind.calculated => 'Calculated',
    MarineDataKind.communityReport => 'Community report',
    MarineDataKind.replay => 'Replay',
  };
}

enum MarineDataAuthority {
  official,
  provider,
  onboard,
  community;

  String get label => switch (this) {
    MarineDataAuthority.official => 'Official source',
    MarineDataAuthority.provider => 'Data provider',
    MarineDataAuthority.onboard => 'On-board source',
    MarineDataAuthority.community => 'Community source',
  };
}

class MarineDataLicence {
  const MarineDataLicence({
    required this.name,
    required this.attribution,
    this.url,
    this.permitsOfflineCache = false,
    this.permitsCrewShare = false,
  });

  final String name;
  final String attribution;
  final String? url;
  final bool permitsOfflineCache;
  final bool permitsCrewShare;

  bool get isUsable => name.trim().isNotEmpty && attribution.trim().isNotEmpty;
}

class MarineDataSource {
  const MarineDataSource({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.authority,
    required this.licence,
    this.coverageNote,
  });

  final String id;
  final String displayName;
  final MarineDataKind kind;
  final MarineDataAuthority authority;
  final MarineDataLicence licence;
  final String? coverageNote;

  bool get isConfigured =>
      id.trim().isNotEmpty && displayName.trim().isNotEmpty && licence.isUsable;
}

enum MarineDataFreshness { upcoming, current, stale }

class MarineDatum<T> {
  const MarineDatum({
    required this.value,
    required this.source,
    required this.validAt,
    required this.receivedAt,
    required this.staleAfter,
    this.unit,
    this.qualityNote,
  });

  final T value;
  final MarineDataSource source;

  /// Time the value describes, as stated by the source.
  final DateTime validAt;

  /// Time this device received or calculated the value.
  final DateTime receivedAt;

  /// Source-specific lifetime after [validAt]. It is deliberately explicit:
  /// an AIS position and a harmonic tide height age at very different rates.
  final Duration staleAfter;
  final String? unit;
  final String? qualityNote;

  Duration ageAt(DateTime now) {
    final age = now.toUtc().difference(validAt.toUtc());
    return age.isNegative ? Duration.zero : age;
  }

  MarineDataFreshness freshnessAt(DateTime now) {
    final instant = now.toUtc();
    final valid = validAt.toUtc();
    if (instant.isBefore(valid)) return MarineDataFreshness.upcoming;
    return instant.difference(valid) <= staleAfter
        ? MarineDataFreshness.current
        : MarineDataFreshness.stale;
  }
}
