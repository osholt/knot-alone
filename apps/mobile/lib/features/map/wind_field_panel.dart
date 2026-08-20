import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/wind_field.dart';
import '../../services/marine_forecast.dart';

class WindFieldPanel extends StatelessWidget {
  const WindFieldPanel({
    super.key,
    required this.field,
    required this.failure,
    required this.selectedAt,
    required this.loading,
    required this.onPrevious,
    required this.onNext,
    required this.onNow,
  });

  final WindField? field;
  final ForecastException? failure;
  final DateTime selectedAt;
  final bool loading;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onNow;

  @override
  Widget build(BuildContext context) {
    final value = field;
    return Column(
      key: const Key('wind-field-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Area wind forecast',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (loading)
              const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text('Valid ${_formatUtc(selectedAt)} UTC · model forecast'),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: const Key('wind-time-previous'),
              tooltip: 'Previous forecast hour',
              onPressed: loading ? null : onPrevious,
              icon: const Icon(Icons.chevron_left),
            ),
            OutlinedButton(
              key: const Key('wind-time-now'),
              onPressed: loading ? null : onNow,
              child: const Text('Now'),
            ),
            IconButton(
              key: const Key('wind-time-next'),
              tooltip: 'Next forecast hour',
              onPressed: loading ? null : onNext,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (failure != null)
          Text(failure!.sailorMessage)
        else if (value == null)
          const Text('No area wind field is available.')
        else ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = math.min(3, value.points.length);
              final width = columns == 0
                  ? constraints.maxWidth
                  : constraints.maxWidth / columns;
              return Wrap(
                children: [
                  for (final point in value.points)
                    SizedBox(
                      width: width,
                      child: Semantics(
                        label:
                            '${point.wind.value.speedKnots.toStringAsFixed(0)} '
                            'knots from '
                            '${point.wind.value.fromDegrees.toStringAsFixed(0)} '
                            'degrees',
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            children: [
                              Transform.rotate(
                                // Arrow points where the wind is going; the
                                // label retains meteorological "from".
                                angle:
                                    (point.wind.value.fromDegrees + 180) *
                                    math.pi /
                                    180,
                                child: const Icon(Icons.arrow_upward, size: 30),
                              ),
                              Text(
                                '${point.wind.value.speedKnots.toStringAsFixed(0)} kn',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                'gust ${point.wind.value.gustKnots?.toStringAsFixed(0) ?? '—'}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          Text(
            value.points.first.wind.source.licence.attribution,
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ],
    );
  }
}

String _formatUtc(DateTime value) {
  final utc = value.toUtc();
  return '${utc.day.toString().padLeft(2, '0')}/'
      '${utc.month.toString().padLeft(2, '0')} '
      '${utc.hour.toString().padLeft(2, '0')}:00';
}
