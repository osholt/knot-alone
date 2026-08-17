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

/// `sailorJoined` used to be visible only through the bulk event batch, so one
/// wedged sync hid a participant entirely — and every surface that filters
/// positions by participant then dropped their marker too.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const voyageId = 'voyage-membership-presence';
  final startedAt = DateTime.utc(2026, 7, 25, 9);
  final now = startedAt.add(const Duration(minutes: 10));

  List<VoyageParticipant> reduce({
    List<VoyageEvent> events = const [],
    List<LiveSailorPresence> livePresence = const [],
    DateTime? voyageStartedAt,
  }) => const VoyageMembershipReducer().fromEvents(
    voyageId: voyageId,
    inviteSecret: secret,
    events: events,
    now: now,
    localSailorId: 'local',
    localDisplayName: 'Oliver',
    localRole: VoyageRole.lead,
    localJoinedAt: startedAt,
    localVesselStyle: vesselIconStyleDefault,
    localSailorColor: sailorColorDefault,
    voyageStartedAt: voyageStartedAt,
    livePresence: livePresence,
  );

  test('a sailor known only to the relay still appears in the roster', () {
    final participants = reduce(
      voyageStartedAt: startedAt,
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now.subtract(const Duration(seconds: 3)),
          knownSince: startedAt.add(const Duration(minutes: 5)),
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.sailorId == 'bill');
    expect(bill.displayName, 'Bill');
    expect(bill.knownFromRelayOnly, isTrue);
    expect(
      bill.transportEvidence,
      contains(VoyageTransportEvidence.internetRelay),
    );
    expect(bill.transportLabel, 'Internet relay · joining');
    expect(bill.isEligibleForLivePosition, isTrue);
    // Contact through presence is current proof of reachability, so the sailor
    // is active rather than "inactive · not heard from".
    expect(bill.state, VoyageMembershipState.active);
  });

  test('the journal stays authoritative for identity once it arrives', () {
    final participants = reduce(
      voyageStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill Smith',
          role: VoyageRole.sweeper,
          createdAt: startedAt.add(const Duration(minutes: 1)),
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.sailorId == 'bill');
    expect(bill.displayName, 'Bill Smith');
    expect(bill.role, VoyageRole.sweeper);
    expect(bill.knownFromRelayOnly, isFalse);
    expect(bill.transportLabel, 'Internet relay');
  });

  test('presence never resurrects a sailor who has left', () {
    final participants = reduce(
      voyageStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill',
          role: VoyageRole.sailor,
          createdAt: startedAt.add(const Duration(minutes: 1)),
        ),
        _event(
          id: 'left-bill',
          deviceId: 'bill',
          type: VoyageEventType.sailorLeft,
          createdAt: startedAt.add(const Duration(minutes: 2)),
          payload: const {'sailorId': 'bill', 'reason': 'left'},
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.sailorId == 'bill');
    expect(bill.state, VoyageMembershipState.left);
    expect(bill.isIncludedInLiveCount, isFalse);
    // The row stays, and it says when they went (#144): 09:02 for a departure
    // two minutes after this voyage started.
    expect(bill.stateLabel, 'Left the voyage at 09:02');
    expect(bill.leftAt, startedAt.add(const Duration(minutes: 2)));
  });

  test('the roster states the position age in words', () {
    PresenceFreshness? labelFor(PresenceFreshness freshness) => freshness;
    String stateLabelFor(PresenceFreshness freshness) => reduce(
      voyageStartedAt: startedAt,
      events: [
        _joinEvent(
          id: 'joined-bill',
          deviceId: 'bill',
          displayName: 'Bill',
          role: VoyageRole.sailor,
          createdAt: now.subtract(const Duration(seconds: 5)),
        ),
      ],
      livePresence: [
        _presence(
          'bill',
          'Bill',
          freshness: labelFor(freshness)!,
          recordedAt: now.subtract(const Duration(seconds: 5)),
          knownSince: startedAt,
        ),
      ],
    ).firstWhere((entry) => entry.sailorId == 'bill').stateLabel;

    expect(stateLabelFor(PresenceFreshness.live), isNot(contains('position')));
    expect(
      stateLabelFor(PresenceFreshness.ageing),
      contains('position ageing'),
    );
    expect(stateLabelFor(PresenceFreshness.stale), contains('position stale'));
    expect(stateLabelFor(PresenceFreshness.none), contains('no position'));
  });

  test('a sailor with no position at all is reported, not omitted', () {
    final participants = reduce(
      voyageStartedAt: startedAt,
      livePresence: [
        LiveSailorPresence(
          sailorId: 'bill',
          displayName: 'Bill',
          role: VoyageRole.sailor,
          freshness: PresenceFreshness.none,
          sources: const {},
          isLocal: false,
          knownSince: startedAt.add(const Duration(minutes: 9)),
        ),
      ],
    );

    final bill = participants.firstWhere((entry) => entry.sailorId == 'bill');
    expect(bill.positionFreshness, PresenceFreshness.none);
    expect(bill.stateLabel, contains('no position'));
    expect(bill.knownFromRelayOnly, isTrue);
  });

  test('a nearby-only presence records the nearby transport', () {
    final participants = reduce(
      voyageStartedAt: startedAt,
      livePresence: [
        _presence(
          'sam',
          'Sam',
          freshness: PresenceFreshness.live,
          recordedAt: now,
          knownSince: startedAt,
          sources: const {LivePresenceSource.nearbyPresence},
        ),
      ],
    );

    final sam = participants.firstWhere((entry) => entry.sailorId == 'sam');
    expect(sam.transportEvidence, {VoyageTransportEvidence.nearbyRelay});
    expect(sam.transportLabel, 'Nearby relay · joining');
  });

  test('a counted sailor with no presence still states why, not nothing', () {
    final events = [
      _joinEvent(
        id: 'joined-bill',
        deviceId: 'bill',
        displayName: 'Bill',
        role: VoyageRole.sailor,
        createdAt: startedAt.add(const Duration(minutes: 1)),
      ),
    ];

    final participants = reduce(events: events, voyageStartedAt: startedAt);

    final bill = participants.firstWhere((entry) => entry.sailorId == 'bill');
    expect(bill.positionFreshness, isNull);
    // Issue #132: "in the count, no marker, nothing said" is the defect. A
    // sailor with no position always carries the reason there is none.
    expect(bill.positionAbsence, VoyagePositionAbsence.noPositionReported);
    // "Not heard from", not "location is stale": with positions reported on
    // distance travelled and a keep-alive on a timer, an old position is not
    // evidence of absence — silence on every channel is (#166).
    expect(
      bill.stateLabel,
      'Inactive · not heard from · no position reported yet',
    );
    expect(bill.hasStatedPositionState, isTrue);
    expect(bill.knownFromRelayOnly, isFalse);
  });
}

