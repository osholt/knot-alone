import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/recorded_route_store.dart';
import 'package:tide_and_seek/features/map/stored_route_picker.dart';
import 'package:tide_and_seek/services/approximate_place_index.dart';
import 'package:tide_and_seek/services/stored_route_library.dart';

void main() {
  final places = ApproximatePlaceIndex.fromJson(
    jsonEncode({
      'schemaVersion': 1,
      'attribution': 'Test offline places',
      'places': [
        [5145000, -210000, 'Kingswood', 2],
        [5145800, -150000, 'Chippenham', 1],
      ],
    }),
  );

  testWidgets('shows approximate endpoints beside an unhelpful voyage title', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '392725', name: 'Voyage 392725'));

    await _pump(tester, recorded: recorded, places: places);

    expect(find.text('Voyage library'), findsOneWidget);
    expect(find.text('RECORDED ROUTES'), findsOneWidget);
    expect(find.text('Voyage 392725'), findsOneWidget);
    expect(find.textContaining('Kingswood to Chippenham'), findsOneWidget);
    expect(find.text('Test offline places'), findsOneWidget);
  });

  testWidgets('a long combined library is scrollable', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final recorded = InMemoryRecordedRouteStore();
    for (var index = 0; index < 30; index += 1) {
      await recorded.save(_route(id: '$index', name: 'Saved route $index'));
    }

    await _pump(tester, recorded: recorded, places: places);
    final last = find.byKey(const Key('stored-route-candidate-recorded:0'));
    await tester.scrollUntilVisible(
      last,
      500,
      scrollable: find.byType(Scrollable).first,
    );

    expect(last, findsOneWidget);
    expect(find.text('Saved route 0'), findsOneWidget);
  });

  testWidgets('voyage details and exports remain reachable from the library', (
    tester,
  ) async {
    final recorded = InMemoryRecordedRouteStore();
    await recorded.save(_route(id: '1', name: 'Saved route'));
    var opened = 0;

    await _pump(
      tester,
      recorded: recorded,
      places: places,
      openPreviousVoyageArchive: (_) async {
        opened += 1;
        return null;
      },
    );
    await tester.tap(
      find.byKey(const Key('voyage-library-details-and-exports')),
    );
    await tester.pump();

    expect(opened, 1);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required RecordedRouteStore recorded,
  required ApproximatePlaceIndex places,
  Future<StoredRouteSelection?> Function(BuildContext context)?
  openPreviousVoyageArchive,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: StoredRoutePickerScreen(
        library: StoredRouteLibrary(
          recordedRoutes: recorded,
          completedVoyages: InMemoryCompletedVoyageStore(),
          approximatePlaceIndex: places,
        ),
        distanceUnit: DistanceUnit.miles,
        openPreviousVoyageArchive: openPreviousVoyageArchive,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ImportedRoute _route({required String id, required String name}) =>
    ImportedRoute(
      id: id,
      name: name,
      importedAt: DateTime.utc(
        2026,
        8,
        13,
      ).add(Duration(minutes: int.parse(id))),
      sourceFileName: 'recorded.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.1),
            GeoPoint(latitude: 51.458, longitude: -1.5),
          ],
        ),
      ],
      waypoints: const [],
    );
