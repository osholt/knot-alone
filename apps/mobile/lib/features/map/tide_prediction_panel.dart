import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/tide.dart';
import '../../services/harmonic_tide_provider.dart';

class TidePredictionPanel extends StatelessWidget {
  const TidePredictionPanel({
    super.key,
    required this.prediction,
    required this.now,
    this.distanceKilometers,
  });

  final TidePrediction prediction;
  final DateTime now;
  final double? distanceKilometers;

  @override
  Widget build(BuildContext context) {
    final currentIndex = _nearestPointIndex(prediction, now);
    final current = prediction.points[currentIndex];
    final previous = prediction.points[math.max(0, currentIndex - 1)];
    final next = prediction
        .points[math.min(prediction.points.length - 1, currentIndex + 1)];
    final trend = next.value.meters > previous.value.meters + 0.01
        ? 'rising'
        : next.value.meters < previous.value.meters - 0.01
        ? 'falling'
        : 'near a turn';
    final upcoming = prediction.extremes
        .where((extreme) => !extreme.at.isBefore(now.toUtc()))
        .take(2)
        .toList();
    final distance = distanceKilometers;

    return Column(
      key: const Key('tide-prediction-panel'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          prediction.station.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          [
            if (distance != null) '${distance.toStringAsFixed(1)} km away',
            '${prediction.station.datum} datum',
            'calculated',
          ].join(' · '),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${current.value.meters.toStringAsFixed(2)} m',
              key: const Key('current-tide-height'),
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('$trend · valid ${_utcTime(current.validAt)} UTC'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 120,
          width: double.infinity,
          child: CustomPaint(
            key: const Key('tide-height-curve'),
            painter: _TideCurvePainter(
              prediction: prediction,
              now: now.toUtc(),
              color: Theme.of(context).colorScheme.primary,
              gridColor: Theme.of(context).dividerColor,
            ),
          ),
        ),
        const SizedBox(height: 10),
        for (final extreme in upcoming)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${extreme.kind == TideExtremeKind.high ? 'High' : 'Low'} '
              '${extreme.height.meters.toStringAsFixed(2)} m · '
              '${_utcTime(extreme.at)} UTC',
            ),
          ),
        const SizedBox(height: 12),
        Text(
          BundledHarmonicTideProvider.warning,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 6),
        Text(
          prediction.station.source.licence.attribution,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

int _nearestPointIndex(TidePrediction prediction, DateTime at) {
  var best = 0;
  var difference = const Duration(days: 36500);
  for (var index = 0; index < prediction.points.length; index += 1) {
    final candidate = prediction.points[index].validAt.difference(at).abs();
    if (candidate < difference) {
      best = index;
      difference = candidate;
    }
  }
  return best;
}

String _utcTime(DateTime value) {
  final utc = value.toUtc();
  return '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}';
}

class _TideCurvePainter extends CustomPainter {
  const _TideCurvePainter({
    required this.prediction,
    required this.now,
    required this.color,
    required this.gridColor,
  });

  final TidePrediction prediction;
  final DateTime now;
  final Color color;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final points = prediction.points;
    if (points.length < 2 || size.isEmpty) return;
    final minimum = points.map((point) => point.value.meters).reduce(math.min);
    final maximum = points.map((point) => point.value.meters).reduce(math.max);
    final range = math.max(0.01, maximum - minimum);
    final start = points.first.validAt.millisecondsSinceEpoch;
    final end = points.last.validAt.millisecondsSinceEpoch;
    final duration = math.max(1, end - start);

    canvas.drawLine(
      Offset(0, size.height - 1),
      Offset(size.width, size.height - 1),
      Paint()..color = gridColor,
    );
    final path = Path();
    for (var index = 0; index < points.length; index += 1) {
      final point = points[index];
      final x =
          (point.validAt.millisecondsSinceEpoch - start) /
          duration *
          size.width;
      final y =
          size.height -
          4 -
          (point.value.meters - minimum) / range * (size.height - 8);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
    final nowX = (now.millisecondsSinceEpoch - start) / duration * size.width;
    if (nowX >= 0 && nowX <= size.width) {
      canvas.drawLine(
        Offset(nowX, 0),
        Offset(nowX, size.height),
        Paint()
          ..color = color.withValues(alpha: 0.55)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TideCurvePainter oldDelegate) =>
      oldDelegate.prediction != prediction ||
      oldDelegate.now != now ||
      oldDelegate.color != color ||
      oldDelegate.gridColor != gridColor;
}
