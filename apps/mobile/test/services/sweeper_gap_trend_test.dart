// Which way the gap to the TEC is going (#181).
//
//   "for lead and sweeper, distance between is often less relevant than distance
//    trend. Could we have the 'distance to sweeper' field RAG for 'Sweeper stopped /
//    about the same speed / distance closing' or similar?"
//
// The cases that matter most are the two the request did not name: a gap that is
// *opening*, which is what tells a skipper to ease off, and a **stale** fix, which
// must never read as a stopped sailor. #132 and #134 both turned on that second
// distinction.

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/services/skipper_voyage_status.dart'
    show SweeperAvailability;
import 'package:tide_and_seek/services/sweeper_gap_trend.dart';

void main() {
  final start = DateTime.utc(2026, 7, 28, 10);

  /// Feeds a sequence of gaps at 10-second intervals and returns the last trend.
  SweeperGapTrend trendFor(
    List<double> gaps, {
    SweeperAvailability availability = SweeperAvailability.tracking,
    GeoPoint? Function(int index)? sweeperPosition,
    SweeperGapTrendTracker? tracker,
  }) {
    final subject = tracker ?? SweeperGapTrendTracker();
    var trend = SweeperGapTrend.unknown;
    for (final (index, gap) in gaps.indexed) {
      trend = subject.update(
        availability: availability,
        gapMeters: gap,
        sweeperPosition: sweeperPosition?.call(index) ?? _movingSweeper(index),
        now: start.add(Duration(seconds: 10 * index)),
      );
    }
    return trend;
  }

  group('the three states the request asked for', () {
    test('a shrinking gap is closing', () {
      // 20 m/s of closure - a skipper easing off while the TEC catches up.
      expect(trendFor([1200, 1000, 800, 600]), SweeperGapTrend.closing);
    });

    test('a steady gap is holding', () {
      // Both riding the same speed, with the number drifting on GPS noise.
      expect(trendFor([800, 803, 797, 801]), SweeperGapTrend.holding);
    });

    test('a stationary TEC is stopped', () {
      expect(
        trendFor(
          [400, 600, 800, 1000],
          sweeperPosition: (_) =>
              const GeoPoint(latitude: 51.46, longitude: -2.5),
        ),
        SweeperGapTrend.stopped,
        reason: 'stopped is a claim about the sailor, not about the gap',
      );
    });
  });

  group('the state the request did not name', () {
    test('a growing gap is opening', () {
      expect(
        trendFor([600, 800, 1000, 1200]),
        SweeperGapTrend.opening,
        reason: 'this is the one that tells a skipper to slow down',
      );
    });

    test('opening is distinguished from stopped by the TEC moving', () {
      // Identical gaps to the stopped case above; the difference is that the TEC
      // is travelling.
      expect(trendFor([400, 600, 800, 1000]), SweeperGapTrend.opening);
    });
  });

  group('a fix that cannot be trusted is never a stopped sailor', () {
    for (final availability in [
      SweeperAvailability.none,
      SweeperAvailability.awaitingLocation,
      SweeperAvailability.stale,
    ]) {
      test('${availability.name} reads as unknown', () {
        expect(
          trendFor([1000, 1000, 1000, 1000], availability: availability),
          SweeperGapTrend.unknown,
        );
      });
    }

    test('going stale clears the history rather than freezing a trend', () {
      final tracker = SweeperGapTrendTracker();
      trendFor([1200, 1000, 800, 600], tracker: tracker);
      expect(tracker.sampleCount, greaterThan(0));

      final trend = tracker.update(
        availability: SweeperAvailability.stale,
        gapMeters: null,
        sweeperPosition: null,
        now: start.add(const Duration(seconds: 40)),
      );

      expect(trend, SweeperGapTrend.unknown);
      expect(
        tracker.sampleCount,
        0,
        reason: 'a resumed TEC starts a fresh trend, not the old one',
      );
    });
  });

  group('it does not flicker', () {
    test('too few samples says unknown rather than guessing', () {
      expect(trendFor([1000, 900]), SweeperGapTrend.unknown);
    });

    test('noise around a steady gap never reads as closing or opening', () {
      // +/- 12 m of jitter on an 800 m gap, which is well inside a phone fix.
      const jitter = <double>[800, 812, 788, 806, 794, 809, 791, 803];
      expect(trendFor(jitter), SweeperGapTrend.holding);
    });

    test('one wild fix does not decide the state', () {
      // A steady gap with a single 400 m outlier in the middle. A last-minus-
      // first difference would call this closing; a fit does not.
      expect(trendFor([800, 805, 400, 802, 798]), SweeperGapTrend.holding);
    });

    test('samples older than the window are dropped', () {
      final tracker = SweeperGapTrendTracker(
        window: const Duration(seconds: 30),
      );
      // Four samples at 10 s intervals fills the window exactly; a fifth pushes
      // the first out.
      for (var index = 0; index < 5; index += 1) {
        tracker.update(
          availability: SweeperAvailability.tracking,
          gapMeters: 800,
          sweeperPosition: _movingSweeper(index),
          now: start.add(Duration(seconds: 10 * index)),
        );
      }
      expect(tracker.sampleCount, lessThanOrEqualTo(4));
    });
  });

  group('what a sailor reads', () {
    test('the growing gap is stated without the ambiguous word opening', () {
      expect(SweeperGapTrend.opening.label, 'Gap increasing');
    });

    test('every trend has a word and a shape, not just a colour', () {
      for (final trend in SweeperGapTrend.values) {
        expect(trend.label, isNotEmpty, reason: '${trend.name} has no label');
        expect(trend.arrow, isNotEmpty, reason: '${trend.name} has no shape');
      }
    });

    test('the labels are distinct, so two states cannot read alike', () {
      final labels = SweeperGapTrend.values.map((trend) => trend.label).toSet();
      expect(labels, hasLength(SweeperGapTrend.values.length));
    });

    test('the smoothing window is stated rather than magic', () {
      expect(
        SweeperGapTrendTracker(
          window: const Duration(seconds: 30),
        ).windowDescription,
        'over the last 30 seconds',
      );
    });
  });
}

/// A TEC travelling steadily north, so the stopped check does not fire.
GeoPoint _movingSweeper(int index) =>
    GeoPoint(latitude: 51.46 + index * 0.002, longitude: -2.5);
