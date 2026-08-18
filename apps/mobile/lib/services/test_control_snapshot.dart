import '../controllers/voyage_controller.dart';
import '../domain/voyage_role.dart';
import '../controllers/situational_awareness_controller.dart';
import '../relay/live_presence.dart';
import 'voyage_membership.dart';

/// The state a driven field-test asserts against.
///
/// The design point of this file is that it reports the roster and live presence
/// as **two independent derivations**, and then states where they disagree.
///
/// That is deliberate. `VoyageController.participants` comes from
/// `VoyageMembershipReducer` over the event journal;
/// `SituationalAwarenessController.livePresenceAt` comes from the presence
/// channel. Issue #132 was exactly a divergence between them - the skipper
/// counted the follower in the roster and simultaneously showed them inactive
/// with no position. A snapshot that reported one merged view would have looked
/// perfectly healthy while that bug was live, and would have been worthless.
///
/// So [TestControlSnapshot.reconcile] does not smooth the two together. It
/// reports both and names the sailors each side accounts for differently, which is
/// the measurement step 8b of `docs/field-test-plan.md` actually calls for:
/// "the sailor count equals the number of drawn markers plus the sailors whose row
/// states why they have no position. There is no sailor in the count with
/// neither."
///
/// Nothing here carries the voyage's invite secret, join token, phone numbers or
/// emergency-contact data. A snapshot is meant to be safe to paste into a test
/// log; capability material is a separate, explicit read.
class TestControlSnapshot {
  const TestControlSnapshot._(this._payload);

  final Map<String, Object?> _payload;

  Map<String, Object?> toJson() => _payload;

  /// [awareness] is null between voyages. That is an ordinary state, not an error:
  /// the roster still reports whatever the journal holds, and presence is empty
  /// because there is no voyage generating it.
  static TestControlSnapshot capture({
    required VoyageController voyage,
    required SituationalAwarenessController? awareness,
    required DateTime now,
  }) {
    final session = voyage.session;
    final participants = voyage.participants;
    final presence = awareness?.livePresenceAt(now) ?? const [];

    return TestControlSnapshot._({
      'capturedAt': now.toUtc().toIso8601String(),
      'voyage': session == null
          ? null
          : {
              'voyageId': session.voyageId,
              'voyageCode': session.voyageCode,
              'localSailorId': session.localSailorId,
              'displayName': session.displayName,
              'role': session.role.wireName,
              // No inviteSecret, no joinToken - see the class comment.
            },
      'roster': [
        for (final participant in participants)
          _participantJson(participant, now),
      ],
      'presence': [for (final sailor in presence) _presenceJson(sailor, now)],
      'reconciliation': reconcile(participants, presence),
    });
  }

  static Map<String, Object?> _participantJson(
    VoyageParticipant participant,
    DateTime now,
  ) => {
    'sailorId': participant.sailorId,
    'displayName': participant.displayName,
    'role': participant.role.wireName,
    'state': participant.state.name,
    'isLocal': participant.isLocal,
    'hasLastKnownLocation': participant.lastKnownLocation != null,
    'secondsSinceLastSeen': now.difference(participant.lastSeenAt).inSeconds,
    'hasLeft': participant.leftAt != null,
  };

  static Map<String, Object?> _presenceJson(
    LiveSailorPresence sailor,
    DateTime now,
  ) => {
    'sailorId': sailor.sailorId,
    'displayName': sailor.displayName,
    'role': sailor.role.wireName,
    'freshness': sailor.freshness.name,
    'isLocal': sailor.isLocal,
    'hasPosition': sailor.location != null,
    'sources': [for (final source in sailor.sources) source.name],
    // The clock-skew case in step 8b sub-step 5. A peer whose clock is wrong
    // must still read as live, with the offset named rather than inferred from
    // a sailor silently going missing.
    'clockBasis': sailor.clockBasis.name,
    'publisherClockOffsetSeconds': sailor.publisherClockOffset?.inSeconds,
    'ageSeconds': sailor.age?.inSeconds,
  };

  /// Where the two derivations disagree.
  ///
  /// [countedWithoutPositionOrReason] is the #132 signature and the one that
  /// fails the pass gate: a sailor present in the roster who has neither a
  /// position nor a presence entry explaining the absence. An empty list is the
  /// passing state.
  ///
  /// `awaitingFirstFix` is deliberately **not** part of that failure, and the
  /// distinction was found by driving a real voyage rather than by reasoning. At
  /// voyage start every sailor is in the roster and nobody has reported a position
  /// yet, so an earlier version of this method reported the skipper as counted
  /// without a reason and failed the gate on a healthy voyage. An automated run
  /// would then have manufactured evidence of a #132 recurrence that was not
  /// there - the precise failure this whole surface is supposed to avoid.
  ///
  /// The discriminator is [VoyageParticipant.lastKnownLocation]. A sailor who has
  /// **never** reported a position is starting up; a sailor who *has* reported one
  /// and has since vanished from the presence channel with no explanation is the
  /// real fault.
  static Map<String, Object?> reconcile(
    List<VoyageParticipant> participants,
    List<LiveSailorPresence> presence,
  ) {
    final presenceById = {
      for (final sailor in presence) sailor.sailorId: sailor,
    };
    final placed = <String>[];
    final explained = <String>[];
    final awaitingFirstFix = <String>[];
    final unaccounted = <String>[];

    for (final participant in participants) {
      if (participant.leftAt != null) continue;
      final sailor = presenceById[participant.sailorId];
      if (sailor?.location != null) {
        placed.add(participant.sailorId);
      } else if (sailor != null) {
        // Present in the presence channel with no position: the row can state
        // why - stale, ageing, no fix yet. That satisfies the gate.
        explained.add(participant.sailorId);
      } else if (participant.lastKnownLocation == null) {
        // Never reported a position, so there is nothing to have lost. Normal
        // between joining and the first fix.
        awaitingFirstFix.add(participant.sailorId);
      } else {
        unaccounted.add(participant.sailorId);
      }
    }

    final rosterIds = {
      for (final participant in participants)
        if (participant.leftAt == null) participant.sailorId,
    };

    return {
      'rosterCount': rosterIds.length,
      'presenceCount': presence.length,
      'withPosition': placed,
      'withoutPositionButExplained': explained,
      // Reported separately so a driver can see the startup state without it
      // being mistaken for a fault. Does not fail the gate.
      'awaitingFirstFix': awaitingFirstFix,
      'countedWithoutPositionOrReason': unaccounted,
      // Present in presence but absent from the roster: the mirror-image fault,
      // which would draw a marker for somebody the roster does not admit to.
      'placedButNotInRoster': [
        for (final sailor in presence)
          if (!rosterIds.contains(sailor.sailorId)) sailor.sailorId,
      ],
      'gateSatisfied':
          unaccounted.isEmpty &&
          presence.every((sailor) => rosterIds.contains(sailor.sailorId)),
    };
  }
}
