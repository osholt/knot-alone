import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/voyage_role.dart';
import '../domain/sailor_location.dart';
import '../domain/voyage_session.dart';
import '../internet/internet_relay_client.dart';
import '../relay/live_presence.dart';
import '../relay/relay_presence.dart';

/// Maintains one short-lived, non-journalled position per sailor for the whole
/// voyage.
///
/// This controller deliberately has no [EventStore] dependency. Its snapshots
/// disappear when stale, when the controller stops, or when the process exits.
/// The durable journal remains the only record of where the group has been;
/// this is only the answer to "where is everyone right now".
///
/// It runs across the `voyageStarted` transition on purpose. Stopping at start
/// left two disconnected channels with no continuity, so a sailor visible before
/// the start vanished at start, and a sailor joining an already-started voyage was
/// never visible at all until a journal round-trip completed.
class PreStartPresenceController extends ChangeNotifier {
  PreStartPresenceController(
    this._api, {
    this.pollInterval = const Duration(seconds: 4),
    this.freshnessPolicy = const PresenceFreshnessPolicy(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PreStartPresenceApi _api;
  final Duration pollInterval;
  final PresenceFreshnessPolicy freshnessPolicy;
  final DateTime Function() _clock;
  VoyageSession? _session;
  SailorLocation? _localPosition;
  final Map<String, SailorLocation> _internetLocations = {};
  final Map<String, RelayPresenceUpdate> _nearbyLocations = {};
  final Map<String, PresenceRosterMember> _roster = {};
  Set<String> _legacyPeerSailorIds = const {};
  Duration _relayClockOffset = Duration.zero;
  int _unreadablePositionCount = 0;
  RelayPresenceGateway? _nearby;
  StreamSubscription<RelayPresenceUpdate>? _nearbySubscription;
  Duration _ttl = const Duration(seconds: 45);
  Timer? _timer;
  bool _active = false;
  bool _syncing = false;
  bool _closed = false;
  bool _clearOnNextSync = false;
  PresenceAvailability _availability = PresenceAvailability.stopped;
  VoyagePresencePhase _phase = VoyagePresencePhase.unknown;

  bool get active => _active;

  /// The named availability of the internet presence channel. Replaces the
  /// previous string comparison against a server status code, which turned a
  /// capability refusal into a silent shrug.
  PresenceAvailability get availability => _availability;

  /// True when at least one presence channel can carry positions.
  bool get supported =>
      _nearby != null ||
      _availability != PresenceAvailability.serviceUnsupported;

  /// Plain-language reason, or null when presence is working.
  String? get unavailableReason => switch (_availability) {
    PresenceAvailability.live || PresenceAvailability.starting => null,
    PresenceAvailability.stopped => null,
    PresenceAvailability.serviceUnsupported =>
      PresenceLimitation.serviceCapabilityMissing.message,
    PresenceAvailability.serviceUnauthorized =>
      PresenceLimitation.serviceUnauthorized.message,
    PresenceAvailability.clientUpdateRequired =>
      PresenceLimitation.clientUpdateRequired.message,
    PresenceAvailability.serviceUpgradeRequired =>
      PresenceLimitation.serviceUpgradeRequired.message,
    PresenceAvailability.serviceUnreachable =>
      PresenceLimitation.serviceUnreachable.message,
  };

  /// Retained so existing callers keep compiling; prefer [unavailableReason].
  String? get statusMessage => unavailableReason;

  /// The phase the relay reports for this voyage, which is what makes presence
  /// continuous rather than something the client has to infer from its own
  /// cursor.
  VoyagePresencePhase get phase => _phase;

  /// Sailors the relay has seen, independent of the bulk event batch.
  List<PresenceRosterMember> get roster =>
      List.unmodifiable(_roster.values.toList()..sort(_byJoinedAt));

  /// The relay's clock minus this device's, from the last successful sync.
  ///
  /// Zero until the relay reports its own time. A peer's position is aged
  /// against the relay's clock rather than this phone's, because that is the
  /// only clock the two phones share.
  Duration get relayClockOffset => _relayClockOffset;

  /// Every named degradation currently affecting live positions.
  List<PresenceLimitation> get limitations {
    final channel = switch (_availability) {
      PresenceAvailability.serviceUnsupported =>
        PresenceLimitation.serviceCapabilityMissing,
      PresenceAvailability.serviceUnauthorized =>
        PresenceLimitation.serviceUnauthorized,
      PresenceAvailability.clientUpdateRequired =>
        PresenceLimitation.clientUpdateRequired,
      PresenceAvailability.serviceUpgradeRequired =>
        PresenceLimitation.serviceUpgradeRequired,
      PresenceAvailability.serviceUnreachable =>
        PresenceLimitation.serviceUnreachable,
      _ => null,
    };
    final result = <PresenceLimitation>[?channel];
    if (_unreadablePositionCount > 0) {
      result.add(
        PresenceLimitation.positionsUnreadable(_unreadablePositionCount),
      );
    }
    for (final sailorId in _legacyPeerSailorIds) {
      if (sailorId == _session?.localSailorId) continue;
      final name =
          _roster[sailorId]?.displayName ??
          _internetLocations[sailorId]?.displayName;
      if (name == null) continue;
      result.add(
        PresenceLimitation.peerAppOlder(sailorId: sailorId, displayName: name),
      );
    }
    // A sailor whose own clock disagrees with the relay is named rather than
    // quietly aged out. Their position is still live: it is timed by the relay.
    for (final presence in presenceAt(_clock())) {
      final offset = presence.publisherClockOffset;
      if (offset == null || presence.isLocal) continue;
      result.add(
        PresenceLimitation.sailorClockUntrusted(
          sailorId: presence.sailorId,
          displayName: presence.displayName,
          offset: offset,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// The freshest retained position per sailor across both presence channels.
  ///
  /// Positions past [PresenceFreshnessPolicy.retainFor] are dropped so nothing
  /// is drawn as if current; between the TTL and that threshold they survive so
  /// they can be visibly demoted to ageing and then stale.
  List<SailorLocation> get locations => [
    for (final presence in presenceAt(_clock())) ?presence.location,
  ];

  /// Retained positions from the internet presence channel only, so a caller
  /// merging in the journal can still attribute each source correctly.
  List<SailorLocation> get internetLocations =>
      List.unmodifiable(_retainedInternet(_clock()));

  /// Retained positions from the nearby presence channel only.
  List<SailorLocation> get nearbyLocations {
    final now = _clock();
    return List.unmodifiable(_retained(_nearbyPositions(now), now));
  }

  /// The reconciled per-sailor state, including sailors the roster names but who
  /// have no position yet.
  List<LiveSailorPresence> presenceAt(DateTime now) =>
      LivePresenceReconciler(policy: freshnessPolicy).reconcile(
        now: now,
        localSailorId: _session?.localSailorId ?? '',
        internetPresence: _retainedInternet(now),
        nearbyPresence: _retained(_nearbyPositions(now), now),
        roster: _roster.values,
        relayClockOffset: _relayClockOffset,
      );

  Iterable<SailorLocation> _retained(
    Iterable<SailorLocation> locations,
    DateTime now,
  ) => locations.where(
    (location) => location.sample.ageAt(now) <= freshnessPolicy.retainFor,
  );

  /// Retention for the internet channel is measured on the relay's clock for a
  /// peer, because their position carries the relay's arrival stamp. Measuring it
  /// against their own timestamp discarded sailors whose phone clock was wrong
  /// while they were still reporting every few seconds.
  Iterable<SailorLocation> _retainedInternet(DateTime now) {
    final localSailorId = _session?.localSailorId;
    final relayNow = now.add(_relayClockOffset);
    return _internetLocations.values.where((location) {
      if (location.sailorId == localSailorId) {
        return location.sample.ageAt(now) <= freshnessPolicy.retainFor;
      }
      final relayAge = relayNow.difference(location.receivedAt);
      return (relayAge.isNegative ? Duration.zero : relayAge) <=
          freshnessPolicy.retainFor;
    });
  }

  Iterable<SailorLocation> _nearbyPositions(DateTime now) => [
    for (final update in _nearbyLocations.values)
      if (update.position case final position?)
        if (update.expiresAt.isAfter(now) ||
            position.sample.ageAt(now) <= freshnessPolicy.retainFor)
          position,
  ];

  Future<void> attachNearby(RelayPresenceGateway nearby) async {
    if (_closed) throw StateError('Live presence controller is closed.');
    await _nearbySubscription?.cancel();
    _nearby = nearby;
    _nearbySubscription = nearby.presenceUpdates.listen(_onNearbyPresence);
    final localPosition = _localPosition;
    if (_active && localPosition != null) {
      await nearby.publishPresence(localPosition, ttl: _ttl);
    }
    notifyListeners();
  }

  Future<void> start(VoyageSession session) async {
    if (_closed) throw StateError('Live presence controller is closed.');
    _session = session;
    _active = true;
    _availability = PresenceAvailability.starting;
    await synchronizeNow();
  }

  /// Takes the newest local fix. Every fix belongs here, whether or not it was
  /// worth a durable position report, because this channel is what keeps a sailor
  /// visible while they are not moving.
  ///
  /// [publishImmediately] only decides whether the scheduled poll is brought
  /// forward. False leaves the fix to go out on the next tick, which is the
  /// keep-alive: the poll runs on a timer regardless of movement and carries
  /// whatever the newest fix is, so nothing is withheld — it is delivered at
  /// [pollInterval] instead of instantly. Callers pass false for a fix that did
  /// not clear the reporting threshold, so a sailor crawling in traffic stops
  /// generating a request per fix (#166).
  void updateLocalPosition(
    SailorLocation location, {
    bool publishImmediately = true,
  }) {
    final session = _session;
    if (!_active ||
        session == null ||
        location.sailorId != session.localSailorId) {
      return;
    }
    _localPosition = location;
    _offerInternet(location);
    _nearbyLocations[location.sailorId] = RelayPresenceUpdate(
      sailorId: location.sailorId,
      sentAt: location.receivedAt,
      expiresAt: location.receivedAt.add(_ttl),
      clear: false,
      position: location,
    );
    notifyListeners();
    if (!publishImmediately) return;
    unawaited(_publishNearby(location));
    wake();
  }

  Future<void> clearLocalPosition() async {
    final localId = _session?.localSailorId;
    _localPosition = null;
    if (localId != null) {
      _internetLocations.remove(localId);
      _nearbyLocations.remove(localId);
    }
    _clearOnNextSync = true;
    notifyListeners();
    await Future.wait([
      synchronizeNow(),
      if (_nearby != null)
        _nearby!.publishPresence(null, clear: true, ttl: _ttl),
    ]);
  }

  Future<void> synchronizeNow() async {
    final session = _session;
    if (!_active || _closed || _syncing || session == null) return;
    _timer?.cancel();
    _timer = null;
    _syncing = true;
    try {
      final result = await _api.synchronizePreStartPresence(
        session: session,
        position: _clearOnNextSync ? null : _localPosition,
        clear: _clearOnNextSync,
      );
      if (!_active || _closed || !identical(session, _session)) return;
      _clearOnNextSync = false;
      _ttl = result.ttl;
      _phase = result.phase;
      final serverTime = result.serverTime;
      if (serverTime != null) {
        _relayClockOffset = serverTime.difference(_clock());
      }
      _unreadablePositionCount = result.unreadablePositionCount;
      _applyInternetResult(result, session);
      _availability = PresenceAvailability.live;
      notifyListeners();
    } on InternetRelayException catch (error) {
      if (!_active || _closed || !identical(session, _session)) return;
      _availability = _availabilityFor(error);
      notifyListeners();
    } finally {
      _syncing = false;
      if (_active && !_closed) {
        _timer = Timer(pollInterval, () => unawaited(synchronizeNow()));
      }
    }
  }

  void wake() {
    if (!_active || _closed || _syncing || _timer == null) return;
    _timer?.cancel();
    _timer = null;
    unawaited(synchronizeNow());
  }

  Future<void> stop({bool clearRemote = true}) async {
    if (!_active) {
      _internetLocations.clear();
      _nearbyLocations.clear();
      _roster.clear();
      return;
    }
    _timer?.cancel();
    _timer = null;
    final session = _session;
    _active = false;
    _availability = PresenceAvailability.stopped;
    _internetLocations.clear();
    _nearbyLocations.clear();
    _roster.clear();
    _legacyPeerSailorIds = const {};
    _relayClockOffset = Duration.zero;
    _unreadablePositionCount = 0;
    notifyListeners();
    if (clearRemote) {
      await Future.wait([
        if (session != null) _clearInternetPresence(session),
        if (_nearby != null) _clearNearbyPresence(),
      ]);
    }
    _localPosition = null;
    _clearOnNextSync = false;
  }

  Future<void> close() async {
    if (_closed) return;
    await stop();
    await _nearbySubscription?.cancel();
    _nearbySubscription = null;
    _nearby = null;
    _closed = true;
    _session = null;
    _api.close();
    dispose();
  }

  void _applyInternetResult(
    PreStartPresenceResult result,
    VoyageSession session,
  ) {
    // An out-of-order or duplicated reply must never rewind a sailor to an older
    // coordinate.
    for (final location in result.locations) {
      _offerInternet(location);
    }
    final localPosition = _localPosition;
    if (localPosition != null) _offerInternet(localPosition);
    _legacyPeerSailorIds = result.legacyPeerSailorIds;
    _roster
      ..clear()
      ..addEntries(
        result.roster.map(
          (entry) => MapEntry(
            entry.sailorId,
            PresenceRosterMember(
              sailorId: entry.sailorId,
              displayName: entry.displayName,
              role: _roleFor(entry.role),
              joinedAt: entry.joinedAt,
              left: entry.left,
              leftAt: entry.leftAt,
            ),
          ),
        ),
      );
    // A sailor missing from the relay's list has stopped reporting; that is
    // shown by demoting their last position to ageing and then stale, not by
    // deleting it, because a marker that silently vanishes is indistinguishable
    // from one that was never there. Only an explicit departure removes a
    // sailor, and only [PresenceFreshnessPolicy.retainFor] drops the position.
    final now = _clock();
    final departed = {
      for (final entry in result.roster)
        if (entry.left) entry.sailorId,
    };
    final retained = _retainedInternet(
      now,
    ).map((location) => location.sailorId).toSet();
    _internetLocations.removeWhere(
      (sailorId, location) =>
          (departed.contains(sailorId) && sailorId != session.localSailorId) ||
          !retained.contains(sailorId),
    );
    _nearbyLocations.removeWhere((sailorId, update) {
      final position = update.position;
      return (departed.contains(sailorId) &&
              sailorId != session.localSailorId) ||
          position == null ||
          position.sample.ageAt(now) > freshnessPolicy.retainFor;
    });
  }

  void _offerInternet(SailorLocation location) {
    final previous = _internetLocations[location.sailorId];
    if (previous != null &&
        !location.sample.recordedAt.isAfter(previous.sample.recordedAt)) {
      return;
    }
    _internetLocations[location.sailorId] = location;
  }

  static PresenceAvailability _availabilityFor(InternetRelayException error) {
    if (error.code == 'feature_unsupported') {
      return PresenceAvailability.serviceUnsupported;
    }
    if (error.code == 'update_required') {
      return PresenceAvailability.clientUpdateRequired;
    }
    if (error.code == 'server_upgrade_required') {
      return PresenceAvailability.serviceUpgradeRequired;
    }
    if (error.unauthorized) return PresenceAvailability.serviceUnauthorized;
    return PresenceAvailability.serviceUnreachable;
  }

  static VoyageRole _roleFor(String value) {
    for (final role in VoyageRole.values) {
      if (role.name == value) return role;
    }
    // An unknown future role must not drop the sailor from the roster.
    return VoyageRole.sailor;
  }

  static int _byJoinedAt(
    PresenceRosterMember left,
    PresenceRosterMember right,
  ) {
    final byJoin = left.joinedAt.compareTo(right.joinedAt);
    return byJoin != 0 ? byJoin : left.sailorId.compareTo(right.sailorId);
  }

  void _onNearbyPresence(RelayPresenceUpdate update) {
    if (!_active || _closed) return;
    final previous = _nearbyLocations[update.sailorId];
    if (previous != null && !update.sentAt.isAfter(previous.sentAt)) return;
    if (update.clear) {
      _nearbyLocations.remove(update.sailorId);
    } else {
      _nearbyLocations[update.sailorId] = update;
    }
    notifyListeners();
  }

  Future<void> _publishNearby(SailorLocation location) async {
    try {
      await _nearby?.publishPresence(location, ttl: _ttl);
    } on Object {
      // Internet presence and the next GPS fix remain independent fallbacks.
    }
  }

  Future<void> _clearInternetPresence(VoyageSession session) async {
    try {
      await _api.synchronizePreStartPresence(
        session: session,
        position: null,
        clear: true,
      );
    } on Object {
      // The shared server TTL remains the bounded cleanup fallback.
    }
  }

  Future<void> _clearNearbyPresence() async {
    try {
      await _nearby?.publishPresence(null, clear: true, ttl: _ttl);
    } on Object {
      // Nearby snapshots expire independently on every peer.
    }
  }
}

/// Why live positions are or are not flowing over the internet presence
/// channel. Every value is a state a sailor can be told about.
enum PresenceAvailability {
  stopped,
  starting,
  live,
  serviceUnsupported,
  serviceUnauthorized,
  serviceUnreachable,
  clientUpdateRequired,
  serviceUpgradeRequired,
}
