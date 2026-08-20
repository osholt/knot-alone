/// What the passage asks for, where the vessel actually is.
///
/// The piece that was missing (#63, #73). Everything it needs already existed
/// and none of it was joined up: `PassagePlan` knew the legs, `PassageManeuverPlan`
/// knew the alterations, `NavigationInstruments` knew where the vessel was and
/// how stale that knowledge was — and the surface under way was still being fed
/// by the road guidance planner, which had nothing to say about any of it.
///
/// So this reads all three and answers the four questions a navigator asks under
/// way: which leg am I on, what is next, how far is it, and what does the plan
/// ask for when I get there.
///
/// ## It reports the plan; it does not decide anything
///
/// `PLAN.md` requires that guidance "never issues helm commands". The
/// distinction worth holding: "alter 22 degrees to port onto 074" is the course
/// *the sailor themselves planned*, read back at the moment it becomes
/// relevant — the same figures the leg table shows in writing. Nothing here
/// chooses a course, avoids a hazard, or judges whether the plan is safe. It
/// cannot: there is no chart under it (#17), no depth (#29) and no tide (#11).
///
/// ## Prompts are state, not events
///
/// [PassageGuidance.prompts] is what is *currently* worth saying, each with a
/// stable [PassagePrompt.key]. Whoever speaks them keeps the set it has already
/// said and skips those — which is what `active_voyage_shell` already does with
/// its spoken-key set. Emitting events instead would mean this service owning a
/// timeline, and a service that owns a timeline cannot be tested by handing it a
/// position.
library;

import '../domain/distance_unit.dart';
import 'measurement_formatter.dart';
import 'navigation_instruments.dart';
import 'passage_legs.dart';
import 'passage_maneuvers.dart';

/// Metres in a nautical mile.
const _metresPerNauticalMile = 1852.0;

/// Metres in a cable, a tenth of a nautical mile.
const _metresPerCable = _metresPerNauticalMile / 10;

/// Where the vessel is in the passage.
enum PassagePhase {
  /// Nothing planned. COG and SOG still work; there is simply no passage to
  /// report progress against.
  noPassage,

  /// A passage, but no position yet — or one too old to use.
  waitingForFix,

  /// On a leg, with the next mark more than an approach away.
  underWay,

  /// Inside [PassageGuidancePolicy.approachMeters] of the next mark, which is
  /// when the alteration waiting there stops being reference and becomes
  /// something to prepare for.
  approachingMark,

  /// Off the planned track by more than the policy allows.
  ///
  /// Not a failure state and not exclusive of the others in reality — a vessel
  /// can be off track *and* approaching a mark. Reported as the phase because it
  /// is the more urgent of the two: a sailor a cable off the line wants to know
  /// that before they want the next course.
  offTrack,

  /// The last mark is within an approach.
  arriving,
}

/// Why something is worth saying aloud.
enum PassagePromptKind {
  /// The next mark is a mile off. Twelve minutes at five knots — time to get
  /// the next course in mind, which is the point of prompting this early.
  markAhead,

  /// The next mark is two cables off. Time to steer it.
  markImminent,

  /// Off the planned track by more than the policy allows.
  offTrack,

  /// The fix is too old to trust, which makes every calculated reading suspect.
  staleFix,

  /// The last mark is an approach away.
  arriving,
}

/// One thing worth saying, once.
class PassagePrompt {
  const PassagePrompt({
    required this.kind,
    required this.key,
    required this.spoken,
  });

  final PassagePromptKind kind;

  /// Stable for as long as this prompt means the same thing, so a speaker that
  /// remembers what it has said does not repeat it. Includes the mark it is
  /// about, so the same kind of prompt at the next mark is a different prompt.
  final String key;

  /// The words, written to be *heard*: three-figure courses digit by digit,
  /// distances in cables inside a mile, no abbreviations a voice would spell out.
  final String spoken;
}

