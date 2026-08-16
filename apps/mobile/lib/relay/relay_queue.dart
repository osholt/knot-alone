import '../domain/ride_event.dart';

const maxRelayHops = 8;

class QueuedRelayEvent {
  const QueuedRelayEvent({
    required this.event,
    required this.firstSeenAt,
    required this.expiresAt,
    required this.hopCount,
    this.acknowledgedPeers = const {},
  });

  final RideEvent event;
  final DateTime firstSeenAt;
  final DateTime expiresAt;
  final int hopCount;
  final Set<String> acknowledgedPeers;

  QueuedRelayEvent copyWith({Set<String>? acknowledgedPeers}) =>
      QueuedRelayEvent(
        event: event,
        firstSeenAt: firstSeenAt,
        expiresAt: expiresAt,
        hopCount: hopCount,
        acknowledgedPeers: acknowledgedPeers ?? this.acknowledgedPeers,
      );
}

abstract interface class RelayQueueStore {
  Future<bool> contains(String eventId);

  Future<void> enqueue(QueuedRelayEvent item);

  Future<List<QueuedRelayEvent>> pendingForPeer(
    String rideId,
    String peerId, {
    required DateTime now,
    required int limit,
  });

  Future<void> acknowledge(String peerId, Iterable<String> eventIds);

  Future<int> prune({required DateTime now, required int maxItems});

  Future<int> count(String rideId, {required DateTime now});

  Future<void> close();
}
