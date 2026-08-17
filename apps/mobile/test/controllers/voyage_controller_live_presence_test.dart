import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';

/// A join must reach the skipper's roster without waiting for the bulk event
/// batch: the field report in issue #99 had a joiner the skipper never saw at all.
void main() {
  final now = DateTime.utc(2026, 7, 25, 9);
  late VoyageController controller;
  late int id;

  setUp(() async {
    id = 0;
    controller = VoyageController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(42),
      voyageCodeDirectory: _UnusedVoyageCodeDirectory(),
    );
    await controller.initialize();
    await controller.createVoyage('Oliver');
  });

  tearDown(() => controller.dispose());

  test('a presence-only sailor joins the roster and notifies listeners', () {
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([_presence('bill', 'Bill', now)]);

    expect(notifications, 1);
    final bill = controller.participants.firstWhere(
      (participant) => participant.sailorId == 'bill',
    );
    expect(bill.displayName, 'Bill');
    expect(bill.knownFromRelayOnly, isTrue);
    expect(controller.liveParticipants.length, 2);
  });

  test('an unchanged observation does not churn listeners', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([_presence('bill', 'Bill', now)]);

    expect(notifications, 0);
    expect(controller.livePresence.single.sailorId, 'bill');
  });

  test('a freshness change is observed and stated in the roster', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([
      _presence('bill', 'Bill', now, freshness: PresenceFreshness.stale),
    ]);

    expect(notifications, 1);
    final bill = controller.participants.firstWhere(
      (participant) => participant.sailorId == 'bill',
    );
    expect(bill.positionFreshness, PresenceFreshness.stale);
    expect(bill.stateLabel, contains('position stale'));
  });

  test('a newer sample for the same sailor is observed', () {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    controller.observeLivePresence([
      _presence('bill', 'Bill', now.add(const Duration(seconds: 4))),
    ]);

    expect(notifications, 1);
  });

  test('presence is discarded when the voyage is left', () async {
    controller.observeLivePresence([_presence('bill', 'Bill', now)]);
    expect(controller.livePresence, isNotEmpty);

    await controller.leaveVoyage();

    expect(controller.livePresence, isEmpty);
    expect(controller.participants, isEmpty);
  });

  /// Issue #144: the departure propagated correctly and then erased the record.
  /// The relay's roster keeps naming a sailor who has left, which is how the row
  /// survives even when their membership events never reached this journal.
  group('a departed sailor stays in the roster', () {
    test('the row remains, out of the live count, and says when', () {
      controller.observeLivePresence([_presence('bill', 'Bill', now)]);
      expect(controller.liveParticipants.length, 2);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      // What the relay reports the moment Bill leaves: no live presence for
      // him, and a roster that still names him as departed.
      controller.observeLivePresence(
        const [],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );

      expect(notifications, 1);
      final bill = controller.participants.singleWhere(
        (participant) => participant.sailorId == 'bill',
      );
      expect(bill.hasLeft, isTrue);
      expect(bill.stateLabel, 'Left the voyage at 09:12');
      expect(bill.displayName, 'Bill');
      // Out of the live group immediately, and off the map with it.
      expect(controller.liveParticipants.length, 1);
      expect(controller.liveView.renderedPositions, isEmpty);
      expect(controller.liveView.isReconciled, isTrue);
    });

    test('a roster-only departure still reaches the roster', () {
      controller.observeLivePresence([_presence('bill', 'Bill', now)]);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      // The positions are unchanged; only the roster moved. The old no-churn
      // check compared positions alone, so this notified nobody.
      controller.observeLivePresence(
        [_presence('bill', 'Bill', now)],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );

      expect(notifications, 1);
    });

    test('the record goes when the voyage goes, and not before', () async {
      controller.observeLivePresence(
        const [],
        roster: [
          _rosterMember(
            'bill',
            'Bill',
            joinedAt: now,
            left: true,
            leftAt: now.add(const Duration(minutes: 12)),
          ),
        ],
      );
      expect(
        controller.participants.where(
          (participant) => participant.sailorId == 'bill',
        ),
        hasLength(1),
      );

      await controller.startVoyage();
      await controller.endVoyage();

      // Ending the voyage does not remove the record: the voyage's own data is still
      // here for its retention window, and so is the sailor who left.
      expect(
        controller.participants.where(
          (participant) => participant.sailorId == 'bill',
        ),
        hasLength(1),
        reason: 'the lost-item lookup happens after the voyage, not during it',
      );

      await controller.clearEndedVoyage();

      // Removing the voyage removes the record with it. There is nowhere else it
      // is kept.
      expect(controller.participants, isEmpty);
      expect(controller.session, isNull);
    });
  });
}

PresenceRosterMember _rosterMember(
  String sailorId,
  String displayName, {
  required DateTime joinedAt,
  bool left = false,
  DateTime? leftAt,
}) => PresenceRosterMember(
  sailorId: sailorId,
  displayName: displayName,
  role: VoyageRole.sailor,
  joinedAt: joinedAt,
  left: left,
  leftAt: leftAt,
);

LiveSailorPresence _presence(
  String sailorId,
  String displayName,
  DateTime recordedAt, {
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveSailorPresence(
  sailorId: sailorId,
  displayName: displayName,
  role: VoyageRole.sailor,
  freshness: freshness,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: recordedAt,
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
  age: Duration.zero,
);

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _UnusedVoyageCodeDirectory implements VoyageCodeDirectory {
  @override
  Future<void> register(VoyageSession session) async {}

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async =>
      throw const VoyageCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}
