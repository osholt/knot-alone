import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import '../domain/sailor_color.dart';
import '../domain/sailor_location.dart';
import '../features/map/vessel_icon.dart';
import '../relay/live_presence.dart';
import 'voyage_event_authenticator.dart';
import 'voyage_lifecycle.dart';

/// The membership lifecycle from #27, with #144's departure retention.
///
/// One distinction carries the whole enum: [inactive] is about *contact*, never
/// about movement. Position reports are driven by distance travelled with a
/// keep-alive on a timer (#166), so a sailor waiting at a set of lights stops
/// producing positions on purpose. A stale position is therefore no longer
/// evidence of absence, and the only thing that makes a sailor [inactive] is
/// nothing arriving from them at all.
enum VoyageMembershipState {
  /// In the voyage, but the voyage has not started or they have not been heard from
  /// since it did.
  joined,

  /// Heard from within [VoyageMembershipReducer.inactiveAfter], by any means: a
  /// journal event, a movement position report, or a keep-alive. A stationary
  /// sailor is active on keep-alives alone, indefinitely.
  active,

  /// Nothing has arrived from this sailor for
  /// [VoyageMembershipReducer.inactiveAfter] — no event, no position, no
  /// keep-alive. Not "their position is old": a sailor who has stopped moving is
  /// still [active].
  inactive,

  /// They left, and their record is kept for the rest of the voyage (#144).
  left,

  /// Nothing from them for [VoyageMembershipReducer.expireAfter], or the voyage is
  /// over.
  expired,
}

/// Wall-clock `HH:mm` for a roster row.
///
/// Formatted on the value exactly as held, which is the local clock: a journal
/// event's `createdAt` is local whether this phone recorded it or decoded it
/// from the relay. Deliberately not re-derived from a time zone here, so a
/// departure time reads the same as the clock the sailor looked at.
String formatVoyageClockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}';

/// Why a sailor who is counted in the live total has no position drawn.
///
/// Issue #132: the count and the marker were two separate judgements of the same
/// sailor, so a sailor could be "one of 2 sailors" and simultaneously have no
/// position and no explanation. Every counted sailor now resolves to exactly one
/// of these, and only [hasPosition] means a marker is drawn.
enum VoyagePositionAbsence {
  /// A position is available and drawn.
  hasPosition,

  /// The sailor is in the voyage and no position has reached this phone yet.
  noPositionReported,

  /// Live positions cannot reach this phone at the moment, so the absence says
  /// nothing about the sailor. The transport's own named limitation says why.
  positionChannelUnavailable,
}

extension VoyagePositionAbsenceLabels on VoyagePositionAbsence {
  /// Wording for a roster row. Never colour, never silence.
  String? get label => switch (this) {
    VoyagePositionAbsence.hasPosition => null,
    VoyagePositionAbsence.noPositionReported => 'no position reported yet',
    VoyagePositionAbsence.positionChannelUnavailable =>
      'live positions paused on this phone',
  };
}

enum VoyageTransportEvidence {
  localDevice,
  internetRelay,
  nearbyRelay,
  journal,
}

class VoyageParticipant {
  const VoyageParticipant({
    required this.sailorId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    required this.lastSeenAt,
    required this.state,
    required this.vesselStyle,
    required this.sailorColor,
    required this.transportEvidence,
    required this.isLocal,
    this.sailorSymbol = sailorSymbolDefault,
    this.leftAt,
    this.rejoinedAfterLeavingAt,
    this.lastKnownLocation,
    this.attentionLabel,
    this.positionFreshness,
    this.knownFromRelayOnly = false,
    this.positionAbsence = VoyagePositionAbsence.noPositionReported,
  });

  final String sailorId;
  final String displayName;
  final VoyageRole role;
  final DateTime joinedAt;
  final DateTime lastSeenAt;
  final DateTime? leftAt;

  /// The departure this sailor's current membership replaced, when they left and
  /// came back (#27's rejoin rule). Non-null only while [leftAt] is null: one
  /// identity, one row, and the history stays readable rather than becoming a
  /// second row or vanishing.
  final DateTime? rejoinedAfterLeavingAt;

