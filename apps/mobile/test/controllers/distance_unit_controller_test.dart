import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults UK and US locales to miles and other locales to km', () {
    expect(
      DistanceUnitController.defaultForLocale(const Locale('en', 'GB')),
      DistanceUnit.miles,
    );
    expect(
      DistanceUnitController.defaultForLocale(const Locale('en', 'US')),
      DistanceUnit.miles,
    );
    expect(
      DistanceUnitController.defaultForLocale(const Locale('fr', 'FR')),
      DistanceUnit.kilometres,
    );
  });

  test('persists an override and can return to the locale default', () async {
    final controller = await DistanceUnitController.load(
      locale: const Locale('en', 'GB'),
    );
    addTearDown(controller.dispose);

    expect(controller.value, DistanceUnit.miles);
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
    expect(reloaded.value, DistanceUnit.miles);
    expect(reloaded.followsLocale, isTrue);
  });
}
