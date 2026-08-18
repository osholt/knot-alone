import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/navigation_instruments.dart';
import 'package:tide_and_seek/services/passage_legs.dart';

/// #34. These are the numbers a navigator steers by, so the tests are mostly
/// about refusing to state what is not known: no VMG without a course, no
/// cross-track error from a coarse fix, no arrival time when the vessel is not
/// closing, and a stale fix flagged rather than quietly reused.
void main() {
  // A due-east leg at 50N, so expected bearings and sides are checkable by hand.
  const west = GeoPoint(latitude: 50.0000, longitude: -1.5000);
  const east = GeoPoint(latitude: 50.0000, longitude: -1.0000);
  final fixedNow = DateTime.utc(2026, 8, 18, 12);

  PassagePlan planOf(List<GeoPoint> marks) => PassagePlan.of(
    ImportedRoute(
      id: 'passage',
      name: 'Test passage',
      importedAt: fixedNow,
      sourceFileName: 'p.gpx',
      paths: const [],
      waypoints: [for (final mark in marks) RouteWaypoint(point: mark)],
    ),
  );

  NavigationFix fixAt(
    GeoPoint point, {
    double? cog,
    double? sog,
    double? accuracy,
    Duration age = Duration.zero,
  }) => NavigationFix(
    point: point,
    recordedAt: fixedNow.subtract(age),
    courseOverGroundDegrees: cog,
    speedOverGroundMetersPerSecond: sog,
    accuracyMeters: accuracy,
  );

  NavigationInstruments computeFor(
    NavigationFix fix, {
    List<GeoPoint> marks = const [west, east],
  }) => NavigationInstruments.compute(
    fix: fix,
    plan: planOf(marks),
    now: fixedNow,
  );

  group('what the receiver measures', () {
    test('COG and SOG are reported as measured', () {
      final instruments = computeFor(fixAt(west, cog: 90, sog: 3.0));

      expect(instruments.courseOverGround.value, 90);
      expect(instruments.courseOverGround.basis, InstrumentBasis.measured);
      expect(instruments.speedOverGround.value, 3.0);
      expect(instruments.speedOverGround.basis, InstrumentBasis.measured);
    });

    test('a stopped vessel has no course, and says so', () {
      // COG is meaningless at rest; a receiver that reports none must not be
      // papered over with the last one.
      final instruments = computeFor(fixAt(west, sog: 0));

      expect(instruments.courseOverGround.isAvailable, isFalse);
      expect(instruments.courseOverGround.basis, InstrumentBasis.unavailable);
      expect(instruments.courseOverGround.reason, contains('stopped'));
    });
  });

  group('the next mark', () {
    test('bearing and distance are calculated against the chart', () {
      final instruments = computeFor(fixAt(west, cog: 90, sog: 3));

      // Due east along the parallel, half a degree of longitude at 50N.
      expect(instruments.bearingToMark.value, closeTo(90, 0.5));
      expect(instruments.bearingToMark.basis, InstrumentBasis.calculated);
      expect(instruments.distanceToMark.value! / 1852, closeTo(19.3, 0.3));
    });

    test('the active leg is the nearest one, not the next by count', () {
      // Blown back down the passage: nearer leg 1 than leg 2, so leg 1 is the
      // one being sailed whatever a counter would say.
      const middle = GeoPoint(latitude: 50.0, longitude: -1.0);
      const far = GeoPoint(latitude: 50.5, longitude: -1.0);
      final instruments = computeFor(
        fixAt(const GeoPoint(latitude: 50.0, longitude: -1.4), cog: 90, sog: 3),
        marks: const [west, middle, far],
      );

      expect(instruments.activeLeg?.number, 1);
      expect(instruments.hasActiveLeg, isTrue);
    });
  });

  group('cross-track error', () {
    test('names the side the vessel is on', () {
      // North of a due-east track is to port of it.
      final north = computeFor(
        fixAt(
          const GeoPoint(latitude: 50.01, longitude: -1.25),
          cog: 90,
          sog: 3,
        ),
      );
      expect(north.offTrackSide, TrackSide.port);
      expect(north.crossTrackError.value!, closeTo(1111, 60));

      final south = computeFor(
        fixAt(
          const GeoPoint(latitude: 49.99, longitude: -1.25),
          cog: 90,
          sog: 3,
        ),
      );
      expect(south.offTrackSide, TrackSide.starboard);
    });

    test('the side to steer toward is the opposite one', () {
      expect(TrackSide.port.opposite, TrackSide.starboard);
      expect(TrackSide.starboard.opposite, TrackSide.port);
      expect(TrackSide.port.label, 'port');
    });

    test('is refused when the fix is too coarse to measure it', () {
      // A 200 m fix cannot tell a sailor they are 80 m off track.
      final instruments = computeFor(
        fixAt(
          const GeoPoint(latitude: 50.0007, longitude: -1.25),
          cog: 90,
          sog: 3,
          accuracy: 200,
        ),
      );

      expect(instruments.crossTrackError.isAvailable, isFalse);
      expect(instruments.crossTrackError.reason, contains('200 m'));
      expect(instruments.offTrackSide, isNull);
      expect(instruments.accuracyIsPoor, isTrue);
    });

    test('on the track it is zero with no side', () {
      final instruments = computeFor(
        fixAt(
          const GeoPoint(latitude: 50.0, longitude: -1.25),
          cog: 90,
          sog: 3,
        ),
      );
      expect(instruments.crossTrackError.value, closeTo(0, 1));
      expect(instruments.offTrackSide, isNull);
    });
  });

  group('velocity made good', () {
    test('equals SOG when steering straight at the mark', () {
      final instruments = computeFor(fixAt(west, cog: 90, sog: 4));
      expect(instruments.velocityMadeGood.value, closeTo(4, 0.05));
      expect(instruments.velocityMadeGood.basis, InstrumentBasis.calculated);
    });

    test('falls off with the angle, and goes negative when opening', () {
      final across = computeFor(fixAt(west, cog: 150, sog: 4));
      expect(across.velocityMadeGood.value, lessThan(4));
      expect(across.velocityMadeGood.value, greaterThan(0));

      // Sailing away from the mark: VMG is negative, and that is the honest
      // number rather than zero.
      final away = computeFor(fixAt(west, cog: 270, sog: 4));
      expect(away.velocityMadeGood.value, closeTo(-4, 0.05));
    });

    test('is absent without both a course and a speed', () {
      expect(
        computeFor(fixAt(west, sog: 4)).velocityMadeGood.isAvailable,
        isFalse,
      );
      expect(
        computeFor(fixAt(west, cog: 90)).velocityMadeGood.isAvailable,
        isFalse,
      );
      expect(
        computeFor(fixAt(west, cog: 90)).velocityMadeGood.reason,
        contains('course and speed'),
      );
    });
  });

  group('time to run', () {
    test('uses the measured closing speed, not the planned speed', () {
      final instruments = computeFor(fixAt(west, cog: 90, sog: 5));
      // 19.3 NM at 5 m/s is about 1h 59m. The plan's 5 kn would say 3h 52m.
      expect(instruments.timeToMark!.inMinutes, closeTo(119, 3));
    });

    test('is absent when the vessel is not closing the mark', () {
      // "Arriving in -3 minutes" is not a time.
      final away = computeFor(fixAt(west, cog: 270, sog: 4));
      expect(away.timeToMark, isNull);
      expect(away.timeToDestination, isNull);

      final stopped = computeFor(fixAt(west, cog: 90, sog: 0));
      expect(stopped.timeToMark, isNull);
    });
  });

  group('a fix that cannot be trusted', () {
    test('a stale fix is flagged, and its age is reported', () {
      final instruments = computeFor(
        fixAt(west, cog: 90, sog: 3, age: const Duration(seconds: 40)),
      );

      expect(instruments.fixIsStale, isTrue);
      expect(instruments.fixAge, const Duration(seconds: 40));
    });

    test('a fresh fix is not', () {
      final instruments = computeFor(
        fixAt(west, cog: 90, sog: 3, age: const Duration(seconds: 2)),
      );
      expect(instruments.fixIsStale, isFalse);
      expect(instruments.accuracyIsPoor, isFalse);
    });

    test('a fix from the future is treated as current, not negative', () {
      final instruments = NavigationInstruments.compute(
        fix: NavigationFix(
          point: west,
          recordedAt: fixedNow.add(const Duration(seconds: 5)),
          courseOverGroundDegrees: 90,
          speedOverGroundMetersPerSecond: 3,
        ),
        plan: planOf(const [west, east]),
        now: fixedNow,
      );
      expect(instruments.fixAge, Duration.zero);
      expect(instruments.fixIsStale, isFalse);
    });

    test('the staleness threshold is configurable', () {
      final instruments = NavigationInstruments.compute(
        fix: fixAt(west, cog: 90, sog: 3, age: const Duration(seconds: 20)),
        plan: planOf(const [west, east]),
        now: fixedNow,
        policy: const NavigationFixPolicy(staleAfter: Duration(minutes: 1)),
      );
      expect(instruments.fixIsStale, isFalse);
    });
  });

  group('with no passage', () {
    test('position instruments still work, plan ones say why not', () {
      final instruments = computeFor(
        fixAt(west, cog: 90, sog: 3),
        marks: const [west],
      );

      // A sailor with no passage still wants COG and SOG.
      expect(instruments.courseOverGround.value, 90);
      expect(instruments.speedOverGround.value, 3);

      expect(instruments.hasActiveLeg, isFalse);
      expect(instruments.bearingToMark.reason, 'No passage');
      expect(instruments.crossTrackError.isAvailable, isFalse);
      expect(instruments.velocityMadeGood.isAvailable, isFalse);
      expect(instruments.timeToMark, isNull);
    });
  });
}
