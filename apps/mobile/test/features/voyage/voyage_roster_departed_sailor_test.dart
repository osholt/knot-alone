import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/voyage/voyage_roster_sheet.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';

/// Issue #144 from the skipper's side. The field report is about this screen:
/// "It also removed the data from the voyage roster list. It would be good to keep
/// that until at least the end of the voyage just in case something came up like a
/// lost item etc."
///
/// So the row survives the departure, reads as its own state with a time, and
/// carries the sailor's last known position — while the live count on the same
/// screen still excludes them.
void main() {
  late InMemoryEventStore eventStore;
  late VoyageController controller;
  final startedAt = DateTime.utc(2026, 7, 26, 14);

  setUp(() async {
    eventStore = InMemoryEventStore();
    var id = 0;
    controller = VoyageController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => startedAt.add(const Duration(minutes: 40)),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(11),
      voyageCodeDirectory: _NullVoyageCodeDirectory(),
    );
    await controller.initialize();
    await controller.createVoyage('Lead');
    final session = controller.session!;
    for (final event in [
      _signed(
        session: session,
        id: 'join-bill',
        deviceId: 'bill',
        type: VoyageEventType.sailorJoined,
        createdAt: startedAt,
        payload: const {'displayName': 'Bill', 'role': 'sweeper'},
      ),
      _signed(
        session: session,
        id: 'location-bill',
        deviceId: 'bill',
        type: VoyageEventType.sailorLocationUpdated,
        createdAt: startedAt.add(const Duration(minutes: 20)),
        payload: {
          'location': SailorLocation(
            sailorId: 'bill',
            displayName: 'Bill',
            role: VoyageRole.sweeper,
            sample: LocationSample(
              position: const GeoPoint(latitude: 51.20011, longitude: -2.40022),
              recordedAt: startedAt.add(const Duration(minutes: 20)),
              accuracyMeters: 6,
            ),
            receivedAt: startedAt.add(const Duration(minutes: 20)),
          ).toJson(),
        },
      ),
      _signed(
        session: session,
        id: 'left-bill',
        deviceId: 'bill',
        type: VoyageEventType.sailorLeft,
        createdAt: startedAt.add(const Duration(minutes: 32)),
        payload: const {
          'sailorId': 'bill',
          'displayName': 'Bill',
          'reason': 'left',
        },
      ),
    ]) {
      await eventStore.append(event);
    }
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness() => MaterialApp(
    home: Scaffold(body: VoyageRosterSheet(controller: controller)),
  );

  testWidgets('a departed sailor is kept, and said to be kept', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // The live count excludes them the moment they leave; the record does not.
    expect(find.text('1 currently included · 2 recorded'), findsOneWidget);
    expect(find.byKey(const Key('roster-sailor-bill')), findsNothing);
    expect(find.byKey(const Key('roster-departed-notice')), findsOneWidget);
    expect(
      find.textContaining('record is kept until this voyage ends'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('roster-show-departed')));
    await tester.pumpAndSettle();

    // The row itself: its own state with a time, the retained role, and where
    // Bill was last known to be.
    expect(find.byKey(const Key('roster-sailor-bill')), findsOneWidget);
    expect(
      find.textContaining('Sweeper · Left the voyage at 14:32'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Last known position 51.20011, -2.40022'),
      findsOneWidget,
    );
    // Nothing on a departed row invites an action on a sailor who is not there.
    expect(find.byKey(const Key('ask-sweeper-bill')), findsNothing);
    // Now that they are on screen, the notice has nothing left to say.
    expect(find.byKey(const Key('roster-departed-notice')), findsNothing);
  });

  testWidgets('the departed row is in the full roster too, and last', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.text('All joined'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('roster-sailor-bill')), findsOneWidget);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles, hasLength(2));
    expect(
      (tiles.last.key as ValueKey<String>).value,
      'roster-sailor-bill',
      reason: 'sailors still in the voyage come first',
    );
  });

  testWidgets('the accessible label states the departure, not a colour', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('roster-show-departed')));
    await tester.pumpAndSettle();

    final semantics = tester.getSemantics(
      find.byKey(const Key('roster-sailor-bill')),
    );
    expect(semantics.label, contains('Left the voyage at 14:32'));
    expect(semantics.label, contains('Last known position'));
  });
}

VoyageEvent _signed({
  required VoyageSession session,
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
    id: id,
    voyageId: session.voyageId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: VoyageEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullVoyageCodeDirectory implements VoyageCodeDirectory {
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
