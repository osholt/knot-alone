import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/chart_source.dart';
import 'package:tide_and_seek/services/marine_layers.dart';

/// These tests exist to stop the "not for navigation" position eroding by
/// drift, which docs/chart-providers.md names as the main risk once the map
/// starts looking like a chart.
///
/// They are assertions about claims, not about rendering: no configured layer
/// may carry hydrographic authority while all of them are free sources, and
/// every layer must carry attribution because attribution is a licence
/// condition for all of them.
void main() {
  group('no free layer may pose as a chart', () {
    test('nothing configured carries hydrographic authority', () {
      expect(MarineLayers.anyOfficial, isFalse);
      for (final source in MarineLayers.all) {
        expect(
          source.authority.isChart,
          isFalse,
          reason: '${source.id} would let a surface say "chart"',
        );
      }
    });

    test('the crowd-sourced layer is labelled as such, not as survey data', () {
      expect(
        MarineLayers.openSeaMapSeamarks.authority,
        ChartAuthority.crowdSourced,
      );
    });

    test('bathymetry is survey-derived rather than official', () {
      // It is citable and survey-based, which is a stronger claim than
      // crowd-sourced and a weaker one than charted.
      expect(
        MarineLayers.emodnetBathymetry.authority,
        ChartAuthority.surveyDerived,
      );
    });
  });

  group('licence conditions are encoded, not assumed', () {
    test('every layer is configured and carries attribution', () {
      for (final source in MarineLayers.all) {
        expect(source.isConfigured, isTrue, reason: source.id);
        expect(
          source.licence.attribution.trim(),
          isNotEmpty,
          reason: source.id,
        );
      }
    });

    test('combined attribution names every source that is drawn', () {
      final combined = MarineLayers.combinedAttribution;
      expect(MarineLayers.drawn, isNotEmpty);
      for (final source in MarineLayers.drawn) {
        expect(combined, contains(source.licence.attribution));
      }
    });

    test('and names nothing that is not drawn', () {
      // Attribution states what is on screen. Crediting a source that is not
      // drawn overstates the map: a sailor reading "Depth data © EMODnet" in the
      // credits would reasonably conclude depth data was present, when this
      // build draws none.
      final combined = MarineLayers.combinedAttribution;
      for (final unused in MarineLayers.notInUse) {
        expect(
          combined,
          isNot(contains(unused.source.licence.attribution)),
          reason: unused.source.id,
        );
      }
    });

    test(
      'every known source is either drawn or has a stated reason not to be',
      () {
        final accounted = {
          ...MarineLayers.drawn.map((source) => source.id),
          ...MarineLayers.notInUse.map((unused) => unused.source.id),
        };
        expect(
          MarineLayers.all.map((source) => source.id).toSet(),
          accounted,
          reason:
              'a source that is neither drawn nor explained is invisible to the '
              'provenance sheet',
        );
        for (final unused in MarineLayers.notInUse) {
          expect(unused.reason.trim(), isNotEmpty, reason: unused.source.id);
        }
      },
    );

    test('UKHO attribution carries the Crown copyright wording', () {
      // Required by the Open Government Licence, and easy to lose in a reword.
      expect(
        MarineLayers.ukhoWrecks.licence.attribution.toLowerCase(),
        contains('crown copyright'),
      );
      expect(MarineLayers.ukhoWrecks.licence.name, contains('Open Government'));
    });

    test('OpenSeaMap is flagged share-alike', () {
      // The rendered tiles are CC-BY-SA, so anything derived from them
      // inherits it. Losing this flag is how a licence breach ships quietly.
      expect(MarineLayers.openSeaMapSeamarks.licence.shareAlike, isTrue);
    });

    test('no other layer is share-alike', () {
      final shareAlike = MarineLayers.all
          .where((source) => source.licence.shareAlike)
          .map((source) => source.id);
      expect(shareAlike, ['openseamap-seamarks']);
    });
  });

  group('layer identity', () {
    test('ids are unique, since they are used as cache namespaces', () {
      final ids = MarineLayers.all.map((source) => source.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every layer says what it does not cover', () {
      for (final source in MarineLayers.all) {
        expect(source.coverageNote?.trim(), isNotEmpty, reason: source.id);
      }
    });

    test('the wrecks note refuses the inference a hazard map invites', () {
      // A sailor reading an empty patch as clear water is the specific
      // misreading this layer enables.
      expect(
        MarineLayers.ukhoWrecks.coverageNote,
        contains('absence of a record is not evidence of clear water'),
      );
    });
  });
}
