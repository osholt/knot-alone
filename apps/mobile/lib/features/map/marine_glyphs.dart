/// The app's own marine glyph set.
///
/// ## Why these are not Material icons
///
/// The inherited app drew `Icons.two_wheeler` in eight places, including the
/// primary navigation bar. Swapping each for the nearest Material marine glyph
/// got the motorbikes out, but Material has one sailing boat and no way to say
/// *which* boat — and this app's whole subject is roles within a group: the
/// skipper at the front, the sweeper at the back, the fleet between them. Those
/// three need to be distinguishable at a glance, on a moving boat, at 18px.
///
/// So the set is drawn rather than borrowed. The geometry was designed by
/// ChatGPT against a written brief and then iterated against renders: the first
/// attempt put three yachts in [fleet] and a pennant on [skipper], which turned
/// to unreadable blobs below about 40px. The rules that fixed it are worth
/// keeping if the set is ever extended:
///
/// - at most two ideas per glyph
/// - no enclosed shape smaller than about 4 units in the 24 grid
/// - one large gesture beats detail
///
/// [skipper] and [sweeper] are deliberately mirror images of each other — a bar
/// ahead of the bow versus a bar astern — because a pair that differs by
/// *reflection* stays distinguishable at sizes where a pair that differs by
/// *ornament* does not.
///
/// ## Why the path data is restricted to M, L, C and Z
///
/// Flutter has no SVG path parser in the SDK and this project has no SVG
/// dependency. Rather than add one for six icons, the glyphs were commissioned
/// with absolute M/L/C/Z commands only, which [parseGlyphPath] converts to a
/// [Path] in about twenty lines. Arcs, quadratics and relative commands are
/// rejected loudly rather than silently mis-drawn.
library;

import 'package:flutter/widgets.dart';

/// The 24x24 grid the glyphs are authored in, matching Material's icon grid.
const _glyphGrid = 24.0;

/// Stroke weight in grid units. Material Symbols Outlined at weight 400 sits
/// near this, which is what lets these sit beside the Material icons still in
/// use without looking lighter or heavier.
const _glyphStrokeWidth = 1.8;

enum MarineGlyph {
  /// A yacht under way. The generic "a sailor" mark.
  sailor,

  /// The yacht leading the group: a bar ahead of the bow.
  skipper,

  /// The yacht at the back that sweeps up stragglers: a bar astern. The mirror
  /// of [skipper], so the two never read as the same glyph.
  sweeper,

  /// Two yachts sailing together.
  fleet,

  /// A finished passage: a track with a tick.
  ///
  /// The tick is the one feature in this set that does not survive 18px. It is
  /// only used at avatar size, so that is acceptable — but do not reuse this one
  /// small.
  passageComplete,

  /// A person beside a sail, for a profile row.
  sailorProfile;

  String get pathData => switch (this) {
    MarineGlyph.sailor =>
      'M12 4 L12 17 M12 5 L7 13 L12 13 Z M13 6 L18 13 L13 13 Z '
          'M5 17 L19 17 L16.5 20 L8 20 L5 17 Z',
    MarineGlyph.skipper =>
      'M10 4 L10 16 M10 5 L6 13 L10 13 Z M11 6 L16 13 L11 13 Z '
          'M5 16 L17 16 L15 19 L7 19 L5 16 Z M19 12 L23 12',
    MarineGlyph.sweeper =>
      'M14 4 L14 16 M14 5 L18 13 L14 13 Z M13 6 L8 13 L13 13 Z '
          'M7 16 L19 16 L17 19 L9 19 L7 16 Z M1 12 L5 12',
    MarineGlyph.fleet =>
      'M8 5 L8 15 M8 6 L13 14 L8 14 Z M4 15 L14 15 L12 18 L6 18 Z '
          'M17 8 L17 16 M17 9 L21 15 L17 15 Z M14 16 L22 16 L20 19 L16 19 Z',
    MarineGlyph.passageComplete =>
      'M3 17 C6 17 6 8 11 8 C14 8 14 13 17 13 M15 17 L18 20 L23 14',
    MarineGlyph.sailorProfile =>
      'M7 4 C4.8 4 3 5.8 3 8 C3 10.2 4.8 12 7 12 C9.2 12 11 10.2 11 8 '
          'C11 5.8 9.2 4 7 4 Z '
          'M2 20 C2.5 15.5 4.2 14 7 14 C9.8 14 11.5 15.5 12 20 '
          'M16 8 L16 19 M16 9 L22 17 L16 17 Z',
  };

