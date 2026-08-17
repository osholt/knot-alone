import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/imported_route.dart' show GeoPoint;

/// Projects route points into a 0..1 unit square, preserving aspect ratio -
/// a wide or tall route is centered rather than stretched to fill the
/// square - so [RouteSketchPainter] can sketch it without a live map/tile
/// provider.
List<Offset> normalizeRoutePoints(List<GeoPoint> points) {
  if (points.isEmpty) return const [];
  final latitudes = points.map((point) => point.latitude);
  final longitudes = points.map((point) => point.longitude);
  final minLat = latitudes.reduce(math.min);
  final maxLat = latitudes.reduce(math.max);
  final minLng = longitudes.reduce(math.min);
  final maxLng = longitudes.reduce(math.max);
  final latSpan = maxLat - minLat;
  final lngSpan = maxLng - minLng;
  final span = math.max(latSpan, lngSpan);
  if (span == 0) return [const Offset(0.5, 0.5)];
  final latPad = (span - latSpan) / 2;
  final lngPad = (span - lngSpan) / 2;
  return [
    for (final point in points)
      Offset(
        (point.longitude - minLng + lngPad) / span,
        // Latitude increases north (up); Offset.dy increases downward.
        1 - (point.latitude - minLat + latPad) / span,
      ),
  ];
}

/// Draws a branded route line from points already normalized by
/// [normalizeRoutePoints] - a start (white) and end (accent) dot, connected
/// by a rounded stroke.
class RouteSketchPainter extends CustomPainter {
  const RouteSketchPainter(
    this.points, {
    this.color = const Color(0xFFFF7A1A),
    this.strokeWidth = 5,
  });

  final List<Offset> points;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final scaled = [
      for (final point in points)
        Offset(point.dx * size.width, point.dy * size.height),
    ];
    if (scaled.length == 1) {
      canvas.drawCircle(scaled.single, 6, Paint()..color = color);
      return;
    }
    final path = Path()..moveTo(scaled.first.dx, scaled.first.dy);
    for (final point in scaled.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(scaled.first, 7, Paint()..color = Colors.white);
    canvas.drawCircle(scaled.last, 7, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant RouteSketchPainter oldDelegate) =>
      !identical(oldDelegate.points, points) ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
