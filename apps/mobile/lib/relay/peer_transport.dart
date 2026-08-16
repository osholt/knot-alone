import 'dart:typed_data';

enum PeerTransportState {
  unavailable,
  stopped,
  starting,
  searching,
  connected,
  failed,
}

class PeerTransportConfig {
  const PeerTransportConfig({
    required this.serviceId,
    required this.endpointName,
  });

  final String serviceId;
  final String endpointName;
}

class PeerTransportStatus {
  const PeerTransportStatus({
    required this.state,
    this.peerIds = const {},
    this.message,
  });

  const PeerTransportStatus.stopped()
    : state = PeerTransportState.stopped,
      peerIds = const {},
      message = null;

  final PeerTransportState state;
  final Set<String> peerIds;
  final String? message;
}

class PeerPacket {
  const PeerPacket({required this.peerId, required this.bytes});

  final String peerId;
  final Uint8List bytes;
}

/// Radio/cloud implementations only move opaque, bounded byte packets.
/// Authentication, replay protection, TTL and forwarding live above this seam.
abstract interface class PeerTransport {
  Stream<PeerTransportStatus> get statuses;

  Stream<PeerPacket> get packets;

  Future<void> start(PeerTransportConfig config);

  Future<void> send(Uint8List bytes, {required Set<String> peerIds});

  Future<void> stop();

  Future<void> dispose();
}
