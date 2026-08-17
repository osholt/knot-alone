import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/vessel_icon_painter.dart';

/// Renders every vessel silhouette to /tmp so they can actually be looked at.
///
/// A silhouette that is technically correct and unreadable at 34pt is no use, and
/// no assertion catches that — only eyes do. Writes a strip at marker size and
/// a larger one for checking the shapes themselves.
void main() {
  test('writes a preview strip of every vessel silhouette', () async {
    const marker = 40.0;
    const large = 110.0;
    final styles = VesselIconStyle.values;

    for (final (size, name) in [(marker, 'marker'), (large, 'large')]) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size * styles.length, size),
        Paint()..color = const Color(0xFF0C6B4F),
      );
      for (final (index, style) in styles.indexed) {
        canvas.save();
        canvas.translate(index * size, 0);
        VesselIconPainter(
          style: style,
          color: const Color(0xFFFDF6E3),
        ).paint(canvas, Size(size, size));
        canvas.restore();
      }
      final image = await recorder.endRecording().toImage(
        (size * styles.length).round(),
        size.round(),
      );
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '/tmp/vessels-$name.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    }

    // Order is the order they appear in the picker, so the preview matches.
    expect(styles.first, VesselIconStyle.sloop);
    expect(styles.length, 8);
  });

  test('every style draws at least one filled shape', () {
    for (final style in VesselIconStyle.values) {
      final paths = VesselIconPainter.pathsFor(style);
      expect(paths, isNotEmpty, reason: style.name);
      for (final path in paths) {
        expect(
          path.getBounds().isEmpty,
          isFalse,
          reason: '${style.name} has an empty path',
        );
      }
    }
  });

  test('nothing is drawn outside the 100x100 box it is scaled from', () {
    // Overflow would clip against the badge rather than scale with it.
    for (final style in VesselIconStyle.values) {
      for (final path in VesselIconPainter.pathsFor(style)) {
        final bounds = path.getBounds();
        expect(bounds.left, greaterThanOrEqualTo(-1), reason: style.name);
        expect(bounds.top, greaterThanOrEqualTo(-1), reason: style.name);
        expect(bounds.right, lessThanOrEqualTo(101), reason: style.name);
        expect(bounds.bottom, lessThanOrEqualTo(101), reason: style.name);
      }
    }
  });

  test('only the rigs report as sailing vessels', () {
    expect(VesselIconStyle.values.where((style) => style.isSailing).toSet(), {
      VesselIconStyle.sloop,
      VesselIconStyle.ketch,
      VesselIconStyle.catamaran,
    });
  });

  test('every style has a label a sailor would recognise', () {
    for (final style in VesselIconStyle.values) {
      expect(style.label.trim(), isNotEmpty, reason: style.name);
    }
    expect(VesselIconStyle.rib.label, contains('RIB'));
  });
}
