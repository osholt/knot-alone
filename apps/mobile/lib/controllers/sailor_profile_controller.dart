import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/sailor_color.dart';
import '../features/map/vessel_icon.dart';
import '../services/sailor_contact_share.dart';

/// The name a sailor appears under when they gave none.
///
/// A sailor name used to be mandatory before the app would open, and "Skip
/// tour" did not skip it (#49) - so a solo sailor could not reach a solo-first
/// app without first naming themselves for a crew they may never have.
///
/// The roster, the journal and every shared event do need *a* name, so one is
/// supplied rather than the requirement being dropped. "Skipper" because that
/// is what a single-handed sailor is, and because it is what a crew would call
/// whoever set the voyage up.
const defaultSailorName = 'Skipper';

/// Remembers how a sailor last presented themselves - name, bike, colour -
/// so the create/join voyage form starts pre-filled instead of blank every
/// time. Deliberately separate from VoyageSession, which is scoped to one
/// voyage: this is a standalone device preference, like DistanceUnitController.
class SailorProfileController extends ChangeNotifier {
  SailorProfileController._(
    this._preferences,
    this._installationId,
    this._displayName,
    this._vesselStyle,
    this._sailorSymbol,
    this._sailorColor,
    this._emergencyContactName,
    this._emergencyContactPhone,
    this._medicalNotes,
    this._shareIceWithSkipperByDefault,
    this._ownPhoneNumber,
    this._onboardingCompleted,
    this._onboardingEducationSkipped,
  );

  static const _nameKey = 'sailor_profile_display_name';
  static const _installationIdKey = 'sailor_profile_installation_id';
  static const _styleKey = 'sailor_profile_motorcycle_style';
  static const _symbolKey = 'sailor_profile_symbol';
  static const _colorKey = 'sailor_profile_colour';
  static const _emergencyContactNameKey = 'sailor_profile_ice_contact_name';
  static const _emergencyContactPhoneKey = 'sailor_profile_ice_contact_phone';
  static const _medicalNotesKey = 'sailor_profile_ice_medical_notes';
  static const _shareIceWithSkipperByDefaultKey =
      'sailor_profile_ice_share_with_skipper_default';

  /// Deliberately a separate key from [_emergencyContactPhoneKey]. One is the
  /// sailor's own number, the other is their next of kin's, and conflating them
  /// would put the wrong person on the end of an emergency call.
  static const _ownPhoneNumberKey = 'sailor_profile_own_phone_number';
  static const _onboardingCompletedKey = 'sailor_profile_onboarding_completed';
  static const _onboardingEducationSkippedKey =
      'sailor_profile_onboarding_education_skipped';

  final SharedPreferences _preferences;
  final String _installationId;
  String _displayName;
  VesselIconStyle _vesselStyle;
  SailorSymbol _sailorSymbol;
  SailorColor _sailorColor;
  String _emergencyContactName;
  String _emergencyContactPhone;
  String _medicalNotes;
  bool _shareIceWithSkipperByDefault;
  String _ownPhoneNumber;
  bool _onboardingCompleted;
  bool _onboardingEducationSkipped;
  OnboardingVoyageChoice? _pendingVoyageChoice;

  String get installationId => _installationId;
  String get displayName => _displayName;
  VesselIconStyle get vesselStyle => _vesselStyle;
  SailorSymbol get sailorSymbol => _sailorSymbol;
  SailorColor get sailorColor => _sailorColor;
  bool get onboardingCompleted => _onboardingCompleted;
  bool get needsOnboarding => !_onboardingCompleted;
  bool get onboardingEducationSkipped => _onboardingEducationSkipped;

  // In-case-of-emergency details. Kept device-local by default: not read by
  // VoyageSession/VoyageEvent, so ordinary voyage events never carry it. It only
  // ever leaves the device through an explicit share action, or the opt-in
  // auto-share-with-skipper setting below - both driven from VoyageController,
  // never automatically.
  String get emergencyContactName => _emergencyContactName;
  String get emergencyContactPhone => _emergencyContactPhone;
  String get medicalNotes => _medicalNotes;
  bool get hasEmergencyInfo =>
      _emergencyContactName.isNotEmpty ||
      _emergencyContactPhone.isNotEmpty ||
      _medicalNotes.isNotEmpty;

  /// If true, triggering an emergency-stop alert also shares this sailor's
  /// ICE info with whoever currently holds the lead role, without a further
  /// explicit step - so it still happens if the sailor can't act again.
  bool get shareIceWithSkipperByDefault => _shareIceWithSkipperByDefault;

  /// This sailor's **own** phone number (issue #188). Emphatically not
  /// [emergencyContactPhone], which is their next of kin: the person to ring
  /// *about* them rather than the person to ring.
  ///
  /// Optional throughout, and empty until the sailor types it. It is never
  /// inferred from the device (no SIM, no telephony subscription lookup) and
  /// never read from the contacts book, so an app that has been given nothing
  /// holds nothing. Like the ICE fields it is not read by VoyageSession or
  /// VoyageEvent, so no ordinary voyage event can carry it; it leaves the device
  /// only through the explicit share action in VoyageController.
  String get ownPhoneNumber => _ownPhoneNumber;
  bool get hasOwnPhoneNumber => _ownPhoneNumber.isNotEmpty;

