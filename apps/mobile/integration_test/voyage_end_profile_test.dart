// Profiles the end-of-voyage flow (#165) on a physical phone, at the scale a
// real voyage reaches.
//
// Run in release mode so the numbers are the ones a sailor gets:
//
//   flutter test integration_test/voyage_end_profile_test.dart \
//     -d <device-id> --release
//
// This is a measurement harness, not an assertion test - it prints a table and
// only fails if the harness itself breaks. The regression test that guards the
// fix lives in test/services/voyage_end_cost_test.dart and runs on the host.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/geo_point.dart' as sample_geo;
import 'package:tide_and_seek/domain/imported_route.dart' show GeoPoint;
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/voyage/voyage_recap_card.dart';
import 'package:tide_and_seek/services/completed_voyage_archiver.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_lifecycle.dart';
import 'package:tide_and_seek/services/voyage_route_reducer.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_summary_exporter.dart';

/// A two-hour voyage at `geolocator`'s configured `distanceFilter: 10` and an
/// average 50 km/h is ~10,000 fixes for the local sailor alone; every other
/// sailor's fixes arrive as journal events too. 4 sailors is a small group.
const _sailorsInGroup = 4;
const _scales = <int>[500, 2000, 8000, 40000];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final session = VoyageSession(
    voyageId: 'voyage-profile',
    voyageCode: '123456',
    inviteSecret: 'profile-secret',
    joinToken: 'profile-token',
    localSailorId: 'sailor-0',
    displayName: 'Oliver',
    role: VoyageRole.skipper,
    joinedAt: DateTime.utc(2026, 7, 27, 9),
  );

  testWidgets(
    'journal-walk cost by voyage length',
    (tester) async {
      final rows = <String>[];
      for (final scale in _scales) {
        final events = _journal(session, locationEvents: scale);
        final lifecycle = _time(
          () => VoyageLifecycleReducer.fromEvents(
            voyageId: session.voyageId,
            inviteSecret: session.inviteSecret,
            events: events,
          ),
        );
        final route = _time(
          () => const VoyageRouteReducer().fromEvents(
            voyageId: session.voyageId,
            inviteSecret: session.inviteSecret,
            events: events,
          ),
        );
        // The first walk of a journal also pays to verify every signature in
        // it. What matters for responsiveness is the second and every walk
        // after: that is what _rebuildLifecycle() costs on each appended
        // event, and what a rebuild costs on rotation.
        final coldRebuild = lifecycle + route;
        final rebuild =
            _time(
              () => VoyageLifecycleReducer.fromEvents(
                voyageId: session.voyageId,
                inviteSecret: session.inviteSecret,
                events: events,
              ),
            ) +
            _time(
              () => const VoyageRouteReducer().fromEvents(
                voyageId: session.voyageId,
                inviteSecret: session.inviteSecret,
                events: events,
              ),
            );
        const exporter = VoyageSummaryExporter();
        final summarize = _time(
          () => exporter.summarize(
            session,
            events,
            generatedAt: DateTime.utc(2026, 7, 27, 11),
          ),
        );
        final archive = _time(
          () => const CompletedVoyageArchiver().create(
            session: session,
            events: events,
            archivedAt: DateTime.utc(2026, 7, 27, 11),
          ),
        );
        final snapshot = const CompletedVoyageArchiver().create(
          session: session,
          events: events,
          archivedAt: DateTime.utc(2026, 7, 27, 11),
        );
        final encode = _time(() => jsonEncode(snapshot.toJson()));
        rows.add(
          '${_pad(scale)}  coldRebuild=${_ms(coldRebuild)}  '
          'warmRebuild=${_ms(rebuild)}  summarize=${_ms(summarize)}  '
          'archive=${_ms(archive)}  jsonEncode=${_ms(encode)}',
        );
        debugPrint('PROFILE #165 ${rows.last}');
      }
      debugPrint('PROFILE #165 ==== journal walks (events, ms) ====');
      for (final row in rows) {
        debugPrint('PROFILE #165 $row');
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  // The path the device actually takes: a live controller holding a
  // voyage-length journal, doing what it does on every menu build and on every
  // appended event.
  testWidgets(
    'live controller cost at voyage length',
    (tester) async {
      for (final scale in <int>[500, 8000, 40000]) {
        final eventStore = InMemoryEventStore();
        for (final event in _journal(session, locationEvents: scale)) {
          await eventStore.append(event);
        }
        final sessionStore = InMemorySessionStore();
        await sessionStore.save(session);
        final controller = VoyageController(
          eventStore,
          sessionStore,
          NearbyBridge(),
          clock: () => DateTime.utc(2026, 7, 27, 11, 30),
          idFactory: () => 'profile-id-${_sequence++}',
          completedVoyageStore: InMemoryCompletedVoyageStore(),
        );
        final initialize = await _timeAsync(controller.initialize);
        final clear = await _timeAsync(controller.clearEndedVoyage);
        debugPrint(
          'PROFILE #165 ${_pad(scale)}  initialize=${_ms(initialize)}  '
          'clearEndedVoyage=${_ms(clear)}',
        );
        controller.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  testWidgets(
    'recap card paint and 3x rasterise',
    (tester) async {
      for (final scale in <int>[500, 8000, 40000]) {
        final events = _journal(session, locationEvents: scale);
        const exporter = VoyageSummaryExporter();
        final generatedAt = DateTime.utc(2026, 7, 27, 11);
        // What _openRecap() does before the screen even appears.
        final prepare = _time(() {
          exporter.summarize(session, events, generatedAt: generatedAt);
          exporter.traveledRoute(session, events, generatedAt: generatedAt);
        });
        final summary = exporter.summarize(
          session,
          events,
          generatedAt: generatedAt,
        );
        final points =
            exporter
                .traveledRoute(session, events, generatedAt: generatedAt)
                ?.paths
                .single
                .points ??
            const <GeoPoint>[];
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: VoyageRecapCard(
                  summary: summary,
                  routePoints: points,
                  distanceUnit: DistanceUnit.kilometres,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final stopwatch = Stopwatch()..start();
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        stopwatch.stop();
        debugPrint(
          'PROFILE #165 ${_pad(scale)}  recapPrepare=${_ms(prepare)}  '
          'points=${points.length}  toImage+png=${_ms(stopwatch.elapsedMicroseconds)}'
          '  bytes=${bytes!.lengthInBytes}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

var _sequence = 0;

Future<int> _timeAsync(Future<void> Function() body) async {
  final stopwatch = Stopwatch()..start();
  await body();
  stopwatch.stop();
  return stopwatch.elapsedMicroseconds;
}

int _time(void Function() body) {
  final stopwatch = Stopwatch()..start();
  body();
  stopwatch.stop();
  return stopwatch.elapsedMicroseconds;
}

String _ms(int microseconds) => '${(microseconds / 1000).toStringAsFixed(1)}ms';

String _pad(int value) => value.toString().padLeft(6);

/// A signed journal shaped like a real voyage: lifecycle events, then position
/// fixes from every sailor in the group along a plausible track.
List<VoyageEvent> _journal(
  VoyageSession session, {
  required int locationEvents,
}) {
  final events = <VoyageEvent>[
    _signed(
      session,
      id: 'created',
      deviceId: session.localSailorId,
      type: VoyageEventType.voyageCreated,
      createdAt: session.joinedAt,
      payload: {'role': VoyageRole.skipper.name, 'displayName': 'Oliver'},
    ),
    for (var sailor = 1; sailor < _sailorsInGroup; sailor += 1)
      _signed(
        session,
        id: 'joined-$sailor',
        deviceId: 'sailor-$sailor',
        type: VoyageEventType.sailorJoined,
        createdAt: session.joinedAt.add(Duration(minutes: sailor)),
        payload: {
          'role': VoyageRole.sailor.name,
          'displayName': 'Sailor $sailor',
        },
      ),
    _signed(
      session,
      id: 'started',
      deviceId: session.localSailorId,
      type: VoyageEventType.voyageStarted,
      createdAt: session.joinedAt.add(const Duration(minutes: 10)),
      payload: {'skipperSailorId': session.localSailorId},
    ),
  ];
  final startedAt = session.joinedAt.add(const Duration(minutes: 10));
  final perSailor = math.max(1, locationEvents ~/ _sailorsInGroup);
  for (var sailor = 0; sailor < _sailorsInGroup; sailor += 1) {
    for (var index = 0; index < perSailor; index += 1) {
      // ~10 m apart, the configured distanceFilter, tracking north-east.
      final latitude = 51.4600 + index * 0.00006 + sailor * 0.0001;
      final longitude = -2.5000 + index * 0.00009;
      final recordedAt = startedAt.add(Duration(milliseconds: 720 * index));
      events.add(
        _signed(
          session,
          id: 'loc-$sailor-$index',
          deviceId: 'sailor-$sailor',
          type: VoyageEventType.sailorLocationUpdated,
          createdAt: recordedAt,
          payload: {
            'location': SailorLocation(
              sailorId: 'sailor-$sailor',
              displayName: sailor == 0 ? 'Oliver' : 'Sailor $sailor',
              role: sailor == 0 ? VoyageRole.skipper : VoyageRole.sailor,
              sample: LocationSample(
                position: sample_geo.GeoPoint(
                  latitude: latitude,
                  longitude: longitude,
                ),
                recordedAt: recordedAt,
                accuracyMeters: 5,
                speedMetersPerSecond: 13.8,
                headingDegrees: 45,
              ),
              receivedAt: recordedAt,
            ).toJson(),
          },
        ),
      );
    }
  }
  events.add(
    _signed(
      session,
      id: 'ended',
      deviceId: session.localSailorId,
      type: VoyageEventType.voyageEnded,
      createdAt: startedAt.add(const Duration(hours: 2)),
      payload: const {},
    ),
  );
  return events;
}

VoyageEvent _signed(
  VoyageSession session, {
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: session.voyageId,
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
    signature: VoyageEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}
