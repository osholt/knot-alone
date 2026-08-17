import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'route_trail_style.dart';
import 'vessel_icon_painter.dart';

// Re-exported so the 40-odd files that import this one keep resolving
// VesselIconStyle without each needing the painter's path.
export 'vessel_icon_painter.dart' show VesselIconStyle, VesselIconPainter;

/// Sailor-selectable bike silhouettes, generated as flat single-colour art
/// (drawn by VesselIconPainter) so they can be tinted per role exactly like
/// the Icon widgets they replace.
/// The style a profile starts on: the most common cruising rig.
const vesselIconStyleDefault = VesselIconStyle.sloop;

/// Decodes a stored style name, falling back to the default.
///
/// The fallback carries the migration: every stored value is a motorcycle style
/// name from the app this was derived from, none of which matches a vessel, so
/// they all resolve to the default rather than throwing. The SharedPreferences
/// key deliberately keeps its old name - it is opaque, and renaming it would
/// orphan the entry for no gain.
VesselIconStyle vesselIconStyleFromName(String? name) =>
    VesselIconStyle.values.firstWhere(
      (style) => style.name == name,
      orElse: () => vesselIconStyleDefault,
    );

/// Style names shipped by the motorcycle app this was derived from. Retained
/// only for decoding peers and stored profiles written before the rename.
const _legacyMotorcycleStyleNames = {
  'adventureTourer',
  'roadster',
  'dualSport',
  'sportNaked',
  'cruiserClassic',
  'standardTwin',
  'cafeRacer',
  'dirtBike',
  'fullTourer',
  'cruiserBagger',
  'scrambler',
  'sportTouring',
  'scooter',
  'sidecarRig',
  'streetFighter',
};

enum SailorSymbolKind { vessel, initials, emoji }

/// Ink choices for an initials marker. These stay separate from the sailor's
/// badge colour because the same initials need to remain recognisable when two
/// sailors choose similar identity colours.
enum SailorInitialsInk { dark, white, yellow, cyan, pink, purple }

extension SailorInitialsInkData on SailorInitialsInk {
  Color get color => switch (this) {
    SailorInitialsInk.dark => const Color(0xFF14202B),
    SailorInitialsInk.white => const Color(0xFFFFFFFF),
    SailorInitialsInk.yellow => const Color(0xFFFFD84D),
    SailorInitialsInk.cyan => const Color(0xFF3DDCFF),
    SailorInitialsInk.pink => const Color(0xFFFF76C8),
    SailorInitialsInk.purple => const Color(0xFF9B7BFF),
  };

  String get label => switch (this) {
    SailorInitialsInk.dark => 'Dark',
    SailorInitialsInk.white => 'White',
    SailorInitialsInk.yellow => 'Yellow',
    SailorInitialsInk.cyan => 'Cyan',
    SailorInitialsInk.pink => 'Pink',
    SailorInitialsInk.purple => 'Purple',
  };
}

const sailorInitialsInkDefault = SailorInitialsInk.dark;

/// How a sailor identifies themselves inside their coloured marker badge.
///
/// The wire representation deliberately reuses the existing
/// `vesselStyle` string. Old builds therefore see an unknown style and
/// safely fall back to the default bike, while new builds can show initials or
/// an emoji without requiring a relay protocol migration.
class SailorSymbol {
  const SailorSymbol.vessel()
    : kind = SailorSymbolKind.vessel,
      emoji = null,
      customInitials = null,
      initialsInk = sailorInitialsInkDefault;

  const SailorSymbol.initials({
    this.customInitials,
    this.initialsInk = sailorInitialsInkDefault,
  }) : kind = SailorSymbolKind.initials,
       emoji = null;

  const SailorSymbol.emoji(this.emoji)
    : kind = SailorSymbolKind.emoji,
      customInitials = null,
      initialsInk = sailorInitialsInkDefault,
      assert(emoji != null && emoji != '');