  /// The newest position this phone ever held for this sailor, frozen at their
  /// departure once they leave (#144).
  ///
  /// It exists so a sailor who has left is still findable afterwards — a lost
  /// item, a question — and it is read from the voyage's own journal, so it lives
  /// exactly as long as the voyage and is deleted with it.
  ///
  /// **Never a marker source.** A departed sailor is not there; only
  /// [VoyageLiveView.renderedPositions] draws, and that comes from live presence.
  final SailorLocation? lastKnownLocation;
  final VoyageMembershipState state;
  final VesselIconStyle vesselStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;
  final Set<VoyageTransportEvidence> transportEvidence;
  final bool isLocal;
  final String? attentionLabel;

  /// How fresh this sailor's newest position is, or null when live presence was
  /// not evaluated for this roster.
  final PresenceFreshness? positionFreshness;

  /// True when the only evidence of this sailor is the relay's out-of-band
  /// roster or presence channel — their membership event has not arrived in the
  /// durable journal yet. They are still a real, reachable participant.
  final bool knownFromRelayOnly;

  /// Whether this sailor's position is drawn, and if not, the stated reason.
  ///
  /// A sailor in the live count with [VoyagePositionAbsence.hasPosition] must have
  /// a rendered marker; any other value must be shown in words. There is no
  /// third state.
  final VoyagePositionAbsence positionAbsence;

  bool get isIncludedInLiveCount =>
      state != VoyageMembershipState.left &&
      state != VoyageMembershipState.expired;

  bool get isEligibleForLivePosition => isIncludedInLiveCount;

  /// True when this sailor's position state is accounted for: either drawn, or
  /// absent with a reason a sailor can read. Asserted by [VoyageLiveView].
  bool get hasStatedPositionState =>
      !isIncludedInLiveCount ||
      positionAbsence == VoyagePositionAbsence.hasPosition ||
      positionAbsence.label != null;

  bool get isEligibleForRouteAlerts => state == VoyageMembershipState.active;

  /// True when this sailor has left and their record is being kept for the rest
  /// of the voyage (#144).
  bool get hasLeft => state == VoyageMembershipState.left;

  String get stateLabel {
    final departedAt = leftAt;
    final base = switch (state) {
      VoyageMembershipState.joined => 'Joined · waiting to voyage',
      VoyageMembershipState.active => 'Active now',
      // Not "location is stale". Positions are reported on distance travelled
      // (#166), so a sailor at a set of lights has an old position and is
      // perfectly present. Only silence on every channel reads as absence, and
      // the wording has to say which of the two this is.
      VoyageMembershipState.inactive => 'Inactive · not heard from',
      // Its own state, with the time on it: "Left at 14:32" is neither active
      // nor inactive, and the row stays until the voyage is over.
      VoyageMembershipState.left =>
        departedAt == null
            ? 'Left the voyage'
            : 'Left the voyage at ${formatVoyageClockTime(departedAt)}',
      VoyageMembershipState.expired => 'Expired',
    };
    if (state == VoyageMembershipState.left ||
        state == VoyageMembershipState.expired) {
      return base;
    }
    // Stated in words, never by colour alone, and never silently absent: a
    // counted sailor with no position always says why.
    final suffix = switch (positionFreshness) {
      PresenceFreshness.live => null,
      PresenceFreshness.ageing => 'position ageing',
      PresenceFreshness.stale => 'position stale',
      null || PresenceFreshness.none => positionAbsence.label,
    };
    return suffix == null ? base : '$base · $suffix';
  }

  /// One identity's visible history: they left, and they came back. Null when
  /// there is nothing to say.
  String? get rejoinLabel {
    final previously = rejoinedAfterLeavingAt;
    if (previously == null || hasLeft) return null;
    return 'Rejoined after leaving at ${formatVoyageClockTime(previously)}';
  }

  /// Where this sailor was last known to be, in words. Null when no position for
  /// them ever reached this phone.
  String? get lastKnownPositionLabel {
    final location = lastKnownLocation;
    if (location == null) return null;
    final position = location.sample.position;
    return 'Last known position '
        '${position.latitude.toStringAsFixed(5)}, '
        '${position.longitude.toStringAsFixed(5)} '
        'at ${formatVoyageClockTime(location.sample.recordedAt)}';
  }

