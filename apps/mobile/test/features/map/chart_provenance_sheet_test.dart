import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/chart_source.dart';
import 'package:tide_and_seek/features/map/chart_provenance_sheet.dart';
import 'package:tide_and_seek/services/chart_coverage.dart';
import 'package:tide_and_seek/services/marine_layers.dart';

/// #17. The model could state provenance; nothing put it on screen. These tests
/// are about what a sailor is told, so they assert on wording rather than on
/// structure: the risk being guarded against is a map that reads as a chart.
void main() {
  final now = DateTime.utc(2026, 8, 17);

  Future<void> pump(
    WidgetTester tester, {
    List<ChartSource>? drawn,
    List<UnusedChartSource>? notInUse,
    List<ChartCoverage> coverage = const [],
    Size size = const Size(430, 932),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: ChartProvenanceSheet(
            now: now,
            drawn: drawn,
            notInUse: notInUse,
            coverage: coverage,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const crowdSourced = ChartSource(
    id: 'test-seamarks',
    displayName: 'Test seamarks',
    authority: ChartAuthority.crowdSourced,
    licence: ChartLicence(
      name: 'ODbL',
      attribution: '© Test contributors',
      url: 'https://example.invalid/licence',
      permitsOfflineCache: true,
      shareAlike: true,
    ),
    continuouslyUpdated: true,
    coverageNote: 'Uneven volunteer coverage.',
  );

  final official = ChartSource(
    id: 'test-official',
    displayName: 'Test official chart',
    authority: ChartAuthority.official,
    licence: const ChartLicence(
      name: 'AVCS',
      attribution: '© Crown copyright',
      permitsOfflineCache: true,
    ),
    vintage: DateTime.utc(2026, 8, 1),
    edition: 'Edition 7',
  );

  group('the authority banner', () {
    testWidgets('says not for navigation when nothing official is drawn', (
      tester,
    ) async {
      await pump(tester, drawn: const [crowdSourced], notInUse: const []);
      expect(find.text('Not for navigation'), findsOneWidget);
      expect(
        find.textContaining('issued by a hydrographic office'),
        findsOneWidget,
      );
      // The actionable half of the sentence, not just the disclaimer.
      expect(find.textContaining('Carry official charts'), findsOneWidget);
    });

    testWidgets('changes when official data is drawn', (tester) async {
      await pump(tester, drawn: [official], notInUse: const []);
      expect(find.text('Not for navigation'), findsNothing);
      expect(find.text('Official chart data in use'), findsOneWidget);
      expect(find.textContaining('Notices to Mariners'), findsOneWidget);
    });

    testWidgets('one official layer among crowd-sourced ones is not enough to '
        'drop the warning for the others', (tester) async {
      await pump(tester, drawn: [official, crowdSourced], notInUse: const []);
      // The banner reflects that official data is present, and each card still
      // carries its own caveat, so the crowd-sourced layer is not laundered by
      // sitting next to a chart.
      expect(find.text('Official chart data in use'), findsOneWidget);
      expect(
        find.textContaining('Crowd-sourced. Not surveyed'),
        findsOneWidget,
      );
    });
  });

  group('a source card', () {
    testWidgets('shows the attribution its licence requires', (tester) async {
      await pump(tester, drawn: const [crowdSourced], notInUse: const []);
      expect(find.text('© Test contributors'), findsOneWidget);
      expect(find.text('ODbL'), findsOneWidget);
      expect(
        find.byKey(const Key('chart-source-test-seamarks')),
        findsOneWidget,
      );
    });

    testWidgets('states the authority rather than leaving it to be inferred', (
      tester,
    ) async {
      await pump(tester, drawn: const [crowdSourced], notInUse: const []);
      expect(find.text('Crowd-sourced'), findsOneWidget);
      expect(find.textContaining('may be wrong or missing'), findsOneWidget);
    });

    testWidgets('a continuously updated source claims no publication date', (
      tester,
    ) async {
      await pump(tester, drawn: const [crowdSourced], notInUse: const []);
      expect(
        find.textContaining('no edition or publication date exists'),
        findsOneWidget,
      );
    });

    testWidgets('a dated source shows its edition and age', (tester) async {
      await pump(tester, drawn: [official], notInUse: const []);
      expect(find.textContaining('Edition 7'), findsOneWidget);
      expect(find.textContaining('16 days old'), findsOneWidget);
    });

    testWidgets('a source with no stated vintage says so, rather than looking '
        'current', (tester) async {
      const undated = ChartSource(
        id: 'test-undated',
        displayName: 'Undated data',
        authority: ChartAuthority.surveyDerived,
        licence: ChartLicence(name: 'OGL', attribution: '© Someone'),
      );
      await pump(tester, drawn: const [undated], notInUse: const []);
      expect(
        find.textContaining('does not say when this was last updated'),
        findsOneWidget,
      );
    });
  });

  group('layers that are not drawn', () {
    testWidgets('are listed with the reason', (tester) async {
      await pump(
        tester,
        drawn: const [crowdSourced],
        notInUse: const [
          UnusedChartSource(
            source: ChartSource(
              id: 'test-depth',
              displayName: 'Test depth data',
              authority: ChartAuthority.surveyDerived,
              licence: ChartLicence(name: 'OGL', attribution: '© Someone'),
            ),
            reason: 'Needs an indexing step that is not built yet.',
          ),
        ],
      );
      expect(find.text('Not shown'), findsOneWidget);
      expect(find.text('Test depth data'), findsOneWidget);
      expect(
        find.text('Needs an indexing step that is not built yet.'),
        findsOneWidget,
      );
    });

    // The real build has no depth layer. A sailor told the app carries depth
    // data has to be able to find out that none is being drawn.
    testWidgets('the real build discloses that its depth source is off', (
      tester,
    ) async {
      await pump(tester, size: const Size(430, 2400));
      expect(
        find.byKey(const Key('chart-source-unused-emodnet-bathymetry')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('chart-source-unused-ukho-wrecks-obstructions')),
        findsOneWidget,
      );
    });
  });

  group('offline coverage', () {
    testWidgets('unassessed is reported as unassessed, not as fine', (
      tester,
    ) async {
      await pump(tester, drawn: const [crowdSourced], notInUse: const []);
      expect(
        find.byKey(const Key('chart-provenance-coverage-unassessed')),
        findsOneWidget,
      );
      expect(
        find.textContaining('assume the map needs a connection'),
        findsOneWidget,
      );
    });

    testWidgets('every shortfall is listed, not only the most severe', (
      tester,
    ) async {
      final coverage = ChartCoverage.assess(
        source: crowdSourced,
        requiredTiles: 40,
        presentTiles: 12,
        now: now,
        // Old enough to breach the 90-day crowd-sourced bound as well as being
        // incomplete, so there are two independent reasons to distrust it.
        fetchedAt: now.subtract(const Duration(days: 200)),
      );
      expect(coverage.shortfalls, hasLength(2));
      await pump(
        tester,
        drawn: const [crowdSourced],
        notInUse: const [],
        coverage: [coverage],
      );
      expect(find.textContaining('never downloaded'), findsOneWidget);
      expect(find.textContaining('older than its usable life'), findsOneWidget);
    });

    testWidgets('a covered area says so with its tile counts', (tester) async {
      final coverage = ChartCoverage.assess(
        source: crowdSourced,
        requiredTiles: 40,
        presentTiles: 40,
        now: now,
        fetchedAt: now.subtract(const Duration(days: 3)),
      );
      expect(coverage.usableOffline, isTrue);
      await pump(
        tester,
        drawn: const [crowdSourced],
        notInUse: const [],
        coverage: [coverage],
      );
      expect(find.textContaining('40 of 40 tiles'), findsOneWidget);
    });
  });

  testWidgets('a build drawing nothing says the map is only a basemap', (
    tester,
  ) async {
    await pump(tester, drawn: const [], notInUse: const []);
    expect(
      find.byKey(const Key('chart-provenance-none-drawn')),
      findsOneWidget,
    );
    expect(find.text('Not for navigation'), findsOneWidget);
  });

  testWidgets('the text keeps a readable measure on an iPad', (tester) async {
    await pump(
      tester,
      drawn: const [crowdSourced],
      notInUse: const [],
      size: const Size(1376, 1032),
    );
    expect(
      tester.getSize(find.byKey(const Key('chart-provenance-scroll'))).width,
      lessThanOrEqualTo(620),
    );
  });
}