  final SailorSymbolKind kind;
  final String? emoji;
  final String? customInitials;
  final SailorInitialsInk initialsInk;

  String get storageValue => switch (kind) {
    // Pinned. This token is both the stored value on device and the value sent
    // over the relay, so moving it to 'vessel' would orphan every saved profile
    // and desync peers on different builds. It is opaque, like the other
    // identifiers recorded in docs/source-baseline.md, and stays put.
    SailorSymbolKind.vessel => 'motorcycle',
    SailorSymbolKind.initials =>
      customInitials == null && initialsInk == sailorInitialsInkDefault
          ? 'initials'
          : 'initials:v1:${_encodeInitials(customInitials)}:${initialsInk.name}',
    SailorSymbolKind.emoji => 'emoji:$emoji',
  };

  String wireValue(VesselIconStyle vesselStyle) => switch (kind) {
    SailorSymbolKind.vessel => vesselStyle.name,
    _ => storageValue,
  };

  String label(String displayName, VesselIconStyle vesselStyle) =>
      switch (kind) {
        SailorSymbolKind.vessel => vesselStyle.label,
        SailorSymbolKind.initials => 'Initials ${initialsFor(displayName)}',
        SailorSymbolKind.emoji => 'Emoji $emoji',
      };

  String initialsFor(String displayName) =>
      customInitials ?? sailorInitials(displayName);

  SailorSymbol withInitials({
    String? customInitials,
    bool useAutomaticInitials = false,
    SailorInitialsInk? ink,
  }) => SailorSymbol.initials(
    customInitials: useAutomaticInitials
        ? null
        : customInitials ?? this.customInitials,
    initialsInk: ink ?? initialsInk,
  );

  String imageName(String displayName, VesselIconStyle vesselStyle) {
    if (kind == SailorSymbolKind.vessel) return vesselStyle.name;
    final glyph = kind == SailorSymbolKind.initials
        ? initialsFor(displayName)
        : emoji!;
    final codePoints = glyph.runes
        .map((value) => value.toRadixString(16))
        .join('-');
    return 'sailor-symbol-${kind.name}-$codePoints'
        '${kind == SailorSymbolKind.initials ? '-${initialsInk.name}' : ''}';
  }

  static SailorSymbol fromStorageValue(String? value) {
    if (value == 'initials') return const SailorSymbol.initials();
    if (value?.startsWith('initials:v1:') ?? false) {
      final parts = value!.split(':');
      if (parts.length != 4) return sailorSymbolDefault;
      final initials = _decodeInitials(parts[2]);
      final ink = _sailorInitialsInkFromName(parts[3]);
      if ((parts[2].isNotEmpty && initials == null) || ink == null) {
        return sailorSymbolDefault;
      }
      return SailorSymbol.initials(customInitials: initials, initialsInk: ink);
    }
    if (value?.startsWith('emoji:') ?? false) {
      final emoji = value!.substring('emoji:'.length);
      if (sailorEmojiChoices.contains(emoji)) return SailorSymbol.emoji(emoji);
    }
    return const SailorSymbol.vessel();
  }

  static SailorSymbol fromWireValue(String? value) {
    if (VesselIconStyle.values.any((style) => style.name == value)) {
      return const SailorSymbol.vessel();
    }
    // A peer on an older build sends one of the motorcycle style names this app
    // was derived from. Those are not decodable as vessels and must not be read
    // as an initials or emoji symbol either, so they resolve to the vessel
    // symbol with this device's own style.
    if (_legacyMotorcycleStyleNames.contains(value)) {
      return const SailorSymbol.vessel();
    }
    return fromStorageValue(value);
  }

  @override
  bool operator ==(Object other) =>
      other is SailorSymbol &&
      other.kind == kind &&
      other.emoji == emoji &&
      other.customInitials == customInitials &&
      other.initialsInk == initialsInk;

  @override
  int get hashCode => Object.hash(kind, emoji, customInitials, initialsInk);
}

