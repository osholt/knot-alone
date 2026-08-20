import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/navigation_instruments.dart';
import 'package:tide_and_seek/services/passage_guidance.dart';
import 'package:tide_and_seek/services/passage_legs.dart';
import 'package:tide_and_seek/services/passage_maneuvers.dart';
import 'package:tide_and_seek/services/spoken_audio_mode.dart';

/// #73. What the voice would actually say, and how often.
///
/// The shell's `_speakPassage` is a loop over `prompts` filtered against the
/// spoken-key set. These tests stand in for that loop rather than driving the
/// whole shell, because what can go wrong is the *keys*: a prompt whose key
/// changes on every fix would be said on every fix, and a sailor a mile from a
/// mark would hear the same sentence twenty times.
void main() {
  group('a prompt is said once', () {
    test('the same approach on twenty consecutive fixes speaks once', () {
      final spoken = <String>{};
      var utterances = 0;

      // Closing the mark slowly, as a yacht does: twenty fixes over the last
      // half mile, all of them inside the approach.
      for (var step = 0; step < 20; step += 1) {
        final guidance = _guidanceAt(
          GeoPoint(latitude: 50.6958 - step * 0.0002, longitude: -1.4145),
        );
        for (final prompt in guidance.prompts) {
          if (spoken.add(prompt.key)) utterances += 1;
        }
      }

      expect(
        utterances,
        lessThanOrEqualTo(2),
        reason:
            'at most the one-mile prompt and the two-cable one; anything more '
            'means a key is changing between fixes',
      );
    });

    test('the next mark is a new prompt, not a repeat', () {
      final spoken = <String>{};
      final said = <String>[];

      for (final point in [
        // Approaching Hamstead.
        const GeoPoint(latitude: 50.6958, longitude: -1.4145),
        // Then approaching Salt Mead on the next leg.
        const GeoPoint(latitude: 50.7060, longitude: -1.3540),
      ]) {
        for (final prompt in _guidanceAt(point).prompts) {
          if (spoken.add(prompt.key)) said.add(prompt.spoken);
        }
      }

      expect(said, hasLength(2));
      expect(said.first, contains('Hamstead'));
      expect(said.last, contains('Salt Mead'));
    });
  });

  group('what the sailor hears', () {
    test('the mile prompt names the mark and the alteration', () {
      final spoken = _guidanceAt(
        const GeoPoint(latitude: 50.6958, longitude: -1.4145),
      ).prompts.single.spoken;

      // The sentence, as a whole, because the parts have to hang together to be
      // followable while steering.
      expect(
        spoken,
        matches(
          RegExp(
            r'^\d+ (cable|cables|mile|miles|point) .*to Hamstead, then alter '
            r'\d+ degrees to (port|starboard) onto '
            r'(zero|one|two|three|four|five|six|seven|eight|nine) ',
          ),
        ),
        reason:
            'heard as: "6 cables to Hamstead, then alter 26 degrees to '
            'port onto zero six eight." — got: $spoken',
      );
    });

    test('a stale fix is safety, so alerts-only still says it', () {
      final guidance = _guidanceAt(
        const GeoPoint(latitude: 50.6958, longitude: -1.4145),
        fixAge: const Duration(minutes: 3),
      );
      final prompt = guidance.prompts.single;

      expect(prompt.kind, PassagePromptKind.staleFix);
      // The shell classes this one as safety and the rest as navigation. A
      // sailor who muted directions still wants to be told their position is
      // three minutes old, because the readings on screen come from it.
      expect(
        spokenAudioAllows(SpokenAudioMode.alertsOnly, SpokenAudioClass.safety),
        isTrue,
      );
      expect(
        spokenAudioAllows(
          SpokenAudioMode.alertsOnly,
          SpokenAudioClass.navigation,
        ),
        isFalse,
      );
    });

    test('nothing is said on a leg with a long way to run', () {
      expect(
        _guidanceAt(
          const GeoPoint(latitude: 50.6990, longitude: -1.4800),
        ).prompts,
        isEmpty,
      );
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

PassageGuidance _guidanceAt(GeoPoint point, {Duration fixAge = Duration.zero}) {
  final now = DateTime.utc(2026, 8, 20, 12);
  final plan = _plan();
  return PassageGuidance.of(
    plan: plan,
    maneuvers: PassageManeuverPlan.of(plan),
    instruments: NavigationInstruments.compute(
      fix: NavigationFix(
        point: point,
        recordedAt: now.subtract(fixAge),
        courseOverGroundDegrees: 85,
        speedOverGroundMetersPerSecond: 2.6,
        accuracyMeters: 5,
      ),
      plan: plan,
      now: now,
    ),
  );
}
