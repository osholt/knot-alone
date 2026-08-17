import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/voyage_diagnostics_log_store.dart';
import '../services/voyage_diagnostics_configuration.dart';

/// Whether this voyage is being recorded for diagnostics (#419).
///
/// The second of the two gates. [VoyageDiagnosticsConfiguration.enabled] is the
/// first and decides whether the code is in the binary at all; this decides
/// whether it runs, and defaults to **off**.
///
/// ## It refuses to be on in an ordinary build
///
/// [isOn] reads `false` whenever the define is absent, whatever storage says. A
/// phone that carried an instrumented build, was switched on, and then took an
/// ordinary build over the top must not quietly keep recording — the stored
/// `true` is still there, and only this check stands between it and a store build
/// writing a location log. `TestControlController` guards its own switch the same
/// way and for the same reason.
class VoyageDiagnosticsController extends ChangeNotifier
    implements ValueListenable<bool> {
  VoyageDiagnosticsController._(this._preferences, this.logStore) {
    _switchedOn = _preferences?.getBool(preferenceKey) ?? false;
  }

  static const preferenceKey = 'voyage_diagnostics_recording_enabled';

  final SharedPreferences? _preferences;
  bool _switchedOn = false;

  /// Where recorded logs are kept between voyages (#456).
  ///
  /// Hung off the controller rather than plumbed separately because this is
  /// already carried to every surface that offers the switch — and the fault
  /// being fixed was precisely that one of several doors to the same room was
  /// left unwired (#439, and again here). A new parameter threaded through the
  /// same widgets would be a third chance to make that mistake.
  ///
  /// Null in an ordinary build, where nothing may be recorded and so nothing may
  /// be stored.
  final VoyageDiagnosticsLogStore? logStore;

  static Future<VoyageDiagnosticsController> load() async {
    SharedPreferences? preferences;
    try {
      preferences = await SharedPreferences.getInstance();
    } catch (_) {
      // A sailor whose preferences will not open still gets a voyage; they just do
      // not get recording, which is the safe direction to fail in.
      preferences = null;
    }
    VoyageDiagnosticsLogStore? store;
    if (VoyageDiagnosticsConfiguration.enabled) {
      try {
        store = await FileVoyageDiagnosticsLogStore.openDefault();
      } catch (_) {
        // Recording still works and can still be shared from the voyage itself;
        // only the keeping-it-afterwards part is lost.
        store = null;
      }
    }
    return VoyageDiagnosticsController._(preferences, store);
  }

  /// In-memory only, for tests and for a build with no storage.
  factory VoyageDiagnosticsController.inMemory({
    bool switchedOn = false,
    VoyageDiagnosticsLogStore? logStore,
  }) {
    final controller = VoyageDiagnosticsController._(null, logStore);
    controller._switchedOn = switchedOn;
    return controller;
  }

  /// Whether anything should be recorded right now.
  ///
  /// Both gates, in one place, so a caller cannot consult only the one it
  /// remembers.
  bool get isOn => VoyageDiagnosticsConfiguration.enabled && _switchedOn;

  /// Whether the switch itself can be offered at all.
  bool get isAvailable => VoyageDiagnosticsConfiguration.enabled;

  @override
  bool get value => isOn;

  Future<void> setEnabled(bool enabled) async {
    if (!VoyageDiagnosticsConfiguration.enabled) return;
    if (_switchedOn == enabled) return;
    _switchedOn = enabled;
    await _preferences?.setBool(preferenceKey, enabled);
    notifyListeners();
  }
}
