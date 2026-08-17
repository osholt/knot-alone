import 'voyage_event.dart';

abstract interface class EventStore {
  Future<void> append(VoyageEvent event);

  Future<List<VoyageEvent>> eventsForVoyage(String voyageId);

  Future<List<VoyageEvent>> pendingEvents(String voyageId);

  Future<void> markAcknowledged(String eventId);

  Future<void> deleteVoyage(String voyageId);

  /// Removes specific events (e.g. an unused ICE-info share, purged once a
  /// voyage ends) without discarding the rest of the voyage's history.
  Future<void> deleteEvents(String voyageId, Iterable<String> eventIds);

  Future<void> close();
}
