import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_diagnostics_controller.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_configuration.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('recording is off until it is asked for', () async {
    final controller = await VoyageDiagnosticsController.load();

    expect(controller.isOn, isFalse);
  });

  group(
    'an ordinary build cannot record, whatever storage says',
    () {
      // The case this exists for: a phone that ran an instrumented build with the
      // switch on, then took an ordinary build over the top. The stored `true`
      // survives the upgrade, and only the compile-time gate stands between it and
      // a store build writing a location log.
      test('a stored true does not switch recording on', () async {
        SharedPreferences.setMockInitialValues({
          VoyageDiagnosticsController.preferenceKey: true,
        });

        final controller = await VoyageDiagnosticsController.load();

        expect(controller.isOn, isFalse);
        expect(controller.isAvailable, isFalse);
      });

      test('it refuses to be switched on when asked directly', () async {
        final controller = await VoyageDiagnosticsController.load();

        await controller.setEnabled(true);

        expect(controller.isOn, isFalse);
      });
    },
    skip: VoyageDiagnosticsConfiguration.enabled
        ? 'asserts the define-off build; run without TIDE_AND_SEEK_VOYAGE_DIAGNOSTICS'
        : null,
  );

  group(
    'an instrumented build can be switched on and off',
    () {
      test('the switch persists and notifies', () async {
        final controller = await VoyageDiagnosticsController.load();
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await controller.setEnabled(true);
        expect(controller.isOn, isTrue);
        expect(notifications, 1);

        // Reloading is what a sailor does by restarting the app.
        final reloaded = await VoyageDiagnosticsController.load();
        expect(reloaded.isOn, isTrue);

        await controller.setEnabled(false);
        expect(controller.isOn, isFalse);
        expect(notifications, 2);
      });

      test('setting the value it already has notifies nobody', () async {
        final controller = await VoyageDiagnosticsController.load();
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await controller.setEnabled(false);

        expect(notifications, 0);
      });
    },
    skip: VoyageDiagnosticsConfiguration.enabled
        ? null
        : 'asserts the instrumented build; run with TIDE_AND_SEEK_VOYAGE_DIAGNOSTICS',
  );
}
