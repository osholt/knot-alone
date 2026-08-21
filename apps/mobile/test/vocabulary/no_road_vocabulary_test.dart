@TestOn('mac-os')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #61. The app was scaffolded from a motorcycle group-riding app, and three
/// passes at renaming it left road vocabulary on live screens - "RIDER PROFILE"
/// in settings, "Who is riding?" when creating a voyage, "Plan road route" on a
/// planner that has no road router, and a switch offering to avoid ferries.
///
/// This is a source scan rather than a widget test on purpose. The strings were
/// scattered across sheets, prompts, progress text and accessibility labels, and
/// no reachable set of widget tests would have caught them all - the previous
/// passes had widget tests and still missed these.
///
/// It scans string literals in `lib`, so it fires on a new one the moment it is
/// written rather than when somebody happens to open that screen.
void main() {
  /// Words that must not reach a sailor. Written as whole words so `broad`,
  /// `crossroads` and `abroad` do not trip it.
  /// Keyed by a full regular expression, so each rule states its own
  /// boundaries. An earlier version wrapped every key in `\b...\b` and the
  /// phone-number exception had to break that wrapping, which then let `\brider`
  /// match the identifier `rideRelayNamespace`.
  const forbidden = <String, String>{
    r'\briding\b': 'sailing',
    r'\brider(s)?\b': 'sailor',
    r'\bmotorcycle\b': 'vessel',
    r'\bmotorbike\b': 'vessel',
    r'\bbiker\b': 'sailor',
    r'\broads?\b': 'passage, course, track, or map detail',
    r'\broad route\b': 'passage',
    r'\broad-following\b': 'a direct course',
    r'\bmotorway\b': 'nothing - a passage has none',
    r'\btoll road\b': 'nothing - a passage has none',
    r'\bbyway\b': 'nothing - a passage has none',
    // Not "your phone number", which is a telephone number and correct.
    r'\byour phone\b(?! number)': 'this device',
    // The road group's role names. #49 fixed the enum label and four call
    // sites; a fifth was still captioning the colour picker "Lead and Sweeper",
    // and "TEC" - Tail End Charlie, the rider who stays at the back - survived
    // in ten more strings after #30 was meant to have removed it. Both are here
    // now because renaming by hand has missed them three times.
    r'\blead\b(?! time)': 'Skipper',
    r'\btec\b': 'Sweeper',
    // “Web planner” is now valid: Tide and Seek ships a passage planner that
    // creates the route codes accepted by the mobile app.
    // "stop" is deliberately absent. A passage has marks and you pass them
    // rather than stop at them, so the noun is wrong - but "Stop sharing",
    // "location sharing stops" and "emergency stop" are all correct, and no
    // regex separates the noun from the verb. The noun uses were fixed by hand
    // in #68; a rule here would cry wolf on eighteen legitimate strings and get
    // switched off.
  };

  /// Files whose road words are correct, each for a stated reason.
  ///
  /// Kept as an explicit list rather than a pattern, so adding one is a decision
  /// somebody makes in a diff.
  const allowed = <String, String>{
    'lib/features/map/route_trail_style.dart':
        'basemap surface keys - the basemap really is a road basemap (#17)',
    'lib/services/map_style_repository.dart':
        'basemap style layer names, for the same reason',
    'lib/features/map/vessel_icon.dart':
        'a pinned storage and wire token; moving it orphans saved profiles',
    'lib/services/gpx_parser.dart': 'reads those same extension keys',
    'lib/features/settings/emergency_info_sheet.dart':
        'an actual telephone number',
    'lib/relay/live_presence.dart': 'an actual telephone number',
    'lib/domain/voyage_role.dart':
        'holds the legacy `lead` wire value on purpose, so a session saved '
        'before #49 still restores',
  };

  /// Only what a person can read: single-quoted Dart string literals, with
  /// comments stripped so an explanation of why a word was removed does not
  /// itself trip the scan.
  Iterable<String> userVisibleStrings(String source) {
    final withoutComments = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .where((line) => !line.trimLeft().startsWith('///'))
        // An import path is not something a sailor reads.
        .where((line) => !line.trimLeft().startsWith('import '))
        .where((line) => !line.trimLeft().startsWith('export '))
        .where((line) => !line.trimLeft().startsWith('part '))
        // A widget key is an identifier the test suite matches on, not prose.
        // Renaming those is #24's job and churns tests for no reader's benefit.
        .where((line) => !line.contains('Key('))
        .join('\n');
    return RegExp(
      r"'([^'\\\n]{4,})'",
    ).allMatches(withoutComments).map((match) => match.group(1)!);
  }

  test('no live screen speaks road', () {
    final offences = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (allowed.containsKey(file.path)) continue;

      for (final literal in userVisibleStrings(file.readAsStringSync())) {
        final lower = literal.toLowerCase();
        for (final entry in forbidden.entries) {
          if (RegExp(entry.key).hasMatch(lower)) {
            offences.add(
              '${file.path}: "$literal" — say ${entry.value} instead',
            );
          }
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'Road vocabulary reached a string a sailor can read:\n'
          '${offences.join('\n')}\n\n'
          'If the word is genuinely correct there, add the file to `allowed` '
          'above with the reason.',
    );
  });

  test('every allowed file still exists', () {
    // An exemption for a deleted file is an exemption nobody is checking, and
    // the next file to take that path inherits it silently.
    for (final path in allowed.keys) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: '$path is exempted but gone; drop the exemption',
      );
    }
  });
}
