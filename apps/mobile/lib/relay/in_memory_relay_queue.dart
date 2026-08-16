import 'relay_queue.dart';

class InMemoryRelayQueue implements RelayQueueStore {
  final Map<String, QueuedRelayEvent> _items = {};

  @override
  Future<void> acknowledge(String peerId, Iterable<String> eventIds) async {
    for (final eventId in eventIds) {
      final item = _items[eventId];
      if (item != null) {
        _items[eventId] = item.copyWith(
          acknowledgedPeers: {...item.acknowledgedPeers, peerId},
        );
      }
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<bool> contains(String eventId) async => _items.containsKey(eventId);

  @override
  Future<int> count(String rideId, {required DateTime now}) async => _items
      .values
      .where(
        (item) => item.event.rideId == rideId && item.expiresAt.isAfter(now),
      )
      .length;

  @override
  Future<void> enqueue(QueuedRelayEvent item) async {
    _items.putIfAbsent(item.event.id, () => item);
  }

  @override
  Future<List<QueuedRelayEvent>> pendingForPeer(
    String rideId,
    String peerId, {
    required DateTime now,
    required int limit,
  }) async {
    final result = _items.values
        .where(
          (item) =>
              item.event.rideId == rideId &&
              item.expiresAt.isAfter(now) &&
              item.hopCount < maxRelayHops &&
              !item.acknowledgedPeers.contains(peerId),
        )
        .toList();
    result.sort((left, right) {
      final priority = right.event.priority.index.compareTo(
        left.event.priority.index,
      );
      return priority != 0
          ? priority
          : left.firstSeenAt.compareTo(right.firstSeenAt);
    });
    return result.take(limit).toList(growable: false);
  }

  @override
  Future<int> prune({required DateTime now, required int maxItems}) async {
    final before = _items.length;
    _items.removeWhere((_, item) => !item.expiresAt.isAfter(now));
    if (_items.length > maxItems) {
      final ranked = _items.values.toList()
        ..sort((left, right) {
          final priority = right.event.priority.index.compareTo(
            left.event.priority.index,
          );
          return priority != 0
              ? priority
              : right.firstSeenAt.compareTo(left.firstSeenAt);
        });
      final keep = ranked.take(maxItems).map((item) => item.event.id).toSet();
      _items.removeWhere((eventId, _) => !keep.contains(eventId));
    }
    return before - _items.length;
  }
}
