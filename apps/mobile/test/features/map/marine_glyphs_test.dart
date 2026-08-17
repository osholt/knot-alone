import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/marine_glyphs.dart';

/// #30. The glyphs ship as white-on-transparent PNG masters, tinted at draw time
/// so they follow the ambient IconTheme like an icon font does. These tests
/// guard the two things that silently break that arrangement: an asset that is
/// not declared in pubspec (which fails only at runtime, on the device), and a
/// master that is not actually a tintable mask.
void main() {
  group('the assets', () {
    test('every glyph has a distinct declared asset', () {
      final paths = MarineGlyph.values.map((g) => g.assetPath).toList();
      expect(
        paths.toSet().length,
        paths.length,
        reason: 'paths must be unique',
      );
      for (final path in paths) {
        expect(path, startsWith('assets/glyphs/'));
        expect(path, endsWith('.png'));
      }
    });

    testWidgets('every declared asset is actually bundled', (tester) async {
      // The failure this catches: adding a glyph and forgetting the pubspec
      // entry. Analysis passes, tests that only pump widgets pass, and the icon
      // is missing on the device.
      for (final glyph in MarineGlyph.values) {
        final data = await rootBundle.load(glyph.assetPath);
        expect(
          data.lengthInBytes,
          greaterThan(1000),
          reason: '${glyph.assetPath} looks empty',
        );
      }
    });

    testWidgets('every master is a PNG with an alpha channel', (tester) async {
      // Checked structurally rather than by scanning pixels: decoding six 512px
      // images and walking 1.5M pixels through toByteData hangs the test VM for
      // minutes. The stronger property - that every master is pure white with
      // real transparency, so BlendMode.srcIn can tint it - was verified against
      // the committed files when they were generated:
      //
      //   fleet             opaque= 70399  transparent=162490  colouredInk=0
      //   passage_complete  opaque= 23871  transparent=225844  colouredInk=0
      //   sailor            opaque= 58484  transparent=183001  colouredInk=0
      //   sailor_profile    opaque= 76396  transparent=164485  colouredInk=0
      //   skipper           opaque= 47290  transparent=196199  colouredInk=0
      //   sweeper           opaque= 57863  transparent=181477  colouredInk=0
      //
      // Re-run that check if a master is ever redrawn; a coloured master would
      // still tint, but it would no longer match a themed icon beside it.
      for (final glyph in MarineGlyph.values) {
        final data = await rootBundle.load(glyph.assetPath);
        final bytes = data.buffer.asUint8List();
        expect(bytes.sublist(0, 8), [
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ], reason: '${glyph.assetPath} is not a PNG');
        // IHDR colour type byte: 6 is RGBA, which is what carries the mask.
        expect(bytes[25], 6, reason: '${glyph.assetPath} has no alpha channel');
      }
    });
  });

  group('MarineGlyphIcon', () {
    testWidgets('takes its size from the ambient icon theme, like Icon does', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: IconTheme(
              data: IconThemeData(size: 42, color: Color(0xFF00FF00)),
              child: MarineGlyphIcon(MarineGlyph.sailor),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(MarineGlyphIcon)), const Size(42, 42));
    });

    testWidgets('an explicit size wins over the theme', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: IconTheme(
              data: IconThemeData(size: 42),
              child: MarineGlyphIcon(MarineGlyph.sailor, size: 18),
            ),
          ),
        ),
      );

      expect(tester.getSize(find.byType(MarineGlyphIcon)), const Size(18, 18));
    });

    testWidgets('is laid out before the asset resolves, so rows cannot jump', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: MarineGlyphIcon(MarineGlyph.fleet, size: 32)),
        ),
      );
      // One pump only - deliberately not pumpAndSettle, so the image has had no
      // chance to decode.
      expect(tester.getSize(find.byType(MarineGlyphIcon)), const Size(32, 32));
    });

    testWidgets('tints through the theme rather than painting white', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: IconTheme(
              data: IconThemeData(color: Color(0xFF6ED89A)),
              child: MarineGlyphIcon(MarineGlyph.sweeper),
            ),
          ),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, const Color(0xFF6ED89A));
      expect(image.colorBlendMode, BlendMode.srcIn);
    });

    testWidgets('an explicit colour wins over the theme', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: IconTheme(
              data: IconThemeData(color: Color(0xFF6ED89A)),
              child: MarineGlyphIcon(
                MarineGlyph.sweeper,
                color: Color(0xFFFF4FA3),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<Image>(find.byType(Image)).color,
        const Color(0xFFFF4FA3),
      );
    });

    testWidgets('is announced by name, once', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: MarineGlyphIcon(MarineGlyph.sweeper)),
      );
      expect(find.bySemanticsLabel('Sweeper'), findsOneWidget);
    });

    testWidgets('renders every glyph without throwing', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Wrap(
            children: [
              for (final glyph in MarineGlyph.values) MarineGlyphIcon(glyph),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(MarineGlyphIcon),
        findsNWidgets(MarineGlyph.values.length),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
