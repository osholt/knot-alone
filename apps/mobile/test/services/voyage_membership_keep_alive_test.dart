import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/position_report_policy.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

/// The #166 guarantee that #27 and #144 must survive: a sailor who has stopped
/// moving is still there.
///
/// These tests drive the real [PositionReportGate] rather than hand-written
/// events, because the thing that could regress is the *coupling* — a keep-alive
/// interval that drifts past `inactiveAfter`, or a membership rule that goes back
/// to reading a position's age as evidence of absence. Both layers have to be in
/// the test or neither is protected.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const voyageId = 'voyage-166';
  final startedAt = DateTime.utc(2026, 7, 27, 10);

  List<VoyageParticipant> reduce({
    required List<VoyageEvent> events,
    required DateTime now,
    List<LiveSailorPresence> livePresence = const [],
  }) => const VoyageMembershipReducer().fromEvents(
    voyageId: voyageId,
    inviteSecret: secret,
    events: events,
    now: now,
    localSailorId: 'skipper',
    localDisplayName: 'Lead',
    localRole: VoyageRole.lead,
    localJoinedAt: startedAt,
    localMotorcycleStyle: motorcycleIconStyleDefault,
    localSailorColor: sailorColorDefault,
    voyageStartedAt: startedAt,
    livePresence: livePresence,
  );

  test('a stationary sailor stays active for an hour on keep-alives alone', () {
    final events = [
      _join(voyageId: voyageId, secret: secret, at: startedAt),
      // A phone parked at a cafe for an hour. Every event here is a keep-alive:
      // the gate produced none of them because the sailor moved.
      ..._journalledPositions(
        voyageId: voyageId,
        secret: secret,
        fixes: _stationaryFixes(seconds: 3600, from: startedAt),
      ),
    ];

    // Every reported event is a keep-alive, so nothing in this journal claims
    // movement.
    expect(events.length - 1, 240);

    // Sampled across the whole hour, including the moments between keep-alives.
    for (var second = 30; second <= 3600; second += 30) {
      final sailor = reduce(
        events: events,
        now: startedAt.add(Duration(seconds: second)),
      ).singleWhere((participant) => participant.sailorId == 'parked');
      expect(
        sailor.state,
        VoyageMembershipState.active,
        reason: '$second s into the stop',
      );
      expect(sailor.isIncludedInLiveCount, isTrue);
    }
  });

  test('a sailor whose keep-alives stop does become inactive', () {
    // The other half of the guarantee: silence still means something. Without
    // this the change would make every sailor permanently active and #27's
    // lifecycle would be decoration.
    final events = [
      _join(voyageId: voyageId, secret: secret, at: startedAt),
      ..._journalledPositions(
        voyageId: voyageId,
        secret: secret,
        fixes: _stationaryFixes(seconds: 60, from: startedAt),
      ),
    ];

    VoyageParticipant sailorAt(Duration elapsed) => reduce(
      events: events,
      now: startedAt.add(elapsed),
    ).singleWhere((participant) => participant.sailorId == 'parked');

    expect(
      sailorAt(const Duration(minutes: 1)).state,
      VoyageMembershipState.active,
    );
    // The last keep-alive was at 45 s, so two minutes after it the sailor has
    // been silent for longer than `inactiveAfter`.
    expect(
      sailorAt(const Duration(minutes: 3)).state,
      VoyageMembershipState.inactive,
    );
    expect(
      sailorAt(const Duration(minutes: 3)).stateLabel,
      startsWith('Inactive · not heard from'),
    );
  });

  test('presence contact keeps a sailor active when their position is old', () {
    // The membership rule that had to change. A peer republishing an unchanged
    // position is in contact *now*; dating that contact to when the position was
    // recorded would read a parked sailor as one who had gone.
    final events = [_join(voyageId: voyageId, secret: secret, at: startedAt)];

    VoyageParticipant sailorAt(Duration elapsed) {
      final now = startedAt.add(elapsed);
      return reduce(
        events: events,
        now: now,
        livePresence: [
          _parkedPresence(
            knownSince: startedAt,
            // The position is as old as the stop, and correct: they have not
            // moved a metre since they reported it.
            recordedAt: startedAt,
            // Contact is four seconds ago, because the presence poll is a timer.
            contactAt: now.subtract(const Duration(seconds: 4)),
          ),
        ],
      ).singleWhere((participant) => participant.sailorId == 'parked');
    }

    expect(
      sailorAt(const Duration(minutes: 30)).state,
      VoyageMembershipState.active,
    );
    // And past `expireAfter`, which is the case that would have caught a rule
    // reading the position's own timestamp: thirteen hours of standing still must
    // not expire a sailor who never stopped reporting.
    expect(
      sailorAt(const Duration(hours: 13)).state,
      VoyageMembershipState.active,
    );
  });
}

