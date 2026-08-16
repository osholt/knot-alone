import 'ride_event.dart';

abstract interface class EventStore {
  Future<void> append(RideEvent event);

  Future<List<RideEvent>> eventsForRide(String rideId);

  Future<List<RideEvent>> pendingEvents(String rideId);

  Future<void> markAcknowledged(String eventId);

  Future<void> deleteRide(String rideId);

  /// Removes specific events (e.g. an unused ICE-info share, purged once a
  /// ride ends) without discarding the rest of the ride's history.
  Future<void> deleteEvents(String rideId, Iterable<String> eventIds);

  Future<void> close();
}
