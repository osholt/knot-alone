import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/features/map/navigation_instrument_panel.dart';
import 'package:tide_and_seek/services/navigation_instruments.dart';
import 'package:tide_and_seek/services/passage_legs.dart';

/// #34. The panel exists for one property: a stale fix must degrade everything
/// derived from it, visibly and at once. A frozen SOG still reading 5.2 kn
/// because the last fix was four minutes ago looks exactly as trustworthy as it
/// did when it was true.
void main() {
  const west = GeoPoint(latitude: 50.0000, longitude: -1.5000);
  const east = GeoPoint(latitude: 50.0000, longitude: -1.0000);
  final now = DateTime.utc(2026, 8, 18, 12);

  PassagePlan planOf(List<GeoPoint> marks) => PassagePlan.of(
    ImportedRoute(
      id: 'p',
      name: 'p',
      importedAt: now,
      sourceFileName: 'p.gpx',
      paths: const [],
      waypoints: [
        for (final mark in marks)
          RouteWaypoint(point: mark, name: mark == east ? 'Nab' : null),
      ],
    ),
  );

  NavigationInstruments instrumentsFor({
    double? cog = 90,
    double? sog = 3,
    double? accuracy,
    Duration age = Duration.zero,
    List<GeoPoint> marks = const [west, east],
    GeoPoint at = west,
  }) => NavigationInstruments.compute(
    fix: NavigationFix(
      point: at,
      recordedAt: now.subtract(age),
      courseOverGroundDegrees: cog,
      speedOverGroundMetersPerSecond: sog,
      accuracyMeters: accuracy,
    ),
    plan: planOf(marks),
    now: now,
  );

  Future<void> pump(WidgetTester tester, NavigationInstruments instruments) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Center(
              child: NavigationInstrumentPanel(instruments: instruments),
            ),
          ),
        ),
      );

  group('the readings', () {
    testWidgets('own motion and mark figures are all present', (tester) async {
      await pump(tester, instrumentsFor());
      await tester.pumpAndSettle();

      for (final label in ['COG', 'SOG', 'BTW', 'DTW', 'VMG', 'XTE']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // Nautical and three-figure, as they are read aloud. Two of them here:
      // steering 090 straight at a mark due east makes COG and BTW equal, which
      // is what being on course looks like.
      expect(find.text('090°T'), findsNWidgets(2));
      expect(find.textContaining('kn'), findsWidgets);
    });

    testWidgets('a value the receiver cannot give shows why, not a stale one', (
      tester,
    ) async {
      await pump(tester, instrumentsFor(cog: null));
      await tester.pumpAndSettle();

      expect(find.text('—'), findsWidgets);
      expect(find.textContaining('stopped'), findsOneWidget);
    });
  });

  // The reason this widget exists.
  group('a stale fix', () {
    testWidgets('is named once, plainly, above the figures', (tester) async {
      await pump(tester, instrumentsFor(age: const Duration(minutes: 4)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('navigation-instruments-stale')),
        findsOneWidget,
      );
      expect(find.textContaining('out of date'), findsOneWidget);
      expect(find.textContaining('4h'), findsNothing);
      expect(find.textContaining('4 min'), findsOneWidget);
    });

    testWidgets('dims every figure together, so none looks fresher', (
      tester,
    ) async {
      const dimmed = Color(0xFF6B7684);

      await pump(tester, instrumentsFor(age: const Duration(minutes: 4)));
      await tester.pumpAndSettle();
      for (final label in ['COG', 'SOG', 'BTW', 'DTW', 'VMG']) {
        expect(
          tester
              .widget<Text>(find.byKey(Key('instrument-$label')))
              .style
              ?.color,
          dimmed,
          reason: '$label should be dimmed with the fix it came from',
        );
      }
    });

    testWidgets('a fresh fix reports its age and dims nothing', (tester) async {
      await pump(tester, instrumentsFor(age: const Duration(seconds: 3)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('navigation-instruments-fix-age')),
        findsOneWidget,
      );
      expect(find.text('Fix 3s old'), findsOneWidget);
      expect(
        find.byKey(const Key('navigation-instruments-stale')),
        findsNothing,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('instrument-SOG')))
            .style
            ?.color,
        isNot(const Color(0xFF6B7684)),
      );
    });
  });

  group('cross-track error', () {
    testWidgets('names the side to steer toward, not the side you are on', (
      tester,
    ) async {
      // North of a due-east track is to port of it, so the helm goes starboard.
      await pump(
        tester,
        instrumentsFor(at: const GeoPoint(latitude: 50.01, longitude: -1.25)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('steer starboard'), findsOneWidget);
    });

    testWidgets('says "on track" rather than showing a bare zero', (
      tester,
    ) async {
      await pump(
        tester,
        instrumentsFor(at: const GeoPoint(latitude: 50.0, longitude: -1.25)),
      );
      await tester.pumpAndSettle();
      expect(find.text('on track'), findsOneWidget);
    });

    testWidgets('a coarse fix suppresses it and says how coarse', (
      tester,
    ) async {
      await pump(tester, instrumentsFor(accuracy: 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('accurate to 200 m'), findsOneWidget);
    });
  });

  group('the mark line', () {
    testWidgets('names the mark and the time at this rate', (tester) async {
      await pump(tester, instrumentsFor(sog: 5));
      await tester.pumpAndSettle();

      expect(find.textContaining('Making for Nab'), findsOneWidget);
      expect(find.textContaining('at this rate'), findsOneWidget);
    });

    testWidgets('says "not closing" rather than a negative time', (
      tester,
    ) async {
      await pump(tester, instrumentsFor(cog: 270));
      await tester.pumpAndSettle();
      expect(find.textContaining('not closing'), findsOneWidget);
    });
  });

  testWidgets('with no passage it shows own motion and asks for marks', (
    tester,
  ) async {
    await pump(tester, instrumentsFor(marks: const [west]));
    await tester.pumpAndSettle();

    expect(find.text('COG'), findsOneWidget);
    expect(find.text('SOG'), findsOneWidget);
    expect(find.text('BTW'), findsNothing);
    expect(
      find.byKey(const Key('navigation-instruments-no-passage')),
      findsOneWidget,
    );
  });
}
