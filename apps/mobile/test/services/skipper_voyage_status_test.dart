import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/domain/route_alert.dart';
import 'package:tide_and_seek/services/skipper_voyage_status.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17, 10);

  test('skipper receives along-route TEC distance and estimated time gap', () {
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: VoyageRole.lead,
        longitude: 0.015,
        speed: 10,
        at: now,
      ),
      sailorLocations: [
        _location(
          id: 'sweeper',
          name: 'Charlie',
          role: VoyageRole.sweeper,
          longitude: 0.005,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      now: now,
    );

    expect(status, isNotNull);
    expect(status!.sweeperName, 'Charlie');
    expect(status.sweeperAvailability, SweeperAvailability.tracking);
    expect(status.sweeperSailorId, 'sweeper');
    expect(status.distanceToSweeperMeters, closeTo(1112, 10));
    expect(
      status.estimatedTimeToSweeper!.inSeconds,
      inInclusiveRange(105, 115),
    );
  });

  group('the three TEC states stay distinct from an absent TEC', () {
    SkipperVoyageStatus? statusFor({
      List<SailorLocation> sailorLocations = const [],
      Iterable<String> registeredSweeperSailorIds = const [],
    }) => const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: VoyageRole.lead,
        longitude: 0.015,
        speed: 10,
        at: now,
      ),
      sailorLocations: sailorLocations,
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      registeredSweeperSailorIds: registeredSweeperSailorIds,
      now: now,
    );

    SailorLocation sweeperAt(DateTime recordedAt) => _location(
      id: 'sweeper',
      name: 'Charlie',
      role: VoyageRole.sweeper,
      longitude: 0.005,
      speed: 10,
      at: recordedAt,
    );

    test('no registered TEC reports nothing to show and nothing to aim at', () {
      final status = statusFor(
        sailorLocations: [
          _location(
            id: 'alex',
            name: 'Alex',
            role: VoyageRole.sailor,
            longitude: 0.01,
            speed: 10,
            at: now,
          ),
        ],
      );

      expect(status!.sweeperAvailability, SweeperAvailability.none);
      expect(status.hasRegisteredSweeper, isFalse);
      expect(status.sweeperSailorId, isNull);
      expect(status.sweeperName, isNull);
      expect(status.distanceToSweeperMeters, isNull);
      expect(status.estimatedTimeToSweeper, isNull);
      expect(status.sweeperLocationAge, isNull);
    });

    test('a registered TEC with no position yet is a waiting state', () {
      final status = statusFor(registeredSweeperSailorIds: const ['sweeper']);

      expect(status!.sweeperAvailability, SweeperAvailability.awaitingLocation);
      expect(status.hasRegisteredSweeper, isTrue);
      expect(status.sweeperSailorId, 'sweeper');
      // Nothing is known about where this TEC is, so no surface may date-stamp
      // or measure a position it has never received.
      expect(status.sweeperName, isNull);
      expect(status.sweeperLocationAge, isNull);
      expect(status.distanceToSweeperMeters, isNull);
      expect(status.estimatedTimeToSweeper, isNull);
    });

    test('a stale TEC position reports its age and withholds the gap', () {
      final status = statusFor(
        sailorLocations: [sweeperAt(now.subtract(const Duration(minutes: 9)))],
        registeredSweeperSailorIds: const ['sweeper'],
      );

      expect(status!.sweeperAvailability, SweeperAvailability.stale);
      expect(status.sweeperSailorId, 'sweeper');
      expect(status.sweeperName, 'Charlie');
      expect(status.sweeperLocationAge, const Duration(minutes: 9));
      expect(status.distanceToSweeperMeters, isNull);
      expect(status.estimatedTimeToSweeper, isNull);
    });

    test('a fresh TEC position reports the measured gap', () {
      final status = statusFor(
        sailorLocations: [sweeperAt(now)],
        registeredSweeperSailorIds: const ['sweeper'],
      );

      expect(status!.sweeperAvailability, SweeperAvailability.tracking);
      expect(status.sweeperSailorId, 'sweeper');
      expect(status.sweeperName, 'Charlie');
      expect(status.sweeperLocationAge, Duration.zero);
      expect(status.distanceToSweeperMeters, closeTo(1112, 10));
      expect(status.estimatedTimeToSweeper, isNotNull);
    });

    test('a TEC known only from a location snapshot still counts', () {
      final status = statusFor(sailorLocations: [sweeperAt(now)]);

      expect(status!.sweeperAvailability, SweeperAvailability.tracking);
      expect(status.sweeperSailorId, 'sweeper');
    });

    test('assigning and then removing the role mid-voyage flips the state', () {
      expect(statusFor()!.sweeperAvailability, SweeperAvailability.none);
      expect(
        statusFor(
          registeredSweeperSailorIds: const ['sweeper'],
        )!.sweeperAvailability,
        SweeperAvailability.awaitingLocation,
      );
      expect(
        statusFor(
          sailorLocations: [sweeperAt(now)],
          registeredSweeperSailorIds: const ['sweeper'],
        )!.sweeperAvailability,
        SweeperAvailability.tracking,
      );
      // The TEC leaves, or their role is reassigned: the surface must vanish
      // again without waiting for a restart.
      final afterRemoval = statusFor();
      expect(afterRemoval!.sweeperAvailability, SweeperAvailability.none);
      expect(afterRemoval.hasRegisteredSweeper, isFalse);
    });

    test('the skipper is never their own TEC', () {
      final status = statusFor(registeredSweeperSailorIds: const ['lead']);

      expect(status!.sweeperAvailability, SweeperAvailability.none);
    });
  });

  test('a fresh TEC without a skipper fix keeps the age but not the gap', () {
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: null,
      sailorLocations: [
        _location(
          id: 'sweeper',
          name: 'Charlie',
          role: VoyageRole.sweeper,
          longitude: 0.005,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: const [],
      route: const [],
      registeredSweeperSailorIds: const ['sweeper'],
      now: now,
    );

    expect(status!.sweeperAvailability, SweeperAvailability.tracking);
    expect(status.sweeperName, 'Charlie');
    expect(status.sweeperLocationAge, Duration.zero);
    expect(status.distanceToSweeperMeters, isNull);
  });

  test('closed loop uses the short gap across its start and finish', () {
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: _location(
        id: 'lead',
        name: 'Lead',
        role: VoyageRole.lead,
        longitude: 0,
        speed: 10,
        at: now,
      ),
      sailorLocations: [
        SailorLocation(
          sailorId: 'sweeper',
          displayName: 'Charlie',
          role: VoyageRole.sweeper,
          sample: LocationSample(
            position: const GeoPoint(latitude: 0.005, longitude: 0),
            recordedAt: now,
            accuracyMeters: 5,
            speedMetersPerSecond: 10,
          ),
          receivedAt: now,
        ),
      ],
      routeAlerts: const [],
      route: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
        GeoPoint(latitude: 0.02, longitude: 0.02),
        GeoPoint(latitude: 0.02, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0),
      ],
      now: now,
    );

    expect(status!.distanceToSweeperMeters, closeTo(556, 15));
  });

  test('skipper receives simple unacknowledged off-course alerts', () {
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: null,
      sailorLocations: [
        _location(
          id: 'sailor',
          name: 'Alex',
          role: VoyageRole.sailor,
          longitude: 0.01,
          speed: 10,
          at: now,
        ),
      ],
      routeAlerts: [
        SailorRouteAlert(
          sailorId: 'sailor',
          displayName: 'Alex',
          assessment: RouteDeviationAssessment(
            state: RouteTrackingState.offRoute,
            alertLevel: RouteAlertLevel.urgent,
            audience: RouteAlertAudience.coordinators,
            evaluatedAt: now,
            message: 'Off route',
            distanceFromRouteMeters: 240,
          ),
        ),
      ],
      route: const [],
      now: now,
    );

    expect(status!.offCourseAlerts.single.displayName, 'Alex');
    expect(status.offCourseAlerts.single.distanceFromRouteMeters, 240);
  });

  test(
    'off-course total excludes stale states and sailors outside the roster',
    () {
      SailorRouteAlert alert({
        required String sailorId,
        required String name,
        required RouteTrackingState state,
        DateTime? evaluatedAt,
      }) => SailorRouteAlert(
        sailorId: sailorId,
        displayName: name,
        assessment: RouteDeviationAssessment(
          state: state,
          alertLevel: RouteAlertLevel.urgent,
          audience: RouteAlertAudience.coordinators,
          evaluatedAt: evaluatedAt ?? now,
          message: 'Coordinator alert',
          distanceFromRouteMeters: state == RouteTrackingState.offRoute
              ? 240
              : null,
        ),
      );

      final status = const SkipperVoyageStatusCalculator().calculate(
        localRole: VoyageRole.lead,
        localSailorId: 'lead',
        localLocation: null,
        sailorLocations: [
          _location(
            id: 'current-off-route',
            name: 'Alex',
            role: VoyageRole.sailor,
            longitude: 0.01,
            speed: 10,
            at: now,
          ),
          _location(
            id: 'current-stale',
            name: 'Sam',
            role: VoyageRole.sailor,
            longitude: 0.012,
            speed: 0,
            at: now.subtract(const Duration(minutes: 3)),
          ),
        ],
        routeAlerts: [
          alert(
            sailorId: 'current-off-route',
            name: 'Alex',
            state: RouteTrackingState.offRoute,
          ),
          alert(
            sailorId: 'current-off-route',
            name: 'Alex duplicate',
            state: RouteTrackingState.offRoute,
            evaluatedAt: now.subtract(const Duration(seconds: 1)),
          ),
          alert(
            sailorId: 'current-stale',
            name: 'Sam',
            state: RouteTrackingState.gpsStale,
          ),
          for (var index = 0; index < 5; index += 1)
            alert(
              sailorId: 'ghost-$index',
              name: 'Ghost $index',
              state: RouteTrackingState.offRoute,
            ),
        ],
        route: const [],
        now: now,
      );

      expect(status!.offCourseAlerts, hasLength(1));
      expect(status.offCourseAlerts.single.sailorId, 'current-off-route');
      expect(status.offCourseAlerts.single.displayName, 'Alex');
    },
  );

  test('a sailor on the skipper\'s own track is not counted as off course', () {
    SailorRouteAlert offCourse(String sailorId, String name) =>
        SailorRouteAlert(
          sailorId: sailorId,
          displayName: name,
          assessment: RouteDeviationAssessment(
            state: RouteTrackingState.offRoute,
            alertLevel: RouteAlertLevel.urgent,
            audience: RouteAlertAudience.coordinators,
            evaluatedAt: now,
            message: 'Off route',
            distanceFromRouteMeters: 2400,
          ),
        );

    // Both sailors are far from the planned GPX and both have an off-route alert
    // raised by another device. Only the one who is not on the skipper's actual
    // track should reach the skipper's count.
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.lead,
      localSailorId: 'lead',
      localLocation: null,
      sailorLocations: [
        _location(
          id: 'follower',
          name: 'Alex',
          role: VoyageRole.sailor,
          longitude: 0.01,
          speed: 10,
          at: now,
        ),
        SailorLocation(
          sailorId: 'stray',
          displayName: 'Sam',
          role: VoyageRole.sailor,
          sample: LocationSample(
            position: const GeoPoint(latitude: 0.05, longitude: 0.01),
            recordedAt: now,
            accuracyMeters: 5,
          ),
          receivedAt: now,
        ),
      ],
      routeAlerts: [offCourse('follower', 'Alex'), offCourse('stray', 'Sam')],
      route: const [
        GeoPoint(latitude: 0.02, longitude: 0),
        GeoPoint(latitude: 0.02, longitude: 0.02),
      ],
      // The skipper abandoned the GPX and rode along latitude 0, where the
      // follower now is.
      skipperTrail: const [
        GeoPoint(latitude: 0, longitude: 0),
        GeoPoint(latitude: 0, longitude: 0.02),
      ],
      now: now,
    );

    expect(status!.offCourseAlerts, hasLength(1));
    expect(status.offCourseAlerts.single.sailorId, 'stray');
  });

  test('non-skippers do not receive skipper map status', () {
    final status = const SkipperVoyageStatusCalculator().calculate(
      localRole: VoyageRole.sailor,
      localSailorId: 'sailor',
      localLocation: null,
      sailorLocations: const [],
      routeAlerts: const [],
      route: const [],
      now: now,
    );

    expect(status, isNull);
  });

  group('resolveSweeperTarget', () {
    const calculator = SkipperVoyageStatusCalculator();

    SweeperTarget resolve({
      List<SailorLocation> sailorLocations = const [],
      Iterable<String> registered = const [],
      DateTime? at,
    }) => calculator.resolveSweeperTarget(
      localSailorId: 'lead',
      sailorLocations: sailorLocations,
      registeredSweeperSailorIds: registered,
      now: at ?? now,
    );

    test('no back-marker at all reports none and offers no target', () {
      final target = resolve();

      expect(target.availability, SweeperAvailability.none);
      expect(target.hasRegisteredSweeper, isFalse);
      expect(target.navigableLocation, isNull);
    });

    test('a registered TEC with no position yet is not navigable', () {
      final target = resolve(registered: const ['sweeper']);

      expect(target.availability, SweeperAvailability.awaitingLocation);
      expect(target.hasRegisteredSweeper, isTrue);
      expect(target.sailorId, 'sweeper');
      expect(target.navigableLocation, isNull);
    });

    test('a stale fix is kept but withheld from navigation', () {
      final target = resolve(
        sailorLocations: [
          _location(
            id: 'sweeper',
            name: 'Charlie',
            role: VoyageRole.sweeper,
            longitude: 0.005,
            speed: 10,
            at: now.subtract(const Duration(minutes: 5)),
          ),
        ],
      );

      expect(target.availability, SweeperAvailability.stale);
      expect(target.location, isNotNull);
      expect(target.navigableLocation, isNull);
    });

    test('a fresh fix is navigable', () {
      final target = resolve(
        sailorLocations: [
          _location(
            id: 'sweeper',
            name: 'Charlie',
            role: VoyageRole.sweeper,
            longitude: 0.005,
            speed: 10,
            at: now,
          ),
        ],
      );

      expect(target.availability, SweeperAvailability.tracking);
      expect(target.navigableLocation?.sailorId, 'sweeper');
    });

    test('a sailor is never their own back-marker', () {
      final target = calculator.resolveSweeperTarget(
        localSailorId: 'sweeper',
        sailorLocations: [
          _location(
            id: 'sweeper',
            name: 'Charlie',
            role: VoyageRole.sweeper,
            longitude: 0.005,
            speed: 10,
            at: now,
          ),
        ],
        registeredSweeperSailorIds: const ['sweeper'],
        now: now,
      );

      expect(target.availability, SweeperAvailability.none);
    });

    test('agrees with the availability the skipper card reports', () {
      // One model, two consumers: the skipper's TEC card and rejoin routing must
      // never disagree about whether there is a usable back-marker.
      for (final scenario in [
        (<SailorLocation>[], const <String>[]),
        (<SailorLocation>[], const ['sweeper']),
        (
          [
            _location(
              id: 'sweeper',
              name: 'Charlie',
              role: VoyageRole.sweeper,
              longitude: 0.005,
              speed: 10,
              at: now.subtract(const Duration(minutes: 5)),
            ),
          ],
          const <String>[],
        ),
        (
          [
            _location(
              id: 'sweeper',
              name: 'Charlie',
              role: VoyageRole.sweeper,
              longitude: 0.005,
              speed: 10,
              at: now,
            ),
          ],
          const <String>[],
        ),
      ]) {
        final status = calculator.calculate(
          localRole: VoyageRole.lead,
          localSailorId: 'lead',
          localLocation: _location(
            id: 'lead',
            name: 'Lead',
            role: VoyageRole.lead,
            longitude: 0,
            speed: 10,
            at: now,
          ),
          sailorLocations: scenario.$1,
          routeAlerts: const [],
          route: const [],
          registeredSweeperSailorIds: scenario.$2,
          now: now,
        );
        final target = resolve(
          sailorLocations: scenario.$1,
          registered: scenario.$2,
        );

        expect(status!.sweeperAvailability, target.availability);
        expect(status.hasRegisteredSweeper, target.hasRegisteredSweeper);
      }
    });
  });
}

SailorLocation _location({
  required String id,
  required String name,
  required VoyageRole role,
  required double longitude,
  required double speed,
  required DateTime at,
}) => SailorLocation(
  sailorId: id,
  displayName: name,
  role: role,
  sample: LocationSample(
    position: GeoPoint(latitude: 0, longitude: longitude),
    recordedAt: at,
    accuracyMeters: 5,
    speedMetersPerSecond: speed,
  ),
  receivedAt: at,
);
