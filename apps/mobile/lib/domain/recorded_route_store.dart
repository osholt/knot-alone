import 'imported_route.dart';

/// A library of saved recordings, distinct from [RouteStore]'s single
/// "active route for this ride" slot - a leader may record several routes
/// ahead of time and pick one later.
abstract interface class RecordedRouteStore {
  Future<List<ImportedRoute>> list();

  Future<void> save(ImportedRoute route);

  Future<void> delete(String id);
}

class InMemoryRecordedRouteStore implements RecordedRouteStore {
  final Map<String, ImportedRoute> _routes = {};

  @override
  Future<List<ImportedRoute>> list() async => _routes.values.toList()
    ..sort((first, second) => second.importedAt.compareTo(first.importedAt));

  @override
  Future<void> save(ImportedRoute route) async => _routes[route.id] = route;

  @override
  Future<void> delete(String id) async => _routes.remove(id);
}
