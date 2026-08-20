import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/navigation_instruments.dart';
import 'package:tide_and_seek/services/passage_guidance.dart';
import 'package:tide_and_seek/services/passage_legs.dart';
import 'package:tide_and_seek/services/passage_maneuvers.dart';

/// #63 and #73. The piece that joins a planned passage to where the vessel
/// actually is — which nothing did, so the surface under way was fed by the road
/// guidance planner and said nothing about legs, marks or alterations.
///
/// The prompts matter most here. They are the words a sailor hears while
/// steering, so these tests read them as sentences rather than checking fields:
/// a course spoken "seventy four" instead of "zero seven four" is a real hazard
/// through wind noise, and "2.5 NM" is right on a screen and wrong in an ear.
void main() {
  // Lymington eastward: three legs, roughly 096, 074, then 059.
  const lymington = GeoPoint(latitude: 50.7000, longitude: -1.5000);
  // ignore: unused_local_variable
  const hamstead = GeoPoint(latitude: 50.6950, longitude: -1.4000);
  // ignore: unused_local_variable
  const saltMead = GeoPoint(latitude: 50.7100, longitude: -1.3400);
  // ignore: unused_local_variable
  const cowes = GeoPoint(latitude: 50.7500, longitude: -1.3000);

  group('with no passage', () {
    test('says so, and still reports position instruments', () {
      final guidance = _guidanceAt(lymington, plan: PassagePlan.empty);

      expect(guidance.phase, PassagePhase.noPassage);
      expect(guidance.headline, 'No passage planned');
      expect(guidance.hasPassage, isFalse);
      expect(guidance.prompts, isEmpty);
      // A sailor with no passage still wants COG and SOG.
      expect(guidance.instruments, isNotNull);
    });
  });

  group('under way', () {
    test('names the leg, its mark, and how many there are', () {
      // Just off Lymington, so the first leg with a long way to run.
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6995, longitude: -1.4900),
      );

      expect(guidance.phase, PassagePhase.underWay);
      expect(guidance.headline, 'Leg 1 of 3 to Hamstead');
      expect(guidance.legCount, 3);
      expect(guidance.activeLeg?.number, 1);
    });

    test('says nothing aloud when the mark is more than a mile off', () {
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6995, longitude: -1.4900),
      );
      // Silence is the normal state. A prompt every update would be unusable.
      expect(guidance.prompts, isEmpty);
    });

    test('shows the distance to run', () {
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6995, longitude: -1.4900),
      );
      expect(guidance.detail, contains('to run'));
    });
  });

  group('approaching a mark', () {
    // A mile out from Hamstead, still on the first leg.
    final approach = _guidanceAt(
      const GeoPoint(latitude: 50.6960, longitude: -1.4150),
    );

    test('changes phase and headline', () {
      expect(approach.phase, PassagePhase.approachingMark);
      expect(approach.headline, 'Approaching Hamstead');
      expect(approach.needsAttention, isTrue);
    });

    test('carries the alteration waiting there', () {
      expect(approach.alterationAhead, isNotNull);
      expect(approach.detail, contains('alter'));
      expect(approach.detail, contains('°T'));
    });

    test('speaks the mark and the alteration in one prompt', () {
      final prompt = approach.prompts.single;

      expect(prompt.kind, PassagePromptKind.markAhead);
      expect(prompt.spoken, contains('Hamstead'));
      expect(prompt.spoken, contains('alter'));
      expect(prompt.spoken, contains('degrees to'));
    });

    test('speaks the course digit by digit, not as a number', () {
      final spoken = approach.prompts.single.spoken;

      // "zero seven four", never "74" or "seventy four": digit by digit is how
      // a course is passed aloud, and it survives wind noise.
      expect(
        spoken,
        matches(
          RegExp(
            r'(zero|one|two|three|four|five|six|seven|eight|nine) '
            r'(zero|one|two|three|four|five|six|seven|eight|nine) '
            r'(zero|one|two|three|four|five|six|seven|eight|nine)',
          ),
        ),
      );
      expect(spoken, isNot(contains('°')));
      expect(spoken, isNot(matches(RegExp(r'\bonto \d'))));
    });

    test('speaks distance in words a voice can say', () {
      final spoken = approach.prompts.single.spoken;

      expect(spoken, isNot(contains('NM')));
      expect(spoken, anyOf(contains('cable'), contains('mile')));
    });
  });

  group('with the mark imminent', () {
    // Two cables off Hamstead.
    final imminent = _guidanceAt(
      const GeoPoint(latitude: 50.6952, longitude: -1.4030),
    );

    test('is a different prompt from the one a mile out', () {
      final prompt = imminent.prompts.single;

      expect(prompt.kind, PassagePromptKind.markImminent);
      // A different key, so a speaker that already said the one-mile prompt
      // still says this one.
      expect(prompt.key, isNot('mark-ahead-Hamstead'));
    });

    test('never both prompts about the same mark at once', () {
      // Two sentences about one mark in the same breath is noise.
      expect(
        imminent.prompts.where((p) => p.kind == PassagePromptKind.markAhead),
        isEmpty,
      );
    });
  });

  group('off the track', () {
    // A quarter-mile north of the first leg: well off a line running roughly
    // east, and still nowhere near the mark.
    final off = _guidanceAt(
      const GeoPoint(latitude: 50.7040, longitude: -1.4600),
    );

    test('takes precedence over the leg, because it is more urgent', () {
      expect(off.phase, PassagePhase.offTrack);
      expect(off.headline, contains('off track'));
      expect(off.needsAttention, isTrue);
    });

    test('names the side it is off, and the side the track is on', () {
      expect(off.headline, anyOf(contains('port'), contains('starboard')));
      // The detail says which way the track lies, which is the opposite side.
      expect(off.detail, contains('Track is to'));
    });

    test('gives the leg course rather than a course to steer back', () {
      // Deliberate: recovering a track is the sailor's decision, and a computed
      // intercept would be this app choosing a course - which it must not do
      // with no chart under it.
      expect(off.detail, contains("Leg 1's course is"));
      expect(off.detail, isNot(contains('steer')));
    });

    test('speaks it once per leg, not once per fix', () {
      final prompt = off.prompts.first;
      expect(prompt.kind, PassagePromptKind.offTrack);
      expect(prompt.key, 'off-track-leg-1');
    });
  });

  group('arriving', () {
    // Approaching Cowes on the last leg.
    final arriving = _guidanceAt(
      const GeoPoint(latitude: 50.7420, longitude: -1.3060),
    );

    test('says it is the last mark rather than offering a next course', () {
      expect(arriving.phase, PassagePhase.arriving);
      expect(arriving.headline, 'Arriving at Cowes');
      expect(arriving.detail, contains('last mark'));
      expect(arriving.alterationAhead, isNull);
    });

    test('the prompt says the same', () {
      final prompt = arriving.prompts.single;
      expect(prompt.kind, PassagePromptKind.arriving);
      expect(prompt.spoken, contains('last mark'));
    });
  });

  group('when the fix goes stale', () {
    test('the passage stops reporting progress and says why', () {
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6960, longitude: -1.4150),
        fixAge: const Duration(minutes: 3),
      );

      expect(guidance.phase, PassagePhase.waitingForFix);
      expect(guidance.headline, 'Position is stale');
      // The readings are still on screen, so a sailor has to be told not to
      // steer by them.
      expect(guidance.detail, contains('Readings below'));
    });

    test('says it aloud, with the age in words', () {
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6960, longitude: -1.4150),
        fixAge: const Duration(minutes: 3),
      );
      final prompt = guidance.prompts.single;

      expect(prompt.kind, PassagePromptKind.staleFix);
      expect(prompt.spoken, contains('stale'));
      expect(prompt.spoken, contains('3 minutes'));
    });

    test('a stale fix outranks an approaching mark', () {
      // Standing two cables from a mark on a three-minute-old fix, the mark is
      // not the thing to say.
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6952, longitude: -1.4030),
        fixAge: const Duration(minutes: 3),
      );

      expect(guidance.phase, PassagePhase.waitingForFix);
      expect(guidance.prompts.map((p) => p.kind), [PassagePromptKind.staleFix]);
    });
  });

  group('the thresholds are stated, not scattered', () {
    test('an approach is a mile and imminent is two cables', () {
      const policy = PassageGuidancePolicy();
      expect(policy.approachMeters, 1852.0);
      expect(policy.imminentMeters, closeTo(370.4, 0.1));
      expect(policy.offTrackMeters, closeTo(185.2, 0.1));
    });

    test('a tighter policy changes when a mark is announced', () {
      final position = const GeoPoint(latitude: 50.6960, longitude: -1.4150);

      // Default: a mile out, so announced.
      expect(_guidanceAt(position).prompts, hasLength(1));
      // Halve the approach and the same position is not yet worth saying.
      expect(
        _guidanceAt(
          position,
          policy: const PassageGuidancePolicy(approachMeters: 900),
        ).prompts,
        isEmpty,
      );
    });
  });

  group('it never issues a helm command', () {
    test('no prompt tells the sailor what to do with the wheel', () {
      for (final position in [
        const GeoPoint(latitude: 50.6960, longitude: -1.4150),
        const GeoPoint(latitude: 50.6952, longitude: -1.4030),
        const GeoPoint(latitude: 50.7040, longitude: -1.4600),
        const GeoPoint(latitude: 50.7420, longitude: -1.3060),
      ]) {
        for (final prompt in _guidanceAt(position).prompts) {
          // "Alter 22 degrees to port onto 074" reports the sailor's own plan.
          // "Turn", "steer", "head for" would be the app choosing, which it
          // cannot do with no chart, no depth and no tide under it.
          for (final verb in ['turn ', 'steer ', 'head for', 'go to']) {
            expect(
              prompt.spoken.toLowerCase(),
              isNot(contains(verb)),
              reason: '"$verb" in: ${prompt.spoken}',
            );
          }
        }
      }
    });
  });

  group('spoken distances read as speech', () {
    test('across the range a passage actually uses', () {
      // Driven through the public surface by placing the vessel at known
      // distances off a mark, because the formatter is private on purpose.
      final phrases = <String>[];
      for (final latitude in [50.6952, 50.6955, 50.6960, 50.6975]) {
        final guidance = _guidanceAt(
          GeoPoint(latitude: latitude, longitude: -1.4100),
        );
        phrases.addAll(guidance.prompts.map((p) => p.spoken));
      }

      expect(phrases, isNotEmpty);
      for (final phrase in phrases) {
        // No unit abbreviation, and no decimal a voice would read as "four
        // point three" when it means four and a bit cables. A bare "4" is fine:
        // every engine says "four". The full stop ending the sentence is fine
        // too, which an earlier version of this assertion tripped over.
        expect(phrase, isNot(contains('NM')));
        expect(
          phrase,
          isNot(matches(RegExp(r'\d\.\d'))),
          reason: 'a decimal in the ear is a mis-heard distance',
        );
      }
    });
  });
}

