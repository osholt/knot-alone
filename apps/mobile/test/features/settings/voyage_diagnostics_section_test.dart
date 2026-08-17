import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_diagnostics_controller.dart';
import 'package:tide_and_seek/features/settings/voyage_diagnostics_section.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_configuration.dart';

void main() {
  Future<void> pumpSection(
    WidgetTester tester,
    VoyageDiagnosticsController controller,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: VoyageDiagnosticsSection(controller: controller)),
    ),
  );

  group(
    'an ordinary build',
    () {
      testWidgets('an ordinary build offers no switch at all', (tester) async {
        // Not merely disabled: the recorder is not in the binary, so a control for
        // it would be a control that cannot work. TestControlSection renders nothing
        // in the same situation for the same reason.
        await pumpSection(tester, VoyageDiagnosticsController.inMemory());

        expect(
          find.byKey(const Key('voyage-diagnostics-toggle')),
          findsNothing,
        );
        expect(find.byType(SwitchListTile), findsNothing);
      });
    },
    skip: VoyageDiagnosticsConfiguration.enabled
        ? 'asserts the define-off build; run without TIDE_AND_SEEK_VOYAGE_DIAGNOSTICS'
        : null,
  );

  group(
    'an instrumented build',
    () {
      testWidgets('an instrumented build says in plain words what it records', (
        tester,
      ) async {
        await pumpSection(tester, VoyageDiagnosticsController.inMemory());

        // #306, and the reasoning docs/test-control-api.md gives for why its row
        // says what it does: a sailor who finds this on should not have to infer
        // "records where I went" from the word "diagnostics".
        expect(
          find.byKey(const Key('voyage-diagnostics-toggle')),
          findsOneWidget,
        );
        expect(find.textContaining('own route'), findsOneWidget);
        expect(
          find.textContaining('No other sailor’s position is recorded'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Nothing is sent anywhere until you choose'),
          findsOneWidget,
        );
      });

      testWidgets('the switch turns recording on', (tester) async {
        final controller = VoyageDiagnosticsController.inMemory();
        await pumpSection(tester, controller);

        await tester.tap(find.byKey(const Key('voyage-diagnostics-toggle')));
        await tester.pumpAndSettle();

        expect(controller.isOn, isTrue);
      });
    },
    skip: VoyageDiagnosticsConfiguration.enabled
        ? null
        : 'asserts the instrumented build; run with TIDE_AND_SEEK_VOYAGE_DIAGNOSTICS',
  );
}
