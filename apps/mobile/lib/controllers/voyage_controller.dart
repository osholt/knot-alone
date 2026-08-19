import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/geo_point.dart' as awareness_geo;
import '../domain/ice_share.dart';
import '../domain/imported_route.dart';
import '../domain/completed_voyage_store.dart';
import '../domain/join_invite.dart';
import '../domain/quick_message.dart';
import '../domain/voyage_coordination_mode.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import '../domain/voyage_join_payload.dart';
import '../domain/voyage_session.dart';
import '../domain/sailor_color.dart';
import '../domain/session_store.dart';
import '../features/map/vessel_icon.dart';
import '../relay/live_presence.dart';
import '../services/nearby_bridge.dart';
import '../services/completed_voyage_archiver.dart';
import '../services/voyage_event_authenticator.dart';
import '../services/voyage_lifecycle.dart';
import '../services/voyage_membership.dart';
import '../services/received_quick_message.dart';
import '../services/voyage_route_reducer.dart';
import '../services/sailor_contact_share.dart';
import '../services/sweeper_role_assignment.dart';
import '../internet/internet_relay_client.dart';

typedef Clock = DateTime Function();
typedef IdFactory = String Function();

/// Why a skipper's Sweeper request did or did not go out.
///
/// Every value other than [sent] is something the skipper is told in words: the
/// one outcome this feature must never have is appearing to have asked somebody
/// who was never asked.
enum SweeperRoleRequestOutcome {
  sent,

  /// Only the current skipper may ask.
  notSkipper,

  /// No such sailor in the live roster, or the skipper picked themselves.
  invalidTarget,

  /// That sailor already holds the role, so there is nothing to ask.
  alreadySweeper,

  /// The negotiated relay cannot carry the request, so nothing was recorded.
  relayUnsupported,

  /// The journal write failed. [VoyageController.errorMessage] carries the reason.
  failed,
}

/// Why a skipper's attempt to un-end a voyage did or did not take effect.
///
/// Every value other than [reopened] is something the skipper is told in words.
/// The outcome this must never have is a skipper back on the map believing the
/// group is with them when nobody else's voyage restarted (#206, #207).
enum VoyageReopenOutcome {
  reopened,

  /// This voyage has not ended, so there is nothing to undo.
  notEnded,

  /// Only the current skipper may reopen a voyage.
  notSkipper,

  /// Past the recovery window the voyage's journal and session are already gone.
  windowExpired,

  /// The negotiated relay cannot carry the reopen, so nothing was recorded.
  relayUnsupported,

  /// The journal write failed. [VoyageController.errorMessage] carries the reason.
  failed,
}

class VoyageController extends ChangeNotifier {
  VoyageController(
    this._eventStore,
    this._sessionStore,
    this._nearbyBridge, {
    Clock? clock,
    IdFactory? idFactory,
    Random? random,
    VoyageCodeDirectory? voyageCodeDirectory,
    this._completedVoyageStore,
    this._installationId,
  }) : _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7,
       _random = random ?? Random.secure(),
       _voyageCodeDirectory =
           voyageCodeDirectory ?? HttpVoyageCodeDirectory.fromEnvironment();

  static const endedVoyageRecoveryWindow = Duration(hours: 24);

  final EventStore _eventStore;
  final SessionStore _sessionStore;
  final NearbyBridge _nearbyBridge;
  final Clock _clock;
  final IdFactory _idFactory;
  final Random _random;
  final CompletedVoyageStore? _completedVoyageStore;
  final String? _installationId;
  final VoyageCodeDirectory _voyageCodeDirectory;

  VoyageSession? _session;
  List<VoyageEvent> _events = <VoyageEvent>[];
  final Set<String> _eventIds = {};
  NearbyCapabilities _nearbyCapabilities =
      const NearbyCapabilities.unavailable();
  bool _busy = false;
  String? _errorMessage;
  bool _errorIsRetryable = false;
  Timer? _endedVoyageCleanupTimer;
  bool _endedVoyageSetAside = false;
  VoyageLifecycle _lifecycle = const VoyageLifecycle();
  VoyageRouteState _routeState = const VoyageRouteState();
  final Map<String, Set<VoyageTransportEvidence>> _transportByEventId = {};
  List<LiveSailorPresence> _livePresence = const [];

  /// The relay's cursor-independent roster, including the sailors it reports as
  /// having left. Live presence drops a departed sailor — they are not there —
  /// so this is what keeps their roster record when their membership events
  /// never reached this phone's journal (#144).
  List<PresenceRosterMember> _presenceRoster = const [];
  List<VoyageParticipant>? _membershipParticipantsCache;
  int _membershipProjectionCount = 0;

  /// True when this device cannot currently receive live positions at all, so a
  /// missing position is attributed to the transport rather than to the sailor.
  bool _positionChannelUnavailable = false;

  /// Personal-detail shares the local sailor has acted on: an ICE contact they
  /// called or texted, or a sailor's own number they dialled. Kept in memory
  /// only, for this session: it gates which received shares survive the
  /// voyage-end purge, not a durable record of anyone's own.
  ///
  /// One set, because event ids are unique across types and the exemption rule
  /// is identical — a share you actually used may be followed up on.
  final Set<String> _usedIceShareEventIds = {};

  VoyageSession? get session => _session;
  EventStore get eventStore => _eventStore;
  List<VoyageEvent> get events => UnmodifiableListView(_events);
  int get eventCount => _events.length;
  NearbyCapabilities get nearbyCapabilities => _nearbyCapabilities;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;

  /// True when the failure behind [errorMessage] is worth simply trying again —
  /// a connection or service problem rather than something the sailor typed.
  ///
  /// Surfaced so the join form can offer a retry instead of leaving a sailor
  /// staring at a sentence about a relay handshake with nothing to press (#208).
  bool get errorIsRetryable => _errorMessage != null && _errorIsRetryable;
  bool get hasActiveVoyage => _session != null;

  /// The skipper persists this in the session and publishes it in `voyageCreated`.
  /// A joining phone starts from the backward-compatible drop-off default, then
  /// adopts the skipper's value as soon as the signed journal arrives.
  VoyageCoordinationMode get coordinationMode {
    final created = _events
        .where((event) => event.type == VoyageEventType.voyageCreated)
        .firstOrNull;
    return VoyageCoordinationMode.fromName(
      created?.payload['coordinationMode'] as String? ??
          _session?.coordinationMode.name,
    );
  }

  /// True when the sailor has stepped away from an ended voyage without filing it.
  ///
  /// Purely a navigation state: the session, the journal, the archived copy and
  /// relay recovery are all untouched. It exists because the voyage-ended screen
  /// replaced the entire app and its only exit filed the voyage, which stops this
  /// phone waiting for other sailors' final events — so a sailor who ended up
  /// there by accident had to choose between staying stuck and giving something
  /// up (#207). Two testers hit that within half an hour.
  ///
  /// Derived rather than stored so it cannot outlive the voyage it refers to: a new
  /// voyage clears `voyageEnded`, and the flag with it.
  bool get endedVoyageSetAside => _endedVoyageSetAside && voyageEnded;

  /// Steps away from an ended voyage, keeping it and all of its data intact.
  void setEndedVoyageAside() {
    if (!voyageEnded || _endedVoyageSetAside) return;
    _endedVoyageSetAside = true;
    notifyListeners();
  }

  /// Re-opens an ended voyage the sailor stepped away from.
  void reopenEndedVoyage() {
    if (!_endedVoyageSetAside) return;
    _endedVoyageSetAside = false;
    notifyListeners();
  }

  bool get voyageStarted => _lifecycle.started;
  DateTime? get voyageStartedAt => _lifecycle.startedAt;
  bool get isLocalVoyageSkipper => _session?.role == VoyageRole.skipper;
  VoyagePhase get voyagePhase => voyageEnded
      ? VoyagePhase.ended
      : voyageStarted
      ? VoyagePhase.started
      : VoyagePhase.open;

  VoyageRouteState get authoritativeRouteState => _routeState;
  ImportedRoute? get authoritativeRoute => _routeState.route;

