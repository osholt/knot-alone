import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/features/map/passage_maneuver_list.dart';
import 'package:tide_and_seek/services/passage_legs.dart';
import 'package:tide_and_seek/services/passage_maneuvers.dart';

/// #63. The list a sailor reads. The model is tested in
/// `test/services/passage_maneuvers_test.dart`; this is about whether the screen
/// says the right thing, including in the three cases where it has nothing to
/// list.
void main() {
  Future<void> pump(
    WidgetTester tester,
    PassageManeuverPlan plan, {
    Size size = const Size(430, 932),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: PassageManeuverList(
          plan: plan,
          distanceUnit: DistanceUnit.nauticalMiles,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('a passage with alterations', () {
    testWidgets('reads as an instruction a helm could act on', (tester) async {
      await pump(tester, _dogLeg());

      expect(find.byKey(const Key('passage-maneuver-list')), findsOneWidget);
      // Due east onto due north: 90 to port, onto 000.
      expect(find.textContaining('to port onto 000°T'), findsOneWidget);
      expect(find.text('at Needles Fairway'), findsOneWidget);
    });

    testWidgets('shows the course it is coming off, not just the new one', (
      tester,
    ) async {
      await pump(tester, _dogLeg());

      expect(find.text('FROM'), findsOneWidget);
      expect(find.text('090°T'), findsOneWidget);
    });

    testWidgets('distance to run is in miles or cables, not metres', (
      tester,
    ) async {
      await pump(tester, _dogLeg());

      expect(find.text('TO RUN'), findsOneWidget);
      // Asserted on the figures themselves rather than by scanning the screen
      // for " m", which matches "from the marks" in the preamble.
      final figures = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('passage-maneuver-1')),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data ?? '')
          .toList();

      expect(
        figures.any((f) => f.endsWith(' NM') || f.endsWith(' cables')),
        isTrue,
        reason: 'a distance should read in nautical units: $figures',
      );
      expect(
        figures.any((f) => RegExp(r'^\d[\d.]* k?m$').hasMatch(f)),
        isFalse,
      );
    });

    testWidgets('every time says what speed it assumed', (tester) async {
      await pump(tester, _dogLeg());
      // PLAN.md requires anything resembling an arrival time to name its
      // assumptions where the figure is shown.
      expect(find.text('AT 5 KN'), findsOneWidget);
    });

    testWidgets('the count is in the title', (tester) async {
      await pump(tester, _dogLeg());
      expect(find.text('Alterations (1)'), findsOneWidget);
    });

    testWidgets('it states what it has not checked, and what it cannot say', (
      tester,
    ) async {
      await pump(tester, _dogLeg());

      expect(find.textContaining('not checked against land'), findsOneWidget);
      // The refusal that matters most: a side needs buoyage, and inventing one
      // from geometry would be exactly the #19 failure.
      expect(find.textContaining('which side to leave a mark'), findsOneWidget);
    });

    testWidgets('no road vocabulary survives', (tester) async {
      await pump(tester, _dogLeg());

      for (final word in ['turn', 'exit', 'lane', 'roundabout', 'road']) {
        expect(
          find.textContaining(word),
          findsNothing,
          reason: '"$word" should not appear on a passage screen',
        );
      }
    });
  });

  group('marks that earn no instruction', () {
    testWidgets('a skipped mark is accounted for rather than dropped', (
      tester,
    ) async {
      await pump(tester, _dogLegWithNearlyStraightMark());

      expect(
        find.textContaining('an alteration under 5°'),
        findsOneWidget,
        reason: 'a shorter list than the mark count needs explaining',
      );
    });

    testWidgets('a passage of one course says so instead of showing nothing', (
      tester,
    ) async {
      await pump(tester, _straightThrough());

      expect(find.text('No alterations'), findsOneWidget);
      expect(find.byKey(const Key('passage-maneuver-list')), findsNothing);
      expect(find.textContaining('one course'), findsOneWidget);
    });

    testWidgets('an empty plan does not pretend to be a passage', (
      tester,
    ) async {
      await pump(tester, PassageManeuverPlan.empty);
      expect(find.text('No alterations'), findsOneWidget);
    });
  });

  group('a big alteration', () {
    testWidgets('is flagged, and a small one is not', (tester) async {
      await pump(tester, _dogLeg());
      expect(find.byIcon(Icons.priority_high), findsOneWidget);

      await pump(tester, _gentleAlteration());
      expect(find.byIcon(Icons.priority_high), findsNothing);
    });
  });
}

PassageManeuverPlan _plan(List<RouteWaypoint> marks) => PassageManeuverPlan.of(
  PassagePlan.of(
    ImportedRoute(
      id: 'passage',
      name: 'Passage',
      importedAt: DateTime.utc(2026, 8, 19),
      sourceFileName: 'passage.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.route,
          points: marks.map((mark) => mark.point).toList(growable: false),
        ),
      ],
      waypoints: marks,
    ),
  ),
);

RouteWaypoint _mark(String name, double latitude, double longitude) =>
    RouteWaypoint(
      name: name,
      point: GeoPoint(latitude: latitude, longitude: longitude),
    );

/// East then north: one 90° alteration to port at the middle mark.
PassageManeuverPlan _dogLeg() => _plan([
  _mark('Lymington', 50.70, -1.50),
  _mark('Needles Fairway', 50.70, -1.40),
  _mark('Cowes', 50.78, -1.40),
]);

/// East, east again a hair off, then north: the middle mark is under threshold.
PassageManeuverPlan _dogLegWithNearlyStraightMark() => _plan([
  _mark('Lymington', 50.70, -1.500),
  _mark('Hurst', 50.70, -1.400),
  _mark('Needles Fairway', 50.7005, -1.300),
  _mark('Cowes', 50.78, -1.300),
]);

/// Two marks on one course: nothing to alter onto.
PassageManeuverPlan _straightThrough() =>
    _plan([_mark('Lymington', 50.70, -1.50), _mark('Cowes', 50.70, -1.30)]);

/// A 20° alteration, which is real but not major.
PassageManeuverPlan _gentleAlteration() => _plan([
  _mark('Lymington', 50.700, -1.500),
  _mark('Hurst', 50.700, -1.400),
  _mark('Cowes', 50.724, -1.300),
]);
