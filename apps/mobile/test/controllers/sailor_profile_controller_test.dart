import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('emergency info defaults to empty and unset', () async {
    final profile = await SailorProfileController.load();

    expect(profile.emergencyContactName, isEmpty);
    expect(profile.emergencyContactPhone, isEmpty);
    expect(profile.medicalNotes, isEmpty);
    expect(profile.hasEmergencyInfo, isFalse);
    expect(profile.shareIceWithSkipperByDefault, isFalse);
    expect(profile.installationId, isNotEmpty);
    expect(profile.needsOnboarding, isTrue);
  });

  test('installation identity is stable across app restarts', () async {
    final first = await SailorProfileController.load();
    final second = await SailorProfileController.load();

    expect(second.installationId, first.installationId);
  });

  test(
    'emergency info survives a fresh load, as if the app restarted',
    () async {
      final profile = await SailorProfileController.load();

      await profile.saveEmergencyInfo(
        emergencyContactName: 'Jamie Sailor',
        emergencyContactPhone: '+44 7700 900123',
        medicalNotes: 'Penicillin allergy',
        shareWithSkipperByDefault: true,
      );

      final reloaded = await SailorProfileController.load();
      expect(reloaded.emergencyContactName, 'Jamie Sailor');
      expect(reloaded.emergencyContactPhone, '+44 7700 900123');
      expect(reloaded.medicalNotes, 'Penicillin allergy');
      expect(reloaded.hasEmergencyInfo, isTrue);
      expect(reloaded.shareIceWithSkipperByDefault, isTrue);
    },
  );

  test('onboarding profile and completion survive an app restart', () async {
    final profile = await SailorProfileController.load();

    await profile.completeOnboarding(
      displayName: '  Oliver  ',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      sailorSymbol: const SailorSymbol.emoji('🦊'),
      sailorColor: SailorColor.cyan,
      educationSkipped: false,
      voyageChoice: OnboardingVoyageChoice.join,
    );
    final reloaded = await SailorProfileController.load();

    expect(profile.takePendingVoyageChoice(), OnboardingVoyageChoice.join);
    expect(profile.takePendingVoyageChoice(), isNull);
    expect(reloaded.onboardingCompleted, isTrue);
    expect(reloaded.displayName, 'Oliver');
    expect(reloaded.motorcycleStyle, MotorcycleIconStyle.scrambler);
    expect(reloaded.sailorSymbol, const SailorSymbol.emoji('🦊'));
    expect(reloaded.sailorColor, SailorColor.cyan);
  });

  test(
    'custom initials, ink and the expanded palette survive a restart',
    () async {
      final profile = await SailorProfileController.load();
      const symbol = SailorSymbol.initials(
        customInitials: 'TEC',
        initialsInk: SailorInitialsInk.white,
      );

      await profile.save(
        displayName: 'Sweeper',
        motorcycleStyle: MotorcycleIconStyle.fullTourer,
        sailorSymbol: symbol,
        sailorColor: SailorColor.purple,
      );
      final reloaded = await SailorProfileController.load();

      expect(reloaded.sailorSymbol, symbol);
      expect(reloaded.sailorColor, SailorColor.purple);
    },
  );

  test('optional education can be skipped and onboarding replayed', () async {
    final profile = await SailorProfileController.load();
    await profile.completeOnboarding(
      displayName: 'Oliver',
      motorcycleStyle: MotorcycleIconStyle.roadster,
      sailorColor: SailorColor.orange,
      educationSkipped: true,
      voyageChoice: OnboardingVoyageChoice.create,
    );

    expect(profile.onboardingEducationSkipped, isTrue);
    await profile.replayOnboarding();
    final reloaded = await SailorProfileController.load();

    expect(reloaded.needsOnboarding, isTrue);
    expect(reloaded.displayName, 'Oliver');
  });

  test('onboarding requires a non-empty sailor name', () async {
    final profile = await SailorProfileController.load();

    await expectLater(
      profile.completeOnboarding(
        displayName: '   ',
        motorcycleStyle: MotorcycleIconStyle.adventureTourer,
        sailorColor: SailorColor.green,
        educationSkipped: false,
        voyageChoice: OnboardingVoyageChoice.create,
      ),
      throwsArgumentError,
    );
    expect(profile.needsOnboarding, isTrue);
  });

  test('an existing saved profile is migrated past first-run setup', () async {
    SharedPreferences.setMockInitialValues({
      'sailor_profile_display_name': 'Existing sailor',
    });

    final profile = await SailorProfileController.load();

    expect(profile.onboardingCompleted, isTrue);
  });

  group("a sailor's own number (#188)", () {
    test('is empty on a fresh install and never inferred', () async {
      final profile = await SailorProfileController.load();

      expect(profile.ownPhoneNumber, isEmpty);
      expect(profile.hasOwnPhoneNumber, isFalse);
      // The whole point of the field: an install that has been given nothing
      // holds nothing. Nothing reads the SIM, the telephony subscription or the
      // contacts book, so there is no path by which a number appears here
      // without the sailor typing it.
    });

    test('survives a restart, and is a different field from the ICE '
        'contact', () async {
      final profile = await SailorProfileController.load();

      await profile.saveOwnPhoneNumber(' +44 7700 900321 ');
      await profile.saveEmergencyInfo(
        emergencyContactName: 'Jamie Sailor',
        emergencyContactPhone: '+44 7700 900123',
        medicalNotes: '',
        shareWithSkipperByDefault: true,
      );
      final reloaded = await SailorProfileController.load();

      expect(reloaded.ownPhoneNumber, '+44 7700 900321');
      expect(reloaded.hasOwnPhoneNumber, isTrue);
      // Distinct storage: ringing one must never ring the other.
      expect(reloaded.emergencyContactPhone, '+44 7700 900123');
      expect(reloaded.ownPhoneNumber, isNot(reloaded.emergencyContactPhone));
    });

    test('saving an ICE contact never populates the sailor\'s own '
        'number', () async {
      final profile = await SailorProfileController.load();

      await profile.saveEmergencyInfo(
        emergencyContactName: 'Next of kin',
        emergencyContactPhone: '+44 7700 900999',
        medicalNotes: 'Penicillin allergy',
        shareWithSkipperByDefault: true,
      );

      expect(profile.ownPhoneNumber, isEmpty);
      expect(profile.hasOwnPhoneNumber, isFalse);
      expect((await SailorProfileController.load()).ownPhoneNumber, isEmpty);
    });

    test('an empty value clears it rather than storing a blank', () async {
      final profile = await SailorProfileController.load();
      await profile.saveOwnPhoneNumber('07700 900321');

      await profile.saveOwnPhoneNumber('   ');

      expect(profile.hasOwnPhoneNumber, isFalse);
      expect((await SailorProfileController.load()).ownPhoneNumber, isEmpty);
    });

    test('a value that is not dialable is rejected, not stored', () async {
      final profile = await SailorProfileController.load();

      // This is handed to `tel:`/`sms:`, so anything carrying a scheme, a path
      // or free text is refused rather than sanitised into something that
      // dials somewhere unintended.
      for (final rejected in [
        'tel:+447700900321',
        '+44 7700 900321?body=hi',
        'call me',
        '123',
        'sms:07700900321',
      ]) {
        await expectLater(
          profile.saveOwnPhoneNumber(rejected),
          throwsArgumentError,
          reason: rejected,
        );
      }
      expect(profile.hasOwnPhoneNumber, isFalse);
    });
  });
}
