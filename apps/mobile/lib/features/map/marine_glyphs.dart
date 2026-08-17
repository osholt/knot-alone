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
/// ## Why these are images rather than drawn paths
///
/// The first attempt at this set asked ChatGPT for SVG path data and converted
/// it to [Path] code. That was the wrong thing to ask for: hand-written path
/// coordinates are one of the weakest things a language model produces, and the
/// result was thin, mean line art that did not match the app icon at all.
///
/// Asking it to *draw* instead — as an image, in the app icon's own flat style —
/// produced solid filled silhouettes of real boats, in the same visual language,
/// good enough to keep. It even reused the app icon's double-chevron motif for
/// [sweeper] without being asked.
///
/// So the glyphs ship as PNG assets: 512px, pure white on transparent, tinted at
/// draw time through [BlendMode.srcIn] so they still follow the ambient
/// [IconTheme] exactly as an icon font would. White-on-transparent is what makes
/// that possible — the alpha channel is the artwork and the colour comes from
/// the theme, so one asset serves light chrome, dark chrome and every accent.
///
/// The trade against vector glyphs is real and accepted: these do not scale
/// indefinitely, and they are ~20KB each rather than a path string. At the sizes
/// the UI actually uses — 18px in a status chip up to about 56px in an avatar —
/// a 512px master downsamples with room to spare.
///
/// [skipper] and [sweeper] read as opposites: a masthead pennant versus chevrons
/// astern. That distinction was checked by rendering the set at 64, 32, 24 and
/// 18px on both light and dark grounds, which is also how the first attempt was
/// found wanting.
library;

import 'package:flutter/widgets.dart';

enum MarineGlyph {
  /// A yacht under way. The generic "a sailor" mark.
  sailor,

  /// The yacht leading the group, marked by a masthead pennant.
  skipper,

  /// The yacht at the back that sweeps up stragglers, marked by chevrons
  /// astern. The opposite of [skipper] rather than a variant of it.
  sweeper,

  /// Two yachts sailing together.
  fleet,

  /// A finished passage: a track ending in a tick.
  passageComplete,

  /// A person beside a sail, for a profile row.
  sailorProfile;

  /// Asset path. The file name is the snake_case form of the enum name, and is
  /// pinned here rather than derived so renaming the enum cannot silently break
  /// the lookup.
  String get assetPath => switch (this) {
    MarineGlyph.sailor => 'assets/glyphs/sailor.png',
    MarineGlyph.skipper => 'assets/glyphs/skipper.png',
    MarineGlyph.sweeper => 'assets/glyphs/sweeper.png',
    MarineGlyph.fleet => 'assets/glyphs/fleet.png',
    MarineGlyph.passageComplete => 'assets/glyphs/passage_complete.png',
    MarineGlyph.sailorProfile => 'assets/glyphs/sailor_profile.png',
  };

  /// Announced by screen readers, so every glyph needs one.
  String get label => switch (this) {
    MarineGlyph.sailor => 'Sailor',
    MarineGlyph.skipper => 'Skipper',
    MarineGlyph.sweeper => 'Sweeper',
    MarineGlyph.fleet => 'Fleet',
    MarineGlyph.passageComplete => 'Completed passage',
    MarineGlyph.sailorProfile => 'Sailor profile',
  };
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
      image: true,
      // Sized by the box rather than by the image, so layout is settled before
      // the asset resolves and a list row cannot jump as glyphs load.
      child: SizedBox(
        width: resolvedSize,
        height: resolvedSize,
        child: Image.asset(
          glyph.assetPath,
          width: resolvedSize,
          height: resolvedSize,
          // The artwork is white; the alpha channel carries the shape. srcIn
          // replaces the white with the theme colour and keeps the alpha.
          color: resolvedColor,
          colorBlendMode: BlendMode.srcIn,
          // A 512px master down to 18-56px needs proper downsampling, or the
          // rigging turns to sparkle.
          filterQuality: FilterQuality.medium,
          // The glyph is decoration next to a label everywhere it is used, and
          // Semantics above already names it.
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}
