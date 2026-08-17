// Guards the end-of-voyage cost that made the app unresponsive on a real voyage
// (#165).
//
// These assertions count work rather than measure time. The bug was quadratic —
// every appended event re-authenticated the whole journal — and a count catches
// that exactly, on any machine, where a millisecond threshold on shared CI
// would either flake or be set so loose it proves nothing.
//
// The measured numbers behind the thresholds, from a physical iPhone in profile
// mode at 40,000 events (a two-hour voyage for a group of four):
//
//   _rebuildLifecycle   2,992 ms -> 20 ms   (it runs on every appended event)
//   markingSummary      1,595 ms -> 45 ms   (the dashboard reads it in build)
//   clearEndedVoyage      3,133 ms -> 42 ms
//
// The full profile harness is integration_test/voyage_end_profile_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_lifecycle.dart';
import 'package:tide_and_seek/services/voyage_route_reducer.dart';
import 'package:tide_and_seek/services/voyage_summary_exporter.dart';
import 'package:tide_and_seek/services/trail_display_simplifier.dart';
import 'package:tide_and_seek/domain/imported_route.dart' as route_domain;

void main() {
  final session = VoyageSession(
    voyageId: 'voyage-cost',
    voyageCode: '123456',
    inviteSecret: 'cost-secret',
    joinToken: 'cost-token',
    localSailorId: 'sailor-0',
    displayName: 'Oliver',
    role: VoyageRole.lead,
    joinedAt: DateTime.utc(2026, 7, 27, 9),
  );

  setUp(() => VoyageEventAuthenticator.verificationsComputed = 0);

  group('journal authentication', () {
    test('authenticates each event once however often it is walked', () {
      final events = _journal(session, locationEvents: 400);
      for (var pass = 0; pass < 10; pass += 1) {
        VoyageLifecycleReducer.fromEvents(
          voyageId: session.voyageId,
          inviteSecret: session.inviteSecret,
          events: events,
        );
        const VoyageRouteReducer().fromEvents(
          voyageId: session.voyageId,
          inviteSecret: session.inviteSecret,
          events: events,
        );
      }

      // Twenty walks of the journal, one authentication per event. Before the
      // fix this was events.length * 20.
      expect(VoyageEventAuthenticator.verificationsComputed, events.length);
    });

    test('appending an event authenticates only what is new', () {
      // A realistic voyage, not a fixture: 12,000 fixes is a two-hour voyage at the
      // 10 m platform distance filter. The bug was invisible at fixture scale,
      // which is why it reached a sailor.
      final events = _journal(session, locationEvents: 12000);
      VoyageLifecycleReducer.fromEvents(
        voyageId: session.voyageId,
        inviteSecret: session.inviteSecret,
        events: events,
      );
      VoyageEventAuthenticator.verificationsComputed = 0;

      // What _record() does: append, then rebuild over the whole journal.
      final appended = [
        ...events,
        _locationEvent(session, sailor: 0, index: 400),
      ];
      VoyageLifecycleReducer.fromEvents(
        voyageId: session.voyageId,
        inviteSecret: session.inviteSecret,
        events: appended,
      );

      // The cost of a position fix late in a voyage must be the cost of that fix,
      // not of the voyage so far. This is the quadratic term, and it is what made
      // the phone unusable by the end of a two-hour voyage.
      expect(VoyageEventAuthenticator.verificationsComputed, 1);
    });

    test('a forged event never inherits a verdict', () {
      final authentic = _locationEvent(session, sailor: 0, index: 1);
      expect(
        VoyageEventAuthenticator.verify(authentic, session.inviteSecret),
        isTrue,
      );

      // Same id and same signature, different payload: a different object, so
      // the identity-keyed memo cannot answer for it.
      final forged = VoyageEvent(
        id: authentic.id,
        voyageId: authentic.voyageId,
        deviceId: authentic.deviceId,
        type: authentic.type,
        priority: authentic.priority,
        createdAt: authentic.createdAt,
        expiresAt: authentic.expiresAt,
        payload: const {'location': 'tampered'},
        signature: authentic.signature,
      );

      expect(
        VoyageEventAuthenticator.verify(forged, session.inviteSecret),
        isFalse,
      );
    });

    test('the same event under a different secret is re-authenticated', () {
      final event = _locationEvent(session, sailor: 0, index: 1);
      expect(
        VoyageEventAuthenticator.verify(event, session.inviteSecret),
        isTrue,
      );
      expect(
        VoyageEventAuthenticator.verify(event, 'a-different-voyage'),
        isFalse,
      );
      expect(
        VoyageEventAuthenticator.verify(event, session.inviteSecret),
        isTrue,
      );
    });
  });

  group('voyage end', () {
    test('archiving a voyage walks the journal without re-authenticating it', () {
      final events = _journal(session, locationEvents: 400);
      const exporter = VoyageSummaryExporter();
      final generatedAt = DateTime.utc(2026, 7, 27, 11);
      exporter.summarize(session, events, generatedAt: generatedAt);
      VoyageEventAuthenticator.verificationsComputed = 0;

      // What clearEndedVoyage() reaches: a summary and the travelled route, each
      // of which runs a lifecycle reduction of its own.
      exporter.summarize(session, events, generatedAt: generatedAt);
      exporter.traveledRoute(session, events, generatedAt: generatedAt);

      expect(VoyageEventAuthenticator.verificationsComputed, 0);
    });
  });

  group('trail display bound', () {
    test('a voyage-length trail is bounded, and endpoints are kept', () {
      final points = [
        for (var index = 0; index < 12000; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + index * 0.00006,
            longitude: -2.5 + index * 0.00009,
          ),
      ];

      final simplified = const TrailDisplaySimplifier().simplify(points);

      expect(
        simplified.length,
        lessThanOrEqualTo(TrailDisplaySimplifier.defaultMaximumPoints),
      );
      expect(simplified.first, points.first);
      expect(simplified.last, points.last);
      // A straight run collapses to almost nothing: the cost of drawing a trail
      // must not track how long the sailor has been riding.
      expect(simplified.length, lessThan(50));
    });

    test('a hairpin keeps its shape', () {
      // ~30 m limbs, the tightest case #166 raises. Simplifying must not turn
      // this into a straight line through the apex.
      const metre = 1 / 111132.0;
      final points = <route_domain.GeoPoint>[
        for (var index = 0; index < 15; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + index * 2 * metre,
            longitude: -2.5,
          ),
        for (var index = 0; index < 15; index += 1)
          route_domain.GeoPoint(
            latitude: 51.46 + 30 * metre - index * 2 * metre,
            longitude: -2.5 + 30 * metre,
          ),
      ];

      final simplified = const TrailDisplaySimplifier().simplify(points);

      // The apex and the return leg both survive: a straight-line reduction
      // would leave two or three points.
      expect(simplified.length, greaterThanOrEqualTo(4));
      final apex = simplified
          .map((point) => point.latitude)
          .reduce((left, right) => left > right ? left : right);
      expect(apex, closeTo(51.46 + 30 * metre, 3 * metre));
    });

    test('a trail too short to simplify is returned untouched', () {
      final points = [
        const route_domain.GeoPoint(latitude: 51.46, longitude: -2.5),
        const route_domain.GeoPoint(latitude: 51.47, longitude: -2.5),
      ];

      expect(const TrailDisplaySimplifier().simplify(points), same(points));
    });
  });
}

