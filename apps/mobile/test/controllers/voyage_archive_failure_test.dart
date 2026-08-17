import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/voyage/ended_voyage_screen.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';

/// "A voyage that cannot be saved says so, loudly, rather than ending silently."
///
/// #299's requirement, and the acceptance criterion "a deliberately failed save
/// surfaces an error instead of completing quietly". Neither was met: a store
/// that threw produced the generic "that action could not be saved", which does
/// not say *what* was lost, and it abandoned the rest of `endVoyage` on the way
/// out.
void main() {
  late _FailingArchive archive;
  late VoyageController controller;
  late InMemoryEventStore events;
  late InMemorySessionStore sessions;
  late DateTime now;
  String? voyageId;

  Future<void> startAndEnd() async {
    await controller.initialize();
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    voyageId = controller.session?.voyageId;
    await controller.endVoyage();
  }

  void buildController({required bool failing}) {
    archive = _FailingArchive()..failing = failing;
    events = InMemoryEventStore();
    sessions = InMemorySessionStore();
    now = DateTime.utc(2026, 8, 2, 12);
    var id = 0;
    controller = VoyageController(
      events,
      sessions,
      NearbyBridge(),
      clock: () => now,
      idFactory: () => 'id-${id++}',
      random: Random(11),
      voyageCodeDirectory: _OfflineVoyageCodeDirectory(),
      completedVoyageStore: archive,
    );
  }

  setUp(() => buildController(failing: false));

  tearDown(() => controller.dispose());

  test('a failed save is reported in words about the voyage', () async {
    buildController(failing: true);

    await startAndEnd();

    expect(controller.voyageArchiveError, isNotNull);
    expect(
      controller.voyageArchiveError,
      VoyageController.voyageArchiveFailedMessage,
    );
    expect(
      controller.voyageArchiveError,
      contains('Previous voyages'),
      reason:
          'the generic "that action could not be saved" never said what '
          'had been lost',
    );
  });

  test('a voyage that saves says nothing', () async {
    await startAndEnd();

    expect(controller.voyageArchiveError, isNull);
    expect(archive.saved, hasLength(1));
  });

  test('the voyage still ends when the save fails', () async {
    // The event is recorded before the archive is attempted, so a write failure
    // must not leave the voyage neither ended nor saved.
    buildController(failing: true);

    await startAndEnd();

    expect(controller.voyageEnded, isTrue);
  });

  test('a later successful save clears the warning', () async {
    // `initialize` retries while the journal survives, so the message states a
    // risk rather than a certainty — and has to stop being shown once the risk
    // is gone.
    buildController(failing: true);
    await startAndEnd();
    expect(controller.voyageArchiveError, isNotNull);

    archive.failing = false;
    await controller.initialize();

    expect(controller.voyageArchiveError, isNull);
    expect(archive.saved, isNotEmpty);
  });

  test('the 24-hour cleanup never deletes a voyage it could not archive', () async {
    // The cleanup exists to reclaim space. Reclaiming it by destroying the only
    // copy of a voyage is the exact data loss #299 is about, and it was reachable:
    // the archive attempt and the delete sat one after the other with nothing
    // between them.
    buildController(failing: true);
    await startAndEnd();
    expect(controller.voyageArchiveError, isNotNull);

    // A day later, with the write still failing.
    now = now.add(const Duration(hours: 25));
    await controller.initialize();

    expect(
      controller.session,
      isNotNull,
      reason: 'the voyage must survive so the next launch can try again',
    );
    expect(await events.eventsForVoyage(voyageId!), isNotEmpty);

    // And once the write succeeds it is archived and then cleaned up as normal.
    archive.failing = false;
    await controller.initialize();

    expect(archive.saved, hasLength(1));
    expect(controller.session, isNull);
  });

  group('the ended-voyage screen', () {
    // The voyage is ended in `setUp`, outside the widget test's fake-async zone.
    // Ending it inside deadlocks: `endVoyage` arms the 24-hour cleanup timer, and
    // a real `await` waiting behind a fake clock that never advances does not
    // return.
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

    group('after a failed save', () {
      setUp(() async {
        buildController(failing: true);
        await startAndEnd();
      });

      testWidgets('leads with the failure', (tester) async {
        await pumpScreen(tester);

        expect(
          find.byKey(const Key('voyage-archive-failed-notice')),
          findsOneWidget,
        );
        expect(find.text('This voyage was not saved'), findsOneWidget);
      });
    });

    group('after a successful save', () {
      setUp(() async {
        buildController(failing: false);
        await startAndEnd();
      });

      testWidgets('says nothing', (tester) async {
        await pumpScreen(tester);

        expect(
          find.byKey(const Key('voyage-archive-failed-notice')),
          findsNothing,
        );
      });
    });
  });
}

class _FailingArchive implements CompletedVoyageStore {
  bool failing = false;
  final List<CompletedVoyage> saved = [];

  @override
  Future<List<CompletedVoyage>> list() async => List.unmodifiable(saved);

  @override
  Future<void> save(CompletedVoyage voyage) async {
    if (failing) throw StateError('disk full');
    // Upsert by voyage, as a real store does: the same voyage is archived by both
    // `initialize` and the expiry sweep, and two rows for one voyage would be a
    // bug in the fake rather than in the controller.
    saved.removeWhere((existing) => existing.voyageId == voyage.voyageId);
    saved.add(voyage);
  }

  @override
  Future<void> delete(String voyageId) async =>
      saved.removeWhere((voyage) => voyage.voyageId == voyageId);
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
