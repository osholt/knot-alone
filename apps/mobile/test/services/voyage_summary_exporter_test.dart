import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_summary_exporter.dart';

void main() {
  test('summarizes complete and active marker sessions deterministically', () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _event('1', VoyageEventType.voyageCreated, 10),
      _event('2', VoyageEventType.markerStarted, 11),
      _event(
        '3',
        VoyageEventType.markerPass,
        12,
        payload: const {'sailorId': 'sailor-1'},
      ),
      _event(
        '4',
        VoyageEventType.markerPass,
        13,
        payload: const {'sailorId': 'sailor-1'},
      ),
      _event(
        '5',
        VoyageEventType.markerEnded,
        16,
        payload: const {'uniquePasses': 3},
      ),
      _event('6', VoyageEventType.markerStarted, 20),
    ];
    const exporter = VoyageSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.markerSessions, hasLength(2));
    expect(summary.markerSessions.first.duration, const Duration(minutes: 5));
    expect(summary.markerSessions.first.uniquePassCount, 3);
    expect(summary.markerSessions.first.isComplete, isTrue);
    expect(summary.markerSessions.last.duration, const Duration(minutes: 5));
    expect(summary.markerSessions.last.isComplete, isFalse);
    expect(summary.totalMarkingDuration, const Duration(minutes: 10));
    expect(summary.totalConfirmedPasses, 3);
    expect(
      exporter.toPlainText(summary),
      contains('Time spent marking: 10m 0s'),
    );
    expect(exporter.toCsv(summary), contains('"duration_seconds"'));
    expect(exporter.toCsv(summary), contains('"300","3","true"'));
    expect(exporter.fileName(summary), 'tide-and-seek-abc123-summary.csv');
  });

  test("counts distinct sailors and totals the local sailor's distance", () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _event('1', VoyageEventType.voyageCreated, 10),
      _joinEvent('2', deviceId: 'device-b', minute: 10),
      _locationEvent(
        '3',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 11,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '4',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 12,
        latitude: 53.01,
        longitude: -1,
      ),
      // A different sailor's own location updates count toward the sailor
      // total, but never toward the local sailor's own trail/distance.
      _locationEvent(
        '5',
        deviceId: 'device-b',
        sailorId: 'device-b',
        minute: 12,
        latitude: 60,
        longitude: 5,
      ),
    ];
    const exporter = VoyageSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.sailorCount, 2);
    expect(summary.totalDistanceMeters, closeTo(1111.95, 1));
    expect(exporter.toCsv(summary), contains('"sailor_count","2"'));
    expect(
      exporter.toPlainText(summary),
      contains('Sailors on this voyage: 2'),
    );
  });

  test("builds a GPX track from the local sailor's own trail", () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _locationEvent(
        '1',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 11,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '2',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 12,
        latitude: 53.01,
        longitude: -1,
      ),
    ];
    const exporter = VoyageSummaryExporter();

    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNotNull);
    expect(route!.paths, hasLength(1));
    expect(route.paths.single.points, hasLength(2));
    expect(route.paths.single.points.first.latitude, 53);
    expect(route.paths.single.points.last.latitude, 53.01);
  });

  test('breaks and excludes distance across a missing location interval', () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _locationEvent(
        '1',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 1,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        '2',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 2,
        latitude: 53.001,
        longitude: -1,
      ),
      _locationEvent(
        '3',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 22,
        latitude: 54,
        longitude: -2,
      ),
      _locationEvent(
        '4',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 23,
        latitude: 54.001,
        longitude: -2,
      ),
    ];
    const exporter = VoyageSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNotNull);
    expect(route!.paths, hasLength(2));
    expect(route.paths.map((path) => path.points.length), const [2, 2]);
    expect(
      summary.totalDistanceMeters,
      closeTo(222, 5),
      reason: 'the unknown cross-country section must not count as travel',
    );
  });

  test('duration and traveled trace begin at the authoritative start', () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      _signedEvent(
        _event(
          'created',
          VoyageEventType.voyageCreated,
          10,
          payload: const {'displayName': 'Oliver', 'role': 'lead'},
        ),
        session.inviteSecret,
      ),
      _locationEvent(
        'early',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 11,
        latitude: 52,
        longitude: -1,
      ),
      _signedEvent(
        _event(
          'started',
          VoyageEventType.voyageStarted,
          12,
          payload: const {'skipperSailorId': 'device-a'},
        ),
        session.inviteSecret,
      ),
      _locationEvent(
        'after-1',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 13,
        latitude: 53,
        longitude: -1,
      ),
      _locationEvent(
        'after-2',
        deviceId: 'device-a',
        sailorId: 'device-a',
        minute: 14,
        latitude: 53.01,
        longitude: -1,
      ),
    ];
    const exporter = VoyageSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 22),
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 22),
    );

    expect(summary.startedAt, DateTime.utc(2026, 7, 16, 10, 12));
    expect(summary.voyageDuration, const Duration(minutes: 10));
    expect(summary.totalDistanceMeters, closeTo(1111.95, 1));
    expect(route!.paths.single.points, hasLength(2));
    expect(route.paths.single.points.first.latitude, 53);
  });

  test('traveledRoute returns null without at least two position fixes', () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    const exporter = VoyageSummaryExporter();

    final route = exporter.traveledRoute(
      session,
      const [],
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(route, isNull);
  });

  test('ignores malformed location payloads instead of failing the export', () {
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );
    final events = [
      VoyageEvent(
        id: '1',
        voyageId: 'voyage-1',
        deviceId: 'device-a',
        type: VoyageEventType.sailorLocationUpdated,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16, 10, 11),
        payload: const {
          'location': {'sample': 'not-a-map'},
        },
        signature: 'test',
      ),
    ];
    const exporter = VoyageSummaryExporter();

    final summary = exporter.summarize(
      session,
      events,
      generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
    );

    expect(summary.totalDistanceMeters, 0);
    expect(
      exporter.traveledRoute(
        session,
        events,
        generatedAt: DateTime.utc(2026, 7, 16, 10, 25),
      ),
      isNull,
    );
  });

  // The decisive experiment for #299: "in single sailor mode it forgets your
  // track after a while and then doesn't save the voyage properly when you end
  // it." A recap shared the same day proved a 20-minute group voyage saves fine,
  // and location events carry a 30-minute expiry, so the question is whether a
  // voyage longer than that keeps its whole track through the save.
  //
  // Run here rather than on a bike: the saved track is derived purely from the
  // event log, so a 90-minute voyage can be constructed exactly.
  group('a long solo voyage with no route', () {
    const exporter = VoyageSummaryExporter();
    final session = VoyageSession(
      voyageId: 'voyage-1',
      voyageCode: 'ABC123',
      inviteSecret: 'secret',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'device-a',
      displayName: 'Oliver',
      // Solo: the sailor creates the voyage, so they lead it.
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 16, 9, 55),
    );

    /// Ninety minutes of riding, one fix a minute, and no route anywhere.
    List<VoyageEvent> ninetyMinutesOfRiding() => [
      _event('created', VoyageEventType.voyageCreated, 0),
      _event('started', VoyageEventType.voyageStarted, 1),
      for (var minute = 1; minute <= 90; minute += 1)
        _locationEvent(
          'fix-$minute',
          deviceId: 'device-a',
          sailorId: 'device-a',
          minute: minute,
          latitude: 51.45 + minute * 0.001,
          longitude: -2.47 + minute * 0.001,
        ),
      _event('ended', VoyageEventType.voyageEnded, 91),
    ];

    test('the whole track survives, not just the last 30 minutes', () {
      final track = exporter.traveledRoute(
        session,
        ninetyMinutesOfRiding(),
        generatedAt: DateTime.utc(2026, 7, 16, 11, 31),
      );

      expect(track, isNotNull, reason: 'a 90-minute voyage must save a track');
      final points = track!.paths.expand((path) => path.points).toList();
      expect(
        points.length,
        90,
        reason:
            'every recorded fix belongs in the saved voyage; anything near 30 '
            'would mean the 30-minute event expiry reaches the saved track',
      );
      // The earliest fix is still the first minute, not a rolling window.
      // Compared in UTC because the exporter converts to local time, and a test
      // that only passes in one timezone is worse than no test.
      expect(
        points.first.recordedAt?.toUtc(),
        DateTime.utc(2026, 7, 16, 10, 1),
      );
      expect(
        points.last.recordedAt?.toUtc(),
        DateTime.utc(2026, 7, 16, 11, 30),
      );
    });

    test('the summary reports the full duration and a distance', () {
      final summary = exporter.summarize(
        session,
        ninetyMinutesOfRiding(),
        generatedAt: DateTime.utc(2026, 7, 16, 11, 31),
      );

      // startedAt is non-nullable; only endedAt can be absent, and a voyage that
      // was ended must have it.
      expect(summary.endedAt, isNotNull);
      expect(
        summary.endedAt!.difference(summary.startedAt).inMinutes,
        greaterThanOrEqualTo(89),
      );
      expect(summary.totalDistanceMeters, greaterThan(0));
    });
  });
}

