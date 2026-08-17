import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/relay/nearby_event_source.dart';

void main() {
  test(
    'server acknowledgement does not suppress nearby carrier delivery',
    () async {
      final store = InMemoryEventStore();
      final event = VoyageEvent(
        id: 'server-acknowledged',
        voyageId: 'voyage-alpha',
        deviceId: 'sailor-one',
        type: VoyageEventType.statusMessage,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16),
        payload: const {'message': 'Road closed'},
        signature: 'a' * 64,
      );
      await store.append(event);
      await store.markAcknowledged(event.id);

      expect(await store.pendingEvents(event.voyageId), isEmpty);
      expect(
        (await eventsEligibleForNearbyRelay(
          store,
          event.voyageId,
        )).map((candidate) => candidate.id),
        ['server-acknowledged'],
      );
    },
  );
}
