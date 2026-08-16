import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/marker_statistics.dart';

void main() {
  final start = DateTime.utc(2026, 7, 16, 12);

  test('interleaved marker devices remain isolated by session and device', () {
    final events = [
      _event(
        id: 'a-start',
        device: 'marker-a',
        type: RideEventType.markerStarted,
        at: start,
        payload: const {
          'markerSessionId': 'shared-session',
          'mode': 'assisted-confirmed',
        },
      ),
      _event(
        id: 'b-start',
        device: 'marker-b',
        type: RideEventType.markerStarted,
        at: start.add(const Duration(minutes: 1)),
        payload: const {'markerSessionId': 'shared-session', 'mode': 'manual'},
      ),
      _pass(
        id: 'a-pass',
        device: 'marker-a',
        session: 'shared-session',
        rider: 'rider-1',
        at: start.add(const Duration(minutes: 2)),
      ),
      _pass(
        id: 'b-pass',
        device: 'marker-b',
        session: 'shared-session',
        rider: 'rider-2',
        at: start.add(const Duration(minutes: 3)),
      ),
      _pass(
        id: 'a-duplicate',
        device: 'marker-a',
        session: 'shared-session',
        rider: 'rider-1',
        at: start.add(const Duration(minutes: 4)),
      ),
      _pass(
        id: 'b-tec',
        device: 'marker-b',
        session: 'shared-session',
        rider: 'tec',
        at: start.add(const Duration(minutes: 5)),
        role: 'tailEndCharlie',
      ),
      _end(
        id: 'a-end',
        device: 'marker-a',
        session: 'shared-session',
        at: start.add(const Duration(minutes: 6)),
      ),
      _end(
        id: 'b-end',
        device: 'marker-b',
        session: 'shared-session',
        at: start.add(const Duration(minutes: 7)),
      ),
    ];

    final all = MarkerStatistics.fromEvents(
      events,
      asOf: start.add(const Duration(minutes: 8)),
    );
    expect(all.sessions, hasLength(2));
    expect(all.sessions[0].markerDeviceId, 'marker-a');
    expect(all.sessions[0].uniquePassCount, 1);
    expect(all.sessions[0].tecPassedAt, isNull);
    expect(all.sessions[1].markerDeviceId, 'marker-b');
    expect(all.sessions[1].uniquePassCount, 2);
    expect(all.sessions[1].tecPassedAt, isNotNull);

    final local = MarkerStatistics.fromEvents(
      events,
      asOf: start.add(const Duration(minutes: 8)),
      markerDeviceId: 'marker-a',
    );
    expect(local.sessions, hasLength(1));
    expect(local.verifiedPassCount, 1);
    expect(local.totalMarkingTime, const Duration(minutes: 6));
  });

  test('TEC is only recognised from authenticated location evidence', () {
    final events = [
      _event(
        id: 'start',
        device: 'marker',
        type: RideEventType.markerStarted,
        at: start,
        payload: const {'markerSessionId': 'session', 'mode': 'manual'},
      ),
      _event(
        id: 'unverified-tec',
        device: 'marker',
        type: RideEventType.markerPass,
        at: start.add(const Duration(minutes: 1)),
        payload: const {
          'markerSessionId': 'session',
          'riderId': 'tec',
          'role': 'tailEndCharlie',
          'authenticated': false,
        },
      ),
    ];

    final summary = MarkerStatistics.fromEvents(events, asOf: start);
    expect(summary.sessions.single.uniquePassCount, 1);
    expect(summary.sessions.single.verifiedPassCount, 0);
    expect(summary.sessions.single.tecPassedAt, isNull);
  });

  test('evidence event must belong to the passed rider when supplied', () {
    final events = [
      _event(
        id: 'start',
        device: 'marker',
        type: RideEventType.markerStarted,
        at: start,
        payload: const {'markerSessionId': 'session', 'mode': 'manual'},
      ),
      _pass(
        id: 'pass',
        device: 'marker',
        session: 'session',
        rider: 'rider-a',
        at: start.add(const Duration(seconds: 10)),
      ),
    ];

    final summary = MarkerStatistics.fromEvents(
      events,
      asOf: start,
      authenticatedLocationEvidence: const {'location-pass': 'different-rider'},
    );
    expect(summary.sessions.single.uniquePassCount, 1);
    expect(summary.sessions.single.verifiedPassCount, 0);
  });

  test('summary JSON preserves session metrics', () {
    final summary = RideMarkingSummary(
      asOf: start.add(const Duration(minutes: 2)),
      sessions: [
        MarkerSessionSummary(
          sessionId: 'session',
          markerDeviceId: 'marker',
          startedAt: start,
          endedAt: start.add(const Duration(minutes: 2)),
          mode: 'manual',
          uniquePassCount: 2,
          uniqueRiderIds: const ['a', 'b'],
          verifiedPassCount: 1,
          verifiedRiderIds: const ['a'],
          tecPassedAt: start.add(const Duration(minutes: 1)),
        ),
      ],
    );

    final restored = RideMarkingSummary.fromJson(summary.toJson());
    expect(restored.sessions.single.sessionId, 'session');
    expect(restored.sessions.single.uniqueRiderIds, ['a', 'b']);
    expect(restored.totalMarkingTime, const Duration(minutes: 2));
  });
}

RideEvent _pass({
  required String id,
  required String device,
  required String session,
  required String rider,
  required DateTime at,
  String role = 'rider',
}) => _event(
  id: id,
  device: device,
  type: RideEventType.markerPass,
  at: at,
  payload: {
    'markerSessionId': session,
    'riderId': rider,
    'role': role,
    'authenticated': true,
    'evidenceEventId': 'location-$id',
  },
);

RideEvent _end({
  required String id,
  required String device,
  required String session,
  required DateTime at,
}) => _event(
  id: id,
  device: device,
  type: RideEventType.markerEnded,
  at: at,
  payload: {'markerSessionId': session},
);

RideEvent _event({
  required String id,
  required String device,
  required RideEventType type,
  required DateTime at,
  required Map<String, Object?> payload,
}) => RideEvent(
  id: id,
  rideId: 'ride',
  deviceId: device,
  type: type,
  priority: EventPriority.routine,
  createdAt: at,
  payload: payload,
  signature: 'test',
);
