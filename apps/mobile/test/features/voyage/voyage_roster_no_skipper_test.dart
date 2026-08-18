// The roster's side of #176: a running voyage whose skipper has gone.
//
//   "No option to assign, have I left? Did you get informed? Is someone else a
//    lead now?"
//   "The voyage seems to continue quite happily without a skipper."
//
// The notice offers the role rather than assigning it. Roles are self-selected -
// the precedent #128 set for the TEC, where the skipper asks and the target's own
// `roleChanged` is what counts - so the app cannot pick a skipper on the strength
// of who happens to be nearest the front.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/voyage/voyage_roster_sheet.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';

void main() {
  late InMemoryEventStore eventStore;
  late VoyageController controller;
  final startedAt = DateTime.utc(2026, 7, 27, 14);

  setUp(() async {
    eventStore = InMemoryEventStore();
    var id = 0;
    controller = VoyageController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => startedAt.add(const Duration(minutes: 30)),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(13),
      voyageCodeDirectory: _NullVoyageCodeDirectory(),
    );
    await controller.initialize();
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    final session = controller.session!;
    await eventStore.append(
      _signed(
        session: session,
        id: 'join-kate',
        deviceId: 'kate',
        type: VoyageEventType.sailorJoined,
        createdAt: startedAt,
        payload: const {'displayName': 'Kate', 'role': 'sailor'},
      ),
    );
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness() => MaterialApp(
    home: Scaffold(body: VoyageRosterSheet(controller: controller)),
  );

  testWidgets('no notice while somebody holds the lead', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('roster-missing-skipper-notice')),
      findsNothing,
    );
  });

  testWidgets('the notice appears once the voyage has no skipper', (
    tester,
  ) async {
    await controller.setRole(VoyageRole.sailor);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('roster-missing-skipper-notice')),
      findsOneWidget,
    );
    expect(find.text('This voyage has no skipper'), findsOneWidget);
    // States the consequences rather than only the fact.
    expect(find.textContaining('setting the pace'), findsOneWidget);
    expect(find.textContaining('Sweeper has no line'), findsOneWidget);
    expect(find.textContaining('route changes'), findsOneWidget);
  });

  testWidgets('taking the lead records it and closes the roster', (
    tester,
  ) async {
    await controller.setRole(VoyageRole.sailor);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('roster-take-the-lead-button')));
    await tester.pumpAndSettle();

    expect(controller.session?.role, VoyageRole.skipper);
    expect(controller.voyageHasNoSkipper, isFalse);
    expect(controller.skipperSailorId, controller.session!.localSailorId);
    // Recorded as this sailor's own role change, which is what makes it
    // authoritative for every other device.
    final roleChanges = controller.events.where(
      (event) => event.type == VoyageEventType.roleChanged,
    );
    expect(roleChanges.last.deviceId, controller.session!.localSailorId);
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
    priority: EventPriority.important,
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
