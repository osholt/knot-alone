import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/situational_awareness_controller.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/sailor_trail_recorder.dart';

/// Regression cover for #100: a sailor's travelled trail is recorded from
/// position history alone, so it survives leaving the planned route, having no
/// planned route, and an app restart mid-voyage.
void main() {
  test('records a trail for a skipper who has ridden off the planned route', () {
    final recorder = SailorTrailRecorder();

    final trails = recorder.update([
      _update('skipper', _point(0, 0), isSkipper: true),
    ]);
    final later = recorder.update([
      // Kilometres away from any plan, and still not flagged off route because
      // the skipper's own trail counts as a valid route.
      _update('skipper', _point(0.02, 0.02), isSkipper: true),
    ]);

    expect(trails.single.isRenderable, isFalse);
    expect(later.single.kind, SailorTrailKind.skipper);
    expect(later.single.points, hasLength(2));
    expect(later.single.isRenderable, isTrue);
  });

  test('records a trail for a follower flagged off route', () {
    final recorder = SailorTrailRecorder();

    recorder.update([_update('sam', _point(0, 0))]);
    final trails = recorder.update([
      _update('sam', _point(0.01, 0), isOffRoute: true),
    ]);

    expect(trails.single.kind, SailorTrailKind.offRoute);
    expect(trails.single.points, hasLength(2));
  });

  test('records trails when no route has been imported at all', () {
    final recorder = SailorTrailRecorder();

    recorder.update([
      _update('skipper', _point(0, 0), isSkipper: true),
      _update('sam', _point(0.1, 0)),
    ]);
    final trails = recorder.update([
      _update('skipper', _point(0, 0.01), isSkipper: true),
      _update('sam', _point(0.1, 0.01)),
    ]);

    expect(trails, hasLength(2));
    expect(trails.every((trail) => trail.isRenderable), isTrue);
    expect(trails.map((trail) => trail.kind), [
      SailorTrailKind.skipper,
      SailorTrailKind.sailor,
    ]);
  });

  test('an excursion and rejoin stay one continuous trail', () {
    final recorder = SailorTrailRecorder();
    final route = [
      _point(0, 0),
      _point(0, 0.001),
      _point(0, 0.002),
      _point(0, 0.003),
    ];
    final excursion = [_point(0.01, 0.0015), _point(0.012, 0.002)];

    // On route, off route, then back on route: the alert state changes, the
    // recorded history does not restart.
    for (final point in route.take(2)) {
      recorder.update([_update('sam', point)]);
    }
    for (final point in excursion) {
      recorder.update([_update('sam', point, isOffRoute: true)]);
    }
    final rejoined = recorder.update([
      _update('sam', route[2], isOffRoute: true),
    ]);
    final settled = recorder.update([_update('sam', route[3])]);

    expect(rejoined.single.kind, SailorTrailKind.offRoute);
    expect(settled.single.kind, SailorTrailKind.sailor);
    expect(settled.single.points, hasLength(6));
    expect(settled.single.points.first.latitude, 0);
    expect(settled.single.points[2].latitude, closeTo(0.01, 1e-9));
    expect(settled.single.points.last.longitude, closeTo(0.003, 1e-9));
  });

  test('journal history restores a trail after an app restart mid-voyage', () {
    // A restart starts with an empty recorder; the skipper's history is replayed
    // from the durable journal instead.
    final recorder = SailorTrailRecorder();
    final journal = [_point(0, 0), _point(0, 0.001), _point(0, 0.002)];

    final restored = recorder.update([
      _update(
        'skipper',
        _point(0, 0.003),
        isSkipper: true,
        journalTrail: journal,
      ),
    ]);
    final live = recorder.update([
      _update('skipper', _point(0, 0.004), isSkipper: true),
    ]);

    expect(restored.single.points, hasLength(3));
    expect(restored.single.isRenderable, isTrue);
    // Once this device has recorded more than the journal replayed, its own
    // history wins, so the trail keeps extending rather than jumping back.
    expect(live.single.points.length, greaterThanOrEqualTo(2));
    expect(live.single.points.last.longitude, closeTo(0.004, 1e-9));
  });

  test('bounds every sailor identically, including the local sailor', () {
    final recorder = SailorTrailRecorder(maximumPointsPerSailor: 4);

    for (var index = 0; index < 10; index += 1) {
      recorder.update([
        _update('me', _point(0, index * 0.001)),
        _update('skipper', _point(0.05, index * 0.001), isSkipper: true),
      ]);
    }

    expect(recorder.trailFor('me'), hasLength(4));
    expect(recorder.trailFor('skipper'), hasLength(4));
    expect(
      recorder.trailFor('me').first.longitude,
      closeTo(0.006, 1e-9),
      reason: 'the oldest points are dropped, not the newest',
    );
  });

  test('bounds a journal trail with the same cap', () {
    final recorder = SailorTrailRecorder(maximumPointsPerSailor: 3);

    final trails = recorder.update([
      _update(
        'skipper',
        _point(0, 0.01),
        isSkipper: true,
        journalTrail: [
          for (var index = 0; index < 40; index += 1) _point(0, index * 0.0001),
        ],
      ),
    ]);

    expect(trails.single.points, hasLength(3));
  });

  group('a long voyage keeps its whole drawn track (#299)', () {
    // The bound was 120 points. Positions become durable reports at roughly one
    // per 20 m of travel, so that was about 2.4 km of riding whatever the
    // length of the voyage: past it the oldest points were deleted and the drawn
    // trail slid along behind the sailor. "It forgets your track after a while."
    test(
      'a solo sailor three hours in still has the start of their voyage',
      () {
        final recorder = SailorTrailRecorder();
        final start = DateTime.utc(2026, 8, 2, 9);
        // 6,000 reports is roughly 120 km at the report rate — a long solo day,
        // and fifty times the old bound.
        const reports = 6000;

        for (var index = 0; index < reports; index += 1) {
          recorder.update([
            _update(
              'me',
              _point(
                51.4,
                -2.5 + index * 0.0002,
                recordedAt: start.add(Duration(seconds: index * 2)),
              ),
              isSkipper: true,
            ),
          ]);
        }

        final trail = recorder.trailFor('me');
        expect(trail, hasLength(reports));
        expect(
          trail.first.recordedAt,
          start,
          reason: 'the first fix of the voyage is still there at the end of it',
        );
        expect(
          trail.last.recordedAt,
          start.add(Duration(seconds: (reports - 1) * 2)),
        );
      },
    );

    test('the recorder no longer cuts the journal trail below its source', () {
      // #280 raised the skipper trail's bound in SituationalAwarenessController
      // from 600 to 100,000 after a 112 mile voyage lost its tail. That trail
      // arrives here as `journalTrail`, and this recorder cut it back to 120,
      // so the fix never reached the map. A bound below its own source is a
      // deletion, not a bound.
      final recorder = SailorTrailRecorder();
      final journal = [
        for (var index = 0; index < 5000; index += 1)
          _point(51.4, -2.5 + index * 0.0002),
      ];

      final trails = recorder.update([
        _update(
          'skipper',
          _point(51.4, -2.5 + 5000 * 0.0002),
          isSkipper: true,
          journalTrail: journal,
        ),
      ]);

      expect(trails.single.points, hasLength(journal.length));
    });

    test('the bound is a memory backstop, not a display policy', () {
      // It must sit at or above the journal trail it is handed, or it silently
      // overrides it again. Drawing cost is bounded elsewhere and separately:
      // TrailDisplaySimplifier reduces every trace to at most 2,000 points
      // before either map implementation sees it.
      expect(
        SailorTrailRecorder.defaultMaximumPointsPerSailor,
        greaterThanOrEqualTo(
          SituationalAwarenessController.maximumRetainedTrailPoints,
        ),
      );
    });
  });

  test('breaks a trail across an implausible reporting gap', () {
    final recorder = SailorTrailRecorder();
    final start = DateTime.utc(2026, 7, 29, 9);
    final points = [
      _point(53, -1, recordedAt: start),
      _point(53.001, -1, recordedAt: start.add(const Duration(seconds: 20))),
      _point(54, -2, recordedAt: start.add(const Duration(minutes: 20))),
      _point(
        54.001,
        -2,
        recordedAt: start.add(const Duration(minutes: 20, seconds: 20)),
      ),
    ];

    final segments = recorder.continuousSegments(points);

    expect(segments, hasLength(2));
    expect(segments.map((segment) => segment.length), const [2, 2]);
    expect(segments.first.last.latitude, 53.001);
    expect(segments.last.first.latitude, 54);
  });

  test('ignores repeated and out-of-order fixes', () {
    final recorder = SailorTrailRecorder();
    final start = DateTime.utc(2026, 7, 25, 9);

    recorder.record(
      sailorId: 'sam',
      point: _point(0, 0, recordedAt: start),
    );
    recorder.record(
      sailorId: 'sam',
      point: _point(0, 0, recordedAt: start),
    );
    recorder.record(
      sailorId: 'sam',
      point: _point(
        0,
        0.001,
        recordedAt: start.add(const Duration(minutes: 2)),
      ),
    );
    final stale = recorder.record(
      sailorId: 'sam',
      point: _point(
        0,
        0.0005,
        recordedAt: start.add(const Duration(minutes: 1)),
      ),
    );

    expect(stale, isTrue, reason: 'a late fix is inserted in recorded order');
    expect(recorder.trailFor('sam'), hasLength(3));
    expect(recorder.trailFor('sam')[1].longitude, closeTo(0.0005, 1e-9));
    expect(recorder.trailFor('sam').last.longitude, closeTo(0.001, 1e-9));
  });

  test('drops history for a sailor who is no longer eligible', () {
    final recorder = SailorTrailRecorder();

    recorder.update([_update('guest', _point(0, 0))]);
    recorder.update([_update('guest', _point(0, 0.001))]);
    final trails = recorder.update([
      _update('guest', _point(0, 0.002), isEligible: false),
    ]);

    expect(trails, isEmpty);
    expect(recorder.trailFor('guest'), isEmpty);
  });

  test('the skipper kind wins over an off-route flag', () {
    expect(
      SailorTrailRecorder.kindFor(isSkipper: true, isOffRoute: true),
      SailorTrailKind.skipper,
    );
    expect(
      SailorTrailRecorder.kindFor(isSkipper: false, isOffRoute: true),
      SailorTrailKind.offRoute,
    );
    expect(
      SailorTrailRecorder.kindFor(isSkipper: false, isOffRoute: false),
      SailorTrailKind.sailor,
    );
  });
}

GeoPoint _point(double latitude, double longitude, {DateTime? recordedAt}) =>
    GeoPoint(latitude: latitude, longitude: longitude, recordedAt: recordedAt);

SailorTrailUpdate _update(
  String sailorId,
  GeoPoint position, {
  bool isSkipper = false,
  bool isOffRoute = false,
  bool isEligible = true,
  List<GeoPoint>? journalTrail,
}) => SailorTrailUpdate(
  sailorId: sailorId,
  displayName: sailorId,
  position: position,
  isSkipper: isSkipper,
  isOffRoute: isOffRoute,
  isEligible: isEligible,
  journalTrail: journalTrail,
);
