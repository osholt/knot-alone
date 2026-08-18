import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/vessel_icon.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

/// Issue #144: leaving a voyage *erased* the sailor. The field report is the
/// requirement — "It would be good to keep that until at least the end of the
/// voyage just in case something came up like a lost item etc." — so a departure
/// now demotes a sailor out of the live group and keeps their record: who they
/// were, when they went, and where they were last known to be.
///
/// The other half of the requirement is that nothing else changes: a departed
/// sailor is still out of the live count, out of route alerts, and out of the
/// rendered positions (#27, #132).
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const voyageId = 'voyage-a';
  final startedAt = DateTime.utc(2026, 7, 26, 14);
  final now = startedAt.add(const Duration(minutes: 30));

  List<VoyageParticipant> reduce({
    List<VoyageEvent> events = const [],
    List<LiveSailorPresence> livePresence = const [],
    List<PresenceRosterMember> presenceRoster = const [],
    DateTime? voyageEndedAt,
  }) => const VoyageMembershipReducer().fromEvents(
    voyageId: voyageId,
    inviteSecret: secret,
    events: events,
    now: now,
    localSailorId: 'skipper',
    localDisplayName: 'Oliver',
    localRole: VoyageRole.skipper,
    localJoinedAt: startedAt,
    localVesselStyle: vesselIconStyleDefault,
    localSailorColor: sailorColorDefault,
    voyageStartedAt: startedAt,
    voyageEndedAt: voyageEndedAt,
    livePresence: livePresence,
    presenceRoster: presenceRoster,
  );

  VoyageParticipant sailorIn(
    List<VoyageParticipant> participants,
    String sailorId,
  ) => participants.singleWhere(
    (participant) => participant.sailorId == sailorId,
  );

  test(
    'a sailor who leaves keeps their row, their role and where they were',
    () {
      final participants = reduce(
        events: [
          _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
          _roleChanged(
            deviceId: 'bill',
            role: VoyageRole.sweeper,
            at: startedAt.add(const Duration(minutes: 1)),
          ),
          _location(
            deviceId: 'bill',
            displayName: 'Bill',
            role: VoyageRole.sweeper,
            at: startedAt.add(const Duration(minutes: 10)),
            latitude: 51.20011,
            longitude: -2.40022,
          ),
          _left(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 32)),
          ),
        ],
      );

      final bill = sailorIn(participants, 'bill');
      expect(bill.state, VoyageMembershipState.left);
      expect(bill.hasLeft, isTrue);
      // Marked as having left, and when.
      expect(bill.leftAt, startedAt.add(const Duration(minutes: 32)));
      expect(bill.stateLabel, 'Left the voyage at 14:32');
      // Role and last-seen survive: this is the record you look somebody up in.
      expect(bill.role, VoyageRole.sweeper);
      expect(bill.lastSeenAt, startedAt.add(const Duration(minutes: 32)));
      // Last known position survives, read from the voyage's own journal.
      expect(bill.lastKnownLocation?.sample.position.latitude, 51.20011);
      expect(bill.lastKnownPositionLabel, contains('51.20011, -2.40022'));
      // And they are out of the live group, immediately.
      expect(bill.isIncludedInLiveCount, isFalse);
      expect(bill.isEligibleForLivePosition, isFalse);
      expect(bill.isEligibleForRouteAlerts, isFalse);
    },
  );

  test('the retained position is the one from before they left', () {
    final participants = reduce(
      events: [
        _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 5)),
          latitude: 51.1,
          longitude: -2.1,
        ),
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 9)),
          latitude: 51.9,
          longitude: -2.9,
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 10)),
        ),
        // A duplicate or late-delivered position from after the departure must
        // not move a sailor who has gone.
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 12)),
          latitude: 52.5,
          longitude: -3.5,
        ),
      ],
    );

    final bill = sailorIn(participants, 'bill');
    expect(bill.lastKnownLocation?.sample.position.latitude, 51.9);
    expect(bill.lastSeenAt, startedAt.add(const Duration(minutes: 10)));
  });

  test('a departure whose join never arrived still leaves a record', () {
    // The #132 failure mode: a wedged or backed-off batch sync means a sailor is
    // known to the relay but their membership events are not in this journal.
    // Before #144 the unmatched departure was dropped and live presence stopped
    // naming them, so the sailor vanished from the roster entirely.
    final participants = reduce(
      events: [
        _location(
          deviceId: 'bill',
          displayName: 'Bill',
          role: VoyageRole.marker,
          at: startedAt.add(const Duration(minutes: 4)),
          latitude: 51.5,
          longitude: -2.5,
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 6)),
        ),
      ],
    );

    final bill = sailorIn(participants, 'bill');
    expect(bill.state, VoyageMembershipState.left);
    expect(bill.displayName, 'Bill');
    expect(bill.role, VoyageRole.marker);
    expect(bill.stateLabel, 'Left the voyage at 14:06');
    expect(bill.lastKnownLocation?.sample.position.latitude, 51.5);
    expect(bill.isIncludedInLiveCount, isFalse);
  });

  test('an unidentifiable departure adds no row at all', () {
    final participants = reduce(
      events: [_left(deviceId: 'ghost', displayName: null, at: startedAt)],
    );

    expect(
      participants.where((participant) => participant.sailorId == 'ghost'),
      isEmpty,
      reason: 'a row nobody can identify is worse than no row',
    );
  });

  test("the relay's roster keeps a departed sailor this journal never saw", () {
    // Presence deliberately drops a departed sailor, so the roster is the only
    // channel still naming them when the batch has delivered nothing.
    final participants = reduce(
      presenceRoster: [
        _rosterMember(
          sailorId: 'bill',
          displayName: 'Bill',
          role: VoyageRole.sweeper,
          joinedAt: startedAt,
          left: true,
          leftAt: startedAt.add(const Duration(minutes: 32)),
        ),
      ],
    );

    final bill = sailorIn(participants, 'bill');
    expect(bill.state, VoyageMembershipState.left);
    expect(bill.stateLabel, 'Left the voyage at 14:32');
    expect(bill.role, VoyageRole.sweeper);
    expect(bill.knownFromRelayOnly, isTrue);
    expect(bill.isIncludedInLiveCount, isFalse);
    expect(bill.lastKnownPositionLabel, isNull);
  });

  test("the relay's roster marks a journal-known sailor as left", () {
    // The fast channel: the roster carries the departure before the batch does,
    // which is the propagation the field report saw working. The row must say
    // "left", not drift into "inactive".
    final participants = reduce(
      events: [_join(deviceId: 'bill', displayName: 'Bill', at: startedAt)],
      presenceRoster: [
        _rosterMember(
          sailorId: 'bill',
          displayName: 'Bill',
          joinedAt: startedAt,
          left: true,
          leftAt: startedAt.add(const Duration(minutes: 20)),
        ),
      ],
    );

    final bill = sailorIn(participants, 'bill');
    expect(bill.state, VoyageMembershipState.left);
    expect(bill.leftAt, startedAt.add(const Duration(minutes: 20)));
    expect(bill.isIncludedInLiveCount, isFalse);
  });

  test(
    'a stale roster departure never resurrects the ghost after a rejoin',
    () {
      final participants = reduce(
        events: [
          _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
          _left(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 10)),
          ),
          _join(
            deviceId: 'bill',
            displayName: 'Bill',
            at: startedAt.add(const Duration(minutes: 20)),
          ),
        ],
        presenceRoster: [
          _rosterMember(
            sailorId: 'bill',
            displayName: 'Bill',
            joinedAt: startedAt,
            left: true,
            leftAt: startedAt.add(const Duration(minutes: 10)),
          ),
        ],
      );

      expect(
        participants.where((participant) => participant.sailorId == 'bill'),
        hasLength(1),
      );
      final bill = sailorIn(participants, 'bill');
      expect(bill.hasLeft, isFalse);
      expect(bill.isIncludedInLiveCount, isTrue);
      expect(bill.rejoinLabel, 'Rejoined after leaving at 14:10');
    },
  );

  test('a relay with no departure time may add a row, never overrule one', () {
    final participants = reduce(
      events: [_join(deviceId: 'bill', displayName: 'Bill', at: startedAt)],
      presenceRoster: [
        _rosterMember(
          sailorId: 'bill',
          displayName: 'Bill',
          joinedAt: startedAt,
          left: true,
        ),
        _rosterMember(
          sailorId: 'sam',
          displayName: 'Sam',
          joinedAt: startedAt,
          left: true,
        ),
      ],
    );

    // Bill's row stays with the journal until its own `sailorLeft` arrives: an
    // undated departure cannot be ordered against a rejoin.
    expect(sailorIn(participants, 'bill').hasLeft, isFalse);
    // Sam is known to nobody else, so the undated departure is all there is.
    final sam = sailorIn(participants, 'sam');
    expect(sam.hasLeft, isTrue);
    expect(sam.stateLabel, 'Left the voyage');
    expect(sam.isIncludedInLiveCount, isFalse);
  });

  test('a departed sailor stops carrying a route alert', () {
    final participants = reduce(
      events: [
        _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
        _event(
          id: 'alert-bill',
          deviceId: 'skipper',
          type: VoyageEventType.routeDeviationChanged,
          createdAt: startedAt.add(const Duration(minutes: 4)),
          payload: const {
            'alert': {
              'sailorId': 'bill',
              'assessment': {'state': 'offRoute'},
            },
          },
        ),
        _left(
          deviceId: 'bill',
          displayName: 'Bill',
          at: startedAt.add(const Duration(minutes: 5)),
        ),
      ],
    );

    final bill = sailorIn(participants, 'bill');
    expect(bill.hasLeft, isTrue);
    expect(
      bill.attentionLabel,
      isNull,
      reason: 'a sailor who has gone is not off course',
    );
  });

  test('the record is retained through the end of the voyage, not beyond it', () {
    final events = [
      _join(deviceId: 'bill', displayName: 'Bill', at: startedAt),
      _location(
        deviceId: 'bill',
        displayName: 'Bill',
        at: startedAt.add(const Duration(minutes: 4)),
        latitude: 51.5,
        longitude: -2.5,
      ),
      _left(
        deviceId: 'bill',
        displayName: 'Bill',
        at: startedAt.add(const Duration(minutes: 5)),
      ),
    ];

    // Ending the voyage does not expire the departure into something vaguer, and
    // does not extend it either: the record lives in the voyage's own journal.
    final ended = reduce(
      events: events,
      voyageEndedAt: startedAt.add(const Duration(minutes: 20)),
    );
    final bill = sailorIn(ended, 'bill');
    expect(bill.state, VoyageMembershipState.left);
    expect(bill.stateLabel, 'Left the voyage at 14:05');
    expect(bill.isIncludedInLiveCount, isFalse);

    // Deleting the voyage takes its journal, and the record goes with it. There is
    // no other place it is kept.
    final deleted = reduce(voyageEndedAt: startedAt);
    expect(
      deleted.where((participant) => participant.sailorId == 'bill'),
      isEmpty,
    );
  });
}

