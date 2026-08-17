import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_simulation_controller.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/imported_route.dart' as imported_route;
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/route_store.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';
import 'package:tide_and_seek/services/road_routing.dart';

void main() {
  test('Voyage Lab marks one point for a paired roundabout', () {
    final entry = RoadRouteManeuver(
      position: const imported_route.GeoPoint(latitude: 51.5, longitude: -2.35),
      type: 'rotary',
      exitNumber: 2,
    );
    final exit = RoadRouteManeuver(
      position: const imported_route.GeoPoint(
        latitude: 51.501,
        longitude: -2.351,
      ),
      type: 'exit rotary',
    );

    expect(simulationMarkerManeuvers([entry, exit]), [entry]);
  });

  group('reroute takeover around a junction', () {
    test('waits while approaching or clearing the current manoeuvre', () {
      expect(
        shouldDeferRejoinNavigation(
          hasRoutedPlan: true,
          distanceToCurrentManeuverMeters: 47,
          metersSincePreviousManeuver: null,
        ),
        isTrue,
      );
      expect(
        shouldDeferRejoinNavigation(
          hasRoutedPlan: true,
          distanceToCurrentManeuverMeters: 300,
          metersSincePreviousManeuver: 42,
        ),
        isTrue,
      );
    });

    test('applies after clearance and never delays a degraded plan', () {
      expect(
        shouldDeferRejoinNavigation(
          hasRoutedPlan: true,
          distanceToCurrentManeuverMeters: 300,
          metersSincePreviousManeuver: 80,
        ),
        isFalse,
      );
      expect(
        shouldDeferRejoinNavigation(
          hasRoutedPlan: false,
          distanceToCurrentManeuverMeters: 10,
          metersSincePreviousManeuver: 10,
        ),
        isFalse,
      );
    });
  });

  group('the registered TEC comes from the reconciled roster', () {
    VoyageParticipant participant({
      required String sailorId,
      required VoyageRole role,
      VoyageMembershipState state = VoyageMembershipState.joined,
    }) => VoyageParticipant(
      sailorId: sailorId,
      displayName: sailorId,
      role: role,
      joinedAt: DateTime.utc(2026, 7, 25, 9),
      lastSeenAt: DateTime.utc(2026, 7, 25, 9),
      state: state,
      motorcycleStyle: motorcycleIconStyleDefault,
      sailorColor: SailorColor.amber,
      transportEvidence: const {VoyageTransportEvidence.internetRelay},
      isLocal: false,
    );

    test('a joined TEC counts before reporting any position', () {
      expect(
        registeredSweeperSailorIds(
          simulatedSailors: null,
          liveParticipants: [
            participant(sailorId: 'lead', role: VoyageRole.lead),
            participant(sailorId: 'charlie', role: VoyageRole.sweeper),
          ],
        ),
        {'charlie'},
      );
    });

    test('a voyage of sailors only has no TEC', () {
      expect(
        registeredSweeperSailorIds(
          simulatedSailors: null,
          liveParticipants: [
            participant(sailorId: 'lead', role: VoyageRole.lead),
            participant(sailorId: 'alex', role: VoyageRole.sailor),
          ],
        ),
        isEmpty,
      );
    });

    test('a TEC who has left the voyage is no longer the TEC', () {
      expect(
        registeredSweeperSailorIds(
          simulatedSailors: null,
          liveParticipants: [
            participant(sailorId: 'lead', role: VoyageRole.lead),
            participant(
              sailorId: 'charlie',
              role: VoyageRole.sweeper,
              state: VoyageMembershipState.left,
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('Voyage Lab resolves its TEC from the virtual roster', () {
      expect(
        registeredSweeperSailorIds(
          simulatedSailors: [
            _simulated(id: 'voyage-lab-maya', role: VoyageRole.lead),
            _simulated(id: 'voyage-lab-charlie', role: VoyageRole.sweeper),
          ],
          liveParticipants: const [],
        ),
        {'voyage-lab-charlie'},
      );
    });
  });

  test(
    'a new voyage waits for its scoped route store before mounting the map',
    () {
      final voyageStore = InMemoryRouteStore();

      expect(
        activeVoyageMapStoreWhenReady(
          initializing: true,
          isSimulation: false,
          voyageRouteStore: voyageStore,
          simulationRouteStore: null,
        ),
        isNull,
      );
      expect(
        activeVoyageMapStoreWhenReady(
          initializing: false,
          isSimulation: false,
          voyageRouteStore: voyageStore,
          simulationRouteStore: null,
        ),
        same(voyageStore),
      );
      expect(
        activeVoyageMapStoreWhenReady(
          initializing: false,
          isSimulation: false,
          voyageRouteStore: null,
          simulationRouteStore: null,
        ),
        isNull,
      );
    },
  );
}

SimulatedSailorSnapshot _simulated({
  required String id,
  required VoyageRole role,
}) => SimulatedSailorSnapshot(
  id: id,
  displayName: id,
  role: role,
  progress: 0,
  speedMetersPerSecond: 12,
  isLocal: false,
  isOffRoute: false,
  position: const GeoPoint(latitude: 51.45, longitude: -2.59),
  headingDegrees: 90,
  offRouteTrail: const [],
  travelTrail: const [],
  motorcycleStyle: motorcycleIconStyleDefault,
  sailorColor: SailorColor.amber,
);
