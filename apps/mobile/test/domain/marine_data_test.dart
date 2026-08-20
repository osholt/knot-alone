import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/marine_data.dart';

const _source = MarineDataSource(
  id: 'open-meteo-wind',
  displayName: 'Open-Meteo wind',
  kind: MarineDataKind.forecast,
  authority: MarineDataAuthority.provider,
  licence: MarineDataLicence(
    name: 'CC BY 4.0',
    attribution: 'Weather data by Open-Meteo.com',
    permitsOfflineCache: true,
    permitsCrewShare: true,
  ),
);

void main() {
  test('a source is configured only with stable identity and attribution', () {
    expect(_source.isConfigured, isTrue);
    expect(
      const MarineDataSource(
        id: '',
        displayName: 'Anonymous',
        kind: MarineDataKind.observation,
        authority: MarineDataAuthority.community,
        licence: MarineDataLicence(name: 'Unknown', attribution: ''),
      ).isConfigured,
      isFalse,
    );
  });

  test('freshness distinguishes future, current, and stale values', () {
    final validAt = DateTime.utc(2026, 8, 20, 12);
    final datum = MarineDatum<double>(
      value: 14,
      source: _source,
      validAt: validAt,
      receivedAt: DateTime.utc(2026, 8, 20, 11, 55),
      staleAfter: const Duration(hours: 2),
      unit: 'kn',
    );

    expect(
      datum.freshnessAt(DateTime.utc(2026, 8, 20, 11)),
      MarineDataFreshness.upcoming,
    );
    expect(
      datum.freshnessAt(DateTime.utc(2026, 8, 20, 14)),
      MarineDataFreshness.current,
    );
    expect(
      datum.freshnessAt(DateTime.utc(2026, 8, 20, 14, 0, 1)),
      MarineDataFreshness.stale,
    );
    expect(datum.ageAt(DateTime.utc(2026, 8, 20, 11)), Duration.zero);
  });
}
