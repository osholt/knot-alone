import '../domain/event_store.dart';
import '../domain/voyage_event.dart';

class InMemoryEventStore implements EventStore {
  final Map<String, VoyageEvent> _events = {};

  @override
  Future<void> append(VoyageEvent event) async {
    _events.putIfAbsent(event.id, () => event);
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteVoyage(String voyageId) async {
    _events.removeWhere((_, event) => event.voyageId == voyageId);
  }

  @override
  Future<void> deleteEvents(String voyageId, Iterable<String> eventIds) async {
    final ids = eventIds.toSet();
    _events.removeWhere(
      (id, event) => event.voyageId == voyageId && ids.contains(id),
    );
  }

  @override
  Future<List<VoyageEvent>> eventsForVoyage(String voyageId) async {
    final result = _events.values
        .where((event) => event.voyageId == voyageId)
        .toList();
    result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return result;
  }

  @override
  Future<void> markAcknowledged(String eventId) async {
    final event = _events[eventId];
    if (event != null) {
      _events[eventId] = event.copyWith(acknowledged: true);
    }
  }

  @override
  Future<List<VoyageEvent>> pendingEvents(String voyageId) async {
    final events = await eventsForVoyage(voyageId);
    return events.where((event) => !event.acknowledged).toList();
  }
}
