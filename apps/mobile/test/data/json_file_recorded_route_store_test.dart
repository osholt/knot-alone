import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/json_file_recorded_route_store.dart';
import 'package:ride_relay/domain/imported_route.dart';

void main() {
  late Directory directory;
  late JsonFileRecordedRouteStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'recorded-route-store-test',
    );
    store = JsonFileRecordedRouteStore(Directory('${directory.path}/routes'));
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('lists nothing before any recording is saved', () async {
    expect(await store.list(), isEmpty);
  });

  test('saves, lists newest-first, and deletes recordings', () async {
    final first = _route('first', 'First recording', DateTime.utc(2026, 1));
    final second = _route('second', 'Second recording', DateTime.utc(2026, 2));

    await store.save(first);
    await store.save(second);

    final listed = await store.list();
    expect(listed.map((route) => route.id), ['second', 'first']);

    await store.delete('second');
    expect((await store.list()).map((route) => route.id), ['first']);
  });

  test('overwrites a recording saved again under the same id', () async {
    await store.save(_route('first', 'Original name', DateTime.utc(2026, 1)));
    await store.save(_route('first', 'Renamed', DateTime.utc(2026, 1)));

    final listed = await store.list();
    expect(listed, hasLength(1));
    expect(listed.single.name, 'Renamed');
  });

  test(
    'skips a damaged recording file instead of failing the whole list',
    () async {
      await store.save(_route('good', 'Good recording', DateTime.utc(2026, 1)));
      await Directory('${directory.path}/routes').create(recursive: true);
      await File(
        '${directory.path}/routes/damaged.json',
      ).writeAsString('not valid json');

      final listed = await store.list();

      expect(listed.map((route) => route.id), ['good']);
    },
  );
}

ImportedRoute _route(String id, String name, DateTime importedAt) =>
    ImportedRoute(
      id: id,
      name: name,
      importedAt: importedAt,
      sourceFileName: 'recorded.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51, longitude: -1),
            GeoPoint(latitude: 51.01, longitude: -1),
          ],
        ),
      ],
      waypoints: const [],
    );
