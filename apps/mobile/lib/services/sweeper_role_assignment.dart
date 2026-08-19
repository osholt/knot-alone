import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import 'voyage_event_authenticator.dart';
import 'voyage_lifecycle.dart';

/// Where one skipper-issued Sweeper request has got to.
///
/// The app is named after the back-marker role, so the skipper must be able to
/// tell "I have asked someone" from "someone is actually watching the back".
/// A sailor who has not noticed they are TEC is worse than no TEC, because the
/// group then believes the back is covered when nobody is watching it — which
/// is why this is a request the target answers rather than a silent assignment.
enum SweeperRoleAssignmentStatus {
  /// Sent, not yet answered. The group still has no confirmed back-marker.
  pending,

  /// The target answered yes. They record their own `roleChanged` alongside the
  /// answer, so the role itself stays self-selected and the membership reducer
  /// is unchanged.
  accepted,

  /// The target answered no. Named rather than silently dropped: the skipper has
  /// to know to ask somebody else.
  declined,

  /// Unanswered for longer than [SweeperRoleAssignmentPolicy.requestExpiresAfter].
  /// A request nobody answered must not sit on the skipper's screen as "pending"
  /// for the rest of the voyage.
  expired,

  /// The skipper asked somebody else while this one was still unanswered.
  superseded,

  /// The target left the voyage. A departed sailor is not a back-marker, whether
  /// they had accepted or not.
  targetLeft,
}

/// One skipper-issued request for the Sweeper role.
class SweeperRoleAssignment {
  const SweeperRoleAssignment({
    required this.requestId,
    required this.skipperSailorId,
    required this.targetSailorId,
    required this.targetDisplayName,
    required this.requestedAt,
    required this.status,
    this.respondedAt,
  });

  final String requestId;

  /// The sailor who issued it, verified to have held [VoyageRole.skipper] at the
  /// moment the event was created.
  final String skipperSailorId;

  final String targetSailorId;

  /// The name the skipper saw when they asked. Only ever used as a label, never
  /// as identity.
  final String targetDisplayName;

  final DateTime requestedAt;
  final SweeperRoleAssignmentStatus status;
  final DateTime? respondedAt;

  bool get isPending => status == SweeperRoleAssignmentStatus.pending;

  bool get isAccepted => status == SweeperRoleAssignmentStatus.accepted;

  /// Skipper-facing one-liner. Deliberately never claims the role is filled
  /// while the request is unanswered.
  String get statusLabel => switch (status) {
    SweeperRoleAssignmentStatus.pending =>
      'Asked $targetDisplayName — waiting for them to accept',
    SweeperRoleAssignmentStatus.accepted =>
      '$targetDisplayName accepted the Sweeper role',
    SweeperRoleAssignmentStatus.declined => '$targetDisplayName declined',
    SweeperRoleAssignmentStatus.expired =>
      '$targetDisplayName never answered, so nobody is covering the back',
    SweeperRoleAssignmentStatus.superseded =>
      'Superseded — you asked somebody else',
    SweeperRoleAssignmentStatus.targetLeft =>
      '$targetDisplayName has left the voyage',
  };

  SweeperRoleAssignment _withStatus(
    SweeperRoleAssignmentStatus next, {
    DateTime? respondedAt,
  }) => SweeperRoleAssignment(
    requestId: requestId,
    skipperSailorId: skipperSailorId,
    targetSailorId: targetSailorId,
    targetDisplayName: targetDisplayName,
    requestedAt: requestedAt,
    status: next,
    respondedAt: respondedAt ?? this.respondedAt,
  );
}

/// How long an unanswered request stays pending.
///
/// Ten minutes. The situation this exists for is a skipper at a fuel stop with a
/// line of bikes: long enough for a sailor to get a glove off and answer, short
/// enough that the group is not still being told the back is "about to be"
/// covered a county later.
class SweeperRoleAssignmentPolicy {
  const SweeperRoleAssignmentPolicy({
    this.requestExpiresAfter = const Duration(minutes: 10),
  });

  final Duration requestExpiresAfter;
}

/// Every skipper-issued Sweeper request in this voyage, reconciled.
class SweeperRoleAssignmentState {
  const SweeperRoleAssignmentState({this.assignments = const []});

  /// Oldest first, by the journal's own deterministic ordering.
  final List<SweeperRoleAssignment> assignments;

