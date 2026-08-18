import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/completed_voyages_controller.dart';
import 'package:tide_and_seek/controllers/personal_voyage_heatmap_controller.dart';
import 'package:tide_and_seek/domain/completed_voyage.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  test('uses travelled tracks and never planned routes', () {
    final heatmap = const PersonalVoyageHeatmapBuilder().build([
      _voyage(
        'one',
        planned: _route([_path(51.0, -3.0, 51.01, -3.01)]),
        travelled: _route([_path(51.45, -2.59, 51.46, -2.58)]),
      ),
    ]);

    expect(heatmap.cells, isNotEmpty);
    expect(
      heatmap.cells.every((cell) => cell.centre.latitude > 51.4),
      isTrue,
      reason: 'the planned route must not enter private coverage',
    );
  });

  test('repeated voyages increase intensity', () {
    final route = _route([_path(51.45, -2.59, 51.451, -2.589)]);
    final once = const PersonalVoyageHeatmapBuilder().build([
      _voyage('one', travelled: route),
    ]);
    final twice = const PersonalVoyageHeatmapBuilder().build([
      _voyage('one', travelled: route),
      _voyage('two', travelled: route),
    ]);

    expect(once.cells.map((cell) => cell.visits), everyElement(1));
    expect(twice.cells.map((cell) => cell.visits), everyElement(2));
    expect(twice.cells.first.weight, greaterThan(once.cells.first.weight));
  });

  test('a loop records a later return to a covered cell', () {
    final heatmap = const PersonalVoyageHeatmapBuilder().build([
      _voyage(
        'loop',
        travelled: _route([
          const RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.4500, longitude: -2.5900),
              GeoPoint(latitude: 51.4510, longitude: -2.5800),
              GeoPoint(latitude: 51.4500, longitude: -2.5900),
            ],
          ),
        ]),
      ),
    ]);

    expect(heatmap.cells.any((cell) => cell.visits >= 2), isTrue);
  });

  test('separate recorded paths do not draw across a GPS gap', () {
    final heatmap = const PersonalVoyageHeatmapBuilder().build([
      _voyage(
        'gapped',
        travelled: _route([
          _path(51.45, -2.59, 51.4501, -2.5899),
          _path(52.45, -1.59, 52.4501, -1.5899),
        ]),
      ),
    ]);

    expect(heatmap.cells.length, lessThan(10));
  });

  test('empty archives stay empty', () {
    expect(const PersonalVoyageHeatmapBuilder().build(const []).cells, isEmpty);
  });

  test(
    'visibility is off by default and persists without a network client',
    () async {
      final store = InMemoryCompletedVoyageStore();
      await store.save(
        _voyage('one', travelled: _route([_path(51.45, -2.59, 51.46, -2.58)])),
      );
      final controller = await PersonalVoyageHeatmapController.load(
        store: store,
      );
      addTearDown(controller.dispose);

      expect(controller.visible, isFalse);
      expect(controller.heatmap.cells, isEmpty);

      await controller.setVisible(true);
      expect(controller.heatmap.cells, isNotEmpty);

      final reloaded = await PersonalVoyageHeatmapController.load(store: store);
      addTearDown(reloaded.dispose);
      expect(reloaded.visible, isTrue);
      expect(reloaded.heatmap.cells, isNotEmpty);
    },
  );

  test(
    'saving and deleting archived voyages rebuilds visible coverage',
    () async {
      final voyages = await CompletedVoyagesController.load(
        InMemoryCompletedVoyageStore(),
      );
      addTearDown(voyages.dispose);
      final controller = await PersonalVoyageHeatmapController.load(
        store: voyages,
      );
      addTearDown(controller.dispose);
      await controller.setVisible(true);

      await voyages.save(
        _voyage('one', travelled: _route([_path(51.45, -2.59, 51.46, -2.58)])),
      );
      await _settleAsyncRefresh();
      expect(controller.heatmap.cells, isNotEmpty);

      await voyages.delete('one');
      await _settleAsyncRefresh();
      expect(controller.heatmap.cells, isEmpty);
    },
  );

  test('100,000 archived fixes are reduced to a bounded spatial index', () {
    final voyages = [
      for (var voyage = 0; voyage < 100; voyage += 1)
        _voyage(
          '$voyage',
          travelled: _route([
            RoutePath(
              kind: RoutePathKind.track,
              points: [
                for (var point = 0; point < 1000; point += 1)
                  GeoPoint(
                    latitude: 50.5 + voyage * 0.001,
                    longitude: -4 + point * 0.00001,
                  ),
              ],
            ),
          ]),
        ),
    ];
    final stopwatch = Stopwatch()..start();

    final heatmap = const PersonalVoyageHeatmapBuilder(
      maximumCells: 20000,
    ).build(voyages);
    stopwatch.stop();

    expect(heatmap.inputPointCount, 100000);
    expect(heatmap.cells.length, lessThanOrEqualTo(20000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}

Future<void> _settleAsyncRefresh() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

CompletedVoyage _voyage(
  String id, {
  ImportedRoute? planned,
  ImportedRoute? travelled,
}) => CompletedVoyage(
  voyageId: id,
  voyageCode: id.padLeft(6, '0'),
  voyageName: null,
  localDisplayName: 'Oliver',
  localRole: VoyageRole.skipper,
  startedAt: DateTime.utc(2026, 8, 12, 9),
  endedAt: DateTime.utc(2026, 8, 12, 10),
  archivedAt: DateTime.utc(2026, 8, 12, 10, 1),
  sailorCount: 1,
  eventCount: 0,
  totalDistanceMeters: 0,
  markerSessions: const [],
  plannedRoute: planned,
  traveledRoute: travelled,
);

ImportedRoute _route(List<RoutePath> paths) => ImportedRoute(
  id: 'route',
  name: 'Route',
  importedAt: DateTime.utc(2026, 8, 12),
  sourceFileName: 'local',
  paths: paths,
  waypoints: const [],
);

RoutePath _path(
  double startLatitude,
  double startLongitude,
  double endLatitude,
  double endLongitude,
) => RoutePath(
  kind: RoutePathKind.track,
  points: [
    GeoPoint(latitude: startLatitude, longitude: startLongitude),
    GeoPoint(latitude: endLatitude, longitude: endLongitude),
  ],
);
