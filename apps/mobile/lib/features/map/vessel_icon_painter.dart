/// Vessel silhouettes, drawn rather than shipped as artwork.
///
/// The native map registers these as SDF images, which use only the alpha
/// channel as a shape mask and tint per feature. A silhouette is therefore all
/// that is needed — so they are painted in code, which costs no assets, scales
/// to any marker size, and cannot drift out of sync with the enum.
///
/// Everything is drawn in a nominal 100×100 box and scaled by the caller. The
/// constraint that matters is legibility at roughly 34pt: no strokes thinner
/// than about 4 units, and each type has to differ in *outline*, not in detail,
/// because detail disappears.
library;

import 'package:flutter/rendering.dart';

/// What kind of vessel a sailor is aboard.
///
/// Chosen so the silhouettes are actually distinguishable at marker size:
/// one mast, two masts, twin hulls, boxy superstructure, low and open, or big
/// and commercial. Finer distinctions than that are invisible at 34pt.
enum VesselIconStyle {
  sloop,
  ketch,
  catamaran,
  motorCruiser,
  motorYacht,
  rib,
  fishingBoat,
  ship;

  String get label => switch (this) {
    VesselIconStyle.sloop => 'Sloop',
    VesselIconStyle.ketch => 'Ketch',
    VesselIconStyle.catamaran => 'Catamaran',
    VesselIconStyle.motorCruiser => 'Motor cruiser',
    VesselIconStyle.motorYacht => 'Motor yacht',
    VesselIconStyle.rib => 'RIB or tender',
    VesselIconStyle.fishingBoat => 'Fishing boat',
    VesselIconStyle.ship => 'Ship',
  };

  /// True for vessels that carry sail, which the roster uses to decide whether
  /// wind-related context is worth showing at all.
  bool get isSailing => switch (this) {
    VesselIconStyle.sloop ||
    VesselIconStyle.ketch ||
    VesselIconStyle.catamaran => true,
    _ => false,
  };
}

/// Paints one vessel silhouette into the given size.
class VesselIconPainter extends CustomPainter {
  const VesselIconPainter({required this.style, required this.color});