  /// The reconciled live presence most recently observed, keyed by sailor.
  List<LiveSailorPresence> get livePresence => List.unmodifiable(_livePresence);

  /// The one reconciled live model. The sailor count, the roster, the main map
  /// and the mini-map all derive from this, so no two of them can disagree about
  /// whether a sailor is present or where they are (#132).
  VoyageLiveView get liveView => VoyageLiveView.reconcile(
    participants: _participantsFromEvents(),
    presence: _livePresence,
    positionChannelUnavailable: _positionChannelUnavailable,
  );

  /// Counts full journal-to-membership projections in tests.
  ///
  /// A live position can move every second while a voyage lasts for hours. The
  /// position itself is reconciled cheaply by [VoyageLiveView]; it must not make
  /// [VoyageMembershipReducer] walk the complete journal again unless an input
  /// that can change membership has actually changed (#165).
  @visibleForTesting
  int get debugMembershipProjectionCount => _membershipProjectionCount;

  List<VoyageParticipant> get participants => liveView.participants;

  /// Whether this phone can receive live positions at all.
  ///
  /// Exposed so one surface can reconcile it with the event batch's own status
  /// instead of two cards contradicting each other (#174).
  bool get positionChannelUnavailable => _positionChannelUnavailable;

  List<VoyageParticipant> _participantsFromEvents() {
    final cached = _membershipParticipantsCache;
    if (cached != null) return cached;
    final activeSession = _session;
    if (activeSession == null) return const [];
    _membershipProjectionCount += 1;
    final participants = const VoyageMembershipReducer().fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      now: _clock(),
      localSailorId: activeSession.localSailorId,
      localDisplayName: activeSession.displayName,
      localRole: activeSession.role,
      localJoinedAt: activeSession.joinedAt,
      localVesselStyle: activeSession.vesselStyle,
      localSailorColor: activeSession.sailorColor,
      localSailorSymbol: activeSession.sailorSymbol,
      voyageStartedAt: voyageStartedAt,
      voyageEndedAt: _voyageEndedAt,
      transportByEventId: _transportByEventId,
      livePresence: _livePresence,
      presenceRoster: _presenceRoster,
    );
    _membershipParticipantsCache = participants;
    return participants;
  }

  /// Records what the live-presence channels can currently see.
  ///
  /// This is how a join reaches the roster and the map without waiting for the
  /// bulk event batch: presence is a separate request with no cursor, so a
  /// wedged or backed-off journal sync cannot hide a reachable participant.
  /// The durable journal stays authoritative — a sailor who has left is never
  /// resurrected by presence.
  ///
  /// [roster] is the relay's own membership list, which unlike [presence] still
  /// names the sailors who have left. It is what keeps a departed sailor's roster
  /// record for the rest of the voyage (#144); it never adds anybody to the live
  /// count, because a departed sailor is not counted anywhere.
  void observeLivePresence(
    Iterable<LiveSailorPresence> presence, {
    Iterable<PresenceRosterMember> roster = const [],
    bool positionChannelUnavailable = false,
  }) {
    final next = presence.toList(growable: false);
    final nextRoster = roster.toList(growable: false);
    if (_isSamePresence(_livePresence, next) &&
        _isSameRoster(_presenceRoster, nextRoster) &&
        positionChannelUnavailable == _positionChannelUnavailable) {
      return;
    }
    if (!_hasSameMembershipInputs(_livePresence, next) ||
        !_isSameRoster(_presenceRoster, nextRoster)) {
      _invalidateMembershipProjection();
    }
    _livePresence = next;
    _presenceRoster = nextRoster;
    _positionChannelUnavailable = positionChannelUnavailable;
    notifyListeners();
  }

  /// A departure that arrives on the roster alone still has to reach the UI, so
  /// the no-churn check covers the roster as well as the positions.
  static bool _isSameRoster(
    List<PresenceRosterMember> current,
    List<PresenceRosterMember> next,
  ) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index += 1) {
      final left = current[index];
      final right = next[index];
      if (left.sailorId != right.sailorId ||
          left.displayName != right.displayName ||
          left.role != right.role ||
          left.joinedAt != right.joinedAt ||
          left.left != right.left ||
          left.leftAt != right.leftAt) {
        return false;
      }
    }
    return true;
  }

  static bool _isSamePresence(
    List<LiveSailorPresence> current,
    List<LiveSailorPresence> next,
  ) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index += 1) {
      final left = current[index];
      final right = next[index];
      if (left.sailorId != right.sailorId ||
          left.freshness != right.freshness ||
          left.displayName != right.displayName ||
          left.role != right.role ||
          !setEquals(left.sources, right.sources) ||
          left.location?.sample.recordedAt !=
              right.location?.sample.recordedAt) {
        return false;
      }
    }
    return true;
  }

  /// Ignores coordinate-only movement while retaining every presence field
  /// that can change the membership projection. The current coordinates still
  /// flow through [VoyageLiveView.reconcile] on every update.
  static bool _hasSameMembershipInputs(
    List<LiveSailorPresence> current,
    List<LiveSailorPresence> next,
  ) {
    if (current.length != next.length) return false;
    final currentById = {
      for (final presence in current) presence.sailorId: presence,
    };
    for (final right in next) {
      final left = currentById[right.sailorId];
      if (left == null ||
          left.displayName != right.displayName ||
          left.role != right.role ||
          left.freshness != right.freshness ||
          !setEquals(left.sources, right.sources) ||
          left.isLocal != right.isLocal ||
          left.knownSince != right.knownSince ||
          left.vesselStyle != right.vesselStyle ||
          left.sailorSymbol != right.sailorSymbol ||
          left.sailorColor != right.sailorColor ||
          (left.contactAt == null) != (right.contactAt == null)) {
        return false;
      }
    }
    return true;
  }

  List<VoyageParticipant> get liveParticipants => liveView.liveParticipants;

  VoyageParticipant? participantFor(String sailorId) => participants
      .where((participant) => participant.sailorId == sailorId)
      .firstOrNull;

  void noteTransportObservation(
    String eventId,
    VoyageTransportEvidence evidence,
  ) {
    if (evidence == VoyageTransportEvidence.localDevice ||
        evidence == VoyageTransportEvidence.journal) {
      return;
    }
    final values = _transportByEventId.putIfAbsent(eventId, () => {});
    if (values.add(evidence)) {
      _invalidateMembershipProjection();
      notifyListeners();
    }
  }

  void refreshMembershipFreshness() {
    _invalidateMembershipProjection();
    notifyListeners();
  }

  void _invalidateMembershipProjection() {
    _membershipParticipantsCache = null;
  }

  /// Whether the voyage has ended, by the later of its end and reopen events.
  ///
  /// Not `any(voyageEnded)` any more. The journal is append-only, so undoing an end
  /// means a later [VoyageEventType.voyageReopened] rather than removing anything
  /// (#206, #207) — the same shape [voyagePaused] already uses.
  bool get voyageEnded =>
      _latestOf(const {
        VoyageEventType.voyageEnded,
        VoyageEventType.voyageReopened,
      })?.type ==
      VoyageEventType.voyageEnded;

  /// Who ended the voyage, when it has ended.
  ///
  /// A tester whose voyage was ended by the skipper read it as a crash: "You can see
  /// that the voyage has ended but not super obvious unless you are looking for
  /// it... Otherwise looks like the app just crashes?" (#283). An unexplained stop
  /// is the worst ambiguity a safety app can offer, because the sailor cannot tell
  /// whether the group can still see them.
  ///
  /// Resolved from the journal rather than from a live callback, so it is just as
  /// available to a phone that was offline when it happened, or that has restarted
  /// since. `deviceId` is the author's sailor id - `_record` sets it from the
  /// session's `localSailorId` - so the roster can name them.
  ({String sailorId, String? displayName, bool isLocalSailor})?
  get voyageEndedBy {
    if (!voyageEnded) return null;
    final event = _latestOf(const {VoyageEventType.voyageEnded});
    if (event == null) return null;
    final sailorId = event.deviceId;
    return (
      sailorId: sailorId,
      displayName: participantFor(sailorId)?.displayName,
      isLocalSailor: sailorId == _session?.localSailorId,
    );
  }

  /// The newest event of any of [types], or null when the journal holds none.
  ///
  /// Local clocks can produce equal timestamps for back-to-back actions; events
  /// are ordered by the durable store, so the later item wins ties.
  VoyageEvent? _latestOf(Set<VoyageEventType> types) {
    VoyageEvent? latest;
    for (final event in _events) {
      if (!types.contains(event.type)) continue;
      if (latest == null || !event.createdAt.isBefore(latest.createdAt)) {
        latest = event;
      }
    }
    return latest;
  }

  /// A lead-owned group coordination pause. It deliberately does not suppress
  /// GPS evidence: sailors can still be found while the group is stopped.
  bool get voyagePaused {
    if (!voyageStarted) return false;
    VoyageEvent? latest;
    for (final event in _events) {
      if (event.type != VoyageEventType.voyagePaused &&
          event.type != VoyageEventType.voyageResumed) {
        continue;
      }
      // Local clocks can produce equal timestamps for back-to-back actions;
      // events are ordered by the durable store, so the later item wins ties.
      if (latest == null || !event.createdAt.isBefore(latest.createdAt)) {
        latest = event;
      }
    }
    return latest?.type == VoyageEventType.voyagePaused;
  }

  int get pendingEventCount =>
      _events.where((event) => !event.acknowledged).length;

  /// ICE shares other sailors have sent to me: either an explicit
  /// whole-group share, or an auto-share addressed to me while I hold the
  /// lead role. Purged from storage at voyage-end unless marked used.
  List<IceShare> get receivedIceShares {
    final localId = _session?.localSailorId;
    if (localId == null) return const [];
    return _events
        .where(
          (event) =>
              event.type == VoyageEventType.iceInfoShared &&
              event.deviceId != localId &&
              _isAddressedToMe(event, localId),
        )
        .map(_iceShareFromEvent)
        .toList(growable: false);
  }

  /// ICE shares I have sent, with read-receipt state if a recipient has
  /// opened one.
  List<IceShare> get sentIceShares {
    final localId = _session?.localSailorId;
    if (localId == null) return const [];
    return _events
        .where(
          (event) =>
              event.type == VoyageEventType.iceInfoShared &&
              event.deviceId == localId,
        )
        .map((event) {
          final share = _iceShareFromEvent(event);
          final view = _events
              .where(
                (candidate) =>
                    candidate.type == VoyageEventType.iceInfoViewed &&
                    candidate.payload['sharedEventId'] == event.id,
              )
              .fold<VoyageEvent?>(
                null,
                (earliest, candidate) =>
                    earliest == null ||
                        candidate.createdAt.isBefore(earliest.createdAt)
                    ? candidate
                    : earliest,
              );
          if (view == null) return share;
          return IceShare(
            eventId: share.eventId,
            sharedBySailorId: share.sharedBySailorId,
            sharedByDisplayName: share.sharedByDisplayName,
            contactName: share.contactName,
            contactPhone: share.contactPhone,
            medicalNotes: share.medicalNotes,
            sharedAt: share.sharedAt,
            toWholeGroup: share.toWholeGroup,
            viewedAt: view.createdAt,
            viewedBySailorId: view.deviceId,
          );
        })
        .toList(growable: false);
  }

  bool _isAddressedToMe(VoyageEvent event, String localId) {
    final recipients = event.payload['recipientSailorIds'];
    if (recipients is! List) return true;
    return recipients.contains(localId);
  }

  IceShare _iceShareFromEvent(VoyageEvent event) => IceShare(
    eventId: event.id,
    sharedBySailorId: event.deviceId,
    sharedByDisplayName: event.payload['sharedByDisplayName'] as String? ?? '',
    contactName: event.payload['contactName'] as String? ?? '',
    contactPhone: event.payload['contactPhone'] as String? ?? '',
    medicalNotes: event.payload['medicalNotes'] as String? ?? '',
    sharedAt: event.createdAt,
    toWholeGroup: event.payload['recipientSailorIds'] == null,
  );

  /// The message sent to invite someone onto a voyage.
  ///
  /// Deliberately carries **no URL** (#51). It used to lead with
  /// `voyageInvitationUrl`, which builds an `https://tideandseek.invalid/...`
  /// address - a reserved TLD (RFC 2606) that can never resolve, on a build
  /// with no Associated Domain to claim it and no custom URL scheme either. So
  /// every invitation opened with the one thing in it that fails when tapped,
  /// and offered the six digits that work underneath.
  ///
  /// The code comes first now because it is what the recipient will actually
  /// type. The link returns the day there is a real domain serving an
  /// `apple-app-site-association` file - that is #40, and one domain answers
  /// both.
  String get voyageCodeShareText {
    final activeSession = _requireSession();
    final name = activeSession.voyageName;
    final group = name == null ? 'my Tide and Seek group' : '"$name"';
    final invite = joinInviteText(
      activeSession.voyageCode,
      activeSession.joinToken,
    );
    return 'Join $group in Tide and Seek.\n\n'
        'Voyage code: ${activeSession.voyageCode}\n\n'
        'Or paste this private invite into the app: $invite';
  }

  Future<void> initialize() async {
    _nearbyCapabilities = await _nearbyBridge.capabilities();
    _session = await _sessionStore.load();
    final activeSession = _session;
    if (activeSession != null) {
      _replaceEvents(await _eventStore.eventsForVoyage(activeSession.voyageId));
      _rebuildLifecycle();
      await _archiveCurrentVoyageIfComplete();
      await _expireEndedVoyageIfDue();
      await _purgeUnusedIceSharesIfEnded();
    }
    _invalidateMembershipProjection();
    notifyListeners();
  }

  Future<void> reloadEvents() async {
    final activeSession = _session;
    if (activeSession == null) {
      return;
    }
    _replaceEvents(await _eventStore.eventsForVoyage(activeSession.voyageId));
    _rebuildLifecycle();
    await _archiveCurrentVoyageIfComplete();
    await _expireEndedVoyageIfDue();
    await _purgeUnusedIceSharesIfEnded();
    notifyListeners();
  }

  /// Projects an event that another controller has already stored.
  ///
  /// Live voyage position and hazard events are written by
  /// [SituationalAwarenessController]. Reloading and JSON-decoding the complete
  /// SQLite journal after every one made the cost of a location update grow
  /// with voyage duration (#165). This accepts that one immutable event into the
  /// in-memory journal instead. A cold start and explicit recovery still use
  /// [reloadEvents] and therefore remain authoritative from disk.
  bool ingestStoredEvent(VoyageEvent event) =>
      _acceptStoredEvent(event, notify: true);

  bool _acceptStoredEvent(VoyageEvent event, {required bool notify}) {
    final activeSession = _session;
    if (activeSession == null ||
        event.voyageId != activeSession.voyageId ||
        _eventIds.contains(event.id) ||
        !VoyageEventAuthenticator.verify(event, activeSession.inviteSecret)) {
      return false;
    }

    if (_events.isEmpty ||
        VoyageLifecycleReducer.compareEvents(_events.last, event) <= 0) {
      _events.add(event);
    } else {
      var lower = 0;
      var upper = _events.length;
      while (lower < upper) {
        final middle = lower + ((upper - lower) >> 1);
        if (VoyageLifecycleReducer.compareEvents(_events[middle], event) <= 0) {
          lower = middle + 1;
        } else {
          upper = middle;
        }
      }
      _events.insert(lower, event);
    }
    _eventIds.add(event.id);
    // Position-only movement is reconciled through live presence and does not
    // change membership identity. The 15-second freshness refresh performs a
    // bounded-rate projection for last-seen state.
    if (event.type != VoyageEventType.sailorLocationUpdated) {
      _invalidateMembershipProjection();
    }
    if (_affectsLifecycleOrRoute(event.type)) {
      _rebuildLifecycle();
    }
    if (notify) notifyListeners();
    return true;
  }

  static bool _affectsLifecycleOrRoute(VoyageEventType type) => switch (type) {
    VoyageEventType.voyageCreated ||
    VoyageEventType.voyageStarted ||
    VoyageEventType.voyagePaused ||
    VoyageEventType.voyageResumed ||
    VoyageEventType.voyageEnded ||
    VoyageEventType.voyageReopened ||
    VoyageEventType.routeRevisionChunk ||
    VoyageEventType.routeRevisionPublished ||
    VoyageEventType.routeCleared => true,
    _ => false,
  };

  Future<void> createVoyage(
    String displayName, {
    VesselIconStyle vesselStyle = vesselIconStyleDefault,
    SailorSymbol sailorSymbol = sailorSymbolDefault,
    SailorColor sailorColor = sailorColorDefault,
    VoyageCoordinationMode coordinationMode = VoyageCoordinationMode.crew,
    String? voyageName,
  }) async {
    await _run(() async {
      await _createVoyage(
        displayName: displayName,
        vesselStyle: vesselStyle,
        sailorSymbol: sailorSymbol,
        sailorColor: sailorColor,
        coordinationMode: coordinationMode,
        voyageName: voyageName,
      );
    });
  }

  Future<void> createSimulationVoyage({
    int sailorCount = VoyageSession.defaultSimulationSailorCount,
    VesselIconStyle vesselStyle = vesselIconStyleDefault,
    SailorSymbol sailorSymbol = sailorSymbolDefault,
    SailorColor sailorColor = sailorColorDefault,
  }) async {
    await _run(() async {
      await _createVoyage(
        displayName: 'Demo Lead',
        isSimulation: true,
        simulationSailorCount: _validatedSimulationSailorCount(sailorCount),
        vesselStyle: vesselStyle,
        sailorSymbol: sailorSymbol,
        sailorColor: sailorColor,
      );
    });
  }

  Future<void> restartSimulationVoyage({int? sailorCount}) async {
    await _run(() async {
      final activeSession = _requireSession();
      if (!activeSession.isSimulation) {
        throw const FormatException(
          'Only a simulated voyage can be restarted.',
        );
      }
      await _eventStore.deleteVoyage(activeSession.voyageId);
      await _sessionStore.clear();
      _session = null;
      _replaceEvents(const []);
      _invalidateMembershipProjection();
      await _createVoyage(
        displayName: 'Demo Lead',
        isSimulation: true,
        simulationSailorCount: _validatedSimulationSailorCount(
          sailorCount ?? activeSession.simulationSailorCount,
        ),
        vesselStyle: activeSession.vesselStyle,
        sailorSymbol: activeSession.sailorSymbol,
        sailorColor: activeSession.sailorColor,
        voyageName: activeSession.voyageName,
      );
    });
  }

  /// Publishes the skipper's short code once the optional internet relay is
  /// reachable. The code only resolves the bootstrap credentials; subsequent
  /// event traffic continues to use the authenticated relay protocols.
  Future<void> publishVoyageCode() async {
    final activeSession = _requireSession();
    if (activeSession.isSimulation ||
        activeSession.coordinationMode == VoyageCoordinationMode.solo ||
        activeSession.role != VoyageRole.skipper) {
      return;
    }
    var session = activeSession;
    for (var attempt = 0; attempt < 8; attempt++) {
      try {
        await _voyageCodeDirectory.register(session);
        return;
      } on VoyageCodeDirectoryException catch (error) {
        if (!error.codeConflict || attempt == 7) rethrow;
        session = session.copyWith(voyageCode: _generateCode());
        _session = session;
        await _sessionStore.save(session);
        notifyListeners();
      }
    }
  }

  /// Joins using credentials carried in a scanned invitation, with **no network
  /// call at all** (#279).
  ///
  /// Every other join path ends in `VoyageCodeDirectory.resolve`, whose only job is
  /// turning a six-digit code into exactly the fields a [VoyageJoinPayload] already
  /// holds. So this is the same join with the lookup removed, and it is what lets
  /// a group with no signal form a voyage - the situation the product is for.
  ///
  /// Deliberately shares [_joinWithCredentials] with [joinVoyage] rather than
  /// duplicating it: an offline join that diverged from the online one would be a
  /// second definition of what being in a voyage means, and the two would drift.
  Future<void> joinVoyageFromInvitation(
    VoyageJoinPayload invitation,
    String displayName, {
    VesselIconStyle vesselStyle = vesselIconStyleDefault,
    SailorSymbol sailorSymbol = sailorSymbolDefault,
    SailorColor sailorColor = sailorColorDefault,
  }) async {
    await _run(
      () => _joinWithCredentials(
        voyageId: invitation.voyageId,
        voyageCode: invitation.voyageCode,
        inviteSecret: invitation.inviteSecret,
        joinToken: invitation.joinToken,
        displayName: displayName,
        vesselStyle: vesselStyle,
        sailorSymbol: sailorSymbol,
        sailorColor: sailorColor,
      ),
    );
  }

  Future<void> joinVoyage(
    String voyageCode,
    String displayName, {
    VesselIconStyle vesselStyle = vesselIconStyleDefault,
    SailorSymbol sailorSymbol = sailorSymbolDefault,
    SailorColor sailorColor = sailorColorDefault,
    String? joinToken,
  }) async {
    await _run(() async {
      final normalisedCode = voyageCode.trim();
      if (!RegExp(r'^\d{6}$').hasMatch(normalisedCode)) {
        throw const FormatException('Enter a valid six-digit voyage code.');
      }
      final credentials = await _voyageCodeDirectory.resolve(
        normalisedCode,
        joinToken: joinToken,
      );
      await _joinWithCredentials(
        voyageId: credentials.voyageId,
        voyageCode: credentials.voyageCode,
        inviteSecret: credentials.inviteSecret,
        joinToken: credentials.joinToken,
        displayName: displayName,
        vesselStyle: vesselStyle,
        sailorSymbol: sailorSymbol,
        sailorColor: sailorColor,
      );
    });
  }

  /// The join itself, once credentials exist however they were obtained.
  Future<void> _joinWithCredentials({
    required String voyageId,
    required String voyageCode,
    required String inviteSecret,
    required String joinToken,
    required String displayName,
    required VesselIconStyle vesselStyle,
    required SailorSymbol sailorSymbol,
    required SailorColor sailorColor,
  }) async {
    {
      // Deep links can arrive while any screen is open. Never let a join path
      // replace a live session silently: that would discard this phone's role,
      // journal and queued safety events. An ended voyage may be filed exactly as
      // createVoyage already does before the replacement is installed.
      if (_session != null) {
        if (!voyageEnded) {
          throw const FormatException(
            'Finish or leave your current voyage before joining another.',
          );
        }
        await _archiveCurrentVoyageIfComplete();
        await _removeVoyageData();
      }
      final credentials = VoyageCodeCredentials(
        voyageId: voyageId,
        voyageCode: voyageCode,
        inviteSecret: inviteSecret,
        joinToken: joinToken,
      );
      final now = _clock();
      final session = VoyageSession(
        voyageId: credentials.voyageId,
        voyageCode: credentials.voyageCode,
        inviteSecret: credentials.inviteSecret,
        joinToken: credentials.joinToken,
        localSailorId: _localSailorIdForVoyage(credentials.voyageId),
        displayName: _normaliseName(displayName),
        role: VoyageRole.sailor,
        joinedAt: now,
        vesselStyle: vesselStyle,
        sailorSymbol: sailorSymbol,
        sailorColor: sailorColor,
      );
      _session = session;
      await _sessionStore.save(session);
      _replaceEvents(await _eventStore.eventsForVoyage(session.voyageId));
      _invalidateMembershipProjection();
      _rebuildLifecycle();
      await _record(
        type: VoyageEventType.sailorJoined,
        payload: {
          'displayName': session.displayName,
          'role': session.role.wireName,
          'vesselStyle': session.sailorSymbol.wireValue(session.vesselStyle),
          'sailorColor': session.sailorColor.name,
        },
      );
    }
  }

  Future<void> setRole(VoyageRole role) async {
    await _run(() async {
      final activeSession = _requireSession();
      final updated = activeSession.copyWith(role: role);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: VoyageEventType.roleChanged,
        payload: {'role': role.wireName},
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Issue #128 part 1 - a skipper can ask a named sailor to be the Sweeper.
  //
  // Deliberately a request, not an assignment. Roles stay self-selected: the
  // target's acceptance records their own `roleChanged`, so the membership
  // reducer, the session's own role and every TEC surface keep exactly one
  // source of truth. These two events carry only who was asked and what they
  // answered, which is what lets the skipper see pending versus accepted instead
  // of believing the back is covered when nobody is watching it.
  // ---------------------------------------------------------------------------

  /// Every skipper-issued TEC request in this voyage, reconciled from the journal.
  SweeperRoleAssignmentState get sweeperRoleAssignments {
    final activeSession = _session;
    if (activeSession == null) return const SweeperRoleAssignmentState();
    return const SweeperRoleAssignmentReducer().fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      now: _clock(),
    );
  }

  /// The unanswered request addressed to this phone, if any.
  SweeperRoleAssignment? get pendingSweeperRoleRequestForLocalSailor {
    final localSailorId = _session?.localSailorId;
    if (localSailorId == null) return null;
    return sweeperRoleAssignments.pendingFor(localSailorId);
  }

  /// The sailor currently holding [VoyageRole.skipper] in the reconciled roster.
  ///
  /// Used to address a skipper-only event. Null when the skipper has left or is
  /// not yet known, in which case the caller must not send rather than
  /// broadcasting to the group.
  String? get skipperSailorId => liveParticipants
      .where((participant) => participant.role == VoyageRole.skipper)
      .map((participant) => participant.sailorId)
      .firstOrNull;

  /// True when a running voyage has nobody holding the lead role.
  ///
  /// A skipper who leaves takes the group's pace, the line the TEC is following
  /// and the route authority with them, and until #176 nothing said so: a tester
  /// left as skipper to see what would happen and the voyage carried on, with the
  /// remaining sailors untold and nobody offered the role.
  ///
  /// Only while the voyage is running. Before the start there is always a creator
  /// holding lead, and after the end there is nothing left to lead.
  bool get voyageHasNoSkipper =>
      voyageStarted && !voyageEnded && skipperSailorId == null;

  /// Asks [targetSailorId] to take the Sweeper role.
  ///
  /// [relayCanCarryRequest] is the negotiated `sweeper-role-assignment-v1`
  /// capability. When it is false nothing is recorded at all: a request that
  /// cannot leave this phone must not sit on the skipper's screen looking sent.
  Future<SweeperRoleRequestOutcome> requestSweeperRole({
    required String targetSailorId,
    required String targetDisplayName,
    bool relayCanCarryRequest = true,
  }) async {
    final activeSession = _session;
    if (activeSession == null || !isLocalVoyageSkipper) {
      return SweeperRoleRequestOutcome.notSkipper;
    }
    if (targetSailorId == activeSession.localSailorId) {
      return SweeperRoleRequestOutcome.invalidTarget;
    }
    final target = participantFor(targetSailorId);
    if (target == null || !target.isIncludedInLiveCount) {
      return SweeperRoleRequestOutcome.invalidTarget;
    }
    final acceptedSweeperSailorId =
        sweeperRoleAssignments.acceptedSweeperSailorId;
    if (target.role == VoyageRole.sweeper &&
        (acceptedSweeperSailorId == null ||
            acceptedSweeperSailorId == targetSailorId)) {
      return SweeperRoleRequestOutcome.alreadySweeper;
    }
    if (!relayCanCarryRequest) {
      return SweeperRoleRequestOutcome.relayUnsupported;
    }
    await _run(() async {
      await _record(
        type: VoyageEventType.sweeperRoleRequested,
        priority: EventPriority.important,
        // Outlives the reducer's ten-minute pending window so the answer and
        // the question are never orphaned from each other in the journal.
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: SweeperRoleAssignmentReducer.requestPayload(
          requestId: _idFactory(),
          skipperSailorId: activeSession.localSailorId,
          targetSailorId: targetSailorId,
          targetDisplayName: targetDisplayName,
        ),
      );
    });
    return _errorMessage == null
        ? SweeperRoleRequestOutcome.sent
        : SweeperRoleRequestOutcome.failed;
  }

  /// Answers the request addressed to this phone.
  ///
  /// Accepting records the answer **and** the local sailor's own
  /// [VoyageEventType.roleChanged], in that order, so a peer that reads only one
  /// of the two still converges: the role change alone is the existing
  /// self-selection, and the answer alone leaves the skipper's view honest.
  Future<bool> respondToSweeperRoleRequest({
    required String requestId,
    required bool accepted,
  }) async {
    final activeSession = _session;
    if (activeSession == null) return false;
    final pending = sweeperRoleAssignments.pendingFor(
      activeSession.localSailorId,
    );
    if (pending == null || pending.requestId != requestId) return false;
    await _run(() async {
      await _record(
        type: VoyageEventType.sweeperRoleResponded,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: SweeperRoleAssignmentReducer.responsePayload(
          requestId: requestId,
          targetSailorId: activeSession.localSailorId,
          accepted: accepted,
        ),
      );
      if (!accepted) return;
      final updated = activeSession.copyWith(role: VoyageRole.sweeper);
      _session = updated;
      await _sessionStore.save(updated);
      await _record(
        type: VoyageEventType.roleChanged,
        payload: {'role': VoyageRole.sweeper.name},
      );
    });
    return _errorMessage == null;
  }

  // ---------------------------------------------------------------------------
  // Issue #128 part 2 - a separated sailor's rejoin route, for the skipper only.
  // ---------------------------------------------------------------------------

  /// Raises a quick message into the voyage.
  ///
  /// [position] is where the sender is standing. It is relayed with the message
  /// because "Bill needs fuel" is not actionable without "1.2 miles back"
  /// (#151), and because a stopped sailor's own location events age out of the
  /// 30-minute retention band while the message itself lives for two hours.
  /// [senderDisplayName] comes from the session for the same reason
  /// `iceInfoShared` carries it: the recipient may not have this sailor in their
  /// roster yet.
  Future<void> sendQuickMessage(
    QuickMessage message, {
    Iterable<String> recipientSailorIds = const [],
    awareness_geo.GeoPoint? position,
  }) async {
    await _run(() async {
      final activeSession = _requireSession();
      final recipients = recipientSailorIds.toSet().toList(growable: false);
      await _record(
        type: VoyageEventType.statusMessage,
        priority: message.priority,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          'message': message.name,
          'label': message.label,
          'senderDisplayName': activeSession.displayName,
          if (position != null) 'position': position.toJson(),
          if (recipients.isNotEmpty) 'recipientSailorIds': recipients,
        },
      );
    });
  }

  /// Quick messages this phone should be presenting, most urgent first.
  ///
  /// Includes this sailor's own outstanding messages, so a sender can be shown
  /// that theirs was seen — the whole point of raising one. Callers separate the
  /// two on [ReceivedQuickMessage.raisedFromLocalSailor].
  List<ReceivedQuickMessage> get quickMessages {
    final activeSession = _session;
    if (activeSession == null) return const [];
    return const ReceivedQuickMessageReducer().fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      localSailorId: activeSession.localSailorId,
      now: _clock(),
      displayNames: {
        for (final participant in participants)
          participant.sailorId: participant.displayName,
      },
      departedSailorIds: participants
          .where((participant) => !participant.isIncludedInLiveCount)
          .map((participant) => participant.sailorId),
      voyageEnded: voyageEnded,
    );
  }

  /// Records that this sailor has seen [message], so its sender is told.
  ///
  /// A no-op when already recorded, the same guard [markIceInfoViewed] keeps: a
  /// second tap must not put a second acknowledgement into the journal.
  Future<void> acknowledgeQuickMessage(ReceivedQuickMessage message) async {
    final localId = _session?.localSailorId;
    if (localId == null || message.acknowledgedBy(localId)) return;
    await _run(() async {
      await _record(
        type: VoyageEventType.statusMessage,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          ...ReceivedQuickMessageReducer.acknowledgementPayload(
            message: message,
          ),
          'senderDisplayName': _requireSession().displayName,
        },
      );
    });
  }

  /// Shares ICE (in-case-of-emergency) info into the voyage. Pass an empty
  /// [recipientSailorIds] to share with the whole group (an explicit sailor
  /// action); pass the current skipper's sailor id to share with just them
  /// (the opt-in default-share-on-emergency setting). The caller resolves
  /// who "the skipper" currently is, the same way it already resolves
  /// emergency-alert recipients.
  Future<void> shareEmergencyInfo({
    required String contactName,
    required String contactPhone,
    required String medicalNotes,
    required Iterable<String> recipientSailorIds,
  }) async {
    await _run(() async {
      final activeSession = _requireSession();
      final recipients = recipientSailorIds.toSet().toList(growable: false);
      await _record(
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        expiresAt: _clock().add(const Duration(hours: 2)),
        payload: {
          'contactName': contactName,
          'contactPhone': contactPhone,
          'medicalNotes': medicalNotes,
          'sharedByDisplayName': activeSession.displayName,
          if (recipients.isNotEmpty) 'recipientSailorIds': recipients,
        },
      );
    });
  }

  /// Records that the local sailor has opened a share sent to them, so the
  /// original sharer can see it was seen. A no-op if already recorded.
  Future<void> markIceInfoViewed(String sharedEventId) async {
    final localId = _session?.localSailorId;
    if (localId == null) return;
    final alreadyViewed = _events.any(
      (event) =>
          event.type == VoyageEventType.iceInfoViewed &&
          event.deviceId == localId &&
          event.payload['sharedEventId'] == sharedEventId,
    );
    if (alreadyViewed) return;
    await _run(() async {
      await _record(
        type: VoyageEventType.iceInfoViewed,
        payload: {'sharedEventId': sharedEventId},
      );
    });
  }

  /// Marks a received ICE share as acted on (called or texted the
  /// contact), exempting it from the voyage-end purge below.
  void markIceShareUsed(String eventId) {
    if (_usedIceShareEventIds.add(eventId)) {
      notifyListeners();
    }
  }

  /// Shares the local sailor's **own** phone number into the voyage (issue #188).
  ///
  /// Nothing here touches ICE. [phoneNumber] is the sailor's own number, and
  /// [recipients] is resolved by [SailorContactRecipients] — the skipper and TEC
  /// for an ordinary sailor, the voyage for whoever holds a coordination role,
  /// because a contact for the role is useless addressed to the other
  /// role-holder.
  ///
  /// Returns false without recording anything when the number is not dialable
  /// or there is nobody to address it to, so the caller can say so rather than
  /// letting a sailor believe a number went out.
  Future<bool> shareOwnContactNumber({
    required String phoneNumber,
    required SailorContactRecipients recipients,
  }) async {
    final activeSession = _session;
    final normalised = SailorContactShare.normalisePhoneNumber(phoneNumber);
    if (activeSession == null || normalised == null || recipients.isEmpty) {
      return false;
    }
    await _run(() async {
      final share = SailorContactShare(
        // Filled in by the journal; the payload never carries an event id.
        eventId: '',
        sailorId: activeSession.localSailorId,
        displayName: activeSession.displayName,
        phoneNumber: normalised,
        sharedAt: _clock(),
        sharedByRole: activeSession.role,
        toVoyageGroup: recipients.toVoyageGroup,
      );
      await _record(
        type: VoyageEventType.sailorContactShared,
        // Important rather than critical: this is a contact detail, not an
        // alert. The emergency alert is the critical event, and it does not
        // depend on a number existing.
        priority: EventPriority.important,
        // The same retention band as an ICE share, and the voyage-end purge
        // normally gets there first.
        expiresAt: _clock().add(sailorContactShareLifetime),
        payload: SailorContactShareReducer.payload(
          share: share,
          recipients: recipients,
        ),
      );
    });
    return _errorMessage == null;
  }

  /// Numbers other sailors have shared with the local sailor, keyed by sailor id.
  ///
  /// Empty once the voyage has ended, and never includes the local sailor's own.
  /// This is the only source the dial controls read: nothing derives a number
  /// from the roster, a location event or a presence row.
  Map<String, SailorContactShare> get receivedSailorContacts {
    final activeSession = _session;
    if (activeSession == null) return const {};
    return const SailorContactShareReducer().fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
      localSailorId: activeSession.localSailorId,
      now: _clock(),
      departedSailorIds: participants
          .where((participant) => !participant.isIncludedInLiveCount)
          .map((participant) => participant.sailorId),
      voyageEnded: voyageEnded,
    );
  }

  /// Whether this sailor's own number is already in the journal for this voyage, so
  /// the share control can say "shared" instead of recording it twice.
  bool get hasSharedOwnContactNumber {
    final localId = _session?.localSailorId;
    if (localId == null) return false;
    return _events.any(
      (event) =>
          event.type == VoyageEventType.sailorContactShared &&
          event.deviceId == localId,
    );
  }

  /// Marks a received number as dialled, exempting it from the voyage-end purge
  /// for the same reason a used ICE share is exempt: a sailor who has just phoned
  /// somebody may need to phone them again.
  void markSailorContactUsed(String eventId) => markIceShareUsed(eventId);

  Future<void> pauseVoyage() => _setVoyagePaused(true);

  Future<void> resumeVoyage() => _setVoyagePaused(false);

  Future<void> startVoyage() async {
    if (voyageStarted || voyageEnded) return;
    await _run(() async {
      final session = _requireSession();
      if (session.role != VoyageRole.skipper) {
        throw const FormatException(
          'Only the voyage skipper can start the voyage.',
        );
      }
      await _record(
        type: VoyageEventType.voyageStarted,
        priority: EventPriority.important,
        payload: {
          'skipperSailorId': session.localSailorId,
          'skipperDisplayName': session.displayName,
        },
      );
    });
  }

  Future<void> publishRoute(ImportedRoute route) async {
    await _run(() async {
      final session = _requireSession();
      if (!isLocalVoyageSkipper) {
        throw const FormatException(
          'Only the voyage skipper can change the group route.',
        );
      }
      final encoded = const VoyageRouteEncoder().encode(route);
      final revisionId = _idFactory();
      final revisionNumber = _routeState.revisionNumber + 1;
      for (var index = 0; index < encoded.chunks.length; index += 1) {
        await _record(
          type: VoyageEventType.routeRevisionChunk,
          priority: EventPriority.important,
          payload: {
            'revisionId': revisionId,
            'revisionNumber': revisionNumber,
            'skipperSailorId': session.localSailorId,
            'index': index,
            'data': encoded.chunks[index],
          },
        );
      }
      await _record(
        type: VoyageEventType.routeRevisionPublished,
        priority: EventPriority.important,
        payload: {
          'revisionId': revisionId,
          'revisionNumber': revisionNumber,
          'skipperSailorId': session.localSailorId,
          'chunkCount': encoded.chunks.length,
          'compressedBytes': encoded.compressedBytes,
          'sha256': encoded.sha256Digest,
          'routeName': route.name,
        },
      );
    });
  }

  Future<void> clearRoute() async {
    await _run(() async {
      final session = _requireSession();
      if (!isLocalVoyageSkipper) {
        throw const FormatException(
          'Only the voyage skipper can clear the group route.',
        );
      }
      await _record(
        type: VoyageEventType.routeCleared,
        priority: EventPriority.important,
        payload: {
          'revisionId': _idFactory(),
          'revisionNumber': _routeState.revisionNumber + 1,
          'skipperSailorId': session.localSailorId,
        },
      );
    });
  }

  Future<void> _setVoyagePaused(bool paused) async {
    if (voyagePaused == paused) return;
    await _run(() async {
      final session = _requireSession();
      if (!voyageStarted) {
        throw const FormatException('Start the voyage before pausing it.');
      }
      if (session.role != VoyageRole.skipper) {
        throw const FormatException(
          'Only the voyage skipper can pause the group.',
        );
      }
      await _record(
        type: paused
            ? VoyageEventType.voyagePaused
            : VoyageEventType.voyageResumed,
        priority: EventPriority.important,
        payload: const {},
      );
    });
  }

  Future<void> endVoyage() async {
    if (voyageEnded) return;
    await _run(() async {
      _requireSession();
      if (!isLocalVoyageSkipper) {
        throw const FormatException(
          'Only the voyage skipper can end the voyage.',
        );
      }
      await _record(
        type: VoyageEventType.voyageEnded,
        priority: EventPriority.important,
        payload: const {},
      );
      await _archiveCurrentVoyageIfComplete();
      await _purgeUnusedIceSharesIfEnded();
      await _expireEndedVoyageIfDue();
    });
  }

  /// Why a skipper could not reopen an ended voyage, or [VoyageReopenOutcome.reopened].
  ///
  /// The recovery window is the same 24 hours the ended voyage survives for
  /// anyway: past it the journal and session are gone, so there is nothing left
  /// to reopen.
  ///
  /// [relayCanCarryReopen] is the negotiated `voyage-reopen-v1` capability. When it
  /// is false nothing is recorded at all — a reopen that cannot leave this phone
  /// would put the skipper back on a map while every other sailor still sees a
  /// finished voyage, which is worse than being told it is unavailable.
  Future<VoyageReopenOutcome> reopenVoyage({
    bool relayCanCarryReopen = true,
  }) async {
    final activeSession = _session;
    if (activeSession == null || !voyageEnded) {
      return VoyageReopenOutcome.notEnded;
    }
    if (activeSession.role != VoyageRole.skipper) {
      return VoyageReopenOutcome.notSkipper;
    }
    final endedAt = _voyageEndedAt;
    if (endedAt != null &&
        _clock().difference(endedAt) >= endedVoyageRecoveryWindow) {
      return VoyageReopenOutcome.windowExpired;
    }
    if (!relayCanCarryReopen) return VoyageReopenOutcome.relayUnsupported;
    await _run(() async {
      await _record(
        type: VoyageEventType.voyageReopened,
        priority: EventPriority.important,
        payload: {'reopenedBy': activeSession.localSailorId},
      );
      // The end scheduled the voyage's own deletion. Reopening has to call this
      // off, and `_voyageEndedAt` is now null, so it cancels rather than reschedules.
      await _expireEndedVoyageIfDue();
    });
    return _errorMessage == null
        ? VoyageReopenOutcome.reopened
        : VoyageReopenOutcome.failed;
  }

  Future<void> clearEndedVoyage() async {
    if (!voyageEnded) return;
    await _run(() async {
      await _archiveCurrentVoyageIfComplete();
      await _removeVoyageData();
    });
  }

  Future<void> leaveVoyage({
    Future<void> Function(VoyageEvent departure)? publishDeparture,
  }) async {
    await _run(() async {
      final session = _requireSession();
      final departure = await _record(
        type: VoyageEventType.sailorLeft,
        priority: EventPriority.important,
        expiresAt: _clock().add(const Duration(hours: 24)),
        payload: {
          'sailorId': session.localSailorId,
          'displayName': session.displayName,
          'reason': 'left',
        },
      );
      if (publishDeparture != null) {
        try {
          await publishDeparture(departure);
        } on Object catch (error, stackTrace) {
          if (kDebugMode) {
            debugPrint('Departure remains queued locally: $error\n$stackTrace');
          }
        }
      }
      await _archiveCurrentVoyageIfComplete(force: true);
      await _removeVoyageData(deleteEvents: false);
    });
  }

  void clearError() {
    _errorMessage = null;
    _errorIsRetryable = false;
    notifyListeners();
  }

  Future<VoyageEvent> _record({
    required VoyageEventType type,
    required Map<String, Object?> payload,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
  }) async {
    final activeSession = _requireSession();
    final now = _clock();
    final id = _idFactory();
    final unsignedEvent = VoyageEvent(
      id: id,
      voyageId: activeSession.voyageId,
      deviceId: activeSession.localSailorId,
      type: type,
      priority: priority,
      createdAt: now,
      expiresAt: expiresAt,
      payload: payload,
      signature: '',
    );
    final event = VoyageEvent(
      id: unsignedEvent.id,
      voyageId: unsignedEvent.voyageId,
      deviceId: unsignedEvent.deviceId,
      type: unsignedEvent.type,
      priority: unsignedEvent.priority,
      createdAt: unsignedEvent.createdAt,
      expiresAt: unsignedEvent.expiresAt,
      payload: unsignedEvent.payload,
      signature: VoyageEventAuthenticator.sign(
        unsignedEvent,
        activeSession.inviteSecret,
      ),
    );
    await _eventStore.append(event);
    _acceptStoredEvent(event, notify: false);
    return event;
  }

  Future<void> _createVoyage({
    required String displayName,
    bool isSimulation = false,
    int simulationSailorCount = VoyageSession.defaultSimulationSailorCount,
    VesselIconStyle vesselStyle = vesselIconStyleDefault,
    SailorSymbol sailorSymbol = sailorSymbolDefault,
    SailorColor sailorColor = sailorColorDefault,
    VoyageCoordinationMode coordinationMode = VoyageCoordinationMode.crew,
    String? voyageName,
  }) async {
    // The home screen deliberately remains available while an ended voyage is
    // set aside (#207). Creating its replacement must file that completed voyage
    // and reset the active journal first; otherwise its `voyageEnded` event stays
    // in memory and makes the new session look ended as soon as it is created.
    //
    // Validate user input before giving up the previous voyage's recovery window,
    // and never let this path overwrite a voyage which has not ended.
    final normalisedDisplayName = _normaliseName(displayName);
    if (_session != null) {
      if (!voyageEnded) {
        throw const FormatException(
          'Finish or leave your current voyage before creating another.',
        );
      }
      await _archiveCurrentVoyageIfComplete();
      await _removeVoyageData();
    }

    final now = _clock();
    final normalisedVoyageName = voyageName?.trim();
    final voyageId = _idFactory();
    final session = VoyageSession(
      voyageId: voyageId,
      voyageCode: _generateCode(),
      inviteSecret: _generateInviteSecret(),
      joinToken: _generateJoinToken(),
      localSailorId: _localSailorIdForVoyage(voyageId),
      displayName: normalisedDisplayName,
      role: VoyageRole.skipper,
      joinedAt: now,
      isSimulation: isSimulation,
      simulationSailorCount: simulationSailorCount,
      vesselStyle: vesselStyle,
      sailorSymbol: sailorSymbol,
      sailorColor: sailorColor,
      coordinationMode: coordinationMode,
      voyageName: normalisedVoyageName == null || normalisedVoyageName.isEmpty
          ? null
          : normalisedVoyageName,
    );
    _session = session;
    await _sessionStore.save(session);
    await _record(
      type: VoyageEventType.voyageCreated,
      payload: {
        'displayName': session.displayName,
        'role': session.role.wireName,
        if (isSimulation) 'simulation': true,
        'vesselStyle': session.sailorSymbol.wireValue(session.vesselStyle),
        'sailorColor': session.sailorColor.name,
        'coordinationMode': session.coordinationMode.name,
        if (session.voyageName != null) 'voyageName': session.voyageName,
      },
    );
  }

  int _validatedSimulationSailorCount(int value) {
    if (value < VoyageSession.minimumSimulationSailorCount ||
        value > VoyageSession.maximumSimulationSailorCount) {
      throw FormatException(
        'Choose between ${VoyageSession.minimumSimulationSailorCount} and '
        '${VoyageSession.maximumSimulationSailorCount} simulated sailors.',
      );
    }
    return value;
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _errorMessage = null;
    _errorIsRetryable = false;
    notifyListeners();
    try {
      await operation();
    } on FormatException catch (error) {
      // The sailor's own input. Retrying it unchanged would fail identically.
      _errorMessage = error.message;
    } on VoyageCodeDirectoryException catch (error) {
      _errorMessage = error.message;
      _errorIsRetryable = error.retryable;
    } on Object catch (error, stackTrace) {
      _errorMessage = 'That action could not be saved. Please try again.';
      _errorIsRetryable = true;
      if (kDebugMode) {
        debugPrint('Voyage action failed: $error\n$stackTrace');
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  VoyageSession _requireSession() {
    final activeSession = _session;
    if (activeSession == null) {
      throw StateError('No active voyage');
    }
    return activeSession;
  }

  String _normaliseName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      throw const FormatException('Enter a sailor name.');
    }
    return name.length <= 24 ? name : name.substring(0, 24);
  }

  String _generateCode() => List.generate(6, (_) => _random.nextInt(10)).join();

  String _generateInviteSecret() => base64Url
      .encode(List<int>.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static const _joinTokenAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  String _generateJoinToken() => List.generate(
    24,
    (_) => _joinTokenAlphabet[_random.nextInt(_joinTokenAlphabet.length)],
  ).join();

  String _localSailorIdForVoyage(String voyageId) {
    final installationId = _installationId;
    if (installationId == null || installationId.isEmpty) {
      return _idFactory();
    }
    final digest = sha256.convert(
      utf8.encode('tail-end-charlie-sailor-v1\n$installationId\n$voyageId'),
    );
    return 'sailor-${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  /// When the voyage ended, or null when it has not — including when a reopen
  /// undid the end. Everything keyed off this unwinds with it: the archived
  /// snapshot's timestamp, the membership reducer's cutoff, and the 24-hour
  /// retention timer.
  DateTime? get _voyageEndedAt {
    final latest = _latestOf(const {
      VoyageEventType.voyageEnded,
      VoyageEventType.voyageReopened,
    });
    return latest?.type == VoyageEventType.voyageEnded
        ? latest!.createdAt
        : null;
  }

  Future<void> _expireEndedVoyageIfDue() async {
    _endedVoyageCleanupTimer?.cancel();
    _endedVoyageCleanupTimer = null;
    final endedAt = _voyageEndedAt;
    if (endedAt == null || _session == null) return;
    final expiresAt = endedAt.add(endedVoyageRecoveryWindow);
    final delay = expiresAt.difference(_clock());
    if (delay <= Duration.zero) {
      await _archiveCurrentVoyageIfComplete();
      if (_voyageArchiveError != null) {
        // Never delete a voyage that could not be archived. The 24-hour cleanup
        // exists to reclaim space, and reclaiming it by destroying the only
        // copy of a voyage is the exact data loss #299 is about. Keeping the
        // journal costs one voyage's events and gives `initialize` another go at
        // it on the next launch.
        notifyListeners();
        return;
      }
      await _removeVoyageData();
      notifyListeners();
      return;
    }
    _endedVoyageCleanupTimer = Timer(delay, () {
      unawaited(_expireEndedVoyageIfDue());
    });
  }

  /// Set when a voyage ended but could not be written to Previous voyages.
  ///
  /// A sailor whose record of a voyage is missing has to be told (#299): the
  /// premise of the app is that the voyage is kept, and losing it silently is
  /// worse than never starting, because they believed it was being kept.
  ///
  /// Cleared on the next successful archive. [initialize] retries while the
  /// journal survives, which is the 24-hour ended-voyage window, so this states a
  /// risk rather than a certainty and says what happens next.
  String? get voyageArchiveError => _voyageArchiveError;
  String? _voyageArchiveError;

  static const voyageArchiveFailedMessage =
      'This voyage could not be added to Previous voyages. It is still on this '
      'phone and will be saved again next time you open the app.';

  Future<void> _archiveCurrentVoyageIfComplete({bool force = false}) async {
    final store = _completedVoyageStore;
    final activeSession = _session;
    if (store == null ||
        activeSession == null ||
        activeSession.isSimulation ||
        (!force && !voyageEnded) ||
        (force && !voyageStarted && !voyageEnded)) {
      return;
    }
    final archivedAt = _voyageEndedAt ?? _clock();
    final snapshot = const CompletedVoyageArchiver().create(
      session: activeSession,
      events: _events,
      archivedAt: archivedAt,
      plannedRoute: _routeState.route,
    );
    // Caught here rather than left to `_run`, for two reasons. It gets the
    // sailor a sentence about their voyage record instead of the generic "that
    // action could not be saved", which does not say what was lost. And it
    // stops one failed write abandoning the rest of `endVoyage` — the unused-ICE
    // purge after it is a privacy obligation, and it must not be skipped
    // because a file could not be written (#299).
    try {
      await store.save(snapshot);
      _voyageArchiveError = null;
    } on Object catch (error, stackTrace) {
      _voyageArchiveError = voyageArchiveFailedMessage;
      if (kDebugMode) {
        debugPrint(
          'Could not archive the completed voyage: $error\n$stackTrace',
        );
      }
    }
  }

  /// Removes personal-detail shares this device received (not ones it sent) as
  /// soon as the voyage ends, unless the recipient acted on them - so a skipper's
  /// app doesn't go on holding another sailor's phone number and medical notes
  /// once the voyage is over, but can still follow up on one they actually
  /// used.
  ///
  /// Both share types are purged together and on the same rule: an ICE contact
  /// ([VoyageEventType.iceInfoShared]) and a sailor's own number
  /// ([VoyageEventType.sailorContactShared], issue #188). They are separate
  /// consents and separate fields, but identical retention - the second was
  /// added here rather than beside here precisely so it cannot be forgotten.
  Future<void> _purgeUnusedIceSharesIfEnded() async {
    final activeSession = _session;
    if (activeSession == null || !voyageEnded) return;
    final localId = activeSession.localSailorId;
    final toRemove = _events
        .where(
          (event) =>
              (event.type == VoyageEventType.iceInfoShared ||
                  event.type == VoyageEventType.sailorContactShared) &&
              event.deviceId != localId &&
              _isAddressedToMe(event, localId) &&
              !_usedIceShareEventIds.contains(event.id),
        )
        .map((event) => event.id)
        .toList(growable: false);
    if (toRemove.isEmpty) return;
    await _eventStore.deleteEvents(activeSession.voyageId, toRemove);
    final removed = toRemove.toSet();
    _events = _events.where((event) => !removed.contains(event.id)).toList();
    _eventIds.removeAll(removed);
    _invalidateMembershipProjection();
  }

  Future<void> _removeVoyageData({bool deleteEvents = true}) async {
    _endedVoyageCleanupTimer?.cancel();
    _endedVoyageCleanupTimer = null;
    _endedVoyageSetAside = false;
    final voyageId = _requireSession().voyageId;
    if (deleteEvents) await _eventStore.deleteVoyage(voyageId);
    await _sessionStore.clear();
    _session = null;
    _replaceEvents(const []);
    _invalidateMembershipProjection();
    _lifecycle = const VoyageLifecycle();
    _routeState = const VoyageRouteState();
    _usedIceShareEventIds.clear();
    _transportByEventId.clear();
    _livePresence = const [];
    _presenceRoster = const [];
    _positionChannelUnavailable = false;
  }

  void _replaceEvents(Iterable<VoyageEvent> events) {
    _events = events.toList(growable: true);
    _eventIds
      ..clear()
      ..addAll(_events.map((event) => event.id));
    _invalidateMembershipProjection();
  }

  void _rebuildLifecycle() {
    final activeSession = _session;
    if (activeSession == null) {
      _lifecycle = const VoyageLifecycle();
      _routeState = const VoyageRouteState();
      return;
    }
    _lifecycle = VoyageLifecycleReducer.fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
    );
    _routeState = const VoyageRouteReducer().fromEvents(
      voyageId: activeSession.voyageId,
      inviteSecret: activeSession.inviteSecret,
      events: _events,
    );
  }

  @override
  void dispose() {
    _endedVoyageCleanupTimer?.cancel();
    _voyageCodeDirectory.close();
    _eventStore.close();
    super.dispose();
  }
}
