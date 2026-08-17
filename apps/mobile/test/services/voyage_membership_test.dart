import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final joinedAt = DateTime.utc(2026, 7, 22, 10);

  test(
    'membership transitions from joined to active, inactive and expired',
    () {
      final events = [
        _event(
          id: 'join-sailor',
          deviceId: 'sailor-a',
          type: VoyageEventType.sailorJoined,
          createdAt: joinedAt,
          payload: const {
            'displayName': 'Alex',
            'role': 'sailor',
            'motorcycleStyle': 'adventure',
            'sailorColor': 'blue',
          },
          secret: secret,
        ),
        _event(
          id: 'location-sailor',
          deviceId: 'sailor-a',
          type: VoyageEventType.sailorLocationUpdated,
          createdAt: joinedAt.add(const Duration(minutes: 1)),
          payload: const {'location': {}},
          secret: secret,
        ),
      ];

      VoyageParticipant sailorAt(DateTime now) =>
          const VoyageMembershipReducer()
              .fromEvents(
                voyageId: 'voyage-a',
                inviteSecret: secret,
                events: events,
                now: now,
                localSailorId: 'skipper',
                localDisplayName: 'Lead',
                localRole: VoyageRole.lead,
                localJoinedAt: joinedAt,
                localMotorcycleStyle: motorcycleIconStyleDefault,
                localSailorColor: sailorColorDefault,
                voyageStartedAt: joinedAt,
                transportByEventId: const {
                  'location-sailor': {VoyageTransportEvidence.internetRelay},
                },
              )
              .singleWhere((participant) => participant.sailorId == 'sailor-a');

      expect(
        sailorAt(joinedAt.add(const Duration(minutes: 2))).state,
        VoyageMembershipState.active,
      );
      expect(
        sailorAt(joinedAt.add(const Duration(minutes: 4))).state,
        VoyageMembershipState.inactive,
      );
      final expired = sailorAt(joinedAt.add(const Duration(hours: 13)));
      expect(expired.state, VoyageMembershipState.expired);
      expect(expired.transportLabel, 'Internet relay');
      expect(expired.isIncludedInLiveCount, isFalse);
    },
  );

  test('leave and later rejoin converge by canonical sailor identity', () {
    final events = [
      _event(
        id: 'join-first',
        deviceId: 'same-sailor',
        type: VoyageEventType.sailorJoined,
        createdAt: joinedAt,
        payload: const {'displayName': 'Alex', 'role': 'sailor'},
        secret: secret,
      ),
      _event(
        id: 'left',
        deviceId: 'same-sailor',
        type: VoyageEventType.sailorLeft,
        createdAt: joinedAt.add(const Duration(minutes: 1)),
        payload: const {'sailorId': 'same-sailor'},
        secret: secret,
      ),
      _event(
        id: 'join-again',
        deviceId: 'same-sailor',
        type: VoyageEventType.sailorJoined,
        createdAt: joinedAt.add(const Duration(minutes: 2)),
        payload: const {'displayName': 'Alex', 'role': 'sailor'},
        secret: secret,
      ),
    ];

    final participants = const VoyageMembershipReducer().fromEvents(
      voyageId: 'voyage-a',
      inviteSecret: secret,
      events: events.reversed,
      now: joinedAt.add(const Duration(minutes: 2, seconds: 30)),
      localSailorId: 'skipper',
      localDisplayName: 'Lead',
      localRole: VoyageRole.lead,
      localJoinedAt: joinedAt,
      localMotorcycleStyle: motorcycleIconStyleDefault,
      localSailorColor: sailorColorDefault,
      voyageStartedAt: joinedAt,
    );

    expect(
      participants.where(
        (participant) => participant.sailorId == 'same-sailor',
      ),
      hasLength(1),
    );
    final sailor = participants.singleWhere(
      (participant) => participant.sailorId == 'same-sailor',
    );
    expect(sailor.state, VoyageMembershipState.joined);
    // One row, and the history is on it rather than lost or duplicated (#144).
    expect(sailor.leftAt, isNull);
    expect(sailor.hasLeft, isFalse);
    expect(
      sailor.rejoinedAfterLeavingAt,
      joinedAt.add(const Duration(minutes: 1)),
    );
    expect(sailor.rejoinLabel, 'Rejoined after leaving at 10:01');
    expect(sailor.isIncludedInLiveCount, isTrue);
  });

  test('only one sailor holds lead, whichever order the claims arrive', () {
    // #284: "still 2 people can be skipper at the same time, which allows either of
    // them to end the voyage for all". #241 restricted ending a voyage for everyone to
    // the skipper, and endVoyage guards on it - but the guard asks only whether this
    // phone believes it leads, so two believers both pass.
    //
    // The rule is latest claim wins, ties broken by sailor id. The tiebreak is the
    // part that matters here: ordering by arrival would let two phones that were
    // offline together reach opposite conclusions, which relocates the bug rather
    // than removing it.
    final earlier = _event(
      id: 'join-first-skipper',
      deviceId: 'sailor-a',
      type: VoyageEventType.sailorJoined,
      createdAt: joinedAt,
      payload: const {
        'displayName': 'Alex',
        'role': 'lead',
        'motorcycleStyle': 'adventure',
        'sailorColor': 'blue',
      },
      secret: secret,
    );
    final later = _event(
      id: 'join-second-skipper',
      deviceId: 'sailor-b',
      type: VoyageEventType.sailorJoined,
      createdAt: joinedAt.add(const Duration(minutes: 5)),
      payload: const {
        'displayName': 'Blake',
        'role': 'lead',
        'motorcycleStyle': 'adventure',
        'sailorColor': 'green',
      },
      secret: secret,
    );

    List<VoyageParticipant> reduce(List<VoyageEvent> events) =>
        const VoyageMembershipReducer().fromEvents(
          voyageId: 'voyage-a',
          inviteSecret: secret,
          events: events,
          now: joinedAt.add(const Duration(minutes: 6)),
          localSailorId: 'observer',
          localDisplayName: 'Observer',
          localRole: VoyageRole.sailor,
          localJoinedAt: joinedAt,
          localMotorcycleStyle: motorcycleIconStyleDefault,
          localSailorColor: sailorColorDefault,
          voyageStartedAt: joinedAt,
        );

    for (final ordering in [
      [earlier, later],
      [later, earlier],
    ]) {
      final participants = reduce(ordering);
      final skippers = participants
          .where((participant) => participant.role == VoyageRole.lead)
          .toList();

      expect(
        skippers,
        hasLength(1),
        reason: 'two sailors may not hold lead at once',
      );
      expect(
        skippers.single.sailorId,
        'sailor-b',
        reason: 'the later claim wins, whichever order the events arrived in',
      );
      // Demoted, not removed: they are still in the voyage, they just do not lead
      // it, and saying so is what stops their phone offering skipper-only actions.
      final demoted = participants.firstWhere((p) => p.sailorId == 'sailor-a');
      expect(demoted.role, VoyageRole.sailor);
      expect(demoted.hasLeft, isFalse);
    }
  });

  test('a forged departure cannot remove a participant', () {
    final joined = _event(
      id: 'join',
      deviceId: 'sailor-a',
      type: VoyageEventType.sailorJoined,
      createdAt: joinedAt,
      payload: const {'displayName': 'Alex', 'role': 'sailor'},
      secret: secret,
    );
    final forged = VoyageEvent(
      id: 'forged-left',
      voyageId: 'voyage-a',
      deviceId: 'sailor-a',
      type: VoyageEventType.sailorLeft,
      priority: EventPriority.important,
      createdAt: joinedAt.add(const Duration(minutes: 1)),
      payload: const {'sailorId': 'sailor-a'},
      signature: '0' * 64,
    );

    final sailor = const VoyageMembershipReducer()
        .fromEvents(
          voyageId: 'voyage-a',
          inviteSecret: secret,
          events: [joined, forged],
          now: joinedAt.add(const Duration(minutes: 1)),
          localSailorId: 'skipper',
          localDisplayName: 'Lead',
          localRole: VoyageRole.lead,
          localJoinedAt: joinedAt,
          localMotorcycleStyle: motorcycleIconStyleDefault,
          localSailorColor: sailorColorDefault,
        )
        .singleWhere((participant) => participant.sailorId == 'sailor-a');

    expect(sailor.state, VoyageMembershipState.joined);
  });
}

VoyageEvent _event({
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
  required String secret,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: VoyageEventAuthenticator.sign(unsigned, secret),
  );
}
