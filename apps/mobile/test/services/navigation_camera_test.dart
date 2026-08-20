import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/services/navigation_camera.dart';

NavigationCameraPlan _plan(
  double? speed, {
  required bool landscape,
  double bottomChromeFraction = 0,
}) => NavigationCameraPlanner.plan(
  speedMetersPerSecond: speed,
  landscape: landscape,
  viewportHeightPixels: landscape ? 390 : 844,
  viewportWidthPixels: landscape ? 844 : 390,
  latitudeDegrees: 53,
  bottomChromeFraction: bottomChromeFraction,
);

void main() {
  test('follow mode uses a flat, wider chart view at every sailing speed', () {
    for (final landscape in [false, true]) {
      final rest = _plan(0, landscape: landscape);
      for (final speed in <double?>[null, double.nan, 3, 15, 100]) {
        final plan = _plan(speed, landscape: landscape);
        expect(plan.tilt, 0);
        expect(plan.zoom, rest.zoom);
        expect(plan.sailorViewportFraction, rest.sailorViewportFraction);
      }
      expect(rest.zoom, lessThan(13));
    }
  });

  test('landscape is wider while both orientations remain top down', () {
    final portrait = _plan(5, landscape: false);
    final landscape = _plan(5, landscape: true);

    expect(portrait.zoom, 12.6);
    expect(landscape.zoom, 12.2);
    expect(landscape.zoom, lessThan(portrait.zoom));
    expect(portrait.tilt, navigationCameraMaximumTiltDegrees);
    expect(landscape.tilt, navigationCameraMaximumTiltDegrees);
  });

  test('a chart has no traffic-side horizontal offset', () {
    final leftTraffic = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 5,
      landscape: true,
      viewportHeightPixels: 390,
      viewportWidthPixels: 844,
      leftHandTraffic: true,
    );
    final rightTraffic = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 5,
      landscape: true,
      viewportHeightPixels: 390,
      viewportWidthPixels: 844,
      leftHandTraffic: false,
    );

    expect(leftTraffic.sailorHorizontalViewportFraction, 0.5);
    expect(rightTraffic.sailorHorizontalViewportFraction, 0.5);
    expect(leftTraffic.lateralBiasPixels, 0);
    expect(rightTraffic.lateralBiasPixels, 0);
  });

  test('a small stable forward bias leaves water visible ahead', () {
    final portrait = _plan(0, landscape: false);
    final fastPortrait = _plan(30, landscape: false);
    final landscape = _plan(0, landscape: true);

    expect(portrait.sailorViewportFraction, 0.58);
    expect(fastPortrait.sailorViewportFraction, 0.58);
    expect(landscape.sailorViewportFraction, 0.58);
    expect(portrait.forwardBiasPixels, closeTo(67.52, 0.01));
    expect(portrait.lookAheadMeters, greaterThan(0));
    expect(
      portrait.lookAheadMeters,
      lessThanOrEqualTo(navigationCameraMaximumLookAheadMeters),
    );
  });

  test('bottom chrome pulls the vessel clear of an overlay', () {
    final light = _plan(5, landscape: false, bottomChromeFraction: 0.2);
    final heavy = _plan(5, landscape: false, bottomChromeFraction: 0.5);
    final absurd = _plan(5, landscape: false, bottomChromeFraction: 0.9);

    expect(light.sailorViewportFraction, 0.58);
    expect(heavy.sailorViewportFraction, 0.44);
    expect(
      absurd.sailorViewportFraction,
      navigationCameraMinimumSailorFraction,
    );
    expect(absurd.lookAheadMeters, lessThan(0));
  });

  test('flat MapLibre and FlutterMap offsets use their own tile scales', () {
    final plan = _plan(0, landscape: false);
    final mapLibre = plan.lookAheadMeters;
    final flutterMap = NavigationCameraPlanner.flatLookAheadMetersFor(
      zoom: plan.zoom,
      forwardBiasPixels: plan.forwardBiasPixels,
      latitudeDegrees: 53,
    );

    expect(flutterMap, closeTo(mapLibre * 2, 0.01));
    expect(
      NavigationCameraPlanner.flatLookAheadMetersFor(
        zoom: 12,
        forwardBiasPixels: 0,
        latitudeDegrees: 53,
      ),
      0,
    );
    expect(
      NavigationCameraPlanner.flatLookAheadMetersFor(
        zoom: 3,
        forwardBiasPixels: 400,
        latitudeDegrees: 53,
      ),
      navigationCameraMaximumLookAheadMeters,
    );
  });

  group('settledOnViewport', () {
    test('uses a pixel-scaled drift tolerance and exact commanded zoom', () {
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 80,
          zoomDelta: 0,
          zoom: 12.6,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isTrue,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 120,
          zoomDelta: 0,
          zoom: 12.6,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 0,
          zoomDelta: -1,
          zoom: 11.6,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
    });

    test('reads the same drift differently on each tile scheme', () {
      const drift = 100.0;
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: drift,
          zoomDelta: 0,
          zoom: 12.6,
          latitudeDegrees: 53,
          tileSize: 256,
        ),
        isTrue,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: drift,
          zoomDelta: 0,
          zoom: 12.6,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
    });

    test('a deliberate 20 pixel pan is outside the arrival window', () {
      for (final tileSize in [256, 512]) {
        final metresPerPixel =
            (tileSize == 256 ? 156543.03392 : 78271.5169) *
            math.cos(53 * math.pi / 180) /
            math.pow(2, 12.6);
        expect(
          NavigationCameraPlanner.settledOnViewport(
            driftMeters: 20 * metresPerPixel,
            zoomDelta: 0,
            zoom: 12.6,
            latitudeDegrees: 53,
            tileSize: tileSize,
          ),
          isFalse,
        );
      }
    });

    test('an unmeasurable camera has not arrived', () {
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: double.nan,
          zoomDelta: 0,
          zoom: 12.6,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
    });
  });
}