  final VesselIconStyle style;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 100;
    canvas.save();
    canvas.translate(
      (size.width - 100 * scale) / 2,
      (size.height - 100 * scale) / 2,
    );
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final path in pathsFor(style)) {
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  /// The filled shapes making up a silhouette, in a 100×100 box.
  ///
  /// Separate paths rather than one union: the map tints the whole mask a single
  /// colour anyway, and keeping hull, rig and superstructure apart makes each
  /// one legible to edit.
  static List<Path> pathsFor(VesselIconStyle style) => switch (style) {
    VesselIconStyle.sloop => [_hull(), _mast(x: 46), _mainsail(), _jib()],
    VesselIconStyle.ketch => [
      _hull(),
      _mast(x: 38, top: 12),
      _mast(x: 68, top: 30),
      _sail(peakX: 38, peakY: 16, footY: 60, sternX: 20),
      _sail(peakX: 68, peakY: 34, footY: 60, sternX: 52),
    ],
    VesselIconStyle.catamaran => [
      _catamaranHulls(),
      _mast(x: 50),
      _mainsail(),
      _jib(),
    ],
    VesselIconStyle.motorCruiser => [
      _hull(),
      _superstructure(left: 30, right: 66, top: 40, rake: 8),
      _flybridge(),
    ],
    VesselIconStyle.motorYacht => [
      _longHull(),
      _superstructure(left: 24, right: 72, top: 46, rake: 14),
    ],
    VesselIconStyle.rib => [_ribHull(), _console()],
    VesselIconStyle.fishingBoat => [
      _hull(),
      _superstructure(left: 22, right: 48, top: 42, rake: 4),
      _mast(x: 56, top: 22),
      _derrick(),
    ],
    VesselIconStyle.ship => [
      _longHull(),
      _shipBridge(),
      _funnel(),
      // Deck line forward of the superstructure: the long flat run is what
      // distinguishes a ship from a large motor yacht.
      Path()..addRect(const Rect.fromLTRB(40, 52, 88, 60)),
    ],
  };

  /// Sheer line rising to a bow on the right, transom on the left.
  static Path _hull() => Path()
    ..moveTo(10, 66)
    ..lineTo(92, 62)
    ..lineTo(86, 80)
    ..quadraticBezierTo(50, 88, 18, 80)
    ..close();

  /// Longer and lower, for powered and commercial hulls.
  static Path _longHull() => Path()
    ..moveTo(6, 64)
    ..lineTo(95, 58)
    ..lineTo(90, 78)
    ..quadraticBezierTo(48, 86, 12, 78)
    ..close();

  /// Twin hulls with the bridgedeck between them — the one outline that reads
  /// unambiguously as a multihull at marker size.
  static Path _catamaranHulls() => Path()
    ..addRect(const Rect.fromLTRB(12, 62, 92, 70))
    ..moveTo(16, 70)
    ..lineTo(40, 70)
    ..lineTo(36, 82)
    ..lineTo(20, 82)
    ..close()
    ..moveTo(62, 70)
    ..lineTo(88, 70)
    ..lineTo(82, 82)
    ..lineTo(66, 82)
    ..close();

  static Path _ribHull() => Path()
    ..moveTo(12, 62)
    ..quadraticBezierTo(50, 56, 90, 62)
    ..quadraticBezierTo(92, 76, 78, 78)
    ..lineTo(24, 78)
    ..quadraticBezierTo(10, 76, 12, 62)
    ..close();

  static Path _console() =>
      Path()
        ..addRRect(RRect.fromLTRBR(44, 44, 60, 62, const Radius.circular(3)));

  static Path _mast({required double x, double top = 14}) =>
      Path()..addRect(Rect.fromLTRB(x - 3, top, x + 3, 64));

  /// Mainsail: luff on the mast, foot on the boom, aft of the mast.
  static Path _mainsail() => _sail(peakX: 46, peakY: 18, footY: 60, sternX: 18);

  /// Headsail forward of the mast, on the forestay.
  static Path _jib() => Path()
    ..moveTo(50, 20)
    ..lineTo(84, 60)
    ..lineTo(52, 60)
    ..close();

  static Path _sail({
    required double peakX,
    required double peakY,
    required double footY,
    required double sternX,
  }) => Path()
    ..moveTo(peakX - 2, peakY)
    ..lineTo(peakX - 2, footY)
    ..lineTo(sternX, footY)
    ..close();

  static Path _superstructure({
    required double left,
    required double right,
    required double top,
    required double rake,
  }) => Path()
    ..moveTo(left, top)
    ..lineTo(right - rake, top)
    ..lineTo(right, 62)
    ..lineTo(left, 62)
    ..close();

  static Path _flybridge() => Path()
    ..moveTo(32, 28)
    ..lineTo(62, 28)
    ..lineTo(66, 42)
    ..lineTo(30, 42)
    ..close();

  static Path _derrick() => Path()
    ..moveTo(56, 24)
    ..lineTo(84, 44)
    ..lineTo(80, 50)
    ..lineTo(52, 30)
    ..close();

  static Path _shipBridge() => Path()
    ..moveTo(12, 34)
    ..lineTo(40, 34)
    ..lineTo(40, 60)
    ..lineTo(12, 60)
    ..close();

  /// Rises out of the superstructure rather than standing apart from it, so the
  /// two read as one mass at marker size instead of as two boxes.
  static Path _funnel() => Path()
    ..moveTo(20, 20)
    ..lineTo(32, 20)
    ..lineTo(32, 36)
    ..lineTo(20, 36)
    ..close();

  @override
  bool shouldRepaint(VesselIconPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.color != color;
}
