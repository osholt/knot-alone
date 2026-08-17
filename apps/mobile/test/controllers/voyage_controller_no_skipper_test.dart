// A running voyage that has lost its skipper (#176).
//
// A tester left the voyage as skipper to see what would happen:
//
//   "No option to assign, have I left? Did you get informed? Is someone else a
//    lead now?"
//
// and a remaining sailor answered:
//
//   "The voyage seems to continue quite happily without a skipper."
//
// Nothing noticed, nobody was told, and nobody was offered the role. The
// departure itself was recorded correctly the whole time - #27 and #144 handle
// that - so what was missing was a state derived from it.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';

void main() {
  // NearbyBridge reaches a platform channel on construction.
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemoryEventStore events;
  late VoyageController controller;
  late DateTime now;

  setUp(() async {
    events = InMemoryEventStore();
    now = DateTime.utc(2026, 7, 27, 12);
    var id = 0;
    controller = VoyageController(
      events,
      InMemorySessionStore(),
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${id++}',
      random: Random(11),
      voyageCodeDirectory: _OfflineVoyageCodeDirectory(),
      completedVoyageStore: InMemoryCompletedVoyageStore(),
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  /// A second sailor joining, as their own device would record it.
  Future<void> joinFollower(String sailorId) async {
    final session = controller.session!;
    final unsigned = VoyageEvent(
      id: 'joined-$sailorId',
      voyageId: session.voyageId,
      deviceId: sailorId,
      type: VoyageEventType.sailorJoined,
      priority: EventPriority.important,
      createdAt: now,
      payload: {'displayName': sailorId, 'role': VoyageRole.sailor.name},
      signature: '',
    );
    await events.append(
      VoyageEvent(
        id: unsigned.id,
        voyageId: unsigned.voyageId,
        deviceId: unsigned.deviceId,
        type: unsigned.type,
        priority: unsigned.priority,
        createdAt: unsigned.createdAt,
        payload: unsigned.payload,
        signature: VoyageEventAuthenticator.sign(
          unsigned,
          session.inviteSecret,
        ),
      ),
    );
    await controller.reloadEvents();
  }

  test('a running voyage with a skipper is not flagged', () async {
    await controller.createVoyage('Oliver');
    await controller.startVoyage();

    expect(controller.skipperSailorId, controller.session!.localSailorId);
    expect(controller.voyageHasNoSkipper, isFalse);
  });

  test('a voyage waiting to start is never flagged', () async {
    await controller.createVoyage('Oliver');

    expect(
      controller.voyageHasNoSkipper,
      isFalse,
      reason:
          'before the start the creator holds lead and nothing has gone '
          'wrong yet',
    );
  });

  test(
    'the voyage is flagged once the skipper stops holding the role',
    () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      await joinFollower('sailor-2');

      // The skipper hands their role away without anyone taking lead - the same
      // end state as the skipper leaving, reached from this device.
      await controller.setRole(VoyageRole.sailor);

      expect(controller.skipperSailorId, isNull);
      expect(
        controller.voyageHasNoSkipper,
        isTrue,
        reason: 'a running voyage with nobody on lead has no skipper',
      );
    },
  );

  test('taking the lead clears it', () async {
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    await joinFollower('sailor-2');
    await controller.setRole(VoyageRole.sailor);
    expect(controller.voyageHasNoSkipper, isTrue);

    await controller.setRole(VoyageRole.lead);

    expect(controller.voyageHasNoSkipper, isFalse);
    expect(controller.skipperSailorId, controller.session!.localSailorId);
  });

  test('an ended voyage is not flagged', () async {
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    await controller.setRole(VoyageRole.sailor);
    expect(controller.voyageHasNoSkipper, isTrue);

    // endVoyage requires the lead role, so take it back to end the voyage.
    await controller.setRole(VoyageRole.lead);
    await controller.endVoyage();

    expect(
      controller.voyageHasNoSkipper,
      isFalse,
      reason: 'there is nothing left to lead',
    );
  });

  test('a forged role change cannot make somebody else the skipper', () async {
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    await joinFollower('sailor-2');
    await controller.setRole(VoyageRole.sailor);
    final session = controller.session!;

    // A device claiming *another* sailor took the lead. Roles are self-selected,
    // so this is the forgery that matters: not "I am skipper now", which any
    // sailor may legitimately say, but "they are".
    final forged = VoyageEvent(
      id: 'forged-promotion',
      voyageId: session.voyageId,
      deviceId: 'sailor-2',
      type: VoyageEventType.roleChanged,
      priority: EventPriority.important,
      createdAt: now,
      payload: {'role': VoyageRole.lead.name},
      // Signed with the wrong secret: a device outside the voyage.
      signature: VoyageEventAuthenticator.sign(
        VoyageEvent(
          id: 'forged-promotion',
          voyageId: session.voyageId,
          deviceId: 'sailor-2',
          type: VoyageEventType.roleChanged,
          priority: EventPriority.important,
          createdAt: now,
          payload: {'role': VoyageRole.lead.name},
          signature: '',
        ),
        'not-this-voyages-secret',
      ),
    );
    await events.append(forged);
    await controller.reloadEvents();

    expect(
      controller.skipperSailorId,
      isNull,
      reason: 'an unsigned promotion must not install a skipper',
    );
    expect(controller.voyageHasNoSkipper, isTrue);
  });
}

class _OfflineVoyageCodeDirectory implements VoyageCodeDirectory {
  @override
  Future<void> register(VoyageSession session) async {}

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async => throw const VoyageCodeDirectoryException('Offline in tests.');

  @override
  void close() {}
}