/// Thresholds, stated rather than scattered.
class PassageGuidancePolicy {
  const PassageGuidancePolicy({
    this.approachMeters = _metresPerNauticalMile,
    this.imminentMeters = 2 * _metresPerCable,
    this.offTrackMeters = _metresPerCable,
  });

  /// How far out a mark is "ahead".
  ///
  /// One nautical mile. A yacht at five knots covers that in twelve minutes,
  /// which is the warning a navigator actually wants — road prompt distances of
  /// a couple of hundred metres would fire nine seconds before the mark.
  final double approachMeters;

  /// How far out a mark is "imminent". Two cables, about 370 m: close enough to
  /// be steering it, far enough to settle on the new course.
  final double imminentMeters;

  /// How far off the planned track is worth mentioning. One cable.
  final double offTrackMeters;
}

/// The passage, as it stands right now.
class PassageGuidance {
  const PassageGuidance({
    required this.phase,
    required this.headline,
    required this.instruments,
    this.detail,
    this.activeLeg,
    this.legCount = 0,
    this.alterationAhead,
    this.prompts = const [],
  });

  final PassagePhase phase;

  /// One line for the banner: where the vessel is in the passage.
  final String headline;

  /// A second line when there is more worth saying — the distance to run and
  /// the alteration waiting at the mark. Null when the headline says it all.
  final String? detail;

  final NavigationInstruments instruments;

  final PassageLeg? activeLeg;
  final int legCount;

  /// The alteration at the end of [activeLeg], when the plan asks for one there.
  ///
  /// Null both when the mark needs no alteration and when it is the last mark.
  /// The list surface distinguishes those; under way the difference does not
  /// change what a sailor does.
  final PassageManeuver? alterationAhead;

  /// What is worth saying now. Empty is the normal case.
  final List<PassagePrompt> prompts;

  bool get hasPassage => phase != PassagePhase.noPassage;

  /// Whether the surface should draw attention to itself.
  bool get needsAttention =>
      phase == PassagePhase.offTrack ||
      phase == PassagePhase.approachingMark ||
      phase == PassagePhase.arriving;

  /// Reads the passage against a fix.
  ///
  /// [maneuvers] is passed in rather than derived here so the caller can share
  /// one `PassageManeuverPlan` with the list surface — deriving it twice would
  /// let the two disagree about how many alterations a passage has.
  static PassageGuidance of({
    required PassagePlan plan,
    required PassageManeuverPlan maneuvers,
    required NavigationInstruments instruments,
    PassageGuidancePolicy policy = const PassageGuidancePolicy(),
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
  }) {
    final formatter = MeasurementFormatter(distanceUnit);

    if (!plan.hasLegs) {
      return PassageGuidance(
        phase: PassagePhase.noPassage,
        headline: 'No passage planned',
        instruments: instruments,
      );
    }

    final leg = instruments.activeLeg;
    if (leg == null || instruments.fixIsStale) {
      return PassageGuidance(
        phase: PassagePhase.waitingForFix,
        headline: instruments.fixIsStale
            ? 'Position is stale'
            : 'Waiting for a position',
        detail: instruments.fixIsStale
            // Said in the same breath as the reason, because the readings are
            // still on screen and a sailor needs to know not to steer by them.
            ? 'Last fix ${_spokenAge(instruments.fixAge)} ago. Readings below '
                  'are from it.'
            : 'The passage is ready. ${plan.legs.length} legs.',
        instruments: instruments,
        legCount: plan.legs.length,
        prompts: instruments.fixIsStale
            ? [
                PassagePrompt(
                  kind: PassagePromptKind.staleFix,
                  key: 'stale-fix',
                  spoken:
                      'Position is stale. Last fix '
                      '${_spokenAge(instruments.fixAge)} ago.',
                ),
              ]
            : const [],
      );
    }

    final distanceMeters = instruments.distanceToMark.value;
    final isLastLeg = leg.number == plan.legs.length;
    final alteration = maneuvers.maneuvers
        .where((maneuver) => maneuver.markLabel == leg.toLabel)
        .firstOrNull;

    final crossTrack = instruments.crossTrackError.value;
    final offTrack = crossTrack != null && crossTrack > policy.offTrackMeters;
    final imminent =
        distanceMeters != null && distanceMeters <= policy.imminentMeters;
    final approaching =
        distanceMeters != null && distanceMeters <= policy.approachMeters;

    final phase = offTrack
        ? PassagePhase.offTrack
        : isLastLeg && approaching
        ? PassagePhase.arriving
        : approaching
        ? PassagePhase.approachingMark
        : PassagePhase.underWay;

    return PassageGuidance(
      phase: phase,
      headline: switch (phase) {
        PassagePhase.offTrack =>
          '${formatter.distance(crossTrack!)} off track to '
              '${instruments.offTrackSide?.label ?? 'one side'}',
        PassagePhase.arriving => 'Arriving at ${leg.toLabel}',
        PassagePhase.approachingMark => 'Approaching ${leg.toLabel}',
        _ => 'Leg ${leg.number} of ${plan.legs.length} to ${leg.toLabel}',
      },
      detail: _detailFor(
        phase: phase,
        leg: leg,
        legCount: plan.legs.length,
        distanceMeters: distanceMeters,
        alteration: alteration,
        formatter: formatter,
        offTrackSide: instruments.offTrackSide,
      ),
      instruments: instruments,
      activeLeg: leg,
      legCount: plan.legs.length,
      alterationAhead: alteration,
      prompts: _promptsFor(
        leg: leg,
        distanceMeters: distanceMeters,
        alteration: alteration,
        isLastLeg: isLastLeg,
        imminent: imminent,
        approaching: approaching,
        offTrack: offTrack,
        crossTrackMeters: crossTrack,
        offTrackSide: instruments.offTrackSide,
      ),
    );
  }