  /// The request that currently matters — the newest admissible one.
  SweeperRoleAssignment? get latest =>
      assignments.isEmpty ? null : assignments.last;

  /// The unanswered request addressed to [sailorId], if any. This is what raises
  /// the accept/decline prompt on the target's own phone.
  SweeperRoleAssignment? pendingFor(String sailorId) => assignments
      .where(
        (assignment) =>
            assignment.isPending && assignment.targetSailorId == sailorId,
      )
      .lastOrNull;

  /// The most recently accepted request still standing.
  SweeperRoleAssignment? get acceptedAssignment =>
      assignments.where((assignment) => assignment.isAccepted).lastOrNull;

  /// The sailor the skipper's own record says is the Sweeper.
  ///
  /// This is the deterministic tie-break when two sailors hold the role at once:
  /// pass it to [SkipperVoyageStatusCalculator.resolveSweeperTarget] and the most
  /// recently accepted skipper request wins over an arbitrary self-selection.
  String? get acceptedSweeperSailorId => acceptedAssignment?.targetSailorId;

  /// True while the skipper has asked somebody and nobody has answered, so a
  /// surface can say "waiting" instead of either "covered" or "nobody asked".
  bool get hasPendingRequest =>
      assignments.any((assignment) => assignment.isPending);
}

/// Rebuilds [SweeperRoleAssignmentState] from the signed event journal.
///
/// Deliberately a pure reducer over the durable journal, like every other voyage
/// state in this app: it converges the same way for both transports, for
/// out-of-order and duplicate delivery, across a restart, and after a skipper
/// handover, because it never depends on arrival order — only on the journal's
/// (createdAt, id) ordering.
///
/// Authority rules, which are what make a forged or replayed assignment
/// harmless:
///
/// * A request is admissible only from a device whose latest signed role **at
///   that point in the journal** is [VoyageRole.skipper], and only when the payload
///   names its own author as the skipper. This is exactly how
///   [VoyageLifecycleReducer] admits `voyageStarted`, and how #99 rejects a forged
///   departure.
/// * A response is admissible only from the device the request named. Nobody
///   can accept or decline on another sailor's behalf.
/// * A duplicate request id is ignored, and only the first response to a
///   request counts, so replaying a frame changes nothing.
class SweeperRoleAssignmentReducer {
  const SweeperRoleAssignmentReducer({
    this.policy = const SweeperRoleAssignmentPolicy(),
  });

  final SweeperRoleAssignmentPolicy policy;

  SweeperRoleAssignmentState fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
    required DateTime now,
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

    final roles = <String, VoyageRole>{};
    final departed = <String>{};
    final byRequestId = <String, SweeperRoleAssignment>{};
    final order = <String>[];
    final answered = <String>{};

