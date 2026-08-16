import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/services/marker_pass_detector.dart';

void main() {
  final now = DateTime.utc(2026, 7, 16, 12);

  test('counts one authenticated approach-to-pass transition', () {
    final detector = MarkerPassDetector();
    detector.start(const GeoPoint(latitude: 51, longitude: -1), [
      _evidence(longitude: -1.001, eventId: 'far', at: now),
    ], now);

    final passes = detector.evaluate([
      _evidence(longitude: -1.0001, eventId: 'near', at: now),
    ], now);
    final duplicate = detector.evaluate([
      _evidence(longitude: -1.0001, eventId: 'newer', at: now),
    ], now);

    expect(passes, hasLength(1));
    expect(passes.single.riderId, 'tec');
    expect(passes.single.locationEventId, 'near');
    expect(passes.single.roleName, RideRole.tailEndCharlie.name);
    expect(duplicate, isEmpty);
  });

  test(
    'ignores unauthenticated, stale, inaccurate, and initially-near fixes',
    () {
      final detector = MarkerPassDetector();
      detector.start(
        const GeoPoint(latitude: 51, longitude: -1),
        const [],
        now,
      );

      expect(
        detector.evaluate([
          _evidence(
            longitude: -1.0001,
            eventId: 'untrusted',
            at: now,
            authenticated: false,
          ),
          _evidence(
            longitude: -1.0001,
            eventId: 'stale',
            at: now.subtract(const Duration(seconds: 21)),
          ),
          _evidence(
            longitude: -1.0001,
            eventId: 'inaccurate',
            at: now,
            accuracy: 60,
          ),
        ], now),
        isEmpty,
      );
    },
  );
}

RiderLocationEvidence _evidence({
  required double longitude,
  required String eventId,
  required DateTime at,
  bool authenticated = true,
  double accuracy = 4,
}) => RiderLocationEvidence(
  location: RiderLocation(
    riderId: 'tec',
    displayName: 'TEC',
    role: RideRole.tailEndCharlie,
    sample: LocationSample(
      position: GeoPoint(latitude: 51, longitude: longitude),
      recordedAt: at,
      accuracyMeters: accuracy,
      speedMetersPerSecond: 5,
    ),
    receivedAt: at,
  ),
  eventId: eventId,
  eventCreatedAt: at,
  authenticated: authenticated,
);