  String get transportLabel {
    if (isLocal) return 'This phone';
    final internet = transportEvidence.contains(
      VoyageTransportEvidence.internetRelay,
    );
    final nearby = transportEvidence.contains(
      VoyageTransportEvidence.nearbyRelay,
    );
    if (knownFromRelayOnly) {
      return internet && nearby
          ? 'Internet + nearby · joining'
          : nearby
          ? 'Nearby relay · joining'
          : 'Internet relay · joining';
    }
    if (internet && nearby) return 'Internet + nearby';
    if (internet) return 'Internet relay';
    if (nearby) return 'Nearby relay';
    return 'Saved voyage journal';
  }

  VoyageParticipant copyWith({
    String? displayName,
    VoyageRole? role,
    DateTime? joinedAt,
    DateTime? lastSeenAt,
    DateTime? leftAt,
    bool clearLeftAt = false,
    DateTime? rejoinedAfterLeavingAt,
    SailorLocation? lastKnownLocation,
    VoyageMembershipState? state,
    VesselIconStyle? vesselStyle,
    SailorSymbol? sailorSymbol,
    SailorColor? sailorColor,
    Set<VoyageTransportEvidence>? transportEvidence,
    bool? isLocal,
    String? attentionLabel,
    bool clearAttention = false,
    PresenceFreshness? positionFreshness,
    bool? knownFromRelayOnly,
    VoyagePositionAbsence? positionAbsence,
  }) => VoyageParticipant(
    sailorId: sailorId,
    displayName: displayName ?? this.displayName,
    role: role ?? this.role,
    joinedAt: joinedAt ?? this.joinedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    leftAt: clearLeftAt ? null : (leftAt ?? this.leftAt),
    rejoinedAfterLeavingAt:
        rejoinedAfterLeavingAt ?? this.rejoinedAfterLeavingAt,
    lastKnownLocation: lastKnownLocation ?? this.lastKnownLocation,
    state: state ?? this.state,
    vesselStyle: vesselStyle ?? this.vesselStyle,
    sailorSymbol: sailorSymbol ?? this.sailorSymbol,
    sailorColor: sailorColor ?? this.sailorColor,
    transportEvidence: transportEvidence ?? this.transportEvidence,
    isLocal: isLocal ?? this.isLocal,
    attentionLabel: clearAttention
        ? null
        : (attentionLabel ?? this.attentionLabel),
    positionFreshness: positionFreshness ?? this.positionFreshness,
    knownFromRelayOnly: knownFromRelayOnly ?? this.knownFromRelayOnly,
    positionAbsence: positionAbsence ?? this.positionAbsence,
  );
}

/// The one reconciled live model: the sailor count, the roster rows, the main map
/// and the mini-map all derive from this and cannot disagree.
///
/// Issue #132: the count came from membership while the marker came from a
/// separate freshness judgement, so a skipper could count a follower and refuse
/// to draw them with nothing said. [reconcile] makes that state unrepresentable:
/// every counted sailor is either in [renderedPositions] or in
/// [countedWithoutPosition] with a stated reason, and never in both or neither.
class VoyageLiveView {
  VoyageLiveView._(this.participants, this.renderedPositions)
    : assert(
        participants.every((participant) => participant.hasStatedPositionState),
        'A sailor in the live count must have a position or a stated reason.',
      );

  /// Builds the reconciled view from the membership roster and the reconciled
  /// live presence for the same sailor set.
  ///
  /// [positionChannelUnavailable] is true when this device cannot currently
  /// receive positions at all, so an absence is attributed to the transport
  /// rather than to the sailor.
  factory VoyageLiveView.reconcile({
    required Iterable<VoyageParticipant> participants,
    required Iterable<LiveSailorPresence> presence,
    bool positionChannelUnavailable = false,
  }) {
    final presenceById = {for (final entry in presence) entry.sailorId: entry};
    final resolved = <VoyageParticipant>[];
    final positions = <SailorLocation>[];
    for (final participant in participants) {
      final location = presenceById[participant.sailorId]?.location;
      final absence = location != null
          ? VoyagePositionAbsence.hasPosition
          : positionChannelUnavailable
          ? VoyagePositionAbsence.positionChannelUnavailable
          : VoyagePositionAbsence.noPositionReported;
      resolved.add(participant.copyWith(positionAbsence: absence));
      if (location != null && participant.isEligibleForLivePosition) {
        positions.add(location);
      }
    }
    return VoyageLiveView._(
      List.unmodifiable(resolved),
      List.unmodifiable(positions),
    );
  }