List<VoyageEvent> _journal(
  VoyageSession session, {
  required int locationEvents,
}) => [
  _signed(
    session,
    id: 'created',
    deviceId: session.localSailorId,
    type: VoyageEventType.voyageCreated,
    createdAt: session.joinedAt,
    payload: {'role': VoyageRole.lead.name, 'displayName': 'Oliver'},
  ),
  _signed(
    session,
    id: 'started',
    deviceId: session.localSailorId,
    type: VoyageEventType.voyageStarted,
    createdAt: session.joinedAt.add(const Duration(minutes: 10)),
    payload: {'skipperSailorId': session.localSailorId},
  ),
  for (var index = 0; index < locationEvents; index += 1)
    _locationEvent(session, sailor: index % 4, index: index),
  _signed(
    session,
    id: 'ended',
    deviceId: session.localSailorId,
    type: VoyageEventType.voyageEnded,
    createdAt: session.joinedAt.add(const Duration(hours: 2)),
    payload: const {},
  ),
];

VoyageEvent _locationEvent(
  VoyageSession session, {
  required int sailor,
  required int index,
}) {
  final recordedAt = session.joinedAt.add(
    Duration(minutes: 10, milliseconds: 720 * index),
  );
  return _signed(
    session,
    id: 'loc-$sailor-$index',
    deviceId: 'sailor-$sailor',
    type: VoyageEventType.sailorLocationUpdated,
    createdAt: recordedAt,
    payload: {
      'location': SailorLocation(
        sailorId: 'sailor-$sailor',
        displayName: sailor == 0 ? 'Oliver' : 'Sailor $sailor',
        role: sailor == 0 ? VoyageRole.lead : VoyageRole.sailor,
        sample: LocationSample(
          position: GeoPoint(
            latitude: 51.46 + index * 0.00006,
            longitude: -2.5 + index * 0.00009,
          ),
          recordedAt: recordedAt,
          accuracyMeters: 5,
        ),
        receivedAt: recordedAt,
      ).toJson(),
    },
  );
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
