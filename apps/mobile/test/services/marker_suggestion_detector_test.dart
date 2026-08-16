import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/marker_assistance.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/marker_suggestion_detector.dart';

void main() {
  const route = [
    GeoPoint(latitude: 51, longitude: -1),
    GeoPoint(latitude: 51, longitude: -0.99),
  ];
  const decision = RouteDecisionPoint(
    id: 'junction',
    position: GeoPoint(latitude: 51, longitude: -0.999),
    source: DecisionPointSource.waypoint,
    label: 'Turn left',
  );
  final start = DateTime.utc(2026, 7, 16, 12);

  test('suggests only after stop dwell while group progress continues', () {
    final detector = MarkerSuggestionDetector(
      route: route,
      decisionPoints: const [decision],
    );

    final first = detector.evaluate(
      _observation(at: start, localSpeed: 0, groupSpeed: 5),
    );
    expect(first.state, MarkerSuggestionState.stoppedNearDecision);

    final suggested = detector.evaluate(
      _observation(
        at: start.add(const Duration(seconds: 12)),
        localSpeed: 0,
        groupSpeed: 5,
      ),
    );
    expect(suggested.state, MarkerSuggestionState.suggested);
    expect(suggested.suggestion?.decisionPoint.id, 'junction');
    expect(suggested.suggestion?.progressingRiderCount, 1);
  });

  test('does not suggest for a stationary group or stale local fix', () {
    final detector = MarkerSuggestionDetector(
      route: route,
      decisionPoints: const [decision],
      config: const MarkerSuggestionConfig(stoppedDwell: Duration.zero),
    );

    final stationary = detector.evaluate(
      _observation(at: start, localSpeed: 0, groupSpeed: 0),
    );
    expect(stationary.state, MarkerSuggestionState.stoppedNearDecision);

    final stale = detector.evaluate(
      MarkerDetectorObservation(
        localLocation: _location(
          id: 'local',
          longitude: -0.999,
          speed: 0,
          at: start.subtract(const Duration(seconds: 21)),
        ),
        groupLocations: [
          _location(id: 'group', longitude: -0.996, speed: 5, at: start),
        ],
        now: start,
        markerActive: false,
      ),
    );
    expect(stale.state, MarkerSuggestionState.monitoring);
    expect(stale.suggestion, isNull);
  });

  test('dismissal and movement cancellation enforce cooldown', () {
    final detector = MarkerSuggestionDetector(
      route: route,
      decisionPoints: const [decision],
      config: const MarkerSuggestionConfig(stoppedDwell: Duration.zero),
    );
    expect(
      detector
          .evaluate(_observation(at: start, localSpeed: 0, groupSpeed: 5))
          .state,
      MarkerSuggestionState.suggested,
    );

    detector.dismiss(start);
    expect(
      detector
          .evaluate(
            _observation(
              at: start.add(const Duration(minutes: 1)),
              localSpeed: 0,
              groupSpeed: 5,
            ),
          )
          .state,
      MarkerSuggestionState.cooldown,
    );

    final movementDetector = MarkerSuggestionDetector(
      route: route,
      decisionPoints: const [decision],
      config: const MarkerSuggestionConfig(stoppedDwell: Duration.zero),
    );
    movementDetector.evaluate(
      _observation(at: start, localSpeed: 0, groupSpeed: 5),
    );
    final cancelled = movementDetector.evaluate(
      _observation(
        at: start.add(const Duration(seconds: 1)),
        localSpeed: 4,
        groupSpeed: 5,
      ),
    );
    expect(cancelled.state, MarkerSuggestionState.cooldown);
    expect(cancelled.message, contains('cancelled'));
  });

  test('marker-active observation cannot produce a suggestion', () {
    final detector = MarkerSuggestionDetector(
      route: route,
      decisionPoints: const [decision],
      config: const MarkerSuggestionConfig(stoppedDwell: Duration.zero),
    );

    final result = detector.evaluate(
      MarkerDetectorObservation(
        localLocation: _location(
          id: 'local',
          longitude: -0.999,
          speed: 0,
          at: start,
        ),
        groupLocations: const [],
        now: start,
        markerActive: true,
      ),
    );
    expect(result.state, MarkerSuggestionState.markerActive);
    expect(result.suggestion, isNull);
  });
}

MarkerDetectorObservation _observation({
  required DateTime at,
  required double localSpeed,
  required double groupSpeed,
}) => MarkerDetectorObservation(
  localLocation: _location(
    id: 'local',
    longitude: -0.999,
    speed: localSpeed,
    at: at,
  ),
  groupLocations: [
    _location(id: 'group', longitude: -0.996, speed: groupSpeed, at: at),
  ],
  now: at,
  markerActive: false,
);

RiderLocation _location({
  required String id,
  required double longitude,
  required double speed,
  required DateTime at,
}) => RiderLocation(
  riderId: id,
  displayName: id,
  role: RideRole.rider,
  sample: LocationSample(
    position: GeoPoint(latitude: 51, longitude: longitude),
    recordedAt: at,
    accuracyMeters: 4,
    speedMetersPerSecond: speed,
  ),
  receivedAt: at,
);