VoyageEvent _join({
  required String deviceId,
  required String displayName,
  required DateTime at,
  VoyageRole role = VoyageRole.sailor,
}) => _event(
  id: 'join-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: VoyageEventType.sailorJoined,
  createdAt: at,
  payload: {'displayName': displayName, 'role': role.name},
);

VoyageEvent _left({
  required String deviceId,
  required String? displayName,
  required DateTime at,
}) => _event(
  id: 'left-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: VoyageEventType.sailorLeft,
  createdAt: at,
  payload: {
    'sailorId': deviceId,
    'displayName': ?displayName,
    'reason': 'left',
  },
);

VoyageEvent _roleChanged({
  required String deviceId,
  required VoyageRole role,
  required DateTime at,
}) => _event(
  id: 'role-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: VoyageEventType.roleChanged,
  createdAt: at,
  payload: {'role': role.name},
);

VoyageEvent _location({
  required String deviceId,
  required String displayName,
  required DateTime at,
  required double latitude,
  required double longitude,
  VoyageRole role = VoyageRole.sailor,
}) => _event(
  id: 'location-$deviceId-${at.millisecondsSinceEpoch}',
  deviceId: deviceId,
  type: VoyageEventType.sailorLocationUpdated,
  createdAt: at,
  payload: {
    'location': SailorLocation(
      sailorId: deviceId,
      displayName: displayName,
      role: role,
      sample: LocationSample(
        position: GeoPoint(latitude: latitude, longitude: longitude),
        recordedAt: at,
        accuracyMeters: 5,
      ),
      receivedAt: at,
    ).toJson(),
  },
);

PresenceRosterMember _rosterMember({
  required String sailorId,
  required String displayName,
  required DateTime joinedAt,
  VoyageRole role = VoyageRole.sailor,
  bool left = false,
  DateTime? leftAt,
}) => PresenceRosterMember(
  sailorId: sailorId,
  displayName: displayName,
  role: role,
  joinedAt: joinedAt,
  left: left,
  leftAt: leftAt,
);

VoyageEvent _event({
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  const secret = '0123456789abcdef0123456789abcdef';
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