PassagePlan _plan() => PassagePlan.of(
  ImportedRoute(
    id: 'solent',
    name: 'Lymington to Cowes',
    importedAt: DateTime.utc(2026, 8, 20),
    sourceFileName: 'solent.gpx',
    paths: const [
      RoutePath(
        kind: RoutePathKind.route,
        points: [
          GeoPoint(latitude: 50.7000, longitude: -1.5000),
          GeoPoint(latitude: 50.6950, longitude: -1.4000),
          GeoPoint(latitude: 50.7100, longitude: -1.3400),
          GeoPoint(latitude: 50.7500, longitude: -1.3000),
        ],
      ),
    ],
    waypoints: const [
      RouteWaypoint(
        name: 'Lymington',
        point: GeoPoint(latitude: 50.7000, longitude: -1.5000),
      ),
      RouteWaypoint(
        name: 'Hamstead',
        point: GeoPoint(latitude: 50.6950, longitude: -1.4000),
      ),
      RouteWaypoint(
        name: 'Salt Mead',
        point: GeoPoint(latitude: 50.7100, longitude: -1.3400),
      ),
      RouteWaypoint(
        name: 'Cowes',
        point: GeoPoint(latitude: 50.7500, longitude: -1.3000),
      ),
    ],
  ),
);

/// Reads the guidance for a vessel at [point], making way on a fresh fix unless
/// told otherwise.
PassageGuidance _guidanceAt(
  GeoPoint point, {
  PassagePlan? plan,
  Duration fixAge = Duration.zero,
  PassageGuidancePolicy policy = const PassageGuidancePolicy(),
}) {
  final now = DateTime.utc(2026, 8, 20, 12);
  final passage = plan ?? _plan();
  final fix = NavigationFix(
    point: point,
    recordedAt: now.subtract(fixAge),
    courseOverGroundDegrees: 90,
    speedOverGroundMetersPerSecond: 2.6, // about 5 knots
    accuracyMeters: 5,
  );
  return PassageGuidance.of(
    plan: passage,
    maneuvers: PassageManeuverPlan.of(passage),
    instruments: NavigationInstruments.compute(
      fix: fix,
      plan: passage,
      now: now,
    ),
    policy: policy,
  );
}
