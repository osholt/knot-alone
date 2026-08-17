import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/chart_source.dart';
import 'package:tide_and_seek/services/chart_coverage.dart';

/// The rule under test is from PLAN.md: the app refuses to call an area cached
/// when required tiles or cells are missing or outside their permitted
/// validity.
///
/// The failure being guarded against is silent. A sailor downloads an area,
/// loses signal, and the map thins out where they actually are. So these tests
/// are mostly about `usableOffline` being false for every individual reason,
/// including the ones that are easy to wave away.
void main() {
  final now = DateTime.utc(2026, 8, 17);

  ChartLicence openLicence({bool cache = true}) => ChartLicence(
    name: 'Open Government Licence v3.0',
    attribution: 'Contains UKHO data © Crown copyright',
    permitsOfflineCache: cache,
  );

  ChartSource sourceWith({
    ChartAuthority authority = ChartAuthority.surveyDerived,
    DateTime? vintage,
    bool cache = true,
    String id = 'ukho-wrecks',
    ChartLicence? licence,
  }) => ChartSource(
    id: id,
    displayName: 'UKHO wrecks and obstructions',
    authority: authority,
    licence: licence ?? openLicence(cache: cache),
    vintage: vintage,
  );

  group('an area is only usable offline when nothing is in doubt', () {
    test('a complete, fresh, cacheable, attributed area is usable', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(vintage: DateTime.utc(2026, 7, 1)),
        requiredTiles: 120,
        presentTiles: 120,
        now: now,
      );

      expect(coverage.usableOffline, isTrue);
      expect(coverage.shortfalls, isEmpty);
      expect(coverage.isComplete, isTrue);
    });

    test('one missing tile out of a thousand is not "downloaded"', () {
      // The whole point. A ratio would call this 99.9% and a UI would round it
      // to "ready offline"; the missing tile is where the sailor will be.
      final coverage = ChartCoverage.assess(
        source: sourceWith(vintage: DateTime.utc(2026, 7, 1)),
        requiredTiles: 1000,
        presentTiles: 999,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(coverage.shortfalls, contains(CoverageShortfall.incomplete));
    });

    test('an area nothing was required for is not trivially complete', () {
      // Zero required tiles means the area was never asked for. Reporting that
      // as covered would make an un-downloaded area look ready.
      final coverage = ChartCoverage.assess(
        source: sourceWith(vintage: DateTime.utc(2026, 7, 1)),
        requiredTiles: 0,
        presentTiles: 0,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(coverage.shortfalls, contains(CoverageShortfall.incomplete));
      expect(coverage.isComplete, isFalse);
    });
  });

  group('licence and configuration gate drawing at all', () {
    test('a licence that forbids caching cannot be usable offline', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(vintage: DateTime.utc(2026, 8, 1), cache: false),
        requiredTiles: 10,
        presentTiles: 10,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(
        coverage.shortfalls,
        contains(CoverageShortfall.cachingNotPermitted),
      );
    });

    test('a source with no attribution is misconfigured, not unencumbered', () {
      // Attribution is a condition of use for every open source considered, and
      // PLAN.md requires it visible offline. Absent attribution is a bug.
      final coverage = ChartCoverage.assess(
        source: sourceWith(
          vintage: DateTime.utc(2026, 8, 1),
          licence: const ChartLicence(name: 'ODbL', attribution: '   '),
        ),
        requiredTiles: 10,
        presentTiles: 10,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(coverage.shortfalls, contains(CoverageShortfall.misconfigured));
    });
  });

  group('validity is judged per authority, and silence is not freshness', () {
    test('a provider that states no vintage cannot be called fresh', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(),
        requiredTiles: 10,
        presentTiles: 10,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(coverage.shortfalls, contains(CoverageShortfall.vintageUnknown));
      expect(coverage.source.vintageUnknown, isTrue);
    });

    test('a crowd-sourced layer expires sooner than a survey grid', () {
      // Deliberate: a crowd-sourced layer has no Notices to Mariners behind it,
      // so its age matters more rather than less.
      const policy = ChartValidityPolicy();
      expect(
        policy.limitFor(ChartAuthority.crowdSourced),
        lessThan(policy.limitFor(ChartAuthority.surveyDerived)),
      );
      expect(
        policy.limitFor(ChartAuthority.official),
        lessThan(policy.limitFor(ChartAuthority.crowdSourced)),
      );
    });

    test('a six-month-old crowd-sourced layer is outside validity', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(
          authority: ChartAuthority.crowdSourced,
          vintage: DateTime.utc(2026, 2, 1),
        ),
        requiredTiles: 10,
        presentTiles: 10,
        now: now,
      );

      expect(coverage.usableOffline, isFalse);
      expect(coverage.shortfalls, contains(CoverageShortfall.outsideValidity));
    });

    test('the same age is still inside validity for a survey grid', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(
          authority: ChartAuthority.surveyDerived,
          vintage: DateTime.utc(2026, 2, 1),
        ),
        requiredTiles: 10,
        presentTiles: 10,
        now: now,
      );

      expect(coverage.usableOffline, isTrue);
    });

    test(
      'a vintage in the future is clamped rather than read as negative age',
      () {
        final source = sourceWith(vintage: DateTime.utc(2027, 1, 1));
        expect(source.ageAt(now), Duration.zero);
      },
    );
  });

  group('what a surface may claim', () {
    test('only an official source may use the bare word chart', () {
      expect(ChartAuthority.official.isChart, isTrue);
      expect(ChartAuthority.surveyDerived.isChart, isFalse);
      expect(ChartAuthority.crowdSourced.isChart, isFalse);
    });

    test('every authority carries a caveat the UI can show verbatim', () {
      for (final authority in ChartAuthority.values) {
        expect(authority.caveat.trim(), isNotEmpty, reason: authority.name);
      }
      expect(
        ChartAuthority.crowdSourced.caveat.toLowerCase(),
        contains('not surveyed'),
      );
    });

    test('every shortfall says what it means without further wording', () {
      for (final shortfall in CoverageShortfall.values) {
        expect(shortfall.message.trim(), isNotEmpty, reason: shortfall.name);
      }
    });

    test('the most severe shortfall is reported first', () {
      final coverage = ChartCoverage.assess(
        source: sourceWith(
          cache: false,
          licence: const ChartLicence(name: '', attribution: ''),
        ),
        requiredTiles: 0,
        presentTiles: 0,
        now: now,
      );

      expect(coverage.primaryShortfall, CoverageShortfall.misconfigured);
      expect(coverage.shortfalls.length, greaterThan(1));
    });
  });
}
