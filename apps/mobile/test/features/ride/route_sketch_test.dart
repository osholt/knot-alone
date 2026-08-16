import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/ride/route_sketch.dart';

void main() {
  test('returns an empty list for no points', () {
    expect(normalizeRoutePoints(const []), isEmpty);
  });

  test('centers a single (degenerate) point', () {
    final normalized = normalizeRoutePoints(const [
      GeoPoint(latitude: 51, longitude: -1),
    ]);

    expect(normalized, [const Offset(0.5, 0.5)]);
  });

  test('preserves aspect ratio for a north-south route', () {
    final normalized = normalizeRoutePoints(const [
      GeoPoint(latitude: 51, longitude: -1),
      GeoPoint(latitude: 52, longitude: -1),
    ]);

    // Equal longitude - the route runs straight up the vertical midline.
    expect(normalized.first.dx, closeTo(0.5, 1e-9));
    expect(normalized.last.dx, closeTo(0.5, 1e-9));
    // North (higher latitude) maps to a smaller dy (nearer the top).
    expect(normalized.last.dy, lessThan(normalized.first.dy));
  });
}
