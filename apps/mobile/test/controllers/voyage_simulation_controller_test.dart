import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_simulation_controller.dart';
import 'package:tide_and_seek/controllers/situational_awareness_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/route_alert.dart';
import 'package:tide_and_seek/services/voyage_completion_detector.dart';

void main() {
  late InMemoryEventStore store;
  late SituationalAwarenessController awareness;
  late VoyageSimulationController simulation;

  setUp(() async {
    store = InMemoryEventStore();
    final session = VoyageSession(
      voyageId: 'sim-voyage',
      voyageCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'lead',
      displayName: 'Demo Lead',
      role: VoyageRole.skipper,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    const route = [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 51, longitude: -0.9),
    ];
    awareness = SituationalAwarenessController(store, session, route: route);
    await awareness.initialize();
    simulation = VoyageSimulationController(
      awareness,
      session: session,
      route: route,
      tickInterval: const Duration(days: 1),
    );
    await simulation.initialize();
  });

  tearDown(() {
    simulation.dispose();
    awareness.dispose();
  });

  test(
    'emits an authenticated five-bike fleet and advances virtual time',
    () async {
      expect(awareness.sailorLocations, hasLength(5));
      expect(awareness.authenticatedLocationEvidence, hasLength(5));
      expect(
        awareness.sailorLocations
            .singleWhere(
              (location) =>
                  location.sailorId ==
                  VoyageSimulationController.sweeperSailorId,
            )
            .role,
        VoyageRole.sweeper,
      );

      final initialProgress = simulation.progress;
      await simulation.advance(const Duration(seconds: 2));

      expect(simulation.progress, greaterThan(initialProgress));
      expect(simulation.simulatedElapsed, const Duration(seconds: 16));
    },
  );

  test('keeps the fleet staged until the voyage starts', () async {
    final stagedSession = VoyageSession(
      voyageId: 'staged-sim-voyage',
      voyageCode: 'SIM123',
      inviteSecret: 'simulation-secret-that-is-long-enough',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'lead',
      displayName: 'Demo Lead',
      role: VoyageRole.skipper,
      joinedAt: DateTime.utc(2026, 7, 17),
      isSimulation: true,
    );
    final stagedAwareness = SituationalAwarenessController(
      InMemoryEventStore(),
      stagedSession,
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ],
      voyageStarted: false,
    );
    await stagedAwareness.initialize();
    final stagedSimulation = VoyageSimulationController(
      stagedAwareness,
      session: stagedSession,
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ],
      tickInterval: const Duration(days: 1),
      voyageStarted: false,
    );
    addTearDown(() {
      stagedSimulation.dispose();
      stagedAwareness.dispose();
    });
    await stagedSimulation.initialize();

    final initialProgress = stagedSimulation.progress;
    stagedSimulation.start();
    await stagedSimulation.advance(const Duration(seconds: 2));

    expect(stagedSimulation.state, VoyageSimulationState.ready);
    expect(stagedSimulation.progress, initialProgress);
    expect(stagedSimulation.simulatedElapsed, Duration.zero);
    expect(
      stagedSimulation.sailors.every(
        (sailor) => sailor.speedMetersPerSecond == 0,
      ),
      isTrue,
    );

    stagedSimulation.setVoyageStarted(true);
    stagedSimulation.start();
    await stagedSimulation.advance(const Duration(seconds: 2));

    expect(stagedSimulation.state, VoyageSimulationState.running);
    expect(stagedSimulation.progress, greaterThan(initialProgress));
  });

  test('uses short updates for continuous visual movement', () {
    final smoothSimulation = VoyageSimulationController(
      awareness,
      session: VoyageSession(
        voyageId: 'sim-voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'simulation-secret-that-is-long-enough',
        joinToken: 'test-join-token-0123456789',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.skipper,
        joinedAt: DateTime.utc(2026, 7, 17),
        isSimulation: true,
      ),
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ],
    );
    addTearDown(smoothSimulation.dispose);

    expect(smoothSimulation.tickInterval, const Duration(milliseconds: 100));
    expect(smoothSimulation.eventInterval, const Duration(seconds: 2));
  });

  test('supports a configurable thirty-sailor fleet', () async {
    final largeFleet = VoyageSimulationController(
      awareness,
      session: VoyageSession(
        voyageId: 'sim-voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'simulation-secret-that-is-long-enough',
        joinToken: 'test-join-token-0123456789',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.skipper,
        joinedAt: DateTime.utc(2026, 7, 17),
        isSimulation: true,
        simulationSailorCount: 30,
      ),
      route: const [
        GeoPoint(latitude: 51, longitude: -1),
        GeoPoint(latitude: 51, longitude: -0.9),
      ],
      sailorCount: 30,
      tickInterval: const Duration(days: 1),
    );
    addTearDown(largeFleet.dispose);
    await largeFleet.initialize();

    expect(largeFleet.sailorCount, 30);
    expect(largeFleet.sailors, hasLength(30));
    expect(
      largeFleet.sailors.map((sailor) => sailor.id).toSet(),
      hasLength(30),
    );
    expect(
      largeFleet.sailors.where((sailor) => sailor.role == VoyageRole.sweeper),
      hasLength(1),
    );
    largeFleet.setAlexOffRoute(true);
    await largeFleet.advance(const Duration(seconds: 1));
    expect(
      largeFleet.sailors
          .singleWhere(
            (sailor) =>
                sailor.id == VoyageSimulationController.offRouteSailorId,
          )
          .isOffRoute,
      isTrue,
    );
  });

  test('retains a recent trail for the simulated skipper', () async {
    final initialSkipper = simulation.sailors.singleWhere(
      (sailor) => sailor.role == VoyageRole.skipper,
    );
    final sweeper = simulation.sailors.singleWhere(
      (sailor) => sailor.role == VoyageRole.sweeper,
    );
    expect(initialSkipper.travelTrail.length, greaterThan(1));
    expect(
      initialSkipper.travelTrail.first.latitude,
      closeTo(sweeper.position.latitude, 1e-7),
    );
    expect(
      initialSkipper.travelTrail.first.longitude,
      closeTo(sweeper.position.longitude, 1e-7),
    );

    await simulation.advance(const Duration(seconds: 1));

    final movingSkipper = simulation.sailors.singleWhere(
      (sailor) => sailor.role == VoyageRole.skipper,
    );
    expect(movingSkipper.travelTrail.length, greaterThan(1));
  });

  test('switches between skipper, follower and TEC perspectives', () {
    simulation.setLocalRole(VoyageRole.sailor);
    expect(simulation.localRole, VoyageRole.sailor);
    final follower = simulation.sailors.singleWhere((sailor) => sailor.isLocal);
    final skipper = simulation.sailors.singleWhere(
      (sailor) => sailor.displayName == 'Maya',
    );
    expect(follower.displayName, 'You · Follower');
    expect(follower.progress, lessThan(skipper.progress));
    expect(skipper.role, VoyageRole.skipper);

    simulation.setLocalRole(VoyageRole.sweeper);
    expect(simulation.localRole, VoyageRole.sweeper);
    expect(
      simulation.sailors
          .singleWhere(
            (sailor) => sailor.id == VoyageSimulationController.sweeperSailorId,
          )
          .role,
      VoyageRole.sailor,
    );
  });

  test('follower perspective remains behind the simulated skipper', () async {
    simulation.setLocalRole(VoyageRole.sailor);
    simulation.setTimeScale(1);

    await simulation.advance(const Duration(seconds: 30));

    final follower = simulation.sailors.singleWhere((sailor) => sailor.isLocal);
    final skipper = simulation.sailors.singleWhere(
      (sailor) => sailor.displayName == 'Maya',
    );
    expect(follower.role, VoyageRole.sailor);
    expect(skipper.role, VoyageRole.skipper);
    expect(follower.progress, lessThan(skipper.progress));
  });

  test(
    'marker mode freezes the local bike while the group continues',
    () async {
      final localBefore = simulation.sailors.singleWhere(
        (sailor) => sailor.isLocal,
      );
      final mayaBefore = simulation.sailors.singleWhere(
        (sailor) => sailor.displayName == 'Maya',
      );
      simulation.setMarkerMode(true);

      await simulation.advance(const Duration(seconds: 1));

      final localAfter = simulation.sailors.singleWhere(
        (sailor) => sailor.isLocal,
      );
      final mayaAfter = simulation.sailors.singleWhere(
        (sailor) => sailor.displayName == 'Maya',
      );
      expect(localAfter.role, VoyageRole.marker);
      expect(localAfter.progress, localBefore.progress);
      expect(localAfter.speedMetersPerSecond, 0);
      expect(mayaAfter.progress, greaterThan(mayaBefore.progress));
    },
  );

  test(
    'follower automatically marks a junction and voyages off before TEC arrives',
    () async {
      final markerSimulation = VoyageSimulationController(
        awareness,
        session: VoyageSession(
          voyageId: 'sim-voyage',
          voyageCode: 'SIM123',
          inviteSecret: 'simulation-secret-that-is-long-enough',
          joinToken: 'test-join-token-0123456789',
          localSailorId: 'lead',
          displayName: 'Demo Lead',
          role: VoyageRole.skipper,
          joinedAt: DateTime.utc(2026, 7, 17),
          isSimulation: true,
        ),
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.9),
        ],
        markerJunctions: const [GeoPoint(latitude: 51, longitude: -0.99)],
        tickInterval: const Duration(days: 1),
      );
      addTearDown(markerSimulation.dispose);
      await markerSimulation.initialize();
      markerSimulation.setLocalRole(VoyageRole.sailor);

      await markerSimulation.advance(const Duration(seconds: 4));

      final stopped = markerSimulation.sailors.singleWhere(
        (sailor) => sailor.isLocal,
      );
      expect(markerSimulation.markerMode, isTrue);
      expect(markerSimulation.automaticMarkerActivation, 1);
      expect(
        markerSimulation.markerPhase,
        SimulationMarkerPhase.waitingForSailors,
      );
      expect(stopped.role, VoyageRole.marker);
      expect(stopped.speedMetersPerSecond, 0);
      expect(markerSimulation.sailorsExpectedToPass, greaterThanOrEqualTo(1));
      expect(markerSimulation.markerInstruction, contains('You are holding'));

      var sawSweeperApproaching = false;
      for (
        var tick = 0;
        tick < 180 &&
            markerSimulation.automaticMarkerGetUnderWayActivation == 0;
        tick += 1
      ) {
        await markerSimulation.advance(const Duration(milliseconds: 100));
        sawSweeperApproaching |=
            markerSimulation.markerPhase ==
            SimulationMarkerPhase.sweeperApproaching;
      }

      expect(sawSweeperApproaching, isTrue);
      expect(markerSimulation.automaticMarkerGetUnderWayActivation, 1);
      expect(markerSimulation.lastAutomaticMarkerGetUnderWayWasLocal, isTrue);
      expect(markerSimulation.markerMode, isFalse);
      expect(markerSimulation.markerPhase, SimulationMarkerPhase.riding);
      expect(
        markerSimulation.sailors.singleWhere((sailor) => sailor.isLocal).role,
        VoyageRole.sailor,
      );
    },
  );

  test(
    'the simulated second bike marks a route decision from skipper view',
    () async {
      final markerSimulation = VoyageSimulationController(
        awareness,
        session: VoyageSession(
          voyageId: 'sim-voyage',
          voyageCode: 'SIM123',
          inviteSecret: 'simulation-secret-that-is-long-enough',
          joinToken: 'test-join-token-0123456789',
          localSailorId: 'lead',
          displayName: 'Demo Lead',
          role: VoyageRole.skipper,
          joinedAt: DateTime.utc(2026, 7, 17),
          isSimulation: true,
        ),
        route: const [
          GeoPoint(latitude: 51, longitude: -1),
          GeoPoint(latitude: 51, longitude: -0.9),
        ],
        markerJunctions: const [GeoPoint(latitude: 51, longitude: -0.99)],
        tickInterval: const Duration(days: 1),
      );
      addTearDown(markerSimulation.dispose);
      await markerSimulation.initialize();

      for (
        var tick = 0;
        tick < 20 && !markerSimulation.automaticMarkerActive;
        tick += 1
      ) {
        await markerSimulation.advance(const Duration(seconds: 1));
      }

      final maya = markerSimulation.sailors.singleWhere(
        (sailor) => sailor.id == 'voyage-lab-maya',
      );
      expect(markerSimulation.localRole, VoyageRole.skipper);
      expect(markerSimulation.automaticMarkerActive, isTrue);
      expect(markerSimulation.automaticMarkerIsLocal, isFalse);
      expect(markerSimulation.automaticMarkerSailorName, 'Maya');
      expect(maya.role, VoyageRole.marker);
      expect(maya.speedMetersPerSecond, 0);
      expect(markerSimulation.markerInstruction, contains('Maya is holding'));

      markerSimulation.setLocalRole(VoyageRole.sailor);
      expect(markerSimulation.localRole, VoyageRole.sailor);
      expect(
        markerSimulation.sailors
            .singleWhere((sailor) => sailor.id == maya.id)
            .role,
        VoyageRole.marker,
      );
    },
  );

  test(
    'off-route scenario drives real alert hysteresis and recovery',
    () async {
      simulation.setAlexOffRoute(true);
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));

      final alert = awareness.alertFor(
        VoyageSimulationController.offRouteSailorId,
      );
      expect(alert?.assessment.state, RouteTrackingState.offRoute);
      expect(alert?.assessment.alertLevel, RouteAlertLevel.urgent);
      expect(alert?.assessment.distanceFromRouteMeters, greaterThan(120));

      simulation.setAlexOffRoute(false);
      await simulation.advance(const Duration(seconds: 1));
      await simulation.advance(const Duration(seconds: 1));

      expect(
        awareness
            .alertFor(VoyageSimulationController.offRouteSailorId)
            ?.assessment
            .state,
        RouteTrackingState.onRoute,
      );
    },
  );

  test(
    'off-route visual trail is local to the current simulation run',
    () async {
      simulation.setAlexOffRoute(true);
      await simulation.advance(const Duration(seconds: 1));

      final alex = simulation.sailors.singleWhere(
        (sailor) => sailor.id == VoyageSimulationController.offRouteSailorId,
      );
      expect(alex.offRouteTrail, hasLength(greaterThanOrEqualTo(2)));
      expect(
        alex.offRouteTrail.every(
          (point) => point.latitude > 50 && point.latitude < 52,
        ),
        isTrue,
      );

      simulation.setAlexOffRoute(false);
      expect(
        simulation.sailors
            .singleWhere(
              (sailor) =>
                  sailor.id == VoyageSimulationController.offRouteSailorId,
            )
            .offRouteTrail,
        isEmpty,
      );
    },
  );

  test('can delay TEC and inject a synthetic roadworks hazard', () async {
    final normalSweeperSpeed = simulation.sailors
        .singleWhere(
          (sailor) => sailor.id == VoyageSimulationController.sweeperSailorId,
        )
        .speedMetersPerSecond;
    simulation.setSweeperDelayed(true);
    final delayedSweeperSpeed = simulation.sailors
        .singleWhere(
          (sailor) => sailor.id == VoyageSimulationController.sweeperSailorId,
        )
        .speedMetersPerSecond;
    expect(delayedSweeperSpeed, lessThan(normalSweeperSpeed));
  });

  test('completion publishes stopped GPS fixes', () async {
    simulation.setTimeScale(16);
    // A marker can be released during one visual step, then needs the next
    // step to rejoin the fleet. Completion is intentionally group-wide.
    for (var index = 0; index < 3; index += 1) {
      await simulation.advance(const Duration(minutes: 1));
      if (simulation.state == VoyageSimulationState.completed) break;
    }

    expect(simulation.state, VoyageSimulationState.completed);
    expect(
      simulation.sailors.every((sailor) => sailor.speedMetersPerSecond == 0),
      isTrue,
    );
    expect(
      awareness.sailorLocations.every(
        (location) => location.sample.speedMetersPerSecond == 0,
      ),
      isTrue,
    );
    expect(
      const VoyageCompletionDetector().everyoneReachedDestination(
        destination: const GeoPoint(latitude: 51, longitude: -0.9),
        sailorLocations: awareness.sailorLocations,
        now: DateTime.now(),
        // The fleet's own progress, not a stand-in: arrival is only arrival once
        // the route is behind the group (#206).
        routeProgressFraction: simulation.progress,
      ),
      isTrue,
    );
  });
}
