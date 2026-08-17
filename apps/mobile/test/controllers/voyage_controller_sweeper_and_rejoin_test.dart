import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/sweeper_role_assignment.dart';

/// Issue #128 end-to-end through [VoyageController]: the two writes, their guards,
/// and that both survive a restart from the durable journal alone.
void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late VoyageController controller;
  late int id;
  var now = DateTime.utc(2026, 7, 26, 12);

  VoyageController build() => VoyageController(
    eventStore,
    sessionStore,
    const _FakeNearbyBridge(),
    clock: () => now,
    idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
    random: Random(42),
    voyageCodeDirectory: _NullVoyageCodeDirectory(),
  );

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    id = 0;
    now = DateTime.utc(2026, 7, 26, 12);
    controller = build();
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  /// Puts a second sailor in the voyage by appending their signed join event, the
  /// way the relay would deliver it.
  Future<void> addSailor(String sailorId, String displayName) async {
    final session = controller.session!;
    await eventStore.append(
      _sign(
        VoyageEvent(
          id: 'join-$sailorId',
          voyageId: session.voyageId,
          deviceId: sailorId,
          type: VoyageEventType.sailorJoined,
          priority: EventPriority.routine,
          createdAt: now,
          payload: {'displayName': displayName, 'role': 'sailor'},
          signature: '',
        ),
        session.inviteSecret,
      ),
    );
    await controller.reloadEvents();
  }

  group('a skipper asking a sailor to be the Sweeper', () {
    test('records a signed, addressed request the sailor can answer', () async {
      await controller.createVoyage('Lead');
      await addSailor('bill', 'Bill');

      final outcome = await controller.requestSweeperRole(
        targetSailorId: 'bill',
        targetDisplayName: 'Bill',
      );

      expect(outcome, SweeperRoleRequestOutcome.sent);
      final request = controller.events.singleWhere(
        (event) => event.type == VoyageEventType.sweeperRoleRequested,
      );
      expect(request.deviceId, controller.session!.localSailorId);
      expect(request.payload['targetSailorId'], 'bill');
      expect(request.payload['skipperSailorId'], request.deviceId);
      expect(request.signature, hasLength(64));
      expect(request.priority, EventPriority.important);

      final assignment = controller.sweeperRoleAssignments.latest!;
      expect(assignment.status, SweeperRoleAssignmentStatus.pending);
      // The skipper is not told the back is covered yet.
      expect(controller.sweeperRoleAssignments.acceptedSweeperSailorId, isNull);
    });

    test(
      'is refused when the relay cannot carry it, recording nothing',
      () async {
        await controller.createVoyage('Lead');
        await addSailor('bill', 'Bill');

        final outcome = await controller.requestSweeperRole(
          targetSailorId: 'bill',
          targetDisplayName: 'Bill',
          relayCanCarryRequest: false,
        );

        expect(outcome, SweeperRoleRequestOutcome.relayUnsupported);
        expect(
          controller.events.where(
            (event) => event.type == VoyageEventType.sweeperRoleRequested,
          ),
          isEmpty,
          reason: 'a request that cannot leave this phone must not look sent',
        );
        expect(controller.sweeperRoleAssignments.latest, isNull);
      },
    );

    test(
      'is refused for a sailor who is not in the voyage, or for oneself',
      () async {
        await controller.createVoyage('Lead');
        await addSailor('bill', 'Bill');

        expect(
          await controller.requestSweeperRole(
            targetSailorId: 'nobody',
            targetDisplayName: 'Nobody',
          ),
          SweeperRoleRequestOutcome.invalidTarget,
        );
        expect(
          await controller.requestSweeperRole(
            targetSailorId: controller.session!.localSailorId,
            targetDisplayName: 'Lead',
          ),
          SweeperRoleRequestOutcome.invalidTarget,
        );
      },
    );

    test('is refused from a sailor who is not the skipper', () async {
      await controller.createVoyage('Lead');
      await addSailor('bill', 'Bill');
      await controller.setRole(VoyageRole.sailor);

      expect(
        await controller.requestSweeperRole(
          targetSailorId: 'bill',
          targetDisplayName: 'Bill',
        ),
        SweeperRoleRequestOutcome.notSkipper,
      );
      expect(
        controller.events.where(
          (event) => event.type == VoyageEventType.sweeperRoleRequested,
        ),
        isEmpty,
      );
    });
  });

  group('the target answering', () {
    /// A voyage where the skipper is another device and this phone was asked.
    Future<void> joinAsAskedSailor() async {
      await controller.createVoyage('Bill');
      // This phone is a sailor; 'skipper' is the lead.
      await controller.setRole(VoyageRole.sailor);
      final session = controller.session!;
      await eventStore.append(
        _sign(
          VoyageEvent(
            id: 'skipper-join',
            voyageId: session.voyageId,
            deviceId: 'skipper',
            type: VoyageEventType.sailorJoined,
            priority: EventPriority.routine,
            createdAt: now,
            payload: const {'displayName': 'Lead', 'role': 'lead'},
            signature: '',
          ),
          session.inviteSecret,
        ),
      );
      await eventStore.append(
        _sign(
          VoyageEvent(
            id: 'skipper-request',
            voyageId: session.voyageId,
            deviceId: 'skipper',
            type: VoyageEventType.sweeperRoleRequested,
            priority: EventPriority.important,
            createdAt: now.add(const Duration(seconds: 5)),
            payload: SweeperRoleAssignmentReducer.requestPayload(
              requestId: 'req-1',
              skipperSailorId: 'skipper',
              targetSailorId: session.localSailorId,
              targetDisplayName: 'Bill',
            ),
            signature: '',
          ),
          session.inviteSecret,
        ),
      );
      await controller.reloadEvents();
    }

    test('accepting takes the role and tells the skipper', () async {
      await joinAsAskedSailor();
      expect(
        controller.pendingSweeperRoleRequestForLocalSailor?.requestId,
        'req-1',
      );

      final answered = await controller.respondToSweeperRoleRequest(
        requestId: 'req-1',
        accepted: true,
      );

      expect(answered, isTrue);
      // The role itself is still self-selected: acceptance records this
      // device's own roleChanged, so the membership reducer is untouched.
      expect(controller.session!.role, VoyageRole.sweeper);
      final roleChange = controller.events.lastWhere(
        (event) => event.type == VoyageEventType.roleChanged,
      );
      expect(roleChange.deviceId, controller.session!.localSailorId);
      expect(roleChange.payload['role'], 'sweeper');
      final response = controller.events.singleWhere(
        (event) => event.type == VoyageEventType.sweeperRoleResponded,
      );
      expect(response.payload['accepted'], isTrue);
      expect(response.deviceId, controller.session!.localSailorId);
      expect(
        controller.sweeperRoleAssignments.acceptedSweeperSailorId,
        controller.session!.localSailorId,
      );
      expect(controller.pendingSweeperRoleRequestForLocalSailor, isNull);

      // And it survives a restart from the journal alone.
      final restored = build();
      await restored.initialize();
      addTearDown(restored.dispose);
      expect(
        restored.sweeperRoleAssignments.acceptedSweeperSailorId,
        controller.session!.localSailorId,
      );
      expect(restored.session!.role, VoyageRole.sweeper);
    });

    test('declining leaves the role alone and is recorded', () async {
      await joinAsAskedSailor();

      final answered = await controller.respondToSweeperRoleRequest(
        requestId: 'req-1',
        accepted: false,
      );

      expect(answered, isTrue);
      expect(controller.session!.role, VoyageRole.sailor);
      expect(
        controller.sweeperRoleAssignments.latest?.status,
        SweeperRoleAssignmentStatus.declined,
      );
      expect(controller.sweeperRoleAssignments.acceptedSweeperSailorId, isNull);
    });

    test(
      'a sailor cannot answer a request that was not addressed to them',
      () async {
        await controller.createVoyage('Lead');
        await addSailor('bill', 'Bill');
        await controller.requestSweeperRole(
          targetSailorId: 'bill',
          targetDisplayName: 'Bill',
        );
        final requestId = controller.sweeperRoleAssignments.latest!.requestId;

        // The skipper's own phone trying to accept on Bill's behalf.
        expect(
          await controller.respondToSweeperRoleRequest(
            requestId: requestId,
            accepted: true,
          ),
          isFalse,
        );
        expect(
          controller.events.where(
            (event) => event.type == VoyageEventType.sweeperRoleResponded,
          ),
          isEmpty,
        );
        expect(
          controller.sweeperRoleAssignments.latest?.status,
          SweeperRoleAssignmentStatus.pending,
        );
      },
    );
  });
}

VoyageEvent _sign(VoyageEvent event, String secret) => VoyageEvent(
  id: event.id,
  voyageId: event.voyageId,
  deviceId: event.deviceId,
  type: event.type,
  priority: event.priority,
  createdAt: event.createdAt,
  expiresAt: event.expiresAt,
  payload: event.payload,
  signature: VoyageEventAuthenticator.sign(event, secret),
);

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