  /// Every sailor in the voyage, each carrying a resolved position state.
  final List<VoyageParticipant> participants;

  /// The positions to draw: one per counted sailor that has one. Nothing else is
  /// drawable, and nothing drawable is missing from the count.
  final List<SailorLocation> renderedPositions;

  List<VoyageParticipant> get liveParticipants => List.unmodifiable([
    for (final participant in participants)
      if (participant.isIncludedInLiveCount) participant,
  ]);

  int get liveSailorCount => liveParticipants.length;

  /// Counted sailors with no marker, each with a reason to show.
  List<VoyageParticipant> get countedWithoutPosition => List.unmodifiable([
    for (final participant in liveParticipants)
      if (participant.positionAbsence != VoyagePositionAbsence.hasPosition)
        participant,
  ]);

  /// The count and the drawn positions agree: every counted sailor is accounted
  /// for exactly once.
  bool get isReconciled =>
      renderedPositions.length + countedWithoutPosition.length ==
      liveSailorCount;
}

class VoyageMembershipReducer {
  const VoyageMembershipReducer({
    this.inactiveAfter = const Duration(minutes: 2),
    this.expireAfter = const Duration(hours: 12),
  });

  /// How long silence on every channel lasts before a sailor reads as
  /// [VoyageMembershipState.inactive].
  ///
  /// It has to stay comfortably longer than the keep-alive interval
  /// (`PositionReportPolicy.keepAliveAfter`, 15 s), because that interval is the
  /// slowest rate at which a stationary sailor says anything at all. 2 minutes
  /// tolerates seven consecutive missed keep-alives before a present sailor is
  /// described as absent.
  final Duration inactiveAfter;
  final Duration expireAfter;

  List<VoyageParticipant> fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
    required DateTime now,
    required String localSailorId,
    required String localDisplayName,
    required VoyageRole localRole,
    required DateTime localJoinedAt,
    required VesselIconStyle localVesselStyle,
    required SailorColor localSailorColor,
    SailorSymbol localSailorSymbol = sailorSymbolDefault,
    DateTime? voyageStartedAt,
    DateTime? voyageEndedAt,
    Map<String, Set<VoyageTransportEvidence>> transportByEventId = const {},
    Iterable<LiveSailorPresence> livePresence = const [],
    Iterable<PresenceRosterMember> presenceRoster = const [],
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.voyageId == voyageId &&
                  VoyageEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(VoyageLifecycleReducer.compareEvents);
    final participants = <String, VoyageParticipant>{
      localSailorId: VoyageParticipant(
        sailorId: localSailorId,
        displayName: localDisplayName,
        role: localRole,
        joinedAt: localJoinedAt,
        lastSeenAt: localJoinedAt,
        state: VoyageMembershipState.joined,
        vesselStyle: localVesselStyle,
        sailorSymbol: localSailorSymbol,
        sailorColor: localSailorColor,
        transportEvidence: const {VoyageTransportEvidence.localDevice},
        isLocal: true,
      ),
    };
    // When each sailor last claimed lead, so a second claimant is resolved
    // deterministically rather than by whichever event happened to arrive last on
    // this particular phone. See [_withOneSkipper].
    final leadClaimedAt = <String, DateTime>{};
    final lastActivityAt = <String, DateTime>{};
    // The newest journal position per sailor, and the one frozen at a departure.
    // Both come from the voyage's own journal, so a retained record is deleted
    // with the voyage and nothing new is written to storage (#144).
    final newestLocation = <String, SailorLocation>{};
    final locationAtDeparture = <String, SailorLocation>{};

