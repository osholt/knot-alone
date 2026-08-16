import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/relay/in_memory_relay_queue.dart';
import 'package:ride_relay/relay/relay_queue.dart';

void main() {
  final now = DateTime.utc(2026, 7, 16, 12);

  test('deduplicates, prioritises, acknowledges and expires events', () async {
    final queue = InMemoryRelayQueue();
    await queue.enqueue(_item('routine', EventPriority.routine, now));
    await queue.enqueue(_item('critical', EventPriority.critical, now));
    await queue.enqueue(_item('critical', EventPriority.critical, now));

    var pending = await queue.pendingForPeer(
      'ride-1',
      'peer-b',
      now: now,
      limit: 10,
    );
    expect(pending.map((item) => item.event.id), ['critical', 'routine']);

    await queue.acknowledge('peer-b', ['critical']);
    pending = await queue.pendingForPeer(
      'ride-1',
      'peer-b',
      now: now,
      limit: 10,
    );
    expect(pending.single.event.id, 'routine');
    expect(
      await queue.pendingForPeer('ride-1', 'peer-c', now: now, limit: 10),
      hasLength(2),
    );

    expect(
      await queue.prune(now: now.add(const Duration(hours: 2)), maxItems: 512),
      2,
    );
  });
}

QueuedRelayEvent _item(String id, EventPriority priority, DateTime now) =>
    QueuedRelayEvent(
      event: RideEvent(
        id: id,
        rideId: 'ride-1',
        deviceId: 'device-a',
        type: RideEventType.statusMessage,
        priority: priority,
        createdAt: now,
        payload: const {},
        signature: 'a' * 64,
      ),
      firstSeenAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 0,
    );