const sailorSymbolDefault = SailorSymbol.vessel();

/// A deliberately small, high-contrast catalogue that renders consistently on
/// both supported platforms and keeps the wire value comfortably below the
/// relay's existing 40-character style limit.
/// Emoji a sailor can use instead of a vessel silhouette.
///
/// Marine first, because the head of this list is the default preview in the
/// picker. The motorcycle and racing emoji this was inherited with are gone;
/// the rest are personal identity rather than domain, so they stay.
///
/// A stored `emoji:` value that is no longer in this list fails the membership
/// check on decode and falls back to the vessel symbol, which is why removing
/// entries is safe.
const sailorEmojiChoices = <String>[
  '⛵',
  '🛥️',
  '🚤',
  '⚓',
  '🧭',
  '🌊',
  '🐬',
  '🐋',
  '🦈',
  '🐙',
  '🦀',
  '🐠',
  '🏝️',
  '🗺️',
  '🌅',
  '🦅',
  '⚡',
  '🔥',
  '⭐',
  '😎',
  '😈',
  '🦊',
  '🐺',
  '🐉',
  '🦄',
  '🐢',
  '🦉',
  '🦁',
  '🐻',
  '💀',
  '👻',
  '🥷',
  '🦖',
  '🐸',
  '🌈',
  '☕',
];

/// Returns an uppercase 1–3 letter/number identity, or null for automatic
/// initials. Punctuation and control characters are deliberately excluded so
/// the compact wire value is safe to parse on Flutter.
String? normalizeCustomSailorInitials(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) return null;
  final characters = normalized.characters.toList(growable: false);
  if (characters.length > 3) return null;
  final letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
  if (characters.any((character) => !letterOrNumber.hasMatch(character))) {
    return null;
  }
  // Keeps `initials:v1:<base64>:<ink>` below the existing 40-character
  // vesselStyle relay limit even for multi-byte letters.
  if (utf8.encode(normalized).length > 12) return null;
  return normalized;
}

String _encodeInitials(String? initials) {
  if (initials == null) return '';
  return base64Url.encode(utf8.encode(initials)).replaceAll('=', '');
}

String? _decodeInitials(String encoded) {
  if (encoded.isEmpty) return null;
  try {
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    return normalizeCustomSailorInitials(utf8.decode(base64Url.decode(padded)));
  } on FormatException {
    return null;
  }
}

SailorInitialsInk? _sailorInitialsInkFromName(String name) {
  for (final ink in SailorInitialsInk.values) {
    if (ink.name == name) return ink;
  }
  return null;
}

String sailorInitials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.single.characters.take(2).toString().toUpperCase();
  }
  return '${words.first.characters.first}${words.last.characters.first}'
      .toUpperCase();
}

/// Side of the square PNG every sailor glyph is rasterised into for the native
/// map.
const double sailorSymbolRasterSize = 128;

/// The share of a sailor badge's diameter that the sailor's initials span.
///
/// This is the one number the whole app sizes initials by, and it exists
/// because there were three different answers to the same question (#259).
///
/// A bike or an emoji is a pictogram: it sits *inside* the badge, and every
/// symbol layer draws one at roughly 0.8 of the badge diameter. Initials are
/// not a pictogram — they are the sailor's identity, and the point of #259 is
/// that they should fill the circle. They silently inherited the pictogram's
/// size on the native map, so they were drawn at about **0.76** of the badge
/// there, while the symbol picker's preview drew them at **0.94**. That is
/// both halves of the report at once: a quarter smaller than they should be,
/// and visibly not matching the preview a sailor chose them from.
const double sailorInitialsBadgeFill = 0.94;