  static String? _detailFor({
    required PassagePhase phase,
    required PassageLeg leg,
    required int legCount,
    required double? distanceMeters,
    required PassageManeuver? alteration,
    required MeasurementFormatter formatter,
    required TrackSide? offTrackSide,
  }) {
    final parts = <String>[];

    if (phase == PassagePhase.offTrack) {
      // The course back is the leg's own course; steering toward the track is
      // the sailor's decision and this only says which way that is.
      parts.add(
        'Track is to ${offTrackSide?.opposite.label ?? 'the other side'}. '
        "Leg ${leg.number}'s course is ${_threeFigures(leg.courseDegreesTrue)}°T",
      );
    }

    if (distanceMeters != null && phase != PassagePhase.offTrack) {
      parts.add('${formatter.distance(distanceMeters)} to run');
    }

    if (alteration != null) {
      parts.add(
        'then alter ${alteration.alterationDegrees.round()}° to '
        '${alteration.side.label} onto '
        '${_threeFigures(alteration.outboundCourseDegreesTrue)}°T',
      );
    } else if (phase == PassagePhase.arriving) {
      parts.add('last mark of the passage');
    }

    return parts.isEmpty ? null : parts.join(' · ');
  }

  static List<PassagePrompt> _promptsFor({
    required PassageLeg leg,
    required double? distanceMeters,
    required PassageManeuver? alteration,
    required bool isLastLeg,
    required bool imminent,
    required bool approaching,
    required bool offTrack,
    required double? crossTrackMeters,
    required TrackSide? offTrackSide,
  }) {
    final prompts = <PassagePrompt>[];

    if (offTrack && crossTrackMeters != null) {
      prompts.add(
        PassagePrompt(
          kind: PassagePromptKind.offTrack,
          // Keyed on the leg, so drifting off the same leg twice does not
          // announce twice, but doing it on the next leg does.
          key: 'off-track-leg-${leg.number}',
          spoken:
              '${_spokenDistance(crossTrackMeters)} off track to '
              '${offTrackSide?.label ?? 'one side'}. '
              "Leg ${leg.number}'s course is "
              '${_spokenCourse(leg.courseDegreesTrue)}.',
        ),
      );
    }

    if (distanceMeters == null) return prompts;

    if (isLastLeg && approaching) {
      prompts.add(
        PassagePrompt(
          kind: PassagePromptKind.arriving,
          key: 'arriving-${leg.toLabel}',
          spoken:
              '${_spokenDistance(distanceMeters)} to ${leg.toLabel}, '
              'the last mark.',
        ),
      );
      return prompts;
    }

    // Imminent supersedes ahead: two prompts about the same mark in the same
    // breath is noise, and the nearer one is the one that matters.
    if (imminent) {
      prompts.add(
        PassagePrompt(
          kind: PassagePromptKind.markImminent,
          key: 'mark-imminent-${leg.toLabel}',
          spoken: _markPhrase(leg, distanceMeters, alteration),
        ),
      );
    } else if (approaching) {
      prompts.add(
        PassagePrompt(
          kind: PassagePromptKind.markAhead,
          key: 'mark-ahead-${leg.toLabel}',
          spoken: _markPhrase(leg, distanceMeters, alteration),
        ),
      );
    }

    return prompts;
  }

