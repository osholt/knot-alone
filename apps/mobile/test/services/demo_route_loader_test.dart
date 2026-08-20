import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/services/demo_route_loader.dart';
import 'package:tide_and_seek/services/passage_legs.dart';

/// #35. The demo used to be a 10.9-mile motorcycle road route from a Kingswood
/// car park to a pub in Old Sodbury, with four turn instructions and a waypoint
/// called "second-bike-drop marker point". It is the option a new sailor is most
/// likely to tap, so it is the app's self-description.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the demo is a Solent passage, in legs', () async {
    final route = await const BundledDemoRouteLoader().load();

    expect(route.name, 'Lymington to Cowes');
    expect(route.waypoints, hasLength(5));
    expect(route.waypoints.first.name, 'Lymington River entrance');
    expect(route.waypoints.last.name, 'Cowes harbour entrance');

    // Four legs of a real crossing, about 8.6 nautical miles.
    final plan = PassagePlan.of(route);
    expect(plan.legs, hasLength(4));
    expect(plan.totalDistanceMeters / 1852, closeTo(8.6, 0.3));
    // Broadly eastward across the Solent.
    expect(plan.legs.first.courseDegreesTrue, closeTo(96, 5));
  });

  test('its geometry follows the legs it declares', () async {
    final route = await const BundledDemoRouteLoader().load();
    final points = route.paths.single.points;

    // Sampled along each rhumb line, so the drawn line is the steered course
    // rather than two points joined on screen.
    expect(points.length, greaterThan(60));
    expect(points.first.latitude, closeTo(50.7378, 0.001));
    expect(points.first.longitude, closeTo(-1.5095, 0.001));
    expect(points.last.latitude, closeTo(50.7680, 0.001));
    expect(points.last.longitude, closeTo(-1.2980, 0.001));
  });

  test('it says it is not a planned passage', () async {
    final route = await const BundledDemoRouteLoader().load();
    final description = route.description?.toLowerCase() ?? '';

    // A demo route in a navigation app must not look like checked chart work.
    expect(description, contains('approximate'));
    expect(description, contains('not be used for navigation'));
  });

  test('nothing about it is a road', () async {
    final route = await const BundledDemoRouteLoader().load();
    final text = [
      route.name,
      route.description ?? '',
      ...route.waypoints.map((waypoint) => waypoint.name ?? ''),
      ...route.waypoints.map((waypoint) => waypoint.description ?? ''),
    ].join(' ').toLowerCase();

    for (final banned in ['road', 'car park', 'bike', 'junction', 'twisty']) {
      expect(text, isNot(contains(banned)), reason: banned);
    }
  });
}
