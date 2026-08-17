import '../domain/sailor_location.dart';

/// One authenticated, replace-only presence update carried by Nearby.
///
/// These updates are never appended to the event journal or relay queue.
class RelayPresenceUpdate {
  const RelayPresenceUpdate({
    required this.sailorId,
    required this.sentAt,
    required this.expiresAt,
    required this.clear,
    this.position,
  });

  final String sailorId;
  final DateTime sentAt;
  final DateTime expiresAt;
  final bool clear;
  final SailorLocation? position;
}

abstract interface class RelayPresenceGateway {
  Stream<RelayPresenceUpdate> get presenceUpdates;

  Future<void> publishPresence(
    SailorLocation? position, {
    bool clear = false,
    Duration ttl = const Duration(seconds: 45),
  });
}
