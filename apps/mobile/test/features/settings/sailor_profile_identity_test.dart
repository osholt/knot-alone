import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/features/settings/sailor_profile_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Sailor Profile saves white, custom initials and chosen ink', (
    tester,
  ) async {
    final profile = await SailorProfileController.load();
    await profile.save(
      displayName: 'Oliver Holt',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      sailorColor: SailorColor.green,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SailorProfileSheet(
            sailorProfile: profile,
            currentVoyageActive: false,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('profile-symbol-initials')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('sailor-custom-initials')),
      'OH3',
    );
    await tester.pump();
    final whiteInk = find.byKey(const Key('profile-symbol-initials-ink-white'));
    await tester.ensureVisible(whiteInk);
    await tester.tap(whiteInk);
    final whiteBadge = find.byKey(const Key('profile-colour-white'));
    await tester.ensureVisible(whiteBadge);
    await tester.tap(whiteBadge);
    final save = find.byKey(const Key('save-sailor-profile'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(profile.sailorSymbol.storageValue, 'initials:v1:T0gz:white');
    expect(profile.sailorColor, SailorColor.white);
    expect(
      (await SailorProfileController.load()).sailorSymbol,
      profile.sailorSymbol,
    );
  });
}