    for (final event in ordered) {
      final existing = participants[event.deviceId];
      if (event.type == VoyageEventType.sailorLocationUpdated) {
        final location = _location(event);
        if (location != null) newestLocation[event.deviceId] = location;
      }
      if (event.type == VoyageEventType.voyageCreated ||
          event.type == VoyageEventType.sailorJoined) {
        final displayName = _nonEmptyString(event.payload['displayName']);
        final role = _role(event.payload['role']);
        if (displayName == null || role == null) continue;
        final isLocal = event.deviceId == localSailorId;
        final joiningRole = isLocal ? localRole : role;
        if (joiningRole == VoyageRole.skipper) {
          leadClaimedAt[event.deviceId] = event.createdAt;
        }
        participants[event.deviceId] = VoyageParticipant(
          sailorId: event.deviceId,
          displayName: isLocal ? localDisplayName : displayName,
          role: joiningRole,
          joinedAt: event.createdAt,
          lastSeenAt: event.createdAt,
          state: VoyageMembershipState.joined,
          vesselStyle: isLocal
              ? localVesselStyle
              : vesselIconStyleFromName(
                  event.payload['vesselStyle'] as String?,
                ),
          sailorSymbol: isLocal
              ? localSailorSymbol
              : SailorSymbol.fromWireValue(
                  event.payload['vesselStyle'] as String?,
                ),
          sailorColor: isLocal
              ? localSailorColor
              : sailorColorFromName(event.payload['sailorColor'] as String?),
          transportEvidence: _evidenceFor(
            event,
            isLocal: isLocal,
            transportByEventId: transportByEventId,
          ),
          isLocal: isLocal,
          // One identity, one row: a sailor who left and came back keeps the
          // departure they came back from instead of becoming a second row or
          // losing the history (#27).
          rejoinedAfterLeavingAt:
              existing?.leftAt ?? existing?.rejoinedAfterLeavingAt,
          lastKnownLocation: existing?.lastKnownLocation,
        );
        lastActivityAt.remove(event.deviceId);
        continue;
      }
      if (event.type == VoyageEventType.sailorLeft) {
        final payloadSailorId = event.payload['sailorId'];
        if (payloadSailorId != null && payloadSailorId != event.deviceId) {
          continue;
        }
        // A departure is never dropped for want of a join event. Before #144 an
        // unmatched `sailorLeft` was ignored, and because live presence also
        // drops a departed sailor, the row disappeared altogether: exactly the
        // record the field report needed afterwards.
        final departing =
            existing ??
            _departedFromJournal(
              event,
              location: newestLocation[event.deviceId],
              transportByEventId: transportByEventId,
            );
        if (departing == null) continue;
        final atDeparture =
            newestLocation[event.deviceId] ?? departing.lastKnownLocation;
        if (atDeparture != null) {
          locationAtDeparture[event.deviceId] = atDeparture;
        }
        participants[event.deviceId] = departing.copyWith(
          lastSeenAt: event.createdAt,
          leftAt: event.createdAt,
          state: VoyageMembershipState.left,
          transportEvidence: Set.unmodifiable({
            ...departing.transportEvidence,
            ..._evidenceFor(
              event,
              isLocal: departing.isLocal,
              transportByEventId: transportByEventId,
            ),
          }),
        );
        continue;
      }
      if (existing == null) continue;
      final evidence = {
        ...existing.transportEvidence,
        ..._evidenceFor(
          event,
          isLocal: existing.isLocal,
          transportByEventId: transportByEventId,
        ),
      };
      if (event.type == VoyageEventType.roleChanged) {
        final role = _role(event.payload['role']);
        if (role == null) continue;
        if (role == VoyageRole.skipper) {
          leadClaimedAt[event.deviceId] = event.createdAt;
        }
        participants[event.deviceId] = existing.copyWith(
          role: existing.isLocal ? localRole : role,
          lastSeenAt: event.createdAt,
          transportEvidence: Set.unmodifiable(evidence),
        );
        continue;
      }
      if (existing.leftAt != null) continue;
      participants[event.deviceId] = existing.copyWith(
        lastSeenAt: event.createdAt,
        transportEvidence: Set.unmodifiable(evidence),
      );
      if (_isActivity(event.type)) {
        lastActivityAt[event.deviceId] = event.createdAt;
      }
    }

