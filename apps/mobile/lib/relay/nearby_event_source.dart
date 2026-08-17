import '../domain/event_store.dart';
import '../domain/voyage_event.dart';

/// Nearby delivery state lives in the nearby relay queue, so the shared event
/// store's server acknowledgement must not make an event ineligible here.
Future<List<VoyageEvent>> eventsEligibleForNearbyRelay(
  EventStore eventStore,
  String voyageId,
) => eventStore.eventsForVoyage(voyageId);
