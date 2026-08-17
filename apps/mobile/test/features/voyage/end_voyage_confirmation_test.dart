import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/voyage/end_voyage_confirmation.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';

/// Ending a voyage stops the group, not just this phone, and it was reachable two
/// ways with a different dialog behind each (#306: "every destructive or safety
/// action reachable by the same gesture every time").
///
/// The two were not merely worded differently. Only the voyage menu's told the
/// skipper whether the voyage could be resumed — including "this action cannot be
/// undone for the group" when the relay cannot carry a reopen. Only the
/// dashboard's showed the marking summary and offered to share it. So **whether
/// a skipper learned that ending the voyage was irreversible depended on which
/// button they happened to press.**
void main() {
  group('the consequence is stated once, for both entry points', () {
    test('a reopenable voyage says it can be resumed', () {
      final text = endVoyageConsequence(relayCanCarryReopen: true);

      expect(text, contains('ends the group voyage for everyone'));
      expect(text, contains('resume it within 24 hours'));
      expect(text, isNot(contains('cannot be undone')));
    });

    test('a voyage that cannot be reopened says it cannot be undone', () {
      // The sentence the dashboard's dialog never had, and the one a skipper
      // needs most.
      final text = endVoyageConsequence(relayCanCarryReopen: false);

      expect(text, contains('cannot resume an ended voyage'));
      expect(text, contains('cannot be undone for the group'));
      expect(text, isNot(contains('within 24 hours')));
    });

    test('both readings name the group, not just this phone', () {
      // The dashboard's old wording led with "Location sharing will stop on
      // this phone", which understates an action that ends everyone's voyage.
      for (final reopenable in [true, false]) {
        expect(
          endVoyageConsequence(relayCanCarryReopen: reopenable),
          contains('for everyone'),
          reason: 'relayCanCarryReopen: $reopenable',
        );
      }
    });

    test('the two readings differ only in whether it can be undone', () {
      // If they diverged anywhere else, the two entry points would be back to
      // telling a skipper different things about the same action.
      final reopenable = endVoyageConsequence(relayCanCarryReopen: true);
      final permanent = endVoyageConsequence(relayCanCarryReopen: false);
      String head(String text) => text.split('\n\n').first;

      expect(head(reopenable), head(permanent));
      expect(reopenable, isNot(permanent));
    });
  });

  group('who may end the voyage for everyone', () {
    // Three surfaces offered this and expressed the condition three ways, two
    // of them wrong. `VoyageController.endVoyage` accepts `isLocalVoyageSkipper`; the
    // shell's end-voyage guard and the map's exit dialog both read
    // `session?.role == VoyageRole.lead`, which is a different thing.
    Future<VoyageController> controllerFor() async {
      var id = 0;
      final controller = VoyageController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 8, 3, 9),
        idFactory: () => 'id-${id++}',
        random: Random(3),
        voyageCodeDirectory: _OfflineVoyageCodeDirectory(),
      );
      await controller.initialize();
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      return controller;
    }

    test('a skipper may', () async {
      final controller = await controllerFor();
      addTearDown(controller.dispose);

      expect(controller.session?.role, VoyageRole.lead);
      expect(canEndVoyageForEveryone(controller), isTrue);
    });

    test('the decision matches what the controller will accept', () async {
      // If these ever diverge again, one surface offers what another refuses.
      final controller = await controllerFor();
      addTearDown(controller.dispose);
      expect(
        canEndVoyageForEveryone(controller),
        controller.isLocalVoyageSkipper,
      );
    });
  });

  // #362: the consequence text named a group, and other phones, that a solo
  // voyage does not have.
  test('a solo voyage is not ended for everyone', () {
    final solo = endVoyageConsequence(relayCanCarryReopen: true, isSolo: true);

    expect(solo, contains('This ends your voyage.'));
    expect(solo, isNot(contains('everyone')));
    expect(solo, isNot(contains('group')));
    expect(solo, contains('resume it within 24 hours'));

    final soloWithoutReopen = endVoyageConsequence(
      relayCanCarryReopen: false,
      isSolo: true,
    );
    expect(soloWithoutReopen, isNot(contains('other phones')));
    expect(soloWithoutReopen, contains('cannot be undone'));

    // The group wording is untouched.
    expect(
      endVoyageConsequence(relayCanCarryReopen: true),
      contains('for everyone'),
    );
  });
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
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
