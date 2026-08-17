import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import '../domain/completed_voyage.dart';
import '../domain/completed_voyage_store.dart';

class JsonFileCompletedVoyageStore implements CompletedVoyageStore {
  JsonFileCompletedVoyageStore(this.directory);

  final Directory directory;

  static Future<JsonFileCompletedVoyageStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return JsonFileCompletedVoyageStore(
      Directory(path.join(support.path, 'completed_voyages')),
    );
  }

  @override
  Future<List<CompletedVoyage>> list() async {
    if (!await directory.exists()) return const [];
    final voyages = <CompletedVoyage>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is Map) {
          voyages.add(
            CompletedVoyage.fromJson(Map<String, Object?>.from(decoded)),
          );
        }
      } on Object {
        // One damaged archive must never make the rest of the library vanish.
      }
    }
    voyages.sort((left, right) => right.endedAt.compareTo(left.endedAt));
    return voyages;
  }

  @override
  Future<void> save(CompletedVoyage voyage) async {
    await directory.create(recursive: true);
    final file = _fileFor(voyage.voyageId);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(voyage.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  @override
  Future<void> delete(String voyageId) async {
    final file = _fileFor(voyageId);
    if (await file.exists()) await file.delete();
  }

  File _fileFor(String voyageId) {
    final safeName = base64Url
        .encode(utf8.encode(voyageId))
        .replaceAll('=', '');
    return File(path.join(directory.path, '$safeName.json'));
  }
}
