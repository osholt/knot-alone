import 'package:flutter/foundation.dart';

import '../domain/completed_voyage.dart';
import '../domain/completed_voyage_store.dart';

class CompletedVoyagesController extends ChangeNotifier
    implements CompletedVoyageStore {
  CompletedVoyagesController._(this._store, this._voyages);

  final CompletedVoyageStore _store;
  List<CompletedVoyage> _voyages;

  List<CompletedVoyage> get voyages => List.unmodifiable(_voyages);

  static Future<CompletedVoyagesController> load(
    CompletedVoyageStore store,
  ) async => CompletedVoyagesController._(store, await store.list());

  @override
  Future<List<CompletedVoyage>> list() async => List.unmodifiable(_voyages);

  @override
  Future<void> save(CompletedVoyage voyage) async {
    await _store.save(voyage);
    _voyages = [
      voyage,
      ..._voyages.where((existing) => existing.voyageId != voyage.voyageId),
    ]..sort((left, right) => right.endedAt.compareTo(left.endedAt));
    notifyListeners();
  }

  @override
  Future<void> delete(String voyageId) async {
    await _store.delete(voyageId);
    _voyages = _voyages
        .where((existing) => existing.voyageId != voyageId)
        .toList(growable: false);
    notifyListeners();
  }
}