  static String _markPhrase(
    PassageLeg leg,
    double distanceMeters,
    PassageManeuver? alteration,
  ) {
    final approach = '${_spokenDistance(distanceMeters)} to ${leg.toLabel}';
    if (alteration == null) return '$approach.';
    return '$approach, then alter '
        '${alteration.alterationDegrees.round()} degrees to '
        '${alteration.side.label} onto '
        '${_spokenCourse(alteration.outboundCourseDegreesTrue)}.';
  }
}

/// Three figures, rounded before normalising so 359.6 reads 000 rather than 360.
String _threeFigures(double degreesTrue) {
  final normalised = ((degreesTrue.round() % 360) + 360) % 360;
  return normalised.toString().padLeft(3, '0');
}

/// A course as it is passed aloud: "zero seven four", not "seventy four".
///
/// Digit by digit is how a course is read over a radio or across a cockpit, and
/// it is unambiguous through wind noise in a way "seventy four" is not — which
/// could be 074 or 74 spoken carelessly for 274.
String _spokenCourse(double degreesTrue) {
  const names = [
    'zero',
    'one',
    'two',
    'three',
    'four',
    'five',
    'six',
    'seven',
    'eight',
    'nine',
  ];
  return _threeFigures(
    degreesTrue,
  ).split('').map((digit) => names[int.parse(digit)]).join(' ');
}

/// A distance as it is said at sea: cables inside a mile, miles beyond.
///
/// Deliberately not `MeasurementFormatter`, which writes for the eye: "2.5 NM"
/// is right on screen and wrong in the ear, where it wants to be "two point five
/// miles". Numerals a voice has to expand are a source of mis-hearing.
String _spokenDistance(double meters) {
  final cables = meters / _metresPerCable;
  if (cables < 1) return 'less than a cable';
  if (cables < 10) {
    final rounded = cables.round();
    return rounded == 1 ? 'one cable' : '$rounded cables';
  }
  final miles = meters / _metresPerNauticalMile;
  if (miles < 10) {
    final tenths = (miles * 10).round();
    if (tenths % 10 == 0) {
      final whole = tenths ~/ 10;
      return whole == 1 ? 'one mile' : '$whole miles';
    }
    return '${tenths ~/ 10} point ${tenths % 10} miles';
  }
  return '${miles.round()} miles';
}

/// A fix age in words rather than a duration a voice would read as digits.
String _spokenAge(Duration age) {
  if (age.inSeconds < 60) {
    final seconds = age.inSeconds;
    return seconds <= 1 ? 'a second' : '$seconds seconds';
  }
  final minutes = age.inMinutes;
  if (minutes < 60) return minutes == 1 ? 'a minute' : '$minutes minutes';
  final hours = age.inHours;
  return hours == 1 ? 'an hour' : '$hours hours';
}