VoyageEvent _joinEvent(
  String id, {
  required String deviceId,
  required int minute,
}) => VoyageEvent(
  id: id,
  voyageId: 'voyage-1',
  deviceId: deviceId,
  type: VoyageEventType.sailorJoined,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10, minute),
  payload: const {},
  signature: 'test',
);

VoyageEvent _locationEvent(
  String id, {
  required String deviceId,
  required String sailorId,
  required int minute,
  required double latitude,
  required double longitude,
}) {
  final location = SailorLocation(
    sailorId: sailorId,
    displayName: sailorId,
    role: VoyageRole.sailor,
    sample: LocationSample(
      position: GeoPoint(latitude: latitude, longitude: longitude),
      recordedAt: DateTime.utc(2026, 7, 16, 10, minute),
      accuracyMeters: 5,
    ),
    receivedAt: DateTime.utc(2026, 7, 16, 10, minute),
  );
  return VoyageEvent(
    id: id,
    voyageId: 'voyage-1',
    deviceId: deviceId,
    type: VoyageEventType.sailorLocationUpdated,
    priority: EventPriority.routine,
    createdAt: DateTime.utc(2026, 7, 16, 10, minute),
    payload: {'location': location.toJson()},
    signature: 'test',
  );
}

VoyageEvent _event(
  String id,
  VoyageEventType type,
  int minute, {
  Map<String, Object?> payload = const {},
}) => VoyageEvent(
  id: id,
  voyageId: 'voyage-1',
  deviceId: 'device-a',
  type: type,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10, minute),
  payload: payload,
  signature: 'test',
);

VoyageEvent _signedEvent(VoyageEvent event, String secret) => VoyageEvent(
  id: event.id,
  voyageId: event.voyageId,
  deviceId: event.deviceId,
  type: event.type,
  priority: event.priority,
  createdAt: event.createdAt,
  payload: event.payload,
  signature: VoyageEventAuthenticator.sign(event, secret),
);
