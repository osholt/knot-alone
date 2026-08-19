import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/app/tide_and_seek_app.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/controllers/completed_voyages_controller.dart';
import 'package:tide_and_seek/controllers/map_style_mode_controller.dart';
import 'package:tide_and_seek/controllers/voyage_code_preference_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/controllers/shared_route_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/map_style_mode.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/recorded_route_store.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_coordination_mode.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/home/home_map_backdrop.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/internet/plan_directory.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets(
    'the app opens on the map, with the voyage actions on it (#405)',
    (tester) async {
      // It used to open on this form alone, so the one surface that is useful
      // before any decision has been taken sat behind the decision. The actions
      // did not move; they stand on the map now.
      final controller = await _controller();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_app(controller));

      expect(find.byType(HomeMapBackdrop), findsOneWidget);
      expect(find.text('New voyage'), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
    },
  );

  testWidgets('home screen exposes the two voyage entry points', (
    tester,
  ) async {
    final controller = await _controller();
    await tester.pumpWidget(_app(controller));

    expect(find.text('New voyage'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
    // The simulator is behind "More" now, and there is no heading or paragraph
    // at all: #426 removed the start panel rather than shrinking it, because
    // "I don't want the start screen at all" leaves no room for a smaller one.
    expect(find.text('Ready to voyage?'), findsNothing);
    expect(find.text('Try a simulated voyage'), findsNothing);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Try a simulated voyage'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('the map is not covered by a panel (#426)', (tester) async {
    // The reported defect twice over: "the screen is still blocked by a
    // translucent start screen". Asserted as area, because the previous fix
    // moved the panel onto the map and left it covering all of it.
    final controller = await _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));

    final screen = tester.getRect(find.byType(HomeMapBackdrop));
    final actions = tester.getRect(
      find.byKey(const Key('home-voyage-actions')),
    );

    expect(
      actions.height,
      lessThan(screen.height * 0.25),
      reason: 'the actions are a bar on the map, not a screen in front of it',
    );
    expect(
      actions.top,
      greaterThan(screen.center.dy),
      reason: 'and they are at the bottom, leaving the map itself alone',
    );
  });

  testWidgets(
    'a stalled saved-voyage journal falls back to an interactive home screen',
    (tester) async {
      final eventStore = _FirstRestoreBlockingEventStore();
      final sessionStore = InMemorySessionStore();
      await sessionStore.save(
        VoyageSession(
          voyageId: 'voyage-994954',
          voyageCode: '994954',
          inviteSecret: '0123456789abcdef',
          joinToken: 'join-token-0123456789',
          localSailorId: 'sailor-android',
          displayName: 'Android tester',
          role: VoyageRole.sailor,
          joinedAt: DateTime(2026, 7, 28, 9),
        ),
      );
      final controller = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _app(
          controller,
          initializeController: controller.initialize,
          startupFallbackAfter: const Duration(milliseconds: 100),
        ),
      );
      await tester.pump();

      expect(find.text('Restoring your voyage…'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.byKey(const Key('voyage-restoration-banner')),
        findsOneWidget,
      );
      expect(find.text('Still restoring voyage 994954'), findsOneWidget);
      expect(find.byTooltip('Settings'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'New voyage'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Join'))
            .onPressed,
        isNull,
      );

      eventStore.completeFirstRestore(const []);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('voyage-restoration-banner')), findsNothing);
      expect(find.text('Navigation map'), findsOneWidget);
      // ActiveVoyageShell must project the controller's already-restored events,
      // not begin a second full SQLite journal read behind another spinner.
      expect(eventStore.eventsForVoyageCalls, 1);
    },
  );

  // Named for a web planner that does not exist for this app (#68). The code
  // path is real - the relay serves plans by code - so the test stays and only
  // its name changes.
  testWidgets('create voyage accepts a shared passage code', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    _sharedRoutes.clearPending();
    addTearDown(_sharedRoutes.clearPending);
    final plans = _FakePlanDirectory();

    await tester.pumpWidget(_app(controller, planDirectory: plans));
    await tester.tap(find.text('New voyage'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('planned-route-code-field')), findsOneWidget);
    expect(find.text('Planned route code (optional)'), findsOneWidget);
    // Solo is the default (#68), and solo has no code to share, so this test's
    // subject - the share-code handoff - needs crew chosen.
    await tester.tap(find.text('With crew'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('planned-route-code-field')),
      'AB12CD34',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create voyage'),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create voyage'));
    await tester.pumpAndSettle();

    expect(plans.requestedCode, 'AB12CD34');
    expect(find.text('Continue to voyage'), findsOneWidget);

    await tester.tap(find.text('Continue to voyage'));
    expect(_sharedRoutes.pending?.name, 'Peak Loop.gpx');
  });

  testWidgets('a solo voyage skips the group share-code step', (tester) async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('New voyage'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voyage-scope-selector')), findsOneWidget);
    // Solo is the default now (#68), so this reaches Create without touching the
    // selector - which is the point of a solo-first app. The crew description
    // appears only once crew is chosen.
    expect(find.text(VoyageCoordinationMode.solo.description), findsOneWidget);
    expect(find.text(VoyageCoordinationMode.crew.description), findsNothing);

    await tester.tap(find.text('With crew'));
    await tester.pumpAndSettle();
    expect(find.text(VoyageCoordinationMode.crew.description), findsOneWidget);

    await tester.tap(find.text('Solo'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create voyage'),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create voyage'));
    await tester.pumpAndSettle();

    expect(controller.coordinationMode, VoyageCoordinationMode.solo);
    expect(find.text('Continue to voyage'), findsNothing);
    expect(find.text('Ready for solo voyage'), findsOneWidget);
  });

  testWidgets('a solo pre-start map can switch straight to joining a group', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    addTearDown(controller.dispose);
    await controller.createVoyage(
      'Oliver',
      coordinationMode: VoyageCoordinationMode.solo,
    );

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('start-voyage-button')), findsOneWidget);
    expect(
      find.byKey(const Key('join-group-before-start-button')),
      findsOneWidget,
    );
    final joinButton = tester.getRect(
      find.byKey(const Key('join-group-before-start-button')),
    );
    final startButton = tester.getRect(
      find.byKey(const Key('start-voyage-button')),
    );
    expect(joinButton.top, startButton.top);
    expect(joinButton.right, lessThan(startButton.left));

    await tester.tap(find.byKey(const Key('join-group-before-start-button')));
    await tester.pumpAndSettle();

    expect(controller.hasActiveVoyage, isFalse);
    expect(find.text('Join your group'), findsOneWidget);
    expect(find.byKey(const Key('voyage-code-field')), findsOneWidget);
    expect(
      find.byKey(const Key('scan-invitation-labelled-button')),
      findsOneWidget,
    );
  });

  testWidgets('join form keeps the active voyage code above an iOS keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = await _controller();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('voyage-code-field')),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.byKey(const Key('voyage-code-field')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 290);
    await tester.pumpAndSettle();

    final keyboardTop = tester.view.physicalSize.height - 290;
    expect(
      tester.getRect(find.byKey(const Key('voyage-code-field'))).bottom,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join voyage'),
      160,
      scrollable: _voyageFormScrollable,
    );
    expect(find.widgetWithText(FilledButton, 'Join voyage'), findsOneWidget);
  });

  testWidgets('join form explains and clears a remembered voyage code', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    final preference = VoyageCodePreferenceController.memory(
      savedCode: '123456',
    );
    addTearDown(preference.dispose);

    await tester.pumpWidget(_app(controller, voyageCodePreference: preference));
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    final codeField = tester.widget<TextField>(
      find.byKey(const Key('voyage-code-field')),
    );
    expect(codeField.controller?.text, '123456');
    expect(find.text('Saved from your last successful join'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('forget-saved-voyage-code')),
      160,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.byKey(const Key('forget-saved-voyage-code')));
    await tester.pump();

    expect(preference.savedCode, isNull);
    expect(codeField.controller?.text, isEmpty);
    expect(find.text('Saved from your last successful join'), findsNothing);
  });

  testWidgets('only a successful join replaces the remembered code', (
    tester,
  ) async {
    final preference = VoyageCodePreferenceController.memory(
      savedCode: '111111',
    );
    addTearDown(preference.dispose);
    final controller = await _controller(
      voyageCodeDirectory: const _SuccessfulVoyageCodeDirectory(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller, voyageCodePreference: preference));
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('sailor-name-field')),
      'Oliver',
    );
    await tester.enterText(find.byKey(const Key('voyage-code-field')), '123');
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join voyage'),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Join voyage'));
    await tester.pumpAndSettle();
    expect(preference.savedCode, '111111');
    expect(find.text('Enter a valid six-digit voyage code.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('voyage-code-field')),
      '222222',
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Join voyage'),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Join voyage'));
    await tester.pumpAndSettle();

    expect(preference.savedCode, '222222');
    expect(controller.hasActiveVoyage, isTrue);
  });

  // #208: a transient relay failure left a sentence on screen and nothing to
  // press, so a tester at a coffee stop could not get back into her own voyage.
  testWidgets('a transient join failure offers a retry that works', (
    tester,
  ) async {
    final directory = _FlakyVoyageCodeDirectory();
    final controller = await _controller(voyageCodeDirectory: directory);
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('sailor-name-field')),
      'Oliver',
    );

    // A local validation failure is not worth retrying unchanged, so it offers
    // no retry.
    await tester.enterText(find.byKey(const Key('voyage-code-field')), '123');
    await _tapJoin(tester);
    expect(find.text('Enter a valid six-digit voyage code.'), findsOneWidget);
    expect(find.byKey(const Key('retry-voyage-submit')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('voyage-code-field')),
      '994954',
    );
    await _tapJoin(tester);

    expect(find.textContaining('temporarily unavailable'), findsOneWidget);
    expect(controller.hasActiveVoyage, isFalse);

    await tester.scrollUntilVisible(
      find.byKey(const Key('retry-voyage-submit')),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.byKey(const Key('retry-voyage-submit')));
    await tester.pumpAndSettle();

    expect(controller.hasActiveVoyage, isTrue);
    expect(directory.attempts, 2);
  });

  testWidgets('settings can override locale-based distance units', (
    tester,
  ) async {
    final controller = await _controller();
    final distanceUnits = DistanceUnitController.forLocale(
      const Locale('fr', 'FR'),
    );
    addTearDown(distanceUnits.dispose);
    await tester.pumpWidget(
      TideAndSeekApp(
        controller: controller,
        distanceUnits: distanceUnits,
        mapStyleMode: _mapStyleMode,
        voyageCodePreference: _voyageCodePreference,
        sailorProfile: _sailorProfile,
        sharedRoutes: _sharedRoutes,
        recordedRoutes: _recordedRoutes,
        completedVoyages: _completedVoyages,
        enableNativeServices: false,
      ),
    );

    // Nautical by default, whatever the locale (#34).
    expect(distanceUnits.value, DistanceUnit.nauticalMiles);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('DISTANCE UNITS'), findsOneWidget);

    await tester.tap(find.text('Miles'));
    await tester.pumpAndSettle();
    expect(distanceUnits.value, DistanceUnit.miles);
    expect(find.byKey(const Key('use-locale-distance-unit')), findsOneWidget);

    controller.dispose();
  });

  testWidgets('active voyage shows coordination controls', (tester) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Navigation'), findsOneWidget);
    expect(find.text('Navigation map'), findsOneWidget);
    expect(find.byIcon(Icons.map), findsOneWidget);
    expect(voyageDestinationTab, findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);

    await tester.tap(voyageDestinationTab);
    await tester.pumpAndSettle();

    expect(find.text('Oliver'), findsOneWidget);
    expect(find.text('Voyage actions'), findsOneWidget);
    expect(find.text('Alerts and reports'), findsOneWidget);
    expect(find.text('Share voyage summary'), findsOneWidget);
    expect(find.text('Voyage roster'), findsWidgets);
    expect(find.text('Navigation map'), findsNothing);
    expect(find.text('End voyage'), findsNothing);

    expect(find.byKey(const Key('open-voyage-actions')), findsNothing);

    await tester.scrollUntilVisible(
      find.text('QUICK MESSAGES'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('QUICK MESSAGES'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('DISTANCE UNITS'), findsOneWidget);
    expect(find.text('MAP APPEARANCE'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('DAYTIME MAP'),
      260,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('day-map-style-selector')), findsOneWidget);
    await tester.tap(find.text('Original'));
    await tester.pumpAndSettle();
    expect(_mapStyleMode.dayStyle, DayMapStyle.original);

    controller.dispose();
  });

  testWidgets('alerts are a Voyage action rather than a primary destination', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    await controller.startVoyage();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Alerts'), findsNothing);
    await tester.tap(voyageDestinationTab);
    await tester.pumpAndSettle();
    final alerts = find.byKey(const Key('voyage-actions-alerts'));
    await tester.scrollUntilVisible(
      alerts,
      260,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(alerts);
    await tester.pumpAndSettle();

    expect(find.text('Alerts'), findsOneWidget);
    expect(find.text('EXTERNAL SOURCES'), findsNothing);
    expect(find.text('RIDER STATUS'), findsNothing);
  });

  testWidgets(
    'embedded Settings keeps the active voyage behind nested editors',
    (tester) async {
      final controller = await _controller();
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_app(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('DISTANCE UNITS'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-sailor-profile')));
      await tester.pumpAndSettle();
      expect(find.text('Sailor profile'), findsOneWidget);
      Navigator.of(tester.element(find.text('Sailor profile'))).pop();
      await tester.pumpAndSettle();

      expect(find.text('DISTANCE UNITS'), findsOneWidget);
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(controller.session, isNotNull);
    },
  );

  testWidgets('skipper confirms start while pre-start roster stays private', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Waiting to start'), findsOneWidget);
    expect(find.textContaining('Current positions only'), findsOneWidget);
    expect(find.byKey(const Key('pre-start-roster')), findsOneWidget);
    expect(find.textContaining('Oliver (you)'), findsOneWidget);
    expect(
      find.byKey(const Key('join-group-before-start-button')),
      findsNothing,
    );
    expect(controller.voyageStarted, isFalse);

    await tester.tap(find.byKey(const Key('start-voyage-button')));
    await tester.pumpAndSettle();
    expect(find.text('Start this voyage?'), findsOneWidget);
    expect(find.textContaining('No route is selected'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    // This solo voyage has no Sweeper, so the safety warning stands
    // between the confirmation and the start. Its own behaviour is covered by
    // voyage_start_sweeper_warning_test.dart.
    expect(controller.voyageStarted, isFalse);
    await tester.tap(find.byKey(const Key('start-without-sweeper-button')));
    await tester.pumpAndSettle();

    expect(controller.voyageStarted, isTrue);
    expect(find.text('Waiting to start'), findsNothing);
    expect(find.text('Navigation map'), findsOneWidget);
  });

  testWidgets('simulated bikes wait for the skipper to start the voyage', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createSimulationVoyage();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_app(controller));
    for (
      var attempt = 0;
      attempt < 30 && find.byIcon(Icons.science_outlined).evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.science_outlined));
    for (
      var attempt = 0;
      attempt < 30 && find.text('READY').evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('READY'), findsOneWidget);
    expect(find.text('Waiting for start'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('simulation-play-pause')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('start-voyage-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-start-voyage-button')));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 30 && find.text('RUNNING').evaluate().isEmpty;
      attempt += 1
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(controller.voyageStarted, isTrue);
    expect(find.text('RUNNING'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('the voyage navigation bar names its destinations (#306)', (
    tester,
  ) async {
    // It was `alwaysHide`, which made the app's primary navigation four
    // unlabelled icons — the thing #306 says no feature may be reachable only
    // through. The bar is hidden while the sailor is moving, so the height the
    // labels cost is only ever paid at a standstill.
    //
    // Portrait explicitly: the default test viewport is landscape, where the
    // shell uses the rail instead and there is no bar to find.
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await _controller();
    await controller.createVoyage('Oliver');

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.labelBehavior, NavigationDestinationLabelBehavior.alwaysShow);
    for (final label in ['Map', 'Voyage', 'Settings']) {
      expect(find.text(label), findsWidgets, reason: label);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    controller.dispose();
  });

  testWidgets(
    'active voyage moves navigation chrome to a left rail in landscape',
    (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = await _controller();
      await controller.createVoyage('Oliver');

      await tester.pumpWidget(_app(controller));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsNothing);
      expect(
        find.byKey(const Key('landscape-navigation-rail')),
        findsOneWidget,
      );
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      // Named destinations, not four bare icons (#306). The rail is hidden
      // while the sailor is moving, so the width the labels cost is only ever
      // paid at a standstill.
      expect(rail.minWidth, 72);
      expect(rail.labelType, NavigationRailLabelType.all);
      for (final label in ['Map', 'Voyage', 'Settings']) {
        expect(find.text(label), findsWidgets, reason: label);
      }

      controller.dispose();
    },
  );

  testWidgets('active voyage can be left to choose another voyage', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(voyageDestinationTab);
    await tester.pumpAndSettle();
    final leaveOrEnd = find.byKey(const Key('voyage-actions-leave-or-end'));
    await tester.ensureVisible(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(leaveOrEnd);
    await tester.pumpAndSettle();
    expect(find.text('Leave or end this voyage?'), findsOneWidget);

    await tester.tap(find.text('Leave only'));
    await tester.pumpAndSettle();

    expect(find.text('New voyage'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget);
    expect(controller.hasActiveVoyage, isFalse);

    controller.dispose();
  });

  testWidgets('ended voyage retains relay recovery until removal', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    await tester.tap(voyageDestinationTab);
    await tester.pumpAndSettle();
    final leaveOrEnd = find.byKey(const Key('voyage-actions-leave-or-end'));
    await tester.ensureVisible(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(leaveOrEnd);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('end-voyage-for-everyone')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'End voyage'));
    await tester.pumpAndSettle();

    expect(find.text('Voyage summary ready'), findsOneWidget);
    // Renamed in #156: the button files the voyage to Previous voyages, and the old
    // label said it was removed from the phone.
    expect(find.text('Finish and file in Previous voyages'), findsOneWidget);
    expect(controller.voyageEnded, isTrue);
    expect(controller.hasActiveVoyage, isTrue);

    await tester.tap(find.text('Share voyage recap image'));
    await tester.pumpAndSettle();
    expect(find.text('Voyage recap'), findsOneWidget);
    expect(find.byKey(const Key('share-recap-image-button')), findsOneWidget);

    controller.dispose();
  });

  // #207: the voyage-ended screen used to be the whole app with no way back, so
  // the only exit filed the voyage and stopped relay recovery.
  testWidgets('ended voyage can be closed and reopened without filing it', (
    tester,
  ) async {
    final controller = await _controller();
    await controller.createVoyage('Oliver');
    await controller.endVoyage();
    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();

    expect(find.text('Voyage summary ready'), findsOneWidget);
    final voyageCode = controller.session!.voyageCode;

    await tester.tap(find.byKey(const Key('leave-ended-voyage-button')));
    await tester.pumpAndSettle();

    expect(find.text('New voyage'), findsOneWidget);
    expect(find.byKey(const Key('set-aside-voyage-banner')), findsOneWidget);
    expect(find.text('Voyage $voyageCode has ended'), findsOneWidget);
    // Nothing was given up to get here.
    expect(controller.hasActiveVoyage, isTrue);
    expect(controller.voyageEnded, isTrue);

    await tester.tap(find.byKey(const Key('reopen-set-aside-voyage')));
    await tester.pumpAndSettle();

    expect(find.text('Voyage summary ready'), findsOneWidget);

    // The app-bar close is the other way out, and it behaves the same.
    await tester.tap(find.byKey(const Key('leave-ended-voyage-screen-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set-aside-voyage-banner')), findsOneWidget);

    controller.dispose();
  });

  testWidgets('creating after a set-aside ended voyage opens the new voyage', (
    tester,
  ) async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await controller.createVoyage('Oliver');
    final endedVoyageId = controller.session!.voyageId;
    await controller.endVoyage();
    controller.setEndedVoyageAside();

    await tester.pumpWidget(_app(controller));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set-aside-voyage-banner')), findsOneWidget);

    await tester.tap(find.text('New voyage'));
    await tester.pumpAndSettle();
    // Crew, because "Continue to voyage" is the share-code handoff and solo -
    // the default since #68 - has no code to share.
    await tester.tap(find.text('With crew'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Create voyage'),
      180,
      scrollable: _voyageFormScrollable,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create voyage'));
    await tester.pumpAndSettle();
    expect(find.text('Continue to voyage'), findsOneWidget);

    await tester.tap(find.text('Continue to voyage'));
    await tester.pumpAndSettle();

    expect(controller.session?.voyageId, isNot(endedVoyageId));
    expect(controller.voyageEnded, isFalse);
    expect(controller.endedVoyageSetAside, isFalse);
    expect(find.text('Navigation map'), findsOneWidget);
  });
}

late SailorProfileController _sailorProfile;
late SharedRouteController _sharedRoutes;
late MapStyleModeController _mapStyleMode;
late VoyageCodePreferenceController _voyageCodePreference;
late CompletedVoyagesController _completedVoyages;
final _recordedRoutes = InMemoryRecordedRouteStore();
final _voyageFormScrollable = find
    .descendant(
      of: find.byKey(const Key('voyage-form-scroll-view')),
      matching: find.byType(Scrollable),
    )
    .first;

TideAndSeekApp _app(
  VoyageController controller, {
  VoyageCodePreferenceController? voyageCodePreference,
  PlanDirectory? planDirectory,
  Future<void> Function()? initializeController,
  Duration startupFallbackAfter = const Duration(seconds: 2),
}) => TideAndSeekApp(
  controller: controller,
  distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
  mapStyleMode: _mapStyleMode,
  voyageCodePreference: voyageCodePreference ?? _voyageCodePreference,
  sailorProfile: _sailorProfile,
  sharedRoutes: _sharedRoutes,
  recordedRoutes: _recordedRoutes,
  completedVoyages: _completedVoyages,
  planDirectory: planDirectory,
  enableNativeServices: false,
  initializeController: initializeController,
  startupFallbackAfter: startupFallbackAfter,
);

Future<VoyageController> _controller({
  VoyageCodeDirectory? voyageCodeDirectory,
}) async {
  final controller = VoyageController(
    InMemoryEventStore(),
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
    voyageCodeDirectory: voyageCodeDirectory,
  );
  await controller.initialize();
  return controller;
}

Future<void> _tapJoin(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.widgetWithText(FilledButton, 'Join voyage'),
    180,
    scrollable: _voyageFormScrollable,
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Join voyage'));
  await tester.pumpAndSettle();
}

/// Fails the first resolve the way an unreachable relay does, then succeeds.
class _FlakyVoyageCodeDirectory implements VoyageCodeDirectory {
  int attempts = 0;

  @override
  void close() {}

  @override
  Future<void> register(VoyageSession session) async {}

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async {
    attempts += 1;
    if (attempts == 1) {
      throw const VoyageCodeDirectoryException(
        'Voyage code service is temporarily unavailable. Check your connection '
        'and try again.',
        retryable: true,
      );
    }
    return VoyageCodeCredentials(
      voyageId: 'voyage-$voyageCode',
      voyageCode: voyageCode,
      inviteSecret: 'test-invite-secret-0123456789',
      joinToken: 'test-join-token-0123456789',
    );
  }
}

class _FirstRestoreBlockingEventStore extends InMemoryEventStore {
  final _firstRestore = Completer<List<VoyageEvent>>();
  int eventsForVoyageCalls = 0;

  @override
  Future<List<VoyageEvent>> eventsForVoyage(String voyageId) {
    eventsForVoyageCalls += 1;
    if (eventsForVoyageCalls == 1) return _firstRestore.future;
    return Completer<List<VoyageEvent>>().future;
  }

  void completeFirstRestore(List<VoyageEvent> events) {
    _firstRestore.complete(events);
  }
}

class _SuccessfulVoyageCodeDirectory implements VoyageCodeDirectory {
  const _SuccessfulVoyageCodeDirectory();

  @override
  void close() {}

  @override
  Future<void> register(VoyageSession session) async {}

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async => VoyageCodeCredentials(
    voyageId: 'voyage-$voyageCode',
    voyageCode: voyageCode,
    inviteSecret: 'test-invite-secret-0123456789',
    joinToken: 'test-join-token-0123456789',
  );
}

class _FakePlanDirectory implements PlanDirectory {
  String? requestedCode;

  @override
  Future<FetchedPlan> fetch(String code) async {
    requestedCode = code;
    return const FetchedPlan(
      name: 'Peak Loop',
      gpx:
          '<gpx version="1.1"><trk><trkseg>'
          '<trkpt lat="53.1" lon="-1.2"/>'
          '<trkpt lat="53.2" lon="-1.1"/>'
          '</trkseg></trk></gpx>',
    );
  }
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

/// The Voyage destination in the shell's navigation bar or landscape rail.
///
/// Found by its label rather than by icon data: the destination now draws the
/// app's own [MarineGlyph] instead of a Material icon (#30), and #306 requires
/// the label to be there anyway, so this is also the affordance a sailor uses.
///
/// Matches in either chrome, because which one the shell builds depends on the
/// surface shape and the default test viewport is landscape.
final voyageDestinationTab = find.byWidgetPredicate(
  (widget) => widget is Text && widget.data == 'Voyage',
);