  /// For semantics and for the vessel-style picker.
  String get label => switch (this) {
    MarineGlyph.sailor => 'Sailor',
    MarineGlyph.skipper => 'Skipper',
    MarineGlyph.sweeper => 'Sweeper',
    MarineGlyph.fleet => 'Fleet',
    MarineGlyph.passageComplete => 'Completed passage',
    MarineGlyph.sailorProfile => 'Sailor profile',
  };

  Path get path => parseGlyphPath(pathData);
}

/// Thrown when glyph data uses something [parseGlyphPath] does not support.
///
/// Loud rather than lenient on purpose: a silently skipped command draws a
/// subtly wrong boat, and a subtly wrong boat is exactly the kind of defect that
/// ships.
class GlyphPathFormatException implements Exception {
  const GlyphPathFormatException(this.message);

  final String message;

  @override
  String toString() => 'GlyphPathFormatException: $message';
}

/// Converts absolute M/L/C/Z SVG path data into a [Path] in the 24x24 grid.
///
/// Supports exactly those four commands, absolute only. Anything else — arcs,
/// quadratics, relative commands, implicit repeats of a command letter — throws.
Path parseGlyphPath(String data) {
  final path = Path();
  // One pass: split into command letters and the numbers following each.
  final tokens = RegExp(
    r'([MLCZmlczAaHhVvQqSsTt])|(-?\d*\.?\d+)',
  ).allMatches(data);

  String? command;
  final numbers = <double>[];
  var started = false;

  void flush() {
    if (command == null) return;
    switch (command) {
      case 'M':
        if (numbers.length != 2) {
          throw GlyphPathFormatException('M needs 2 numbers, got $numbers');
        }
        path.moveTo(numbers[0], numbers[1]);
        started = true;
      case 'L':
        if (numbers.length != 2) {
          throw GlyphPathFormatException('L needs 2 numbers, got $numbers');
        }
        if (!started) {
          throw const GlyphPathFormatException('L before any M');
        }
        path.lineTo(numbers[0], numbers[1]);
      case 'C':
        if (numbers.length != 6) {
          throw GlyphPathFormatException('C needs 6 numbers, got $numbers');
        }
        if (!started) {
          throw const GlyphPathFormatException('C before any M');
        }
        path.cubicTo(
          numbers[0],
          numbers[1],
          numbers[2],
          numbers[3],
          numbers[4],
          numbers[5],
        );
      case 'Z':
        if (numbers.isNotEmpty) {
          throw GlyphPathFormatException('Z takes no numbers, got $numbers');
        }
        path.close();
      case final other:
        throw GlyphPathFormatException(
          'unsupported command "$other" - glyph data must use absolute '
          'M, L, C and Z only',
        );
    }
    numbers.clear();
  }

  for (final token in tokens) {
    final letter = token.group(1);
    if (letter != null) {
      flush();
      command = letter;
    } else {
      if (command == null) {
        throw const GlyphPathFormatException('numbers before any command');
      }
      numbers.add(double.parse(token.group(2)!));
    }
  }
  flush();

  if (!started) throw const GlyphPathFormatException('no drawable commands');
  return path;
}

/// Draws a [MarineGlyph] as stroked line art, scaled to the paint box.
class MarineGlyphPainter extends CustomPainter {
  MarineGlyphPainter({required this.glyph, required this.color})
    : _path = glyph.path;

  final MarineGlyph glyph;
  final Color color;
  final Path _path;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _glyphGrid;
    if (scale <= 0) return;
    canvas.save();
    // Centred so a non-square box does not stretch the glyph.
    canvas.translate(
      (size.width - _glyphGrid * scale) / 2,
      (size.height - _glyphGrid * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawPath(
      _path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _glyphStrokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(MarineGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

/// A [MarineGlyph] as a drop-in replacement for [Icon].
///
/// Takes size and colour from the ambient [IconTheme] when not given, so it
/// behaves like an `Icon` inside buttons, list tiles and navigation bars — which
/// is what lets it sit in the places the motorbike glyphs occupied without each
/// call site restating the theme.
class MarineGlyphIcon extends StatelessWidget {
  const MarineGlyphIcon(this.glyph, {super.key, this.size, this.color});

  final MarineGlyph glyph;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24.0;
    final resolvedColor =
        color ??
        iconTheme.color ??
        DefaultTextStyle.of(context).style.color ??
        const Color(0xFFFFFFFF);
    return Semantics(
      label: glyph.label,
      child: SizedBox(
        width: resolvedSize,
        height: resolvedSize,
        child: CustomPaint(
          painter: MarineGlyphPainter(glyph: glyph, color: resolvedColor),
          // Reported so the whole set can be found on screen in a widget test.
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
