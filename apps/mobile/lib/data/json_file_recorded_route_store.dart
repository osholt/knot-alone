import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/imported_route.dart';
import '../domain/recorded_route_store.dart';

class JsonFileRecordedRouteStore implements RecordedRouteStore {
  JsonFileRecordedRouteStore(this.directory);

  final Directory directory;

  static Future<JsonFileRecordedRouteStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return JsonFileRecordedRouteStore(
      Directory(path.join(support.path, 'recorded_routes')),
    );
  }

  @override
  Future<List<ImportedRoute>> list() async {
    if (!await directory.exists()) return const [];
    final routes = <ImportedRoute>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        routes.add(ImportedRoute.fromJsonString(await entity.readAsString()));
      } on FormatException {
        // A damaged recording must never block loading the rest.
        continue;
      }
    }
    routes.sort(
      (first, second) => second.importedAt.compareTo(first.importedAt),
    );
    return routes;
  }

  @override
  Future<void> save(ImportedRoute route) async {
    await directory.create(recursive: true);
    final file = _fileFor(route.id);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(route.toJsonString(), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  Future<void> delete(String id) async {
    final file = _fileFor(id);
    if (await file.exists()) await file.delete();
  }

  File _fileFor(String id) => File(path.join(directory.path, '$id.json'));
}
