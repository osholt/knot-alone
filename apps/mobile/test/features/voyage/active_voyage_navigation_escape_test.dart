import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/app/tide_and_seek_app.dart';
import 'package:tide_and_seek/controllers/completed_voyages_controller.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/controllers/map_style_mode_controller.dart';
import 'package:tide_and_seek/controllers/voyage_code_preference_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/controllers/shared_route_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/recorded_route_store.dart';
import 'package:tide_and_seek/features/map/voyage_map.dart';
import 'package:tide_and_seek/services/skipper_voyage_status.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Its own file on purpose.
///
/// The state this exercises is reached by running a whole simulated voyage, and
/// it did not survive sharing a file with the other shell tests: the voyage
/// refused to start at all once earlier tests had run against the same
/// process-wide controllers. A separate file is a separate isolate, so the
/// voyage this drives is the only voyage there has ever been.
void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _sailorProfile = await SailorProfileController.load();
    await _sailorProfile.completeOnboarding(
      displayName: 'Oliver',
      vesselStyle: _sailorProfile.vesselStyle,
      sailorColor: _sailorProfile.sailorColor,
      educationSkipped: false,
      voyageChoice: OnboardingVoyageChoice.create,
    );
    _sailorProfile.takePendingVoyageChoice();
    _sharedRoutes = await SharedRouteController.load();
    _mapStyleMode = await MapStyleModeController.load();
    _voyageCodePreference = VoyageCodePreferenceController.memory();
    _completedVoyages = await CompletedVoyagesController.load(
      InMemoryCompletedVoyageStore(),
    );
  });

  testWidgets('a moving sailor can still reach the other tabs (#404)', (
    tester,
  ) async {
    // The defect: once a voyage is under way on the map tab with a route and a
    // navigation fix, `hideWhileMoving` removes the whole navigation bar. Its
    // condition includes `_selectedIndex == 0`, so hiding the only control that
    // could change the index kept it hidden for the rest of the voyage — Voyage and
    // Settings were gone until the voyage ended.
    //
    // It needs a *moving* voyage with a route to appear, which is why a
    // stationary phone never showed it. That is the #133 pattern again.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createSimulationVoyage();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    Future<void> pumpUntil(bool Function() satisfied) async {
      for (var attempt = 0; attempt < 60 && !satisfied(); attempt += 1) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // Same opening as the simulation test above: the lab tab has to reach
    // READY before the voyage can be started.
    await pumpUntil(
      () => find.byIcon(Icons.science_outlined).evaluate().isNotEmpty,
    );
    await tester.tap(find.byIcon(Icons.science_outlined));
    await pumpUntil(() => find.text('READY').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('start-voyage-button')));
    // Which dialogs the start puts up depends on whether the bundled demo
    // route has finished loading and whether anyone holds TEC, and that varies
    // with what ran before this test. Answer whichever appears rather than
    // assuming an order.
    const startButtons = [
      'start-without-route-button',
      'start-without-sweeper-button',
      'confirm-start-voyage-button',
    ];
    for (
      var attempt = 0;
      attempt < 40 && !controller.voyageStarted;
      attempt++
    ) {
      var tapped = false;
      for (final key in startButtons) {
        final button = find.byKey(Key(key));
        if (button.evaluate().isNotEmpty) {
          await tester.tap(button);
          tapped = true;
          break;
        }
      }
      await tester.pump(
        tapped ? Duration.zero : const Duration(milliseconds: 100),
      );
    }
    expect(controller.voyageStarted, isTrue);
    // The bikes have to be moving, not merely started: the navigation fix that
    // hides the bar comes from a simulated position.
    await pumpUntil(() => find.text('RUNNING').evaluate().isNotEmpty);
    expect(find.text('RUNNING'), findsOneWidget);

    // Back to the map, which is where a sailor actually voyages.
    await tester.tap(find.text('Map').last);
    await tester.pump();

    // Voyage Lab's authenticated virtual fixes are its source of truth. They do
    // not appear in the relay participant list, so filtering them through that
    // real-voyage roster left the TEC card waiting forever despite Charlie
    // moving on the map.
    final voyageMap = tester.widget<VoyageMapFeature>(
      find.byType(VoyageMapFeature),
    );
    final status = voyageMap.skipperStatus?.value;
    expect(status?.hasRegisteredSweeper, isTrue);
    expect(status?.sweeperAvailability, SweeperAvailability.tracking);
    expect(status?.sweeperName, 'Charlie');
    expect(status?.distanceToSweeperMeters, isPositive);
    expect(status?.estimatedTimeToSweeper, isNotNull);

    // Voyage until the shell decides the sailor is navigating and takes the bar
    // away. That state is the whole point of the test: if it never arrives,
    // the test is not exercising the defect and must say so rather than pass.
    await pumpUntil(() => find.byType(NavigationBar).evaluate().isEmpty);
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: 'the moving-map state this regression is about was never reached',
    );

    // Pre-fix this found nothing: ActiveVoyageShell never passed
    // `onOpenVoyageMenu`, so the corner button existed only where a test supplied
    // it and the sailor had no way off the map at all.
    final voyageMenu = find.byKey(const Key('voyage-menu-button'));
    expect(voyageMenu, findsOneWidget);
    expect(
      tester.getRect(voyageMenu).top,
      closeTo(portraitVoyageMenuTopOffset, 1),
      reason: 'the menu should sit below the ETA/mini-map header',
    );

    // Bounded pumps, not pumpAndSettle: a running simulation never settles.
    await tester.tap(voyageMenu);
    await pumpUntil(
      () => find
          .byKey(const Key('voyage-menu-destination-2'))
          .evaluate()
          .isNotEmpty,
    );
    // The tile exists as soon as the sheet starts sliding up; tapping then
    // lands on the barrier instead. Let it finish arriving.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Voyage'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);

    // Leaving the map puts the sailor's navigation back, because the condition
    // that hid it required the map tab.
    await tester.tap(find.byKey(const Key('voyage-menu-destination-2')));
    await pumpUntil(() => find.byType(NavigationBar).evaluate().isNotEmpty);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

late SailorProfileController _sailorProfile;
late SharedRouteController _sharedRoutes;
late MapStyleModeController _mapStyleMode;
late VoyageCodePreferenceController _voyageCodePreference;
late CompletedVoyagesController _completedVoyages;
final _recordedRoutes = InMemoryRecordedRouteStore();

TideAndSeekApp _app(VoyageController controller) => TideAndSeekApp(
  controller: controller,
  distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
  mapStyleMode: _mapStyleMode,
  voyageCodePreference: _voyageCodePreference,
  sailorProfile: _sailorProfile,
  sharedRoutes: _sharedRoutes,
  recordedRoutes: _recordedRoutes,
  completedVoyages: _completedVoyages,
  enableNativeServices: false,
);

Future<VoyageController> _controller() async {
  final controller = VoyageController(
    InMemoryEventStore(),
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
  );
  await controller.initialize();
  return controller;
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
