import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_simulation_controller.dart';
import 'package:tide_and_seek/controllers/situational_awareness_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/simulation/voyage_simulation_screen.dart';

void main() {
  testWidgets(
    'Voyage Lab disables motion before the skipper starts the voyage',
    (tester) async {
      final session = VoyageSession(
        voyageId: 'staged-sim-voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'simulation-secret-that-is-long-enough',
        joinToken: 'test-join-token-0123456789',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.lead,
        joinedAt: DateTime.utc(2026, 7, 17),
        isSimulation: true,
      );
      const route = [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ];
      final awareness = SituationalAwarenessController(
        InMemoryEventStore(),
        session,
        route: route,
        voyageStarted: false,
      );
      await awareness.initialize();
      final simulation = VoyageSimulationController(
        awareness,
        session: session,
        route: route,
        tickInterval: const Duration(days: 1),
        voyageStarted: false,
      );
      await simulation.initialize();
      addTearDown(() {
        simulation.dispose();
        awareness.dispose();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: VoyageSimulationScreen(
            controller: simulation,
            onRestart: () async {},
            onExit: () async {},
            onRoleChanged: (role) async => simulation.setLocalRole(role),
            onToggleMarker: () async =>
                simulation.setMarkerMode(!simulation.markerMode),
            onGetUnderWay: () async => simulation.getUnderWay(),
            onSailorCountChanged: (_) async {},
          ),
        ),
      );

      expect(find.text('READY'), findsOneWidget);
      expect(find.text('Waiting for start'), findsOneWidget);
      final playButton = tester.widget<FilledButton>(
        find.byKey(const Key('simulation-play-pause')),
      );
      expect(playButton.onPressed, isNull);
    },
  );

  testWidgets('Voyage Lab exposes fleet scenarios in landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = VoyageSession(
      voyageId: 'sim-voyage',
      voyageCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'lead',
      displayName: 'Demo Lead',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.9),
    ];
    final awareness = SituationalAwarenessController(
      InMemoryEventStore(),
      session,
      route: route,
    );
    await awareness.initialize();
    final simulation = VoyageSimulationController(
      awareness,
      session: session,
      route: route,
      tickInterval: const Duration(days: 1),
    );
    await simulation.initialize();
    addTearDown(() {
      simulation.dispose();
      awareness.dispose();
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VoyageSimulationScreen(
          controller: simulation,
          onRestart: () async {},
          onExit: () async {},
          onRoleChanged: (role) async => simulation.setLocalRole(role),
          onToggleMarker: () async =>
              simulation.setMarkerMode(!simulation.markerMode),
          onGetUnderWay: () async => simulation.getUnderWay(),
          onSailorCountChanged: (_) async {},
        ),
      ),
    );

    expect(find.text('Voyage Lab'), findsOneWidget);
    expect(find.text('VIRTUAL FLEET'), findsOneWidget);
    expect(find.text('Demo Lead'), findsOneWidget);
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.byKey(const Key('simulation-off-route')), findsOneWidget);
    expect(find.byKey(const Key('simulation-role')), findsOneWidget);
    expect(find.text('Follower'), findsOneWidget);
    expect(find.byKey(const Key('simulation-marker-mode')), findsOneWidget);
    expect(find.byKey(const Key('simulation-sailor-count')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('simulation-off-route')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('simulation-off-route')));
    await tester.pump();
    expect(simulation.alexOffRoute, isTrue);

    await tester.ensureVisible(find.text('Follower'));
    await tester.tap(find.text('Follower'));
    await tester.pump();
    expect(simulation.localRole, VoyageRole.sailor);

    await tester.ensureVisible(find.byKey(const Key('simulation-marker-mode')));
    await tester.tap(find.byKey(const Key('simulation-marker-mode')));
    await tester.pump();
    expect(simulation.markerMode, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('automatic junction marker shows the TEC voyage-off prompt', (
    tester,
  ) async {
    final session = VoyageSession(
      voyageId: 'marker-sim-voyage',
      voyageCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'lead',
      displayName: 'Demo Lead',
      role: VoyageRole.lead,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.9),
    ];
    final awareness = SituationalAwarenessController(
      InMemoryEventStore(),
      session,
      route: route,
    );
    await awareness.initialize();
    final simulation = VoyageSimulationController(
      awareness,
      session: session,
      route: route,
      markerJunctions: const [GeoPoint(latitude: 51, longitude: -0.99)],
      tickInterval: const Duration(days: 1),
    );
    await simulation.initialize();
    simulation.setLocalRole(VoyageRole.sailor);
    await simulation.advance(const Duration(seconds: 4));
    for (var tick = 0; tick < 180; tick += 1) {
      await simulation.advance(const Duration(milliseconds: 100));
      if (simulation.markerPhase == SimulationMarkerPhase.sweeperApproaching) {
        break;
      }
    }
    addTearDown(() {
      simulation.dispose();
      awareness.dispose();
    });
    expect(simulation.markerPhase, SimulationMarkerPhase.sweeperApproaching);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VoyageSimulationScreen(
          controller: simulation,
          onRestart: () async {},
          onExit: () async {},
          onRoleChanged: (role) async => simulation.setLocalRole(role),
          onToggleMarker: () async =>
              simulation.setMarkerMode(!simulation.markerMode),
          onGetUnderWay: () async => simulation.getUnderWay(),
          onSailorCountChanged: (_) async {},
        ),
      ),
    );

    expect(
      find.byKey(const Key('simulation-auto-marker-viewport')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('simulation-get-ready-to-voyage-off')),
      findsOneWidget,
    );
  });
}
