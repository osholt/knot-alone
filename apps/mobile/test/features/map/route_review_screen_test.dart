import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/features/map/route_review_screen.dart';
import 'package:tide_and_seek/services/basemap_configuration.dart';
import 'package:tide_and_seek/services/biker_place_catalogue.dart';
import 'package:tide_and_seek/services/route_reshape_planner.dart';

void main() {
  test('warns when recalculation materially changes the route', () {
    final warning = materialRouteChangeWarning(
      _route(0.02),
      _route(0.04),
      DistanceUnit.kilometres,
    );

    expect(warning, contains('longer than the current route'));
  });

  test('does not warn for a small recalculation', () {
    final warning = materialRouteChangeWarning(
      _route(0.02),
      _route(0.022),
      DistanceUnit.kilometres,
    );

    expect(warning, isNull);
  });

  testWidgets('a long route can be confirmed without scrolling its points', (
    tester,
  ) async {
    final waypoints = [
      for (var index = 0; index < 102; index += 1)
        RouteWaypoint(
          point: GeoPoint(
            latitude: 51.46 + index * 0.0001,
            longitude: -2.5 + index * 0.0001,
          ),
          name: 'Point ${index + 1}',
        ),
    ];
    final route = ImportedRoute(
      id: 'long-review',
      name: 'Long review route',
      importedAt: DateTime.utc(2026, 7, 29),
      sourceFileName: 'long-review.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          points: waypoints.map((waypoint) => waypoint.point).toList(),
        ),
      ],
      waypoints: waypoints,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    final confirm = find.byKey(const Key('confirm-reviewed-route'));
    expect(confirm, findsOneWidget);
    expect(tester.getTopLeft(confirm).dy, lessThan(80));
    expect(find.text('Route points (102)'), findsOneWidget);
    expect(
      find.byKey(const Key('route-review-waypoint-0')),
      findsNothing,
      reason: 'the long detail list starts collapsed',
    );

    await tester.tap(find.text('Route points (102)'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('route-review-waypoint-0')), findsOneWidget);
  });

  testWidgets(
    'route adjustments stay distinct from named stops and recalculate',
    (tester) async {
      final route = _route(0.02).withShapingPoints(const [
        RouteShapingPoint(
          id: 'shape-one',
          legIndex: 0,
          point: GeoPoint(latitude: 51.001, longitude: -1.99),
        ),
      ]);
      var reshapeCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: route,
            distanceUnit: DistanceUnit.miles,
            basemapConfiguration: const BasemapConfiguration(),
            onReshapeRoute: (candidate, shapingPoints) async {
              reshapeCalls += 1;
              return RouteReshapeResult(
                route: candidate.withShapingPoints(shapingPoints),
                distanceMeters: 1200,
                duration: const Duration(minutes: 4),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('toggle-route-reshape')), findsOneWidget);
      expect(
        find.byKey(const Key('route-shaping-point-shape-one')),
        findsOneWidget,
      );
      expect(find.text('Adjustment 1'), findsOneWidget);
      expect(find.text('2 route points'), findsOneWidget);

      final chip = tester.widget<InputChip>(
        find.byKey(const Key('route-shaping-point-shape-one')),
      );
      chip.onDeleted!();
      await tester.pumpAndSettle();

      expect(reshapeCalls, 1);
      expect(
        find.byKey(const Key('route-shaping-point-shape-one')),
        findsNothing,
      );
    },
  );

  testWidgets('a mapped point of interest becomes a live route waypoint', (
    tester,
  ) async {
    ImportedRoute? recalculated;
    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: _route(0.02),
          distanceUnit: DistanceUnit.miles,
          basemapConfiguration: const BasemapConfiguration(),
          canEditStops: true,
          pointOfInterestLoader: () async => const BikerPlaceCatalogue(
            places: [
              BikerPlace(
                id: 'cafe-1',
                name: 'Sailor Cafe',
                address: 'High Street',
                point: GeoPoint(latitude: 51.001, longitude: -1.99),
                source: 'Bike + Brew 2026',
              ),
            ],
          ),
          onReshapeRoute: (candidate, shapingPoints) async {
            recalculated = candidate;
            return RouteReshapeResult(
              route: candidate.withShapingPoints(shapingPoints),
              distanceMeters: 1800,
              duration: const Duration(minutes: 6),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Finish drawing'), findsOneWidget);
    expect(
      find.byKey(const Key('toggle-route-points-of-interest')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('route-point-of-interest-cafe-1')));
    await tester.pumpAndSettle();

    expect(find.text('Add as waypoint'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-point-of-interest-cafe-1')));
    await tester.pumpAndSettle();

    expect(recalculated, isNotNull);
    expect(recalculated!.waypoints.map((point) => point.name), [
      'Start',
      'Sailor Cafe',
      'Destination',
    ]);
    await tester.scrollUntilVisible(
      find.text('Route points (3)'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Route points (3)'), findsOneWidget);
  });

  // #32. Adding a mark by tapping the chart is a mode, not a default: a chart is
  // panned far more often than it is edited, and a stray tap that silently added
  // a mark would be discovered later, in the leg table, by a sailor who did not
  // do it.
  group('adding a mark', () {
    Future<ImportedRoute?> pumpEditable(WidgetTester tester) async {
      ImportedRoute? recalculated;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _route(0.02),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
            canEditStops: true,
            onReshapeRoute: (candidate, shapingPoints) async {
              recalculated = candidate;
              return RouteReshapeResult(
                route: candidate.withShapingPoints(shapingPoints),
                distanceMeters: 1800,
                duration: const Duration(minutes: 6),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return recalculated;
    }

    testWidgets('is offered as a mode alongside redrawing', (tester) async {
      await pumpEditable(tester);
      expect(find.byKey(const Key('toggle-add-marks')), findsOneWidget);
      expect(find.text('Add a mark'), findsOneWidget);
    });

    testWidgets('is offered for an imported route too, not just a plan', (
      tester,
    ) async {
      // canEditStops distinguishes a destination plan from an imported route.
      // Adding a mark to someone else's GPX is exactly the adjustment a sailor
      // wants, so this is gated on being able to re-plan instead.
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _route(0.02),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
            onReshapeRoute: (candidate, shapingPoints) async =>
                RouteReshapeResult(
                  route: candidate.withShapingPoints(shapingPoints),
                  distanceMeters: 1800,
                  duration: const Duration(minutes: 6),
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-add-marks')), findsOneWidget);
    });

    testWidgets('is absent when the route cannot be re-planned', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _route(0.02),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('toggle-add-marks')), findsNothing);
    });

    testWidgets('a tap on the chart inserts a mark and re-plans', (
      tester,
    ) async {
      ImportedRoute? recalculated;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _route(0.02),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
            canEditStops: true,
            onReshapeRoute: (candidate, shapingPoints) async {
              recalculated = candidate;
              return RouteReshapeResult(
                route: candidate.withShapingPoints(shapingPoints),
                distanceMeters: 1800,
                duration: const Duration(minutes: 6),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = recalculated?.waypoints.length;

      await tester.tap(find.byKey(const Key('toggle-add-marks')));
      await tester.pumpAndSettle();

      // The wired callback is invoked directly rather than by synthesising a tap
      // on the map. Whether flutter_map turns a pointer into onTap is its own
      // business; what matters here is that the option is wired only in add-mark
      // mode and that invoking it inserts a mark.
      final map = tester.widget<FlutterMap>(
        find.byKey(const Key('route-review-map')),
      );
      expect(map.options.onTap, isNotNull);
      map.options.onTap!(
        TapPosition(Offset.zero, Offset.zero),
        const LatLng(51.001, -1.995),
      );
      await tester.pumpAndSettle();

      expect(recalculated, isNotNull);
      expect(
        recalculated!.waypoints.length,
        (before ?? 2) + 1,
        reason: 'the tap should have added one mark',
      );
      // Inserted between the existing marks rather than appended past the
      // destination, because that is what tapping mid-passage means.
      expect(recalculated!.waypoints.first.name, 'Start');
      expect(recalculated!.waypoints.last.name, 'Destination');
    });

    testWidgets('the chart does not add marks outside the mode', (
      tester,
    ) async {
      await pumpEditable(tester);
      final map = tester.widget<FlutterMap>(
        find.byKey(const Key('route-review-map')),
      );
      expect(map.options.onTap, isNull);
    });

    // The two modes share one gesture surface, so a sailor must never be in both.
    testWidgets('turning it on turns redrawing off, and vice versa', (
      tester,
    ) async {
      await pumpEditable(tester);

      // Redrawing starts on for an editable route.
      expect(find.text('Finish drawing'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-add-marks')));
      await tester.pumpAndSettle();
      expect(find.text('Finish adding'), findsOneWidget);
      expect(find.text('Draw route around'), findsNothing);
      expect(find.text('Finish drawing'), findsNothing);
      expect(find.text('Redraw a leg'), findsOneWidget);

      await tester.tap(find.byKey(const Key('toggle-route-reshape')));
      await tester.pumpAndSettle();
      expect(find.text('Finish drawing'), findsOneWidget);
      expect(find.text('Add a mark'), findsOneWidget);
      expect(find.text('Finish adding'), findsNothing);
    });
  });

  group('editing a mark (#43)', () {
    Future<ImportedRoute?> pumpPassage(
      WidgetTester tester, {
      bool replannable = true,
      ImportedRoute? route,
    }) async {
      ImportedRoute? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: route ?? _passage(),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
            onRouteChanged: (updated) => changed = updated,
            onReshapeRoute: replannable
                ? (candidate, shapingPoints) async => RouteReshapeResult(
                    route: candidate.withShapingPoints(shapingPoints),
                    distanceMeters: 1800,
                    duration: const Duration(minutes: 6),
                  )
                : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The marks list now sits below the leg table, which is far enough down
      // the lazily-built detail list that it is not constructed at all until
      // scrolled to. Reviewing a passage is done on the courses first and the
      // names second, so that order is deliberate - the tests just have to
      // follow the sailor's thumb.
      await tester.scrollUntilVisible(
        find.byKey(const Key('route-review-points-section')),
        240,
        scrollable: find.descendant(
          of: find.byKey(const Key('route-review-detail')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      return changed;
    }

    // The one-way door this ticket closes. #37 let a mark be added to an
    // imported passage; the delete button stayed gated on canEditStops, so on
    // that same passage there was no way to take it off again.
    testWidgets('an imported passage can have a mark removed', (tester) async {
      await pumpPassage(tester);
      expect(
        find.byKey(const Key('remove-reviewed-waypoint-1')),
        findsOneWidget,
      );
    });

    testWidgets('the start and the destination cannot be removed', (
      tester,
    ) async {
      await pumpPassage(tester);
      expect(find.byKey(const Key('remove-reviewed-waypoint-0')), findsNothing);
      expect(find.byKey(const Key('remove-reviewed-waypoint-2')), findsNothing);
    });

    testWidgets('every mark can be renamed, including the ends', (
      tester,
    ) async {
      await pumpPassage(tester);
      for (final index in [0, 1, 2]) {
        expect(
          find.byKey(Key('rename-reviewed-waypoint-$index')),
          findsOneWidget,
          reason: 'mark $index should be nameable',
        );
      }
    });

    testWidgets('naming a mark updates the list without a re-plan', (
      tester,
    ) async {
      var replans = 0;
      ImportedRoute? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: RouteReviewScreen(
            route: _passage(),
            distanceUnit: DistanceUnit.nauticalMiles,
            basemapConfiguration: const BasemapConfiguration(),
            onRouteChanged: (updated) => changed = updated,
            onReshapeRoute: (candidate, shapingPoints) async {
              replans += 1;
              return RouteReshapeResult(
                route: candidate.withShapingPoints(shapingPoints),
                distanceMeters: 1800,
                duration: const Duration(minutes: 6),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('route-review-points-section')),
        240,
        scrollable: find.descendant(
          of: find.byKey(const Key('route-review-detail')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('rename-reviewed-waypoint-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mark-name-field')),
        'Needles Fairway',
      );
      await tester.tap(find.byKey(const Key('save-mark-name')));
      await tester.pumpAndSettle();

      // The list labels a mark by role and name - "Stop 1: Needles Fairway" -
      // so this asserts on the tile rather than on a bare string, which also
      // keeps it from matching the leg table's "from Needles Fairway".
      expect(
        find.descendant(
          of: find.byKey(const Key('route-review-waypoint-1')),
          matching: find.textContaining('Needles Fairway'),
        ),
        findsOneWidget,
      );
      expect(changed?.waypoints[1].name, 'Needles Fairway');
      // A name moves nothing, so the passage must not be re-planned and the
      // courses and times already on screen must not blank out.
      expect(replans, 0, reason: 'renaming must not re-plan the passage');
    });

    testWidgets('cancelling the name dialog leaves the mark alone', (
      tester,
    ) async {
      await pumpPassage(tester);

      await tester.tap(find.byKey(const Key('rename-reviewed-waypoint-1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mark-name-field')),
        'Discarded',
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Discarded'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('route-review-waypoint-1')),
          matching: find.textContaining('Middle mark'),
        ),
        findsOneWidget,
      );
    });

    // The synthesised-waypoint trap. A recorded track has geometry and no
    // waypoints, so the list invents a start and an end to have something to
    // show. Those have no index into route.waypoints, so an edit control on
    // them would rename or remove the wrong mark.
    testWidgets('a track with no waypoints of its own stays read-only', (
      tester,
    ) async {
      await pumpPassage(tester, route: _route(0.02));
      expect(find.byKey(const Key('rename-reviewed-waypoint-0')), findsNothing);
      expect(find.byKey(const Key('remove-reviewed-waypoint-1')), findsNothing);
    });

    testWidgets('a passage that cannot be re-planned stays read-only', (
      tester,
    ) async {
      await pumpPassage(tester, replannable: false);
      expect(find.byKey(const Key('rename-reviewed-waypoint-1')), findsNothing);
      expect(find.byKey(const Key('remove-reviewed-waypoint-1')), findsNothing);
    });
  });

  testWidgets('keeps disconnected imported paths visually separate', (
    tester,
  ) async {
    final route = ImportedRoute(
      id: 'segmented',
      name: 'Segmented route',
      importedAt: DateTime.utc(2026, 7, 23),
      sourceFileName: 'segmented.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51.01, longitude: -2.01),
          ],
        ),
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 52, longitude: -3),
            GeoPoint(latitude: 52.005, longitude: -3.005),
          ],
        ),
      ],
      waypoints: const [],
      // Both manoeuvres sit on the first, longer path: the one the group voyages.
      // They were on one path each until #179 stopped scoring manoeuvres that
      // lie off the ridden line - a road nobody on this voyage will use cannot be
      // missed, so it earns no marking position. That rule is asserted directly
      // in test/services/route_marker_plan_test.dart; this test is about the two
      // paths staying visually separate, which they still are.
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.005, longitude: -2.005),
          type: 'turn',
          modifier: 'left',
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.0075, longitude: -2.0075),
          type: 'off ramp',
          modifier: 'left',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    expect(layer.polylines, hasLength(2));
    expect(find.text('2 turn instructions'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Destination'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Destination'), findsOneWidget);
  });

  testWidgets('draws a road-matched candidate against the original line', (
    tester,
  ) async {
    final original = _route(0.02);
    final candidate = ImportedRoute(
      id: 'matched',
      name: 'Review route (navigable)',
      importedAt: DateTime.utc(2026, 8, 3),
      sourceFileName: 'matched-review.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -2),
            GeoPoint(latitude: 51.001, longitude: -1.99),
            GeoPoint(latitude: 51, longitude: -1.98),
          ],
        ),
      ],
      waypoints: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: candidate,
          comparisonRoute: original,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    final originalLayer = tester.widget<PolylineLayer>(
      find.byKey(const Key('route-review-original-line')),
    );
    expect(originalLayer.polylines, hasLength(1));
    expect(originalLayer.polylines.single.color, const Color(0xFFB8C0CC));
    final candidateLayer = tester
        .widgetList<PolylineLayer>(find.byType(PolylineLayer))
        .last;
    expect(candidateLayer.polylines.single.color, const Color(0xFF3478F6));
  });

  testWidgets('route review opens the full manoeuvre list before the voyage', (
    tester,
  ) async {
    final route = ImportedRoute(
      id: 'reviewed',
      name: 'Reviewed route',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'reviewed.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.59),
            GeoPoint(latitude: 51.47, longitude: -2.59),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [
        RouteManeuver(
          position: GeoPoint(latitude: 51.46, longitude: -2.59),
          type: 'roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          exitNumber: 2,
          drivingSide: 'left',
          bearingBeforeDegrees: 0,
          bearingAfterDegrees: 300,
        ),
        RouteManeuver(
          position: GeoPoint(latitude: 51.4602, longitude: -2.59),
          type: 'exit roundabout',
          modifier: 'slight left',
          name: 'Wells Road',
          drivingSide: 'left',
          bearingBeforeDegrees: 40,
          bearingAfterDegrees: 2,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: RouteReviewScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          basemapConfiguration: const BasemapConfiguration(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('1 turn instruction'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('review-maneuver-list')),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('review-maneuver-list')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byKey(const Key('maneuver-list')), findsOneWidget);
    expect(find.text('2nd exit, straight on'), findsOneWidget);
  });
}

ImportedRoute _route(double longitudeDelta) => ImportedRoute(
  id: 'route-$longitudeDelta',
  name: 'Review route',
  importedAt: DateTime.utc(2026, 7, 23),
  sourceFileName: 'review.gpx',
  paths: [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        const GeoPoint(latitude: 51, longitude: -2),
        GeoPoint(latitude: 51, longitude: -2 + longitudeDelta),
      ],
    ),
  ],
  waypoints: const [],
);

/// A passage carrying its own named marks, which is what makes them editable.
ImportedRoute _passage() => ImportedRoute(
  id: 'passage',
  name: 'Solent passage',
  importedAt: DateTime.utc(2026, 8, 18),
  sourceFileName: 'passage.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.route,
      points: [
        GeoPoint(latitude: 50.75, longitude: -1.52),
        GeoPoint(latitude: 50.74, longitude: -1.40),
        GeoPoint(latitude: 50.76, longitude: -1.30),
      ],
    ),
  ],
  waypoints: const [
    RouteWaypoint(
      name: 'Lymington',
      point: GeoPoint(latitude: 50.75, longitude: -1.52),
    ),
    RouteWaypoint(
      name: 'Middle mark',
      point: GeoPoint(latitude: 50.74, longitude: -1.40),
    ),
    RouteWaypoint(
      name: 'Cowes',
      point: GeoPoint(latitude: 50.76, longitude: -1.30),
    ),
  ],
);