/// A relay-stamped presence entry for a sailor who is parked and still
/// republishing, as `LivePresenceReconciler` would produce it.
LiveSailorPresence _parkedPresence({
  required DateTime knownSince,
  required DateTime recordedAt,
  required DateTime contactAt,
}) => LiveSailorPresence(
  sailorId: 'parked',
  displayName: 'Parked',
  role: VoyageRole.sailor,
  freshness: PresenceFreshness.live,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: knownSince,
  location: SailorLocation(
    sailorId: 'parked',
    displayName: 'Parked',
    role: VoyageRole.sailor,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -2.4),
      recordedAt: recordedAt,
      accuracyMeters: 5,
    ),
    receivedAt: recordedAt,
  ),
  age: const Duration(seconds: 4),
  contactAt: contactAt,
);

/// A phone that is not moving but whose receiver wanders enough to keep the OS
/// delivering.
List<LocationSample> _stationaryFixes({
  required int seconds,
  required DateTime from,
}) => [
  for (var second = 0; second < seconds; second += 1)
    LocationSample(
      position: GeoPoint(
        latitude: 51.5 + 6 * math.cos(second * 1.9) / 111132,
        longitude: -2.4 + 6 * math.sin(second * 1.9) / 69163,
      ),
      recordedAt: from.add(Duration(seconds: second)),
      accuracyMeters: 5,
      speedMetersPerSecond: 0,
    ),
];

/// The fixes the gate agreed to report, as signed journal events — the same path
/// the voyage shell takes.
List<VoyageEvent> _journalledPositions({
  required String voyageId,
  required String secret,
  required List<LocationSample> fixes,
}) {
  final gate = PositionReportGate();
  final events = <VoyageEvent>[];
  for (final fix in fixes) {
    final reason = gate.consider(fix);
    if (reason == null) continue;
    // Nothing in this journal may claim the sailor moved.
    expect(reason.isMovement, isFalse);
    events.add(
      _signed(
        voyageId: voyageId,
        secret: secret,
        id: 'position-${events.length}',
        deviceId: 'parked',
        type: VoyageEventType.sailorLocationUpdated,
        createdAt: fix.recordedAt,
        payload: {
          'location': SailorLocation(
            sailorId: 'parked',
            displayName: 'Parked',
            role: VoyageRole.sailor,
            sample: fix,
            receivedAt: fix.recordedAt,
          ).toJson(),
        },
      ),
    );
  }
  return events;
}

VoyageEvent _join({
  required String voyageId,
  required String secret,
  required DateTime at,
}) => _signed(
  voyageId: voyageId,
  secret: secret,
  id: 'join-parked',
  deviceId: 'parked',
  type: VoyageEventType.sailorJoined,
  createdAt: at,
  payload: const {'displayName': 'Parked', 'role': 'sailor'},
);

VoyageEvent _signed({
  required String voyageId,
  required String secret,
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: voyageId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: id,
    voyageId: voyageId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: VoyageEventAuthenticator.sign(unsigned, secret),
  );
}
