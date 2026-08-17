import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/features/voyage/voyage_roster_sheet.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/sweeper_role_assignment.dart';

/// Issue #128 part 1 from the skipper's side: the roster is where a skipper closes
/// the TEC gap, and it must never claim the gap is closed before the sailor has
/// accepted.
void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late VoyageController controller;
  final now = DateTime.utc(2026, 7, 26, 12);

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    var id = 0;
    controller = VoyageController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(7),
      voyageCodeDirectory: _NullVoyageCodeDirectory(),
    );
    await controller.initialize();
    await controller.createVoyage('Lead');
    final session = controller.session!;
    final join = VoyageEvent(
      id: 'join-bill',
      voyageId: session.voyageId,
      deviceId: 'bill',
      type: VoyageEventType.sailorJoined,
      priority: EventPriority.routine,
      createdAt: now,
      payload: const {
        'displayName': 'Bill',
        'role': 'sailor',
        'sailorColor': 'crimson',
      },
      signature: '',
    );
    await eventStore.append(
      VoyageEvent(
        id: join.id,
        voyageId: join.voyageId,
        deviceId: join.deviceId,
        type: join.type,
        priority: join.priority,
        createdAt: join.createdAt,
        payload: join.payload,
        signature: VoyageEventAuthenticator.sign(join, session.inviteSecret),
      ),
    );
    await controller.reloadEvents();
  });

  tearDown(() => controller.dispose());

  Widget harness({
    bool relayCanCarrySweeperRequest = true,
    Set<String> legacyPeerSailorIds = const {},
  }) => MaterialApp(
    home: Scaffold(
      body: VoyageRosterSheet(
        controller: controller,
        relayCanCarrySweeperRequest: relayCanCarrySweeperRequest,
        legacyPeerSailorIds: legacyPeerSailorIds,
      ),
    ),
  );

  testWidgets('the skipper can ask a named sailor, and sees pending state', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    // The gap is named, and so is the way to close it.
    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('have\nto accept'), findsNothing);
    expect(
      find.byKey(const Key('roster-sweeper-request-status')),
      findsNothing,
    );
    // The skipper cannot ask themselves.
    expect(find.byKey(const Key('ask-sweeper-bill')), findsOneWidget);

    await tester.tap(find.byKey(const Key('ask-sweeper-bill')));
    await tester.pumpAndSettle();

    expect(controller.sweeperRoleAssignments.latest?.targetSailorId, 'bill');
    expect(
      controller.sweeperRoleAssignments.latest?.status,
      SweeperRoleAssignmentStatus.pending,
    );
    expect(
      find.byKey(const Key('roster-sweeper-request-status')),
      findsOneWidget,
    );
    expect(
      find.textContaining('waiting for them to accept'),
      findsOneWidget,
      reason: 'the back is not covered until Bill accepts',
    );
    // The gap notice is still up: nobody holds the role yet.
    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsOneWidget,
    );
  });

  testWidgets('an older relay is named instead of recording a request', (
    tester,
  ) async {
    await tester.pumpWidget(harness(relayCanCarrySweeperRequest: false));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ask-sweeper-bill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('sweeper-request-outcome')), findsOneWidget);
    expect(find.textContaining('too old to pass on'), findsOneWidget);
    expect(
      controller.events.where(
        (event) => event.type == VoyageEventType.sweeperRoleRequested,
      ),
      isEmpty,
    );
  });

  testWidgets("an older peer's build is named before the request goes out", (
    tester,
  ) async {
    await tester.pumpWidget(harness(legacyPeerSailorIds: const {'bill'}));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ask-sweeper-bill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining("Bill's app is older"), findsOneWidget);
    expect(
      controller.events.where(
        (event) => event.type == VoyageEventType.sweeperRoleRequested,
      ),
      isEmpty,
    );
  });

  testWidgets('a sailor who already holds the role is not asked again', (
    tester,
  ) async {
    final session = controller.session!;
    final roleChange = VoyageEvent(
      id: 'bill-role',
      voyageId: session.voyageId,
      deviceId: 'bill',
      type: VoyageEventType.roleChanged,
      priority: EventPriority.routine,
      createdAt: now.add(const Duration(seconds: 1)),
      payload: const {'role': 'sweeper'},
      signature: '',
    );
    await eventStore.append(
      VoyageEvent(
        id: roleChange.id,
        voyageId: roleChange.voyageId,
        deviceId: roleChange.deviceId,
        type: roleChange.type,
        priority: roleChange.priority,
        createdAt: roleChange.createdAt,
        payload: roleChange.payload,
        signature: VoyageEventAuthenticator.sign(
          roleChange,
          session.inviteSecret,
        ),
      ),
    );
    await controller.reloadEvents();

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsNothing,
    );
    expect(find.byKey(const Key('ask-sweeper-bill')), findsNothing);
    final badge = tester.widget<SailorMarkerBadge>(
      find.descendant(
        of: find.byKey(const Key('roster-sailor-bill')),
        matching: find.byType(SailorMarkerBadge),
      ),
    );
    expect(
      badge.badgeColor,
      SailorColor.crimson.color,
      reason: 'taking the TEC role must not replace Bill’s identity colour',
    );
  });

  testWidgets('an accepted assignment supersedes an older TEC selection', (
    tester,
  ) async {
    final session = controller.session!;
    final daveJoin = VoyageEvent(
      id: 'join-dave',
      voyageId: session.voyageId,
      deviceId: 'dave',
      type: VoyageEventType.sailorJoined,
      priority: EventPriority.routine,
      createdAt: now.add(const Duration(seconds: 1)),
      payload: const {
        'displayName': 'Dave',
        'role': 'sweeper',
        'sailorColor': 'amber',
      },
      signature: '',
    );
    await eventStore.append(
      VoyageEvent(
        id: daveJoin.id,
        voyageId: daveJoin.voyageId,
        deviceId: daveJoin.deviceId,
        type: daveJoin.type,
        priority: daveJoin.priority,
        createdAt: daveJoin.createdAt,
        payload: daveJoin.payload,
        signature: VoyageEventAuthenticator.sign(
          daveJoin,
          session.inviteSecret,
        ),
      ),
    );
    await controller.reloadEvents();
    expect(
      await controller.requestSweeperRole(
        targetSailorId: 'bill',
        targetDisplayName: 'Bill',
      ),
      SweeperRoleRequestOutcome.sent,
    );
    final request = controller.sweeperRoleAssignments.latest!;
    final response = VoyageEvent(
      id: 'bill-accepts',
      voyageId: session.voyageId,
      deviceId: 'bill',
      type: VoyageEventType.sweeperRoleResponded,
      priority: EventPriority.important,
      createdAt: now.add(const Duration(seconds: 2)),
      payload: SweeperRoleAssignmentReducer.responsePayload(
        requestId: request.requestId,
        targetSailorId: 'bill',
        accepted: true,
      ),
      signature: '',
    );
    final billRole = VoyageEvent(
      id: 'bill-role',
      voyageId: session.voyageId,
      deviceId: 'bill',
      type: VoyageEventType.roleChanged,
      priority: EventPriority.routine,
      createdAt: now.add(const Duration(seconds: 3)),
      payload: const {'role': 'sweeper'},
      signature: '',
    );
    for (final event in [response, billRole]) {
      await eventStore.append(
        VoyageEvent(
          id: event.id,
          voyageId: event.voyageId,
          deviceId: event.deviceId,
          type: event.type,
          priority: event.priority,
          createdAt: event.createdAt,
          payload: event.payload,
          signature: VoyageEventAuthenticator.sign(event, session.inviteSecret),
        ),
      );
    }
    await controller.reloadEvents();

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(controller.sweeperRoleAssignments.acceptedSweeperSailorId, 'bill');
    expect(
      find.descendant(
        of: find.byKey(const Key('roster-sailor-bill')),
        matching: find.textContaining('Sweeper'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('roster-sailor-dave')),
        matching: find.textContaining(
          'Sailor · previous TEC selection superseded',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a sailor who is not the skipper sees no ask action', (
    tester,
  ) async {
    await controller.setRole(VoyageRole.sailor);

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ask-sweeper-bill')), findsNothing);
    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsNothing,
    );
  });
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}

class _NullVoyageCodeDirectory implements VoyageCodeDirectory {
  @override
  Future<void> register(VoyageSession session) async {}

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) => throw const VoyageCodeDirectoryException('Not used in this test');

  @override
  void close() {}
}