    // A sailor the relay can demonstrably reach must appear even when their
    // membership event has not arrived through the bulk batch. Otherwise a
    // wedged or backed-off sync hides a participant completely, and every
    // surface that filters positions by participant drops their marker too.
    final presenceById = <String, LiveSailorPresence>{};
    for (final presence in livePresence) {
      presenceById[presence.sailorId] = presence;
      if (participants.containsKey(presence.sailorId)) continue;
      final evidence = _presenceEvidence(presence);
      participants[presence.sailorId] = VoyageParticipant(
        sailorId: presence.sailorId,
        displayName: presence.displayName,
        role: presence.role,
        joinedAt: presence.knownSince,
        lastSeenAt: presence.location?.sample.recordedAt ?? presence.knownSince,
        state: VoyageMembershipState.joined,
        vesselStyle: presence.vesselStyle,
        sailorSymbol: presence.sailorSymbol,
        sailorColor: presence.sailorColor,
        // A roster entry with no position yet is still internet-relay evidence:
        // the relay named the sailor.
        transportEvidence: Set.unmodifiable(
          evidence.isEmpty
              ? const {VoyageTransportEvidence.internetRelay}
              : evidence,
        ),
        isLocal: false,
        knownFromRelayOnly: true,
      );
    }

    // The mirror image of the loop above, for a sailor who has *gone*. Live
    // presence deliberately drops a departed sailor — they are not there — so the
    // relay's roster is the only channel that still names them when their
    // membership events never made it into this phone's journal. Keeping the row
    // here is what stops a departure erasing the record (#144).
    for (final member in presenceRoster) {
      if (!member.left || member.sailorId == localSailorId) continue;
      final existing = participants[member.sailorId];
      final departedAt = member.leftAt;
      if (existing != null) {
        // Already recorded as gone by the journal, which carries the time.
        if (existing.hasLeft) continue;
        // A relay without a departure time cannot be ordered against a rejoin,
        // so it may only add a row it alone knows about, never overrule one the
        // journal is maintaining. The journal's own `sailorLeft` follows.
        if (departedAt == null) continue;
        // The journal has a later membership: they came back after this
        // departure, and a stale roster flag must not resurrect the ghost.
        if (existing.joinedAt.isAfter(departedAt)) continue;
        participants[member.sailorId] = existing.copyWith(
          leftAt: departedAt,
          lastSeenAt: existing.lastSeenAt.isAfter(departedAt)
              ? existing.lastSeenAt
              : departedAt,
          state: VoyageMembershipState.left,
        );
        continue;
      }
      participants[member.sailorId] = VoyageParticipant(
        sailorId: member.sailorId,
        displayName: member.displayName,
        role: member.role,
        joinedAt: member.joinedAt,
        lastSeenAt: departedAt ?? member.joinedAt,
        leftAt: departedAt,
        state: VoyageMembershipState.left,
        vesselStyle: member.vesselStyle,
        sailorSymbol: member.sailorSymbol,
        sailorColor: member.sailorColor,
        transportEvidence: const {VoyageTransportEvidence.internetRelay},
        isLocal: false,
        knownFromRelayOnly: true,
      );
    }

    for (final event in ordered) {
      if (event.type != VoyageEventType.routeDeviationChanged &&
          event.type != VoyageEventType.routeAlertAcknowledged) {
        continue;
      }
      final alert = event.payload['alert'];
      if (alert is! Map) continue;
      final sailorId = alert['sailorId'];
      final assessment = alert['assessment'];
      final state = assessment is Map ? assessment['state'] : null;
      final participant = sailorId is String ? participants[sailorId] : null;
      if (participant == null) continue;
      // A sailor who has left is not off course, not being looked for, and not
      // something the group can act on. Their record says they left; it must not
      // also keep claiming an alert that stopped applying when they went.
      if (participant.hasLeft) continue;
      final label = switch (state) {
        'offRoute' => 'Off course',
        'suspectedOffRoute' => 'Route check',
        'staleGps' => 'GPS stale',
        _ => null,
      };
      participants[sailorId as String] = participant.copyWith(
        attentionLabel: label,
        clearAttention: label == null,
      );
    }

