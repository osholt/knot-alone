import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/imported_route.dart';
import '../domain/route_store.dart';

class JsonFileRouteStore implements RouteStore {
  JsonFileRouteStore(this.file);

  factory JsonFileRouteStore.forRide(
    Directory supportDirectory,
    String rideId,
  ) {
    final scope = base64Url.encode(utf8.encode(rideId)).replaceAll('=', '');
    return JsonFileRouteStore(
      File(
        path.join(
          supportDirectory.path,
          'routes',
          'rides',
          scope,
          'active-route.json',
        ),
      ),
    );
  }

  final File file;

  static Future<JsonFileRouteStore> openDefault() async {
    final supportDirectory = await getApplicationSupportDirectory();
    return JsonFileRouteStore(
      File(path.join(supportDirectory.path, 'routes', 'active-route.json')),
    );
  }

  static Future<JsonFileRouteStore> openForRide(String rideId) async {
    if (rideId.trim().isEmpty) {
      throw ArgumentError.value(rideId, 'rideId', 'Must not be empty');
    }
    final supportDirectory = await getApplicationSupportDirectory();
    return JsonFileRouteStore.forRide(supportDirectory, rideId);
  }

  @override
  Future<ImportedRoute?> loadActiveRoute() async {
    if (!await file.exists()) return null;
    return ImportedRoute.fromJsonString(await file.readAsString());
  }

  @override
  Future<void> saveActiveRoute(ImportedRoute route) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    await temporary.writeAsString(route.toJsonString(), flush: true);

    try {
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await file.rename(backup.path);
      await temporary.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        await backup.rename(file.path);
      }
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<void> clearActiveRoute() async {
    if (await file.exists()) await file.delete();
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();
  }
}
