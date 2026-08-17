// Ties the end-of-voyage copy to what the code actually does (#156).
//
// The button used to say "Remove voyage from this phone" beside a delete icon,
// while `clearEndedVoyage()` archives the voyage to Previous voyages and clears only
// the live working copy. A tester read the label and believed the voyage was being
// deleted. Copy and behaviour drifted because nothing held them together, so the
// assertions below do: the same test presses the button and then looks in the
// archive.

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/voyage/ended_voyage_screen.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';

void main() {
  late InMemoryEventStore events;
  late InMemorySessionStore sessions;
  late InMemoryCompletedVoyageStore archive;
  late VoyageController controller;

  setUp(() async {
    events = InMemoryEventStore();
    sessions = InMemorySessionStore();
    archive = InMemoryCompletedVoyageStore();
    var id = 0;
    controller = VoyageController(
      events,
      sessions,
      NearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 27, 12),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      voyageCodeDirectory: _OfflineVoyageCodeDirectory(),
      completedVoyageStore: archive,
    );
    await controller.initialize();
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    await controller.endVoyage();
  });

  tearDown(() => controller.dispose());

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: EndedVoyageScreen(
        controller: controller,
        distanceUnits: DistanceUnitController.forLocale(
          const Locale('en', 'GB'),
        ),
      ),
    ),
  );

  testWidgets('no copy claims the voyage leaves the phone', (tester) async {
    await pumpScreen(tester);

    final forbidden = RegExp(
      r'remove|delete|erase|wipe|lose|permanent',
      caseSensitive: false,
    );
    final offending = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .where(forbidden.hasMatch)
        .toList();

    expect(
      offending,
      isEmpty,
      reason: 'the voyage is archived, so nothing may describe it as destroyed',
    );
    expect(find.text('Finish and file in Previous voyages'), findsOneWidget);
  });

  // #206/#207: the tester was stranded here by an automatic end she did not
  // ask for, so the screen has to offer the way back into the voyage.
  testWidgets('the skipper can resume a voyage that ended', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('reopen-ended-voyage-button')));
    await tester.pumpAndSettle();
    expect(find.text('Resume this voyage?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-reopen-voyage-button')));
    await tester.pumpAndSettle();
    expect(controller.voyageEnded, isTrue);

    await tester.tap(find.byKey(const Key('reopen-ended-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reopen-voyage-button')));
    await tester.pumpAndSettle();

    expect(controller.voyageEnded, isFalse);
  });

  testWidgets('a relay that cannot carry a resume does not offer one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EndedVoyageScreen(
          controller: controller,
          distanceUnits: DistanceUnitController.forLocale(
            const Locale('en', 'GB'),
          ),
          relayCanCarryReopen: false,
        ),
      ),
    );

    expect(find.byKey(const Key('reopen-ended-voyage-button')), findsNothing);
    // The way out is still there; only the resume is withheld.
    expect(find.byKey(const Key('leave-ended-voyage-button')), findsOneWidget);
  });

  // #207: this screen replaces the whole app, so without an exit of its own the
  // only way off it was to file the voyage and stop relay recovery.
  testWidgets('offers two exits that give nothing up', (tester) async {
    await pumpScreen(tester);

    for (final exit in [
      const Key('leave-ended-voyage-button'),
      const Key('leave-ended-voyage-screen-button'),
    ]) {
      controller.reopenEndedVoyage();
      expect(controller.endedVoyageSetAside, isFalse);

      await tester.tap(find.byKey(exit));
      await tester.pump();

      expect(controller.endedVoyageSetAside, isTrue, reason: '$exit');
      expect(controller.hasActiveVoyage, isTrue);
      expect(controller.voyageEnded, isTrue);
    }
  });

  testWidgets('the confirmation says what is kept and what stops', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tester.tap(find.byKey(const Key('file-ended-voyage-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('stays on this phone'), findsOneWidget);
    expect(find.textContaining('Previous voyages'), findsWidgets);
    // The one real consequence, in sailor language rather than "relay recovery".
    expect(find.textContaining('stop waiting for them'), findsOneWidget);
  });

  testWidgets('filing the voyage archives it and clears the working copy', (
    tester,
  ) async {
    final voyageId = controller.session!.voyageId;
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('file-ended-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-file-ended-voyage-button')));
    await tester.pumpAndSettle();

    // This is the assertion the copy has to match: the voyage is still here.
    final archived = await archive.list();
    expect(archived.map((voyage) => voyage.voyageId), contains(voyageId));
    expect(
      controller.session,
      isNull,
      reason: 'the live working copy is what gets cleared',
    );
  });

  testWidgets('declining leaves the voyage open and archives nothing new', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const Key('file-ended-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keep-ended-voyage-open-button')));
    await tester.pumpAndSettle();

    expect(controller.session, isNotNull);
    expect(find.text('Finish and file in Previous voyages'), findsOneWidget);
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
