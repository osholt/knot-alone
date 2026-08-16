import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/distance_unit.dart';

class DistanceUnitController extends ChangeNotifier
    implements ValueListenable<DistanceUnit> {
  DistanceUnitController.forLocale(this.locale)
    : _preferences = null,
      _override = null;

  DistanceUnitController._(this._preferences, this.locale, this._override);

  static const preferenceKey = 'distance_unit_override';

  final SharedPreferences? _preferences;
  final Locale locale;
  DistanceUnit? _override;

  static Future<DistanceUnitController> load({required Locale locale}) async {
    final preferences = await SharedPreferences.getInstance();
    final stored = preferences.getString(preferenceKey);
    final override = DistanceUnit.values
        .where((unit) => unit.name == stored)
        .firstOrNull;
    return DistanceUnitController._(preferences, locale, override);
  }

  static DistanceUnit defaultForLocale(Locale locale) {
    final country = locale.countryCode?.toUpperCase();
    return country == 'GB' || country == 'UK' || country == 'US'
        ? DistanceUnit.miles
        : DistanceUnit.kilometres;
  }

  DistanceUnit get localeDefault => defaultForLocale(locale);

  bool get followsLocale => _override == null;

  @override
  DistanceUnit get value => _override ?? localeDefault;

  Future<void> setUnit(DistanceUnit unit) async {
    if (_override == unit) return;
    _override = unit;
    await _preferences?.setString(preferenceKey, unit.name);
    notifyListeners();
  }

  Future<void> useLocaleDefault() async {
    if (_override == null) return;
    _override = null;
    await _preferences?.remove(preferenceKey);
    notifyListeners();
  }
}
