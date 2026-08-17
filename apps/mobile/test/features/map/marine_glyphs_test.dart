import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/marine_glyphs.dart';

/// #30. The parser exists because the glyph data is authored as SVG and Flutter
/// has no SVG path parser in the SDK. It supports absolute M, L, C and Z only,
/// and the tests below pin that it *rejects* everything else rather than
/// silently skipping it — a skipped command draws a subtly wrong boat, which is
/// the kind of defect that ships.
void main() {
  group('the glyph set', () {
    test('every glyph parses', () {
      for (final glyph in MarineGlyph.values) {
        expect(
          () => glyph.path,
          returnsNormally,
          reason: '${glyph.name} should parse',
        );
      }
    });

    test('every glyph draws inside its 24x24 grid', () {
      for (final glyph in MarineGlyph.values) {
        final bounds = glyph.path.getBounds();
        // A stroke of 1.8 straddles the path by 0.9 either side, so geometry is
        // allowed to reach 1 unit outside and still ink inside the box.
        expect(bounds.left, greaterThanOrEqualTo(-1), reason: glyph.name);
        expect(bounds.top, greaterThanOrEqualTo(-1), reason: glyph.name);
        expect(bounds.right, lessThanOrEqualTo(25), reason: glyph.name);
        expect(bounds.bottom, lessThanOrEqualTo(25), reason: glyph.name);
      }
    });

    test('every glyph is big enough to read, not a speck in the corner', () {
      for (final glyph in MarineGlyph.values) {
        final bounds = glyph.path.getBounds();
        expect(bounds.width, greaterThan(10), reason: glyph.name);
        expect(bounds.height, greaterThan(10), reason: glyph.name);
      }
    });

    test('every glyph has a label, since each one is announced', () {
      for (final glyph in MarineGlyph.values) {
        expect(glyph.label.trim(), isNotEmpty, reason: glyph.name);
      }
    });

    // The pair that has to stay distinguishable on a moving boat. They differ by
    // reflection rather than by ornament, so the marker bar sits on opposite
    // sides of the grid.
    test('skipper and sweeper are mirror images, not variants', () {
      final skipper = MarineGlyph.skipper.path.getBounds();
      final sweeper = MarineGlyph.sweeper.path.getBounds();

      expect(MarineGlyph.skipper.pathData, isNot(MarineGlyph.sweeper.pathData));
      // The skipper's mark reaches the right edge; the sweeper's the left.
      expect(skipper.right, greaterThan(20));
      expect(sweeper.left, lessThan(4));
      expect(skipper.center.dx, greaterThan(sweeper.center.dx));
    });
  });

  group('the path parser', () {
    test('reads a move, a line and a close', () {
      final path = parseGlyphPath('M2 2 L20 2 L20 20 Z');
      final bounds = path.getBounds();
      expect(bounds.left, 2);
      expect(bounds.top, 2);
      expect(bounds.right, 20);
      expect(bounds.bottom, 20);
    });

    test('reads a cubic', () {
      final path = parseGlyphPath('M2 12 C2 2 22 2 22 12');
      expect(path.getBounds().width, greaterThan(15));
    });

    test('reads decimals and multiple subpaths', () {
      final path = parseGlyphPath('M1.5 1.5 L4.5 1.5 M10 10 L22.5 22.5');
      final bounds = path.getBounds();
      expect(bounds.left, 1.5);
      expect(bounds.bottom, 22.5);
    });

    test('rejects relative commands rather than treating them as absolute', () {
      // The failure this prevents: `l` silently read as `L` puts the point in
      // completely the wrong place.
      expect(
        () => parseGlyphPath('M2 2 l10 10'),
        throwsA(isA<GlyphPathFormatException>()),
      );
    });

    test('rejects arcs and quadratics', () {
      for (final data in [
        'M2 2 A5 5 0 0 1 10 10',
        'M2 2 Q5 5 10 10',
        'M2 2 S5 5 10 10',
        'M2 2 H10',
        'M2 2 V10',
      ]) {
        expect(
          () => parseGlyphPath(data),
          throwsA(isA<GlyphPathFormatException>()),
          reason: data,
        );
      }
    });

    test('rejects the wrong number of coordinates', () {
      expect(
        () => parseGlyphPath('M2'),
        throwsA(isA<GlyphPathFormatException>()),
      );
      expect(
        () => parseGlyphPath('M2 2 L5'),
        throwsA(isA<GlyphPathFormatException>()),
      );
      expect(
        () => parseGlyphPath('M2 2 C1 1 2 2'),
        throwsA(isA<GlyphPathFormatException>()),
      );
    });

    test('rejects drawing before any move', () {
      expect(
        () => parseGlyphPath('L5 5'),
        throwsA(isA<GlyphPathFormatException>()),
      );
      expect(
        () => parseGlyphPath('5 5'),
        throwsA(isA<GlyphPathFormatException>()),
      );
    });

    test('rejects empty data instead of returning a blank icon', () {
      expect(
        () => parseGlyphPath(''),
        throwsA(isA<GlyphPathFormatException>()),
      );
      expect(
        () => parseGlyphPath('Z'),
        throwsA(isA<GlyphPathFormatException>()),
      );
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

    testWidgets('is announced by name', (tester) async {
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
      expect(
        find.byType(MarineGlyphIcon),
        findsNWidgets(MarineGlyph.values.length),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