/// `icon-size` for an initials raster drawn on a badge of [badgeDiameter].
///
/// [rasterizeSailorSymbolPng] already insets the glyph by
/// [sailorInitialsBadgeFill] inside its own square, so the raster maps one to
/// one onto the badge and this is simply the ratio of the two. Derived rather
/// than tuned, so a change to a badge's radius cannot leave its initials
/// behind — which is exactly how they got left behind the first time.
double sailorInitialsIconSize({
  required double badgeDiameter,
  double rasterSize = sailorSymbolRasterSize,
}) => badgeDiameter / rasterSize;

/// A vessel glyph standing in for the plain circle/Material icon
/// previously used for sailor map markers, tinted by the caller (role colour)
/// exactly like the `Icon` widget it replaces.
class VesselIcon extends StatelessWidget {
  const VesselIcon({
    super.key,
    required this.style,
    required this.color,
    this.size = 34,
  });

  final VesselIconStyle style;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: VesselIconPainter(style: style, color: color),
  );
}

/// A white bike silhouette on a filled circle in the sailor's colour - reads
/// clearly against any basemap, unlike a flat-tinted icon alone, and matches
/// the badge look used for the "you are here" marker.
class SailorMarkerBadge extends StatelessWidget {
  const SailorMarkerBadge({
    super.key,
    required this.style,
    required this.badgeColor,
    this.symbol = sailorSymbolDefault,
    this.displayName = '',
    this.size = 34,
    this.borderColor = RouteTrailStyle.casing,
    this.borderWidth = 2,
    this.glyphColor = RouteTrailStyle.markerGlyph,
  });

  final VesselIconStyle style;
  final Color badgeColor;
  final SailorSymbol symbol;
  final String displayName;
  final double size;
  final Color borderColor;
  final double borderWidth;

  /// Ink for the vessel glyph inside the badge.
  final Color glyphColor;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: badgeColor,
      shape: BoxShape.circle,
      border: borderWidth <= 0
          ? null
          : Border.all(color: borderColor, width: borderWidth),
    ),
    child: Center(
      child: switch (symbol.kind) {
        SailorSymbolKind.vessel => VesselIcon(
          style: style,
          // Dark, not white. Every badge fill is light because it has to be
          // found on a dark basemap, so a white glyph on top had almost no
          // contrast at all - 1.76:1 on the default sailor green, 1.53:1 on
          // yellow. See `RouteTrailStyle.markerGlyph` (#133).
          color: glyphColor,
          size: size * 0.62,
        ),
        SailorSymbolKind.initials => Padding(
          // The same fill as the raster the native map draws, so the two
          // renderers of the same marker agree (#259). Measured against the
          // coloured circle rather than the widget's outer box, because the
          // border is drawn inside that box and the raster has no border at
          // all — basing it on the outer box left the two 6% apart.
          padding: EdgeInsets.all(
            (size - 2 * borderWidth) * (1 - sailorInitialsBadgeFill) / 2,
          ),
          child: FittedBox(
            key: const Key('sailor-marker-initials-fill'),
            fit: BoxFit.contain,
            child: Text(
              symbol.initialsFor(displayName),
              maxLines: 1,
              style: TextStyle(
                color: symbol.initialsInk.color,
                shadows: sailorInitialsShadows(
                  symbol.initialsInk.color,
                  size * 0.025,
                ),
                // Start at the badge diameter, then let FittedBox use whichever
                // dimension is limiting. One and two letters therefore occupy
                // the circle instead of inheriting a body-text-sized glyph
                // (#259).
                fontSize: size,
                height: 0.9,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.8,
              ),
            ),
          ),
        ),
        SailorSymbolKind.emoji => Text(
          symbol.emoji!,
          maxLines: 1,
          style: TextStyle(fontSize: size * 0.55, height: 1),
        ),
      },
    ),
  );
}