  static Future<SailorProfileController> load() async {
    final preferences = await SharedPreferences.getInstance();
    var installationId = preferences.getString(_installationIdKey);
    if (installationId == null || installationId.isEmpty) {
      installationId = const Uuid().v7();
      await preferences.setString(_installationIdKey, installationId);
    }
    final displayName = preferences.getString(_nameKey) ?? '';
    final onboardingCompleted =
        preferences.getBool(_onboardingCompletedKey) ?? displayName.isNotEmpty;
    if (!preferences.containsKey(_onboardingCompletedKey) &&
        onboardingCompleted) {
      await preferences.setBool(_onboardingCompletedKey, true);
    }
    return SailorProfileController._(
      preferences,
      installationId,
      displayName,
      vesselIconStyleFromName(preferences.getString(_styleKey)),
      SailorSymbol.fromStorageValue(preferences.getString(_symbolKey)),
      sailorColorFromName(preferences.getString(_colorKey)),
      preferences.getString(_emergencyContactNameKey) ?? '',
      preferences.getString(_emergencyContactPhoneKey) ?? '',
      preferences.getString(_medicalNotesKey) ?? '',
      preferences.getBool(_shareIceWithSkipperByDefaultKey) ?? false,
      preferences.getString(_ownPhoneNumberKey) ?? '',
      onboardingCompleted,
      preferences.getBool(_onboardingEducationSkippedKey) ?? false,
    );
  }

  Future<void> save({
    required String displayName,
    required VesselIconStyle vesselStyle,
    SailorSymbol? sailorSymbol,
    required SailorColor sailorColor,
  }) async {
    _displayName = displayName;
    _vesselStyle = vesselStyle;
    _sailorSymbol = sailorSymbol ?? _sailorSymbol;
    _sailorColor = sailorColor;
    await Future.wait([
      _preferences.setString(_nameKey, displayName),
      _preferences.setString(_styleKey, vesselStyle.name),
      _preferences.setString(_symbolKey, _sailorSymbol.storageValue),
      _preferences.setString(_colorKey, sailorColor.name),
    ]);
    notifyListeners();
  }

  Future<void> completeOnboarding({
    required String displayName,
    required VesselIconStyle vesselStyle,
    SailorSymbol? sailorSymbol,
    required SailorColor sailorColor,
    required bool educationSkipped,

    /// What to open on arrival, or null to land on the chart and sail alone.
    ///
    /// Nullable since #49. Onboarding used to end on "Create a voyage" or "Join
    /// a voyage" with no third option, so a solo-first app made every new
    /// sailor pick a crew activity before it would let them in.
    required OnboardingVoyageChoice? voyageChoice,
  }) async {
    final normalizedName = displayName.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(displayName, 'displayName', 'is required');
    }
    _displayName = normalizedName;
    _vesselStyle = vesselStyle;
    _sailorSymbol = sailorSymbol ?? sailorSymbolDefault;
    _sailorColor = sailorColor;
    _onboardingCompleted = true;
    _onboardingEducationSkipped = educationSkipped;
    _pendingVoyageChoice = voyageChoice;
    await Future.wait([
      _preferences.setString(_nameKey, normalizedName),
      _preferences.setString(_styleKey, vesselStyle.name),
      _preferences.setString(_symbolKey, _sailorSymbol.storageValue),
      _preferences.setString(_colorKey, sailorColor.name),
      _preferences.setBool(_onboardingCompletedKey, true),
      _preferences.setBool(_onboardingEducationSkippedKey, educationSkipped),
    ]);
    notifyListeners();
  }

  Future<void> replayOnboarding() async {
    _onboardingCompleted = false;
    _pendingVoyageChoice = null;
    await _preferences.setBool(_onboardingCompletedKey, false);
    notifyListeners();
  }

  OnboardingVoyageChoice? takePendingVoyageChoice() {
    final choice = _pendingVoyageChoice;
    _pendingVoyageChoice = null;
    return choice;
  }

  Future<void> saveEmergencyInfo({
    required String emergencyContactName,
    required String emergencyContactPhone,
    required String medicalNotes,
    required bool shareWithSkipperByDefault,
  }) async {
    _emergencyContactName = emergencyContactName;
    _emergencyContactPhone = emergencyContactPhone;
    _medicalNotes = medicalNotes;
    _shareIceWithSkipperByDefault = shareWithSkipperByDefault;
    await Future.wait([
      _preferences.setString(_emergencyContactNameKey, emergencyContactName),
      _preferences.setString(_emergencyContactPhoneKey, emergencyContactPhone),
      _preferences.setString(_medicalNotesKey, medicalNotes),
      _preferences.setBool(
        _shareIceWithSkipperByDefaultKey,
        shareWithSkipperByDefault,
      ),
    ]);
    notifyListeners();
  }

  /// Saves this sailor's own number, or clears it when [ownPhoneNumber] is empty.
  ///
  /// A separate call from [saveEmergencyInfo] on purpose: the ICE payload
  /// builder takes its arguments from that method, so there is no code path in
  /// which a sailor's own number can be picked up and relayed as their next of
  /// kin's. Rejects anything that is not a plain dialable number rather than
  /// storing something that would later be handed to `tel:`.
  Future<void> saveOwnPhoneNumber(String ownPhoneNumber) async {
    final trimmed = ownPhoneNumber.trim();
    if (trimmed.isEmpty) {
      _ownPhoneNumber = '';
      await _preferences.remove(_ownPhoneNumberKey);
      notifyListeners();
      return;
    }
    final normalised = SailorContactShare.normalisePhoneNumber(trimmed);
    if (normalised == null) {
      throw ArgumentError.value(
        ownPhoneNumber,
        'ownPhoneNumber',
        'is not a phone number this app can dial',
      );
    }
    _ownPhoneNumber = normalised;
    await _preferences.setString(_ownPhoneNumberKey, normalised);
    notifyListeners();
  }
}

enum OnboardingVoyageChoice { create, join }
