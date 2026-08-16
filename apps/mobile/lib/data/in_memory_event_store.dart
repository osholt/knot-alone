import '../domain/event_store.dart';
import '../domain/ride_event.dart';

class InMemoryEventStore implements EventStore {
  final Map<String, RideEvent> _events = {};

  @override
  Future<void> append(RideEvent event) async {
    _events.putIfAbsent(event.id, () => event);
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> deleteRide(String rideId) async {
    _events.removeWhere((_, event) => event.rideId == rideId);
  }

  @override
  Future<void> deleteEvents(String rideId, Iterable<String> eventIds) async {
    final ids = eventIds.toSet();
    _events.removeWhere(
      (id, event) => event.rideId == rideId && ids.contains(id),
    );
  }

  @override
  Future<List<RideEvent>> eventsForRide(String rideId) async {
    final result = _events.values
        .where((event) => event.rideId == rideId)
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
  Future<List<RideEvent>> pendingEvents(String rideId) async {
    final events = await eventsForRide(rideId);
    return events.where((event) => !event.acknowledged).toList();
  }
}
