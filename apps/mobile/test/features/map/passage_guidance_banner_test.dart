import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/navigation_instruments.dart';
import 'package:tide_and_seek/services/passage_guidance.dart';
import 'package:tide_and_seek/services/passage_legs.dart';
import 'package:tide_and_seek/services/passage_maneuvers.dart';

/// #63 step 3. The banner under way was fed by the road guidance planner, which
/// on a passage could only ever say "following the passage line" — true, and
/// useless to somebody steering. These check what it says instead.
///
/// Driven through `PassageGuidance` and rendered into the same two-line shape
/// the banner uses, rather than through the map widget, which needs a platform
/// view. What is under test is the words a helm reads.
void main() {
  testWidgets('under way it names the leg and the mark', (tester) async {
    await _pump(tester, const GeoPoint(latitude: 50.6975, longitude: -1.4450));

    expect(find.textContaining('Leg 1 of 3'), findsOneWidget);
    expect(find.textContaining('Hamstead'), findsWidgets);
    expect(find.textContaining('to run'), findsOneWidget);
  });

  testWidgets('approaching a mark it shows the alteration waiting there', (
    tester,
  ) async {
    await _pump(tester, const GeoPoint(latitude: 50.6958, longitude: -1.4145));

    expect(find.textContaining('Approaching Hamstead'), findsOneWidget);
    expect(find.textContaining('alter'), findsOneWidget);
    // Three figures and true, the same as the leg table says in writing.
    expect(find.textContaining('°T'), findsOneWidget);
  });

  testWidgets('arriving it says so instead of offering a next course', (
    tester,
  ) async {
    await _pump(tester, const GeoPoint(latitude: 50.7420, longitude: -1.3060));

    expect(find.textContaining('Arriving at Cowes'), findsOneWidget);
    expect(find.textContaining('last mark'), findsOneWidget);
  });

  testWidgets('a stale fix says the readings below came from it', (
    tester,
  ) async {
    await _pump(
      tester,
      const GeoPoint(latitude: 50.6958, longitude: -1.4145),
      fixAge: const Duration(minutes: 4),
    );

    expect(find.textContaining('Position is stale'), findsOneWidget);
    expect(find.textContaining('Readings below'), findsOneWidget);
    // And not the mark it happens to be near, which would invite steering by a
    // four-minute-old position.
    expect(find.textContaining('Approaching'), findsNothing);
  });

  testWidgets('it never falls back to the road planner wording', (
    tester,
  ) async {
    await _pump(tester, const GeoPoint(latitude: 50.6975, longitude: -1.4450));

    expect(find.textContaining('Following the passage line'), findsNothing);
    expect(find.textContaining('turn'), findsNothing);
  });
}

Future<void> _pump(
  WidgetTester tester,
  GeoPoint point, {
  Duration fixAge = Duration.zero,
}) async {
  final now = DateTime.utc(2026, 8, 20, 12);
  final plan = PassagePlan.of(_passage());
  final guidance = PassageGuidance.of(
    plan: plan,
    maneuvers: PassageManeuverPlan.of(plan),
    instruments: NavigationInstruments.compute(
      fix: NavigationFix(
        point: point,
        recordedAt: now.subtract(fixAge),
        courseOverGroundDegrees: 80,
        speedOverGroundMetersPerSecond: 2.6,
        accuracyMeters: 5,
      ),
      plan: plan,
      now: now,
    ),
    distanceUnit: DistanceUnit.nauticalMiles,
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(guidance.headline),
            if (guidance.detail case final detail?) Text(detail),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ImportedRoute _passage() => ImportedRoute(
  id: 'solent',
  name: 'Lymington to Cowes',
  importedAt: DateTime.utc(2026, 8, 20),
  sourceFileName: 'solent.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 50.7000, longitude: -1.5000),
        GeoPoint(latitude: 50.6950, longitude: -1.4000),
        GeoPoint(latitude: 50.7100, longitude: -1.3400),
        GeoPoint(latitude: 50.7500, longitude: -1.3000),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(
      name: 'Lymington',
      point: GeoPoint(latitude: 50.7000, longitude: -1.5000),
    ),
    RouteWaypoint(
      name: 'Hamstead',
      point: GeoPoint(latitude: 50.6950, longitude: -1.4000),
    ),
    RouteWaypoint(
      name: 'Salt Mead',
      point: GeoPoint(latitude: 50.7100, longitude: -1.3400),
    ),
    RouteWaypoint(
      name: 'Cowes',
      point: GeoPoint(latitude: 50.7500, longitude: -1.3000),
    ),
  ],
);
