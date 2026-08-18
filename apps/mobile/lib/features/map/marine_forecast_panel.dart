/// Wind, pressure, visibility and sea state, with the age of the forecast.
///
/// ## Nothing here is an observation
///
/// Open-Meteo's "current" block is model output for the current hour, not a
/// reading from a weather station. `PLAN.md` requires observed and forecast to
/// stay distinguishable; the honest answer is that this is all forecast, and the
/// panel says so once at the top rather than implying a measurement.
///
/// ## Age, not run time
///
/// The provider publishes what its values are valid *for*, and does not publish
/// the model run behind them. So the panel shows the validity time and how long
/// ago that was — and says the run is not published, rather than showing a server
/// timing as though it were provenance.
///
/// ## Wind reads the way a forecast is read
///
/// Direction is where the wind blows *from*, with its compass point, and Beaufort
/// sits beside knots: "force 6" carries meaning that "24 knots" does not, and a
/// forecast is discussed in both. Gusts are given their own line because the
/// difference between 18 knots and gusting 30 is the difference between a good
/// sail and a reef.
library;

import 'package:flutter/material.dart';

import '../../services/marine_forecast.dart';
import 'passage_leg_table.dart' show formatPassageDuration;

class MarineForecastPanel extends StatelessWidget {
  const MarineForecastPanel({
    super.key,
    this.forecast,
    this.failure,
    required this.now,
    this.staleAfter = const Duration(hours: 3),
  });

  final MarineForecast? forecast;

  /// Set when there is no forecast. A missing forecast is an ordinary state on a
  /// free endpoint with no uptime guarantee, and at sea, so it is reported rather
  /// than treated as a fault.
  final ForecastException? failure;

  final DateTime now;

  /// A three-hour-old forecast is still worth reading; it just needs saying.
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = forecast;

    return Column(
      key: const Key('marine-forecast-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Weather', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        // Said once, at the top: none of this is measured.
        Text(
          'Forecast, not an observation. No weather station reading here.',
          key: const Key('marine-forecast-not-observed'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        if (current == null)
          _Unavailable(failure: failure)
        else ...[
          _Validity(forecast: current, now: now, staleAfter: staleAfter),
          const SizedBox(height: 14),
          _Wind(forecast: current),
          const SizedBox(height: 14),
          _SeaState(forecast: current),
          const SizedBox(height: 14),
          _Other(forecast: current),
          const SizedBox(height: 16),
          // CC BY 4.0 requires this, and it must survive being offline.
          Text(
            OpenMeteoForecastService.attribution,
            key: const Key('marine-forecast-attribution'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({this.failure});

  final ForecastException? failure;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('marine-forecast-unavailable'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 2, right: 8),
        child: Icon(Icons.cloud_off_outlined, size: 18),
      ),
      Expanded(
        child: Text(
          failure?.sailorMessage ?? 'No forecast yet.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    ],
  );
}

class _Validity extends StatelessWidget {
  const _Validity({
    required this.forecast,
    required this.now,
    required this.staleAfter,
  });

  final MarineForecast forecast;
  final DateTime now;
  final Duration staleAfter;

  @override
  Widget build(BuildContext context) {
    final age = forecast.ageAt(now);
    final stale = age > staleAfter;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              stale ? Icons.warning_amber_outlined : Icons.schedule,
              size: 16,
              color: stale ? const Color(0xFFE8A33D) : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                age.inMinutes < 1
                    ? 'Valid now'
                    : 'Valid ${formatPassageDuration(age)} ago',
                key: const Key('marine-forecast-age'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: stale ? const Color(0xFFE8A33D) : null,
                  fontWeight: stale ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          // Checked against the live API: the provider does not publish it.
          'The forecast run behind this is not published by the provider.',
          key: const Key('marine-forecast-no-run-time'),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Wind extends StatelessWidget {
  const _Wind({required this.forecast});

  final MarineForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!forecast.hasWind) {
      return Text(
        'No wind in this forecast.',
        key: const Key('marine-forecast-no-wind'),
        style: theme.textTheme.bodyMedium,
      );
    }
    final point = MarineForecast.compassPoint(forecast.windFromDegrees);
    final force = forecast.beaufortForce;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'WIND',
          style: theme.textTheme.labelSmall?.copyWith(
            color: const Color(0xFF98A3B1),
            letterSpacing: 0.6,
          ),
        ),
        Text(
          // "from" spelled out: a wind from 270 is a westerly, and the
          // ambiguity between from and toward is worth a word.
          [
            if (point != null) 'from $point',
            '${forecast.windSpeedKnots!.round()} kn',
            if (force != null) 'force $force',
          ].join(' · '),
          key: const Key('marine-forecast-wind'),
          style: theme.textTheme.titleMedium,
        ),
        if (forecast.windGustKnots case final gust?)
          Text(
            'gusting ${gust.round()} kn',
            key: const Key('marine-forecast-gust'),
            style: theme.textTheme.bodyMedium,
          ),
      ],
    );
  }
}

class _SeaState extends StatelessWidget {
  const _SeaState({required this.forecast});

  final MarineForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!forecast.hasSeaState) {
      return Text(
        // Absence is normal for an inland or sheltered position, not a fault.
        'No sea state for this position.',
        key: const Key('marine-forecast-no-sea-state'),
        style: theme.textTheme.bodyMedium,
      );
    }
    final point = MarineForecast.compassPoint(forecast.waveFromDegrees);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FORECAST WAVE',
          style: theme.textTheme.labelSmall?.copyWith(
            color: const Color(0xFF98A3B1),
            letterSpacing: 0.6,
          ),
        ),
        Text(
          [
            '${forecast.waveHeightMeters!.toStringAsFixed(1)} m',
            if (forecast.wavePeriodSeconds case final period?)
              '${period.toStringAsFixed(0)} s',
            if (point != null) 'from $point',
          ].join(' · '),
          key: const Key('marine-forecast-wave'),
          style: theme.textTheme.titleMedium,
        ),
        Text(
          // Modelled significant wave height is not the sea a sailor meets near
          // a lee shore, over a bank, or against the tide.
          'Modelled open-water wave. Not the sea you will meet in a tide race '
          'or under a lee shore.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Other extends StatelessWidget {
  const _Other({required this.forecast});

  final MarineForecast forecast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visibility = forecast.visibilityMeters;
    return Wrap(
      spacing: 20,
      runSpacing: 8,
      children: [
        if (forecast.pressureHectopascals case final pressure?)
          _Small(
            label: 'PRESSURE',
            value: '${pressure.round()} hPa',
            valueKey: const Key('marine-forecast-pressure'),
            theme: theme,
          ),
        if (visibility != null)
          _Small(
            label: 'VISIBILITY',
            // Read in miles at sea for anything but fog.
            value: visibility >= 1852
                ? '${(visibility / 1852).toStringAsFixed(visibility < 9260 ? 1 : 0)} NM'
                : '${visibility.round()} m',
            valueKey: const Key('marine-forecast-visibility'),
            theme: theme,
          ),
        if (forecast.temperatureCelsius case final temperature?)
          _Small(
            label: 'AIR',
            value: '${temperature.round()}°C',
            valueKey: const Key('marine-forecast-temperature'),
            theme: theme,
          ),
      ],
    );
  }
}

class _Small extends StatelessWidget {
  const _Small({
    required this.label,
    required this.value,
    required this.valueKey,
    required this.theme,
  });

  final String label;
  final String value;
  final Key valueKey;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: const Color(0xFF98A3B1),
          letterSpacing: 0.6,
        ),
      ),
      Text(value, key: valueKey, style: theme.textTheme.bodyLarge),
    ],
  );
}