LiveSailorPresence _presence(
  String sailorId,
  String displayName, {
  required PresenceFreshness freshness,
  required DateTime recordedAt,
  required DateTime knownSince,
  Set<LivePresenceSource> sources = const {LivePresenceSource.internetPresence},
}) => LiveSailorPresence(
  sailorId: sailorId,
  displayName: displayName,
  role: VoyageRole.sailor,
  freshness: freshness,
  sources: sources,
  isLocal: false,
  knownSince: knownSince,
  location: SailorLocation(
    sailorId: sailorId,
    displayName: displayName,
    role: VoyageRole.sailor,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -2.4),
      recordedAt: recordedAt,
      accuracyMeters: 5,
    ),
    receivedAt: recordedAt,
  ),
  age: const Duration(seconds: 5),
  // What `LivePresenceReconciler` sets: the newest evidence of this sailor on
  // this device's clock. Presence is contact, and contact is what decides
  // whether a sailor reads as present — not how old their position is (#166).
  contactAt: recordedAt,
);

VoyageEvent _joinEvent({
  required String id,
  required String deviceId,
  required String displayName,
  required VoyageRole role,
  required DateTime createdAt,
}) => _event(
  id: id,
  deviceId: deviceId,
  type: VoyageEventType.sailorJoined,
  createdAt: createdAt,
  payload: {'displayName': displayName, 'role': role.name},
);

VoyageEvent _event({
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: 'voyage-membership-presence',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: unsigned.id,
    voyageId: unsigned.voyageId,
    deviceId: unsigned.deviceId,
    type: unsigned.type,
    priority: unsigned.priority,
    createdAt: unsigned.createdAt,
    payload: unsigned.payload,
    signature: VoyageEventAuthenticator.sign(
      unsigned,
      '0123456789abcdef0123456789abcdef',
    ),
  );
}
