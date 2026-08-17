import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/sailor_location.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_session.dart';
import '../relay/relay_engine.dart';
import '../relay/relay_presence.dart';

/// Narrow UI integration seam; it does not couple the voyage controller to a
/// particular radio SDK.
class NearbyRelayController extends ChangeNotifier
    implements RelayPresenceGateway {
  NearbyRelayController(this._engine) {
    _subscription = _engine.statuses.listen((status) {
      _status = status;
      notifyListeners();
    });
  }

  final RelayEngine _engine;
  late final StreamSubscription<RelayStatus> _subscription;
  RelayStatus _status = const RelayStatus.stopped();

  RelayStatus get status => _status;
  int get peerCount => _status.peerIds.length;
  Stream<VoyageEvent> get receivedEvents => _engine.receivedEvents;
  @override
  Stream<RelayPresenceUpdate> get presenceUpdates => _engine.receivedPresence;

  Future<void> start(VoyageSession session) => _engine.start(
    RelayEngineConfig(
      voyageId: session.voyageId,
      voyageSecret: session.inviteSecret,
      localDeviceId: session.localSailorId,
      endpointName: session.displayName,
    ),
  );

  Future<void> publish(VoyageEvent event) => _engine.enqueueLocal(event);

  @override
  Future<void> publishPresence(
    SailorLocation? position, {
    bool clear = false,
    Duration ttl = const Duration(seconds: 45),
  }) => _engine.publishPresence(position, clear: clear, ttl: ttl);

  @Deprecated('Use publish')
  Future<void> relay(VoyageEvent event) => publish(event);

  Future<void> stop() => _engine.stop();

  Future<void> close() async {
    await _subscription.cancel();
    await _engine.dispose();
    dispose();
  }
}
