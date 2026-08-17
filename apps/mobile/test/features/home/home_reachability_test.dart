import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/completed_voyages_controller.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/controllers/map_style_mode_controller.dart';
import 'package:tide_and_seek/controllers/voyage_code_preference_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/controllers/shared_route_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/recorded_route_store.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/home/home_screen.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every way into the app, by the words a sailor can read (#306).
///
/// "Features that exist but cannot be found are not delivered." QR joining
/// shipped in #279 and was then reported as missing, because its only
/// affordance was an unlabelled icon with a tooltip — and a tooltip does not
/// appear when you tap a phone. "Voyage again" (#251) went the same way.
///
/// These assert the journeys #306 names by their **label**, not by a key or an
/// icon, so a consolidation that moves them has to keep them findable. They are
/// deliberately written before the reorganisation rather than after it: their
/// job is to be the safety net it lands into.
void main() {
  late InMemoryEventStore eventStore;
  late VoyageController voyageController;
  late DistanceUnitController distanceUnits;
  late MapStyleModeController mapStyleMode;
  late VoyageCodePreferenceController voyageCodePreference;
  late SailorProfileController sailorProfile;
  late SharedRouteController sharedRoutes;
  late CompletedVoyagesController completedVoyages;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    eventStore = InMemoryEventStore();
    var id = 0;
    voyageController = VoyageController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 2, 9),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      voyageCodeDirectory: _NullVoyageCodeDirectory(),
    );
    await voyageController.initialize();
    distanceUnits = DistanceUnitController.forLocale(const Locale('en', 'GB'));
    mapStyleMode = await MapStyleModeController.load();
    voyageCodePreference = await VoyageCodePreferenceController.load();
    sailorProfile = await SailorProfileController.load();
    sharedRoutes = await SharedRouteController.load(planDirectory: null);
    completedVoyages = await CompletedVoyagesController.load(
      _EmptyCompletedVoyageStore(),
    );
  });

  tearDown(() {
    voyageController.dispose();
    distanceUnits.dispose();
    mapStyleMode.dispose();
    voyageCodePreference.dispose();
    sailorProfile.dispose();
    sharedRoutes.dispose();
    completedVoyages.dispose();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(
          controller: voyageController,
          distanceUnits: distanceUnits,
          mapStyleMode: mapStyleMode,
          voyageCodePreference: voyageCodePreference,
          sailorProfile: sailorProfile,
          sharedRoutes: sharedRoutes,
          recordedRoutes: InMemoryRecordedRouteStore(),
          completedVoyages: completedVoyages,
          // The home map backdrop is live in production. Without this it would
          // wait forever here on a platform map and a location plugin that
          // never answer, and pumpAndSettle would time out.
          enableNativeServices: false,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('starting a voyage is offered in words on the first screen', (
    tester,
  ) async {
    await pumpHome(tester);

    expect(find.text('Create a voyage'), findsOneWidget);
    expect(find.text('Join a voyage'), findsOneWidget);
  });

  testWidgets(
    'voyage setup uses the saved symbol and colour without repicking',
    (tester) async {
      await sailorProfile.save(
        displayName: 'Oliver',
        motorcycleStyle: MotorcycleIconStyle.scrambler,
        sailorSymbol: const SailorSymbol.emoji('🦊'),
        sailorColor: SailorColor.cyan,
      );
      await pumpHome(tester);

      await tester.tap(find.text('Create a voyage'));
      await tester.pumpAndSettle();

      expect(find.text('Your colour'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'voyage-symbol-',
              ),
        ),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(
                'sailor-colour-',
              ),
        ),
        findsNothing,
      );

      await tester.scrollUntilVisible(
        find.widgetWithText(FilledButton, 'Create voyage'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('voyage-form-scroll-view')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create voyage'));
      await tester.pumpAndSettle();

      expect(
        voyageController.session?.sailorSymbol,
        const SailorSymbol.emoji('🦊'),
      );
      expect(voyageController.session?.sailorColor, SailorColor.cyan);
    },
  );

  testWidgets('a past voyage is reachable by words alone', (tester) async {
    // Moved one tap in by #426, which removed the full-screen start panel these
    // rows used to sit on. The #306 rule is what matters and it still holds: the
    // path is words the whole way, "More" then "Voyage library", with no
    // unlabelled icon anywhere on it. An overflow nobody can read would not be
    // reachable, which is why the control is a word rather than `more_horiz`.
    await pumpHome(tester);

    expect(find.text('More'), findsOneWidget);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();

    expect(find.text('Voyage library'), findsOneWidget);
    expect(
      find.textContaining('Recorded routes and previous voyages'),
      findsOneWidget,
    );

    await tester.tap(find.text('Voyage library'));
    await tester.pumpAndSettle();
    expect(find.text('Voyage library'), findsOneWidget);
    expect(find.text('No saved routes yet'), findsOneWidget);
  });

  testWidgets('the simulator and route recorder are reachable too', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();

    expect(find.text('Try a simulated voyage'), findsOneWidget);
    expect(find.text('Record a route'), findsOneWidget);
  });

  testWidgets('joining by QR is offered in words, not only as an icon', (
    tester,
  ) async {
    // The specific failure #306 was raised over: this shipped in #279 and was
    // then concluded to be missing, because the only way to find it was an
    // unlabelled camera icon inside a text field's suffix.
    await pumpHome(tester);
    await tester.tap(find.text('Join a voyage'));
    await tester.pumpAndSettle();

    expect(
      find.text('Scan an invitation code'),
      findsOneWidget,
      reason: 'a sailor who has never seen the app has to be able to read it',
    );
  });

  testWidgets('the QR icon still works for sailors who have learned it', (
    tester,
  ) async {
    // Adding the label must not have quietly replaced the compact affordance.
    await pumpHome(tester);
    await tester.tap(find.text('Join a voyage'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scan-invitation-button')), findsOneWidget);
    expect(
      find.byKey(const Key('scan-invitation-labelled-button')),
      findsOneWidget,
    );
  });
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

class _EmptyCompletedVoyageStore implements CompletedVoyageStore {
  @override
  Future<List<CompletedVoyage>> list() async => const [];

  @override
  Future<void> save(CompletedVoyage voyage) async {}

  @override
  Future<void> delete(String voyageId) async {}
}
