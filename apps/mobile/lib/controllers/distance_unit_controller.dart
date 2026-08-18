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

  /// Nautical miles, whatever the locale.
  ///
  /// The road build picked miles for GB and US and kilometres elsewhere, which is
  /// how shore distances work. At sea there is one unit and it is the same in
  /// every country: a nautical mile is a minute of latitude, which is why a
  /// chart's latitude scale is a distance scale (#34).
  ///
  /// [locale] is retained because a sailor may still prefer a shore unit, and the
  /// override that expresses that preference goes through the same seam.
  static DistanceUnit defaultForLocale(Locale locale) =>
      DistanceUnit.nauticalMiles;

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