    final result =
        participants.values
            .map((participant) {
              final presence = presenceById[participant.sailorId];
              // Where this sailor was last known to be. A departed sailor keeps
              // the position frozen at their departure; nothing here is ever
              // drawn, because only live presence produces a marker.
              final recorded = participant.copyWith(
                lastKnownLocation: participant.hasLeft
                    ? locationAtDeparture[participant.sailorId] ??
                          newestLocation[participant.sailorId]
                    : newestLocation[participant.sailorId],
              );
              final resolved = presence == null
                  ? recorded
                  : recorded.copyWith(
                      positionFreshness: presence.freshness,
                      transportEvidence: Set.unmodifiable({
                        ...recorded.transportEvidence,
                        ..._presenceEvidence(presence),
                      }),
                    );
              if (resolved.state == VoyageMembershipState.left) {
                return resolved;
              }
              // A live presence position is current proof of reachability, so
              // it counts as recent contact even if no journal event has
              // arrived. Without this a demonstrably visible sailor expires.
              //
              // Read from `contactAt`, not from the position's own timestamp: a
              // stationary sailor republishing an unchanged position is in
              // contact now, and dating that contact to when the position was
              // *recorded* would creep them toward `expired` for standing still
              // (#166).
              final contactAt =
                  presence != null && presence.freshness.isTrackedAsContact
                  ? presence.contactAt
                  : null;
              final lastSeenAt =
                  contactAt != null && contactAt.isAfter(resolved.lastSeenAt)
                  ? contactAt
                  : resolved.lastSeenAt;
              final age = now.difference(lastSeenAt);
              if (voyageEndedAt != null || age >= expireAfter) {
                return resolved.copyWith(state: VoyageMembershipState.expired);
              }
              if (voyageStartedAt == null) {
                return resolved.copyWith(state: VoyageMembershipState.joined);
              }
              // Either channel on its own is enough. A journal keep-alive and a
              // presence republish are both contact; neither requires the sailor
              // to have moved a metre.
              final activityAt = lastActivityAt[resolved.sailorId];
              if ((activityAt != null &&
                      now.difference(activityAt) < inactiveAfter) ||
                  contactAt != null) {
                return resolved.copyWith(state: VoyageMembershipState.active);
              }
              final waitingSince = resolved.joinedAt.isAfter(voyageStartedAt)
                  ? resolved.joinedAt
                  : voyageStartedAt;
              if (now.difference(waitingSince) < inactiveAfter) {
                return resolved.copyWith(state: VoyageMembershipState.joined);
              }
              return resolved.copyWith(state: VoyageMembershipState.inactive);
            })
            .toList(growable: false)
          ..sort((left, right) {
            final byJoin = left.joinedAt.compareTo(right.joinedAt);
            if (byJoin != 0) return byJoin;
            return left.sailorId.compareTo(right.sailorId);
          });
    return List.unmodifiable(_withOneSkipper(result, leadClaimedAt));
  }

  /// Leaves exactly one sailor holding [VoyageRole.skipper].
  ///
  /// A tester found that two sailors could hold lead at the same time, and that
  /// either could then end the voyage for everyone (#284). #241 restricted that
  /// action to the skipper, and `endVoyage` guards on it - but the guard asks only
  /// whether *this phone* believes it leads, so if two phones both believe it,
  /// both pass. A skipper-only rule is worth no more than the guarantee that there
  /// is one skipper.
  ///
  /// The rule is the latest claim wins, ties broken by sailor id. Both halves
  /// matter: latest-wins makes a handover work without a separate protocol, and
  /// the id tiebreak is what makes every device agree. Ordering by arrival would
  /// let two phones that were offline together reach opposite conclusions, which
  /// is the failure this is supposed to remove rather than relocate.
  ///
  /// This is the narrow half of the problem. Roles are still not bound to a
  /// device: trust rests on one shared per-voyage HMAC secret, so anyone holding it
  /// can mint an event that verifies as any role, and no reducer can detect that.
  /// #272 is the review that has to settle it. What this removes is two *honest*
  /// phones both believing they lead.
  static List<VoyageParticipant> _withOneSkipper(
    List<VoyageParticipant> participants,
    Map<String, DateTime> leadClaimedAt,
  ) {
    final skippers = participants
        .where((participant) => participant.role == VoyageRole.skipper)
        .toList(growable: false);
    if (skippers.length < 2) return participants;

    VoyageParticipant? winner;
    for (final candidate in skippers) {
      if (winner == null) {
        winner = candidate;
        continue;
      }
      final candidateAt = leadClaimedAt[candidate.sailorId];
      final winnerAt = leadClaimedAt[winner.sailorId];
      if (candidateAt == null) continue;
      if (winnerAt == null) {
        winner = candidate;
        continue;
      }
      final byTime = candidateAt.compareTo(winnerAt);
      if (byTime > 0 ||
          (byTime == 0 && candidate.sailorId.compareTo(winner.sailorId) > 0)) {
        winner = candidate;
      }
    }

    return [
      for (final participant in participants)
        participant.role == VoyageRole.skipper &&
                participant.sailorId != winner!.sailorId
            // Demoted to sailor rather than dropped: they are still in the voyage,
            // they just do not lead it, and saying so is what stops their phone
            // offering skipper-only actions.
            ? participant.copyWith(role: VoyageRole.sailor)
            : participant,
    ];
  }

  /// The sailor's own position from an authenticated journal location event, or
  /// null when the payload is not one this build can read. A sailor may only
  /// report their own position, so anything else is discarded.
  static SailorLocation? _location(VoyageEvent event) {
    final raw = event.payload['location'];
    if (raw is! Map) return null;
    try {
      final location = SailorLocation.fromJson(Map<String, Object?>.from(raw));
      return location.sailorId == event.deviceId ? location : null;
    } on Object {
      return null;
    }
  }

  /// A record for a sailor whose departure reached this phone but whose join
  /// never did.
  ///
  /// Null when there is no name to show from either the departure itself or a
  /// position they reported: a row nobody can identify is worse than no row, and
  /// #27 was raised partly over generic device labels. The role is taken from
  /// their own last position when it is known.
  static VoyageParticipant? _departedFromJournal(
    VoyageEvent event, {
    required SailorLocation? location,
    required Map<String, Set<VoyageTransportEvidence>> transportByEventId,
  }) {
    final displayName =
        _nonEmptyString(event.payload['displayName']) ?? location?.displayName;
    if (displayName == null) return null;
    return VoyageParticipant(
      sailorId: event.deviceId,
      displayName: displayName,
      role: location?.role ?? VoyageRole.sailor,
      joinedAt: location?.sample.recordedAt ?? event.createdAt,
      lastSeenAt: event.createdAt,
      state: VoyageMembershipState.left,
      vesselStyle: location?.vesselStyle ?? vesselIconStyleDefault,
      sailorSymbol: location?.sailorSymbol ?? sailorSymbolDefault,
      sailorColor: location?.sailorColor ?? sailorColorDefault,
      transportEvidence: _evidenceFor(
        event,
        isLocal: false,
        transportByEventId: transportByEventId,
      ),
      isLocal: false,
      lastKnownLocation: location,
    );
  }

  static Set<VoyageTransportEvidence> _presenceEvidence(
    LiveSailorPresence presence,
  ) => {
    if (presence.sources.contains(LivePresenceSource.internetPresence))
      VoyageTransportEvidence.internetRelay,
    if (presence.sources.contains(LivePresenceSource.nearbyPresence))
      VoyageTransportEvidence.nearbyRelay,
  };

  static bool _isActivity(VoyageEventType type) => switch (type) {
    VoyageEventType.voyageCreated ||
    VoyageEventType.sailorJoined ||
    VoyageEventType.sailorLeft ||
    VoyageEventType.roleChanged => false,
    _ => true,
  };

  static Set<VoyageTransportEvidence> _evidenceFor(
    VoyageEvent event, {
    required bool isLocal,
    required Map<String, Set<VoyageTransportEvidence>> transportByEventId,
  }) {
    if (isLocal) return const {VoyageTransportEvidence.localDevice};
    final evidence = transportByEventId[event.id];
    if (evidence == null || evidence.isEmpty) {
      return const {VoyageTransportEvidence.journal};
    }
    return Set.unmodifiable(evidence);
  }

  static VoyageRole? _role(Object? value) {
    if (value is! String) return null;
    return VoyageRoleWire.tryParse(value);
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim();
  }
}