/// Raw PNG bytes for a style's asset, for registering with
/// `MapLibreMapController.addImage(name, bytes, sdf: true)` on the native
/// map. SDF images are tinted per-feature via the layer's `iconColor` paint
/// property, using only this asset's alpha channel as the shape mask.
Future<Uint8List> loadVesselIconPng(
  VesselIconStyle style, {
  double size = sailorSymbolRasterSize,
}) => _rasterizePng(
  size: size,
  paint: (canvas) => VesselIconPainter(
    style: style,
    // Alpha is all an SDF image uses; the map tints per feature.
    color: const Color(0xFFFFFFFF),
  ).paint(canvas, Size.square(size)),
);

Future<({Uint8List bytes, bool sdf})> rasterizeSailorSymbolPng({
  required SailorSymbol symbol,
  required String displayName,
  required VesselIconStyle vesselStyle,
  double size = sailorSymbolRasterSize,
}) async {
  if (symbol.kind == SailorSymbolKind.vessel) {
    return (bytes: await loadVesselIconPng(vesselStyle), sdf: true);
  }
  final glyph = symbol.kind == SailorSymbolKind.initials
      ? symbol.initialsFor(displayName)
      : symbol.emoji!;
  final initials = symbol.kind == SailorSymbolKind.initials;
  return (
    bytes: await _rasterizePng(
      size: size,
      paint: (canvas) {
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          maxLines: 1,
          text: TextSpan(
            text: glyph,
            style: TextStyle(
              color: initials
                  ? symbol.initialsInk.color
                  : const Color(0xFFFFFFFF),
              fontSize: size * (initials ? 1 : 0.72),
              height: initials ? 0.9 : 1,
              fontWeight: initials ? FontWeight.w900 : FontWeight.normal,
              letterSpacing: initials ? -3 : null,
              shadows: initials
                  ? sailorInitialsShadows(
                      symbol.initialsInk.color,
                      size * 0.012,
                    )
                  : null,
            ),
          ),
        )..layout();
        if (initials) {
          // The same fill the Flutter badge uses, so the raster is the badge
          // rather than something drawn inside it. The layer completes the
          // other half by scaling this square onto the badge itself; see
          // [sailorInitialsIconSize].
          final available = size * sailorInitialsBadgeFill;
          final scale = math.min(
            available / painter.width,
            available / painter.height,
          );
          final paintedWidth = painter.width * scale;
          final paintedHeight = painter.height * scale;
          canvas
            ..save()
            ..translate((size - paintedWidth) / 2, (size - paintedHeight) / 2)
            ..scale(scale);
          painter.paint(canvas, Offset.zero);
          canvas.restore();
          return;
        }
        painter.paint(
          canvas,
          Offset((size - painter.width) / 2, (size - painter.height) / 2),
        );
      },
    ),
    // Initials now carry sailor-selected ink and their own contrast edge. A
    // non-SDF image preserves those colours; MapLibre ignores iconColor for it
    // just as it already does for emoji rasters.
    sdf: false,
  );
}

List<Shadow> sailorInitialsShadows(Color ink, double offset) {
  final edge = ink.computeLuminance() > 0.48
      ? const Color(0xE610151C)
      : const Color(0xE6FFFFFF);
  return <Shadow>[
    Shadow(color: edge, offset: Offset(-offset, 0)),
    Shadow(color: edge, offset: Offset(offset, 0)),
    Shadow(color: edge, offset: Offset(0, -offset)),
    Shadow(color: edge, offset: Offset(0, offset)),
  ];
}

/// Renders an arbitrary Material icon glyph as a PNG, for markers (such as
/// hazards) that stay on the existing generic-icon style.
Future<Uint8List> rasterizeIconGlyphPng(IconData icon, {double size = 128}) =>
    _rasterizePng(
      size: size,
      paint: (canvas) {
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontSize: size * 0.82,
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              color: const Color(0xFFFFFFFF),
            ),
          ),
        )..layout();
        painter.paint(
          canvas,
          Offset((size - painter.width) / 2, (size - painter.height) / 2),
        );
      },
    );

Future<Uint8List> _rasterizePng({
  required double size,
  required void Function(Canvas canvas) paint,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.round(), size.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}
