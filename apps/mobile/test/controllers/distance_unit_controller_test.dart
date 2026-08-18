import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/distance_unit_controller.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // #34. The road build defaulted GB and US to miles and everywhere else to
  // kilometres, which is how shore distances work. At sea there is one unit and
  // it does not vary by country.
  test('defaults every locale to nautical miles', () {
    for (final locale in const [
      Locale('en', 'GB'),
      Locale('en', 'US'),
      Locale('fr', 'FR'),
      Locale('de', 'DE'),
    ]) {
      expect(
        DistanceUnitController.defaultForLocale(locale),
        DistanceUnit.nauticalMiles,
        reason: '$locale',
      );
    }
  });

  test('persists an override and can return to the locale default', () async {
    final controller = await DistanceUnitController.load(
      locale: const Locale('en', 'GB'),
    );
    addTearDown(controller.dispose);

    expect(controller.value, DistanceUnit.nauticalMiles);
    expect(controller.followsLocale, isTrue);

    await controller.setUnit(DistanceUnit.kilometres);
    expect(controller.value, DistanceUnit.kilometres);
    expect(controller.followsLocale, isFalse);

    final reloaded = await DistanceUnitController.load(
      locale: const Locale('en', 'GB'),
    );
    addTearDown(reloaded.dispose);
    expect(reloaded.value, DistanceUnit.kilometres);

    await reloaded.useLocaleDefault();
    expect(reloaded.value, DistanceUnit.nauticalMiles);
    expect(reloaded.followsLocale, isTrue);
  });
}
