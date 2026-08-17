abstract interface class InternetCursorStore {
  Future<String?> load(String voyageId);

  Future<void> save(String voyageId, String cursor);

  Future<void> clear(String voyageId);
}

class InMemoryInternetCursorStore implements InternetCursorStore {
  final Map<String, String> _cursors = {};

  @override
  Future<void> clear(String voyageId) async => _cursors.remove(voyageId);

  @override
  Future<String?> load(String voyageId) async => _cursors[voyageId];

  @override
  Future<void> save(String voyageId, String cursor) async {
    _cursors[voyageId] = cursor;
  }
}
