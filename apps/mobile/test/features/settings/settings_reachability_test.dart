import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_diagnostics_controller.dart';
import 'package:tide_and_seek/features/settings/voyage_diagnostics_section.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_configuration.dart';

/// The Settings sheet is opened from two places — the home screen and the voyage
/// menu — and they pass their arguments separately.
///
/// #419's recorder was wired into the voyage shell's call site and not the home
/// screen's, so a tester who had not started a voyage found no switch at all. The
/// build was correct; one of the two doors to the same room was not.
///
/// This asserts the sheet renders the section when it is given a controller, so
/// the remaining risk is only "was it passed" — which is what the call sites
/// below are read for.
void main() {
  testWidgets('the sheet shows the recorder when it is given one', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoyageDiagnosticsSection(
            controller: VoyageDiagnosticsController.inMemory(),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('voyage-diagnostics-toggle')),
      VoyageDiagnosticsConfiguration.enabled ? findsOneWidget : findsNothing,
    );
  });

  test('both Settings entry points pass the recorder', () {
    // Read as source rather than driven through the widget tree: opening the
    // sheet from the home screen needs a whole app, and what actually broke was
    // an argument list, which is exactly what this reads.
    for (final path in [
      'lib/features/home/home_screen.dart',
      'lib/features/voyage/active_voyage_shell.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final opensSettings = source.contains('UnitSettingsSheet.show');
      if (!opensSettings) continue;
      expect(
        source,
        contains('voyageDiagnostics:'),
        reason: '$path opens Settings and must pass the recorder',
      );
    }
  });
}