    for (final event in ordered) {
      switch (event.type) {
        case VoyageEventType.voyageCreated:
        case VoyageEventType.sailorJoined:
        case VoyageEventType.roleChanged:
          final role = _role(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
        case VoyageEventType.sailorLeft:
          // Same rule as the membership reducer: a departure only speaks for
          // the device that recorded it.
          final claimed = event.payload['sailorId'];
          if (claimed == null || claimed == event.deviceId) {
            departed.add(event.deviceId);
          }
        case VoyageEventType.sweeperRoleRequested:
          final assignment = _requestFrom(event, roles);
          if (assignment == null) continue;
          if (byRequestId.containsKey(assignment.requestId)) continue;
          byRequestId[assignment.requestId] = assignment;
          order.add(assignment.requestId);
        case VoyageEventType.sweeperRoleResponded:
          // Applied in a second pass below. An answer can legitimately carry an
          // earlier timestamp than the question - two phones, two clocks - and
          // it must still count, so the two halves are never matched by their
          // relative position in the journal.
          break;
        case VoyageEventType.voyageStarted:
        case VoyageEventType.markerStarted:
        case VoyageEventType.markerPass:
        case VoyageEventType.markerEnded:
        case VoyageEventType.statusMessage:
        case VoyageEventType.sailorLocationUpdated:
        case VoyageEventType.hazardReported:
        case VoyageEventType.hazardCleared:
        case VoyageEventType.routeDeviationChanged:
        case VoyageEventType.routeAlertAcknowledged:
        case VoyageEventType.routeRevisionChunk:
        case VoyageEventType.routeRevisionPublished:
        case VoyageEventType.routeCleared:
        case VoyageEventType.voyagePaused:
        case VoyageEventType.voyageResumed:
        case VoyageEventType.voyageEnded:
        case VoyageEventType.voyageReopened:
        case VoyageEventType.iceInfoShared:
        case VoyageEventType.iceInfoViewed:
        case VoyageEventType.rejoinRouteShared:
        case VoyageEventType.sailorContactShared:
          break;
      }
    }

    // Second pass: the answers. Ordered, so the first admissible answer to a
    // request wins however many duplicates arrive after it.
    for (final event in ordered) {
      if (event.type != VoyageEventType.sweeperRoleResponded) continue;
      final requestId = _identifier(event.payload['requestId']);
      if (requestId == null) continue;
      final request = byRequestId[requestId];
      // Only the sailor the skipper named may answer, and only once.
      if (request == null ||
          event.deviceId != request.targetSailorId ||
          answered.contains(requestId)) {
        continue;
      }
      final accepted = event.payload['accepted'];
      if (accepted is! bool) continue;
      answered.add(requestId);
      byRequestId[requestId] = request._withStatus(
        accepted
            ? SweeperRoleAssignmentStatus.accepted
            : SweeperRoleAssignmentStatus.declined,
        respondedAt: event.createdAt,
      );
    }

    final resolved = <SweeperRoleAssignment>[];
    for (var index = 0; index < order.length; index += 1) {
      var assignment = byRequestId[order[index]]!;
      final isNewest = index == order.length - 1;
      if (assignment.isPending && !isNewest) {
        assignment = assignment._withStatus(
          SweeperRoleAssignmentStatus.superseded,
        );
      } else if (assignment.isPending &&
          now.difference(assignment.requestedAt) >=
              policy.requestExpiresAfter) {
        assignment = assignment._withStatus(
          SweeperRoleAssignmentStatus.expired,
        );
      }
      if (departed.contains(assignment.targetSailorId) &&
          (assignment.isPending || assignment.isAccepted)) {
        assignment = assignment._withStatus(
          SweeperRoleAssignmentStatus.targetLeft,
        );
      }
      resolved.add(assignment);
    }
    return SweeperRoleAssignmentState(assignments: List.unmodifiable(resolved));
  }

  /// Builds the request payload the skipper records. Kept here so the writer and
  /// the reducer cannot disagree about the field names.
  static Map<String, Object?> requestPayload({
    required String requestId,
    required String skipperSailorId,
    required String targetSailorId,
    required String targetDisplayName,
  }) => {
    'requestId': requestId,
    'skipperSailorId': skipperSailorId,
    'targetSailorId': targetSailorId,
    'targetDisplayName': targetDisplayName,
  };

  /// Builds the answer payload the target records.
  static Map<String, Object?> responsePayload({
    required String requestId,
    required String targetSailorId,
    required bool accepted,
  }) => {
    'requestId': requestId,
    'targetSailorId': targetSailorId,
    'accepted': accepted,
  };

  static SweeperRoleAssignment? _requestFrom(
    VoyageEvent event,
    Map<String, VoyageRole> roles,
  ) {
    // Only the current skipper may initiate, and the event must name its own
    // author as that skipper. A request forged or replayed by another device
    // fails one of these and is dropped whole.
    if (roles[event.deviceId] != VoyageRole.skipper) return null;
    if (event.payload['skipperSailorId'] != event.deviceId) return null;
    final requestId = _identifier(event.payload['requestId']);
    final targetSailorId = _identifier(event.payload['targetSailorId']);
    if (requestId == null || targetSailorId == null) return null;
    // A skipper taking the role themselves is a self-selection, not a request.
    if (targetSailorId == event.deviceId) return null;
    final name = event.payload['targetDisplayName'];
    return SweeperRoleAssignment(
      requestId: requestId,
      skipperSailorId: event.deviceId,
      targetSailorId: targetSailorId,
      targetDisplayName: name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'That sailor',
      requestedAt: event.createdAt,
      status: SweeperRoleAssignmentStatus.pending,
    );
  }

  static String? _identifier(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 128) return null;
    return trimmed;
  }

  static VoyageRole? _role(Object? value) {
    if (value is! String) return null;
    return VoyageRoleWire.tryParse(value);
  }
}
