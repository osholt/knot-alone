import 'dart:async';
import 'package:flutter/services.dart';

import 'peer_transport.dart';

/// Flutter adapter for the official Google Nearby Connections native SDKs.
///
/// The SDKs compile on both platforms, but product availability remains gated
/// on the physical-device matrix in `docs/nearby-relay.md`.
class NativeNearbyTransport implements PeerTransport {
  NativeNearbyTransport([
    this._methodChannel = const MethodChannel('me.osholt.ride_relay/nearby'),
    this._eventChannel = const EventChannel(
      'me.osholt.ride_relay/nearby_events',
    ),
  ]);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final _statuses = StreamController<PeerTransportStatus>.broadcast();
  final _packets = StreamController<PeerPacket>.broadcast();
  StreamSubscription<Object?>? _nativeSubscription;

  @override
  Stream<PeerPacket> get packets => _packets.stream;

  @override
  Stream<PeerTransportStatus> get statuses => _statuses.stream;

  @override
  Future<void> start(PeerTransportConfig config) async {
    _nativeSubscription ??= _eventChannel.receiveBroadcastStream().listen(
      _onNativeEvent,
      onError: (Object error) {
        _statuses.add(
          PeerTransportStatus(
            state: PeerTransportState.failed,
            message: 'Native nearby event stream failed: $error',
          ),
        );
      },
    );
    final permissionsGranted =
        await _methodChannel.invokeMethod<bool>('requestPermissions') ?? false;
    if (!permissionsGranted) {
      _statuses.add(
        const PeerTransportStatus(
          state: PeerTransportState.unavailable,
          message: 'Nearby-device permission is required',
        ),
      );
      throw StateError('Nearby-device permission was denied');
    }
    await _methodChannel.invokeMethod<void>('start', {
      'serviceId': config.serviceId,
      'endpointName': config.endpointName,
    });
  }

  @override
  Future<void> send(Uint8List bytes, {required Set<String> peerIds}) async {
    if (bytes.isEmpty || peerIds.isEmpty) {
      return;
    }
    await _methodChannel.invokeMethod<void>('send', {
      'bytes': bytes,
      'peerIds': peerIds.toList(growable: false),
    });
  }

  @override
  Future<void> stop() async {
    try {
      await _methodChannel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // A test/unsupported host can still shut down the Dart relay cleanly.
    }
  }

  void _onNativeEvent(Object? raw) {
    if (raw is! Map<Object?, Object?>) {
      return;
    }
    final kind = raw['kind'];
    if (kind == 'packet') {
      final peerId = raw['peerId'];
      final bytes = raw['bytes'];
      if (peerId is String && bytes is Uint8List) {
        _packets.add(PeerPacket(peerId: peerId, bytes: bytes));
      }
      return;
    }
    if (kind != 'status') {
      return;
    }
    final state = switch (raw['state']) {
      'starting' => PeerTransportState.starting,
      'searching' => PeerTransportState.searching,
      'connected' => PeerTransportState.connected,
      'failed' => PeerTransportState.failed,
      'unavailable' => PeerTransportState.unavailable,
      _ => PeerTransportState.stopped,
    };
    final rawPeerIds = raw['peerIds'];
    final peerIds = rawPeerIds is List<Object?>
        ? rawPeerIds.whereType<String>().toSet()
        : <String>{};
    _statuses.add(
      PeerTransportStatus(
        state: state,
        peerIds: peerIds,
        message: raw['message'] as String?,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _nativeSubscription?.cancel();
    await _statuses.close();
    await _packets.close();
  }
}
