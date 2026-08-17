import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #441 reported that the Start voyage control on the phone "does nothing".
///
/// ## Why this is instrumentation and not a fix
///
/// Reading `active_voyage_shell.dart` shows nothing that would swallow the tap:
/// the button is `onPressed: busy ? null : onStartVoyage`, where `busy` is
/// `voyageController.busy || _loading`. So there is nothing to fix that can be
/// pointed at, and guessing at a safety-relevant control is how #408 nearly
/// shipped an illegal manoeuvre.
///
/// What the log can settle in one voyage:
///
/// - **no `start voyage tapped` entry** — the tap never reached Dart;
/// - **tapped, then `refused before the dialog`** — the leadership or
///   already-started gate swallowed it, and the entry says which;
/// - **tapped, then `decision: dismissed`** — the dialog appeared and was
///   dismissed, which would mean the control works and the dialog is the
///   problem.
///
/// The entries are asserted structurally because starting a voyage needs a
/// session, a relay, a location stream and a map, and no test here constructs
/// `ActiveVoyageShell`.
void main() {
  final source = File(
    'lib/features/voyage/active_voyage_shell.dart',
  ).readAsStringSync();

  group('the next voyage can say what the start button did (#441)', () {
    test('the tap is recorded before any gate can swallow it', () {
      expect(source, contains('start voyage tapped on the phone'));
      // Before the early return, or a refused tap would leave no trace at all.
      expect(
        source.indexOf('start voyage tapped on the phone'),
        lessThan(source.indexOf('start voyage refused before the dialog')),
      );
    });

    test('the tap entry carries the state that decides the gate', () {
      // Without these, "it did nothing" stays unfalsifiable.
      for (final field in ['role=', 'started=', 'busy=', 'route=']) {
        expect(source, contains(field), reason: field);
      }
    });

    test('the outcome of the dialog is recorded', () {
      expect(source, contains('start voyage decision:'));
    });
  });
}
