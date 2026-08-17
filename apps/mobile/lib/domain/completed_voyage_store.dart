import 'completed_voyage.dart';

abstract interface class CompletedVoyageStore {
  Future<List<CompletedVoyage>> list();

  Future<void> save(CompletedVoyage voyage);

  Future<void> delete(String voyageId);
}

class InMemoryCompletedVoyageStore implements CompletedVoyageStore {
  final Map<String, CompletedVoyage> _voyages = {};

  @override
  Future<List<CompletedVoyage>> list() async =>
      _voyages.values.toList()
        ..sort((left, right) => right.endedAt.compareTo(left.endedAt));

  @override
  Future<void> save(CompletedVoyage voyage) async =>
      _voyages[voyage.voyageId] = voyage;

  @override
  Future<void> delete(String voyageId) async => _voyages.remove(voyageId);
}
