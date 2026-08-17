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
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Starting a voyage with no Sweeper silently removes the safety role
/// the app is named after, so the skipper is warned before the voyage starts
/// rather than after.
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
    _completedVoyages = await CompletedVoyagesController.load(
      InMemoryCompletedVoyageStore(),
    );
  });

  testWidgets(
    'a voyage with no TEC warns before it starts and names the loss',
    (tester) async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      await harness.controller.createVoyage('Oliver');

      await tester.pumpWidget(harness.app);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-voyage-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-without-route-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('no-sweeper-warning')), findsOneWidget);
      expect(find.text('No Sweeper'), findsOneWidget);
      expect(find.textContaining('no back-marker'), findsOneWidget);
      expect(find.textContaining('no distance to the back'), findsOneWidget);
      expect(find.textContaining('falls a long way behind'), findsOneWidget);
      // The warning must not have started the voyage behind the skipper's back.
      expect(harness.controller.voyageStarted, isFalse);

      // Proceeding is a single deliberate action, not a block.
      await tester.tap(find.byKey(const Key('start-without-sweeper-button')));
      await tester.pumpAndSettle();

      expect(harness.controller.voyageStarted, isTrue);
      expect(find.byKey(const Key('no-sweeper-warning')), findsNothing);
    },
  );

  testWidgets(
    'the warning is shown once per voyage start, not during the voyage',
    (tester) async {
      final harness = await _harness();
      addTearDown(harness.dispose);
      await harness.controller.createVoyage('Oliver');

      await tester.pumpWidget(harness.app);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-voyage-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-without-route-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-without-sweeper-button')));
      await tester.pumpAndSettle();

      expect(harness.controller.voyageStarted, isTrue);

      // The voyage is running with no TEC. Nothing may re-open the warning while
      // it runs: it lives in the start confirmation only.
      for (var frame = 0; frame < 5; frame += 1) {
        await tester.pump(const Duration(seconds: 3));
        expect(find.byKey(const Key('no-sweeper-warning')), findsNothing);
      }
      harness.controller.refreshMembershipFreshness();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('no-sweeper-warning')), findsNothing);
    },
  );

  testWidgets('a registered TEC starts the voyage with no warning at all', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createVoyage('Oliver');
    // A TEC who has joined but never reported a position still counts: the
    // check reads the reconciled membership model, not a location snapshot.
    await harness.joinRemoteSailor(
      sailorId: 'charlie',
      displayName: 'Charlie',
      role: VoyageRole.sweeper,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-sweeper-warning')), findsNothing);
    expect(harness.controller.voyageStarted, isTrue);
  });

  testWidgets('a sailor who is not the TEC does not satisfy the warning', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createVoyage('Oliver');
    await harness.joinRemoteSailor(
      sailorId: 'alex',
      displayName: 'Alex',
      role: VoyageRole.sailor,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('no-sweeper-warning')), findsOneWidget);
    expect(harness.controller.voyageStarted, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(harness.controller.voyageStarted, isFalse);
    expect(find.text('Waiting to start'), findsOneWidget);
  });

  testWidgets('the warning offers the roster as the role-assignment route', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createVoyage('Oliver');
    await harness.joinRemoteSailor(
      sailorId: 'alex',
      displayName: 'Alex',
      role: VoyageRole.sailor,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-voyage-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-without-route-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('assign-sweeper-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voyage-roster-list')), findsOneWidget);
    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsOneWidget,
    );
    // Issue #128 turned this signpost into an action: the skipper can ask Alex
    // directly. It stays a request, so the notice still says Alex must accept.
    expect(find.byKey(const Key('ask-sweeper-alex')), findsOneWidget);
    expect(find.textContaining('have to accept'), findsOneWidget);
    // Choosing to fix the gap does not start the voyage.
    expect(harness.controller.voyageStarted, isFalse);
  });

  testWidgets('the roster drops the missing-TEC notice once a TEC exists', (
    tester,
  ) async {
    final harness = await _harness();
    addTearDown(harness.dispose);
    await harness.controller.createVoyage('Oliver');
    await harness.joinRemoteSailor(
      sailorId: 'charlie',
      displayName: 'Charlie',
      role: VoyageRole.sweeper,
    );

    await tester.pumpWidget(harness.app);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.two_wheeler_outlined));
    await tester.pumpAndSettle();
    final roster = find.byKey(const Key('voyage-menu-open-roster'));
    await tester.scrollUntilVisible(
      roster,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(roster);
    await tester.pumpAndSettle();
    await tester.tap(roster);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voyage-roster-list')), findsOneWidget);
    expect(
      find.byKey(const Key('roster-missing-sweeper-notice')),
      findsNothing,
    );
    expect(find.byKey(const Key('roster-sailor-charlie')), findsOneWidget);
  });
}

late SailorProfileController _sailorProfile;
late SharedRouteController _sharedRoutes;
late MapStyleModeController _mapStyleMode;
late CompletedVoyagesController _completedVoyages;

Future<_Harness> _harness() async {
  final eventStore = InMemoryEventStore();
  final controller = VoyageController(
    eventStore,
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
  );
  await controller.initialize();
  return _Harness(controller, eventStore);
}

class _Harness {
  _Harness(this.controller, this.eventStore);

  final VoyageController controller;
  final InMemoryEventStore eventStore;

  TideAndSeekApp get app => TideAndSeekApp(
    controller: controller,
    distanceUnits: DistanceUnitController.forLocale(const Locale('en', 'GB')),
    mapStyleMode: _mapStyleMode,
    voyageCodePreference: VoyageCodePreferenceController.memory(),
    sailorProfile: _sailorProfile,
    sharedRoutes: _sharedRoutes,
    recordedRoutes: InMemoryRecordedRouteStore(),
    completedVoyages: _completedVoyages,
    enableNativeServices: false,
  );

  /// Appends the signed join another device would have relayed, so the
  /// membership reducer resolves the same roster the skipper's phone would.
  Future<void> joinRemoteSailor({
    required String sailorId,
    required String displayName,
    required VoyageRole role,
  }) async {
    final session = controller.session!;
    final unsigned = VoyageEvent(
      id: 'join-$sailorId',
      voyageId: session.voyageId,
      deviceId: sailorId,
      type: VoyageEventType.sailorJoined,
      priority: EventPriority.important,
      createdAt: DateTime.now(),
      payload: {'displayName': displayName, 'role': role.name},
      signature: '',
    );
    await eventStore.append(
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

  void dispose() => controller.dispose();
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
