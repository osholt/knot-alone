import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/navigation_export.dart';

/// #30. The handoff targets were Google Maps, Waze, Calimoto, BMW Motorrad and
/// Harley-Davidson, and the Google Maps link asked for a *driving* route between
/// the route's endpoints — which between two sea waypoints returns a road route
/// around the coast, confidently. These tests pin the marine replacement and the
/// property that made the old design unsafe: nothing here invents a route.
void main() {
  test('the registry covers every target and declares both platforms', () {
    expect(
      navigationHandoffCapabilities.map((capability) => capability.target),
      unorderedEquals(NavigationTarget.values),
    );
    for (final platform in NavigationPlatform.values) {
      expect(
        navigationCapabilitiesFor(
          platform,
        ).map((capability) => capability.target),
        unorderedEquals(NavigationTarget.values),
        reason: 'Every current handoff should declare $platform support',
      );
    }
  });

  test('every target transfers the whole route, not a summary of it', () {
    // The old design had two targets that could only carry sampled via points
    // or a bare destination. Both were road links. Nothing here discards part
    // of a passage.
    for (final target in NavigationTarget.values) {
      expect(
        target.capability.routeTransfer,
        NavigationRouteTransfer.fullGpx,
        reason: '${target.name} should hand over the full GPX',
      );
    }
  });

  test('no target is a road or motorcycle app', () {
    final labels = NavigationTarget.values
        .map((target) => target.label.toLowerCase())
        .join(' | ');
    for (final banned in [
      'google maps',
      'waze',
      'calimoto',
      'myroute',
      'motorrad',
      'harley',
    ]) {
      expect(labels, isNot(contains(banned)), reason: banned);
    }
  });

  test('every target says what will actually happen', () {
    for (final target in NavigationTarget.values) {
      expect(target.limitation.trim(), isNotEmpty, reason: target.name);
    }
    // The one that always works, whatever is installed.
    expect(
      NavigationTarget.shareGpx.limitation.toLowerCase(),
      contains('any gpx-compatible app'),
    );
  });

  test(
    'a platform-exclusive capability is excluded from the other platform',
    () {
      // Every current entry declares both platforms, so this is the only path
      // that exercises exclusion - a synthetic capability, not a fabricated real
      // provider.
      const androidOnly = NavigationHandoffCapability(
        target: NavigationTarget.garmin,
        label: 'Garmin (Android only, hypothetical)',
        routeTransfer: NavigationRouteTransfer.fullGpx,
        platforms: {NavigationPlatform.android},
        limitation: 'test fixture',
      );

      expect(androidOnly.supports(NavigationPlatform.android), isTrue);
      expect(androidOnly.supports(NavigationPlatform.iOS), isFalse);
    },
  );

  test(
    'every target goes through the share sheet, inventing no URL scheme',
    () async {
      final gateway = _FakeShareGateway();
      final coordinator = NavigationExportCoordinator(shareGateway: gateway);

      for (final target in NavigationTarget.values) {
        final result = await coordinator.export(target, _route(4));
        expect(result.sharedGpx, isTrue, reason: target.name);
      }

      expect(gateway.targets, NavigationTarget.values);
    },
  );

  test('a route with no points still shares rather than failing', () async {
    // An empty route used to be the case that skipped the direct link. There is
    // no direct link now, so the only requirement is that it does not throw.
    final gateway = _FakeShareGateway();
    final coordinator = NavigationExportCoordinator(shareGateway: gateway);

    final result = await coordinator.export(
      NavigationTarget.shareGpx,
      _route(0),
    );

    expect(result.sharedGpx, isTrue);
    expect(gateway.targets, [NavigationTarget.shareGpx]);
  });

  test(
    'a named target tells the sailor to pick it in the share sheet',
    () async {
      final gateway = _FakeShareGateway();
      final coordinator = NavigationExportCoordinator(shareGateway: gateway);

      final named = await coordinator.export(
        NavigationTarget.navionics,
        _route(4),
      );
      expect(named.message, contains('Navionics'));
      expect(named.message.toLowerCase(), contains('share sheet'));

      // The generic option makes no claim about another app.
      final generic = await coordinator.export(
        NavigationTarget.shareGpx,
        _route(4),
      );
      expect(generic.message.toLowerCase(), isNot(contains('share sheet')));
    },
  );
}

ImportedRoute _route(int count) => ImportedRoute(
  id: 'route',
  name: 'Test route',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'test.gpx',
  paths: [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        for (var index = 0; index < count; index += 1)
          GeoPoint(latitude: 53 + index / 100, longitude: -1 - index / 100),
      ],
    ),
  ],
  waypoints: const [],
);

class _FakeShareGateway implements GpxShareGateway {
  final List<NavigationTarget> targets = [];

  @override
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  }) async {
    targets.add(target);
  }
}
