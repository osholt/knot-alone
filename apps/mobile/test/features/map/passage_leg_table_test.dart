import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/features/map/passage_leg_table.dart';
import 'package:tide_and_seek/services/passage_legs.dart';

/// #32. The table is what a navigator reads before leaving and checks underway,
/// so these tests are about what it says rather than how it is built — and in
/// particular that it never presents an assumed time as an ETA.
void main() {
  const needles = GeoPoint(latitude: 50.6620, longitude: -1.5900);
  const cherbourg = GeoPoint(latitude: 49.6600, longitude: -1.6200);
  const nab = GeoPoint(latitude: 50.6700, longitude: -0.9500);

  ImportedRoute routeWith(List<RouteWaypoint> waypoints) => ImportedRoute(
    id: 'passage',
    name: 'Test passage',
    importedAt: DateTime.utc(2026, 8, 18),
    sourceFileName: 'passage.gpx',
    paths: const [],
    waypoints: waypoints,
  );

  Future<void> pump(
    WidgetTester tester,
    PassagePlan plan, {
    List<String> warnings = const [],
    ValueChanged<PassageLeg>? onSelectLeg,
    Size size = const Size(834, 1194),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: PassageLegTable(
            plan: plan,
            warnings: warnings,
            onSelectLeg: onSelectLeg,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final twoLegs = PassagePlan.of(
    routeWith(const [
      RouteWaypoint(point: needles, name: 'Needles'),
      RouteWaypoint(point: nab, name: 'Nab Tower'),
      RouteWaypoint(point: cherbourg, name: 'Cherbourg'),
    ]),
  );

  group('the figures on screen', () {
    testWidgets('a row per leg, plus a totals row', (tester) async {
      await pump(tester, twoLegs);
      expect(find.byKey(const Key('passage-leg-1')), findsOneWidget);
      expect(find.byKey(const Key('passage-leg-2')), findsOneWidget);
      expect(find.byKey(const Key('passage-plan-totals')), findsOneWidget);
      expect(find.text('2 legs'), findsOneWidget);
    });

    testWidgets('each leg names where it goes and where it came from', (
      tester,
    ) async {
      await pump(tester, twoLegs);
      expect(find.text('Nab Tower'), findsOneWidget);
      expect(find.text('from Needles'), findsOneWidget);
      expect(find.text('Cherbourg'), findsOneWidget);
      expect(find.text('from Nab Tower'), findsOneWidget);
    });

    testWidgets('distances are nautical, never miles or kilometres', (
      tester,
    ) async {
      await pump(tester, twoLegs);
      expect(find.textContaining('NM'), findsWidgets);
      expect(find.textContaining(' mi'), findsNothing);
      expect(find.textContaining(' km'), findsNothing);
    });

    testWidgets('courses are three figures true, as they are spoken', (
      tester,
    ) async {
      await pump(tester, twoLegs);
      // Needles to Nab is roughly east; Nab to Cherbourg roughly south-west.
      expect(find.textContaining('°T'), findsWidgets);
      expect(find.text('COURSE'), findsWidgets);
    });
  });

  // The point of the whole surface: nothing here is an ETA.
  group('the speed assumption', () {
    testWidgets('is stated in the header', (tester) async {
      await pump(tester, twoLegs);
      expect(find.byKey(const Key('passage-plan-speed')), findsOneWidget);
      expect(find.text('at 5 kn'), findsOneWidget);
    });

    testWidgets('is repeated on the totals row rather than called an ETA', (
      tester,
    ) async {
      await pump(tester, twoLegs);
      expect(find.text('AT 5 KN'), findsOneWidget);
      expect(find.textContaining('ETA'), findsNothing);
      expect(find.textContaining('eta'), findsNothing);
    });

    testWidgets('follows a different planning speed', (tester) async {
      final quick = PassagePlan.of(
        routeWith(const [
          RouteWaypoint(point: needles),
          RouteWaypoint(point: cherbourg),
        ]),
        planningSpeedKnots: 7.5,
      );
      await pump(tester, quick);
      expect(find.text('at 7.5 kn'), findsOneWidget);
    });
  });

  group("the planner's warnings", () {
    testWidgets('are shown up front, not behind a disclosure', (tester) async {
      await pump(
        tester,
        twoLegs,
        warnings: const [
          'Legs are direct courses between your waypoints.',
          'Times assume 5 kn made good.',
        ],
      );
      expect(
        find.text('Legs are direct courses between your waypoints.'),
        findsOneWidget,
      );
      expect(find.text('Times assume 5 kn made good.'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_outlined), findsNWidgets(2));
    });
  });

  group('a plan with nothing to tabulate', () {
    testWidgets('an empty plan asks for waypoints', (tester) async {
      await pump(tester, PassagePlan.empty);
      expect(find.byKey(const Key('passage-plan-no-legs')), findsOneWidget);
      expect(find.textContaining('at least two waypoints'), findsOneWidget);
      expect(find.byKey(const Key('passage-leg-list')), findsNothing);
    });

    testWidgets('an imported track says why it has no legs, and how far', (
      tester,
    ) async {
      final track = PassagePlan.of(
        ImportedRoute(
          id: 'track',
          name: 'Imported track',
          importedAt: DateTime.utc(2026, 8, 18),
          sourceFileName: 'track.gpx',
          paths: const [
            RoutePath(
              kind: RoutePathKind.track,
              points: [needles, nab, cherbourg],
            ),
          ],
          waypoints: const [],
        ),
      );
      await pump(tester, track);
      expect(find.textContaining('no marks in it'), findsOneWidget);
      expect(find.textContaining('NM'), findsOneWidget);
    });
  });

  group('selecting a leg', () {
    testWidgets('reports the tapped leg', (tester) async {
      PassageLeg? tapped;
      await pump(tester, twoLegs, onSelectLeg: (leg) => tapped = leg);
      await tester.tap(find.byKey(const Key('passage-leg-2')));
      await tester.pumpAndSettle();
      expect(tapped?.number, 2);
    });

    testWidgets('rows are not tappable when no handler is given', (
      tester,
    ) async {
      await pump(tester, twoLegs);
      // The key sits on the InkWell itself.
      final row = tester.widget<InkWell>(
        find.byKey(const Key('passage-leg-1')),
      );
      expect(row.onTap, isNull);
    });
  });

  group('formatting helpers', () {
    test('a course is always three figures', () {
      expect(formatCourse(7), '007°T');
      expect(formatCourse(181.4), '181°T');
      expect(formatCourse(0), '000°T');
      expect(formatCourse(359.6), '000°T');
      expect(formatCourse(-1), '359°T');
      expect(formatCourse(361), '001°T');
    });

    test('durations read the way a passage is discussed', () {
      expect(formatPassageDuration(const Duration(seconds: 20)), '<1 min');
      expect(formatPassageDuration(const Duration(minutes: 45)), '45 min');
      expect(formatPassageDuration(const Duration(hours: 3)), '3h');
      expect(
        formatPassageDuration(const Duration(hours: 12, minutes: 5)),
        '12h 5m',
      );
    });
  });
}
