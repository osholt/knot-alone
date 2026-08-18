/// Wind, pressure, visibility and sea state for a position.
///
/// ## Source and licence
///
/// Open-Meteo. The data is **CC BY 4.0**, so caching it on the device and showing
/// it to crew are both permitted with attribution — which is why this fits the
/// `ChartSource` provenance model the charts already use. The free endpoint is
/// for non-commercial use at 10,000 calls a day and carries no uptime guarantee,
/// so a missing forecast is an ordinary state here rather than an error (#12).
///
/// ## What "current" is, and is not
///
/// Open-Meteo's `current` block is **model output for the current hour**, not a
/// reading from a weather station. Nothing in this file is an observation, and
/// nothing may be labelled as one: `PLAN.md` requires observed and forecast to
/// stay distinguishable, and the honest answer here is that it is all forecast.
///
/// ## There is no forecast run time
///
/// Checked against the live API rather than assumed. The response carries
/// `generationtime_ms`, which is how long the *server* spent answering, and
/// `current.time`, which is what the values are valid for. The underlying model
/// run is not published. So this exposes [MarineForecast.validAt] and an age, and
/// says plainly that the run time is unknown, rather than showing a server timing
/// as though it meant something.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// One forecast for one position, with everything needed to judge its worth.
class MarineForecast {
  const MarineForecast({
    required this.latitude,
    required this.longitude,
    required this.validAt,
    required this.fetchedAt,
    this.windSpeedKnots,
    this.windGustKnots,
    this.windFromDegrees,
    this.pressureHectopascals,
    this.visibilityMeters,
    this.temperatureCelsius,
    this.waveHeightMeters,
    this.wavePeriodSeconds,
    this.waveFromDegrees,
  });

  final double latitude;
  final double longitude;

  /// What the values are valid for, from the provider.
  final DateTime validAt;

  /// When this device fetched them, which is what makes an offline copy ageable.
  final DateTime fetchedAt;

  /// Wind is reported as the direction it blows *from*, which is the convention
  /// every forecast and every sailor uses. A wind "from 270" is a westerly.
  final double? windSpeedKnots;
  final double? windGustKnots;
  final double? windFromDegrees;

  final double? pressureHectopascals;
  final double? visibilityMeters;
  final double? temperatureCelsius;

  /// Sea state. Absent for an inland position, and absence is not a failure.
  final double? waveHeightMeters;
  final double? wavePeriodSeconds;
  final double? waveFromDegrees;

  bool get hasWind => windSpeedKnots != null;
  bool get hasSeaState => waveHeightMeters != null;

  /// How old the forecast's own validity is, which is not the same as how long
  /// ago it was fetched: a cached forecast can be recent and already stale.
  Duration ageAt(DateTime now) {
    final age = now.difference(validAt);
    return age.isNegative ? Duration.zero : age;
  }

  /// Beaufort force for [windSpeedKnots], because forecasts are read in both and
  /// "force 6" carries meaning that "24 knots" does not.
  int? get beaufortForce {
    final knots = windSpeedKnots;
    if (knots == null) return null;
    // Force 0 is calm, below one knot. Every other force is bounded above by its
    // published upper limit in knots, so force 1 is 1-3, force 6 is 22-27, and
    // force 12 is anything from 64 up.
    if (knots < 1) return 0;
    const upperLimits = [0, 3, 6, 10, 16, 21, 27, 33, 40, 47, 55, 63];
    for (var force = 1; force < upperLimits.length; force += 1) {
      if (knots <= upperLimits[force]) return force;
    }
    return 12;
  }

  /// The compass point a direction lies in, for reading aloud.
  static String? compassPoint(double? degrees) {
    if (degrees == null) return null;
    const points = [
      'N',
      'NNE',
      'NE',
      'ENE',
      'E',
      'ESE',
      'SE',
      'SSE',
      'S',
      'SSW',
      'SW',
      'WSW',
      'W',
      'WNW',
      'NW',
      'NNW',
    ];
    final normalised = ((degrees % 360) + 360) % 360;
    return points[((normalised / 22.5).round()) % 16];
  }
}

/// Why a forecast is not available. Named so the UI can say which.
enum ForecastFailure {
  /// No network, or the provider did not answer. Ordinary at sea.
  unreachable,

  /// The provider answered with something this code does not understand.
  unreadable,

  /// The provider refused — most likely the free tier's daily limit.
  refused,
}

class ForecastException implements Exception {
  const ForecastException(this.failure, this.message);

  final ForecastFailure failure;
  final String message;

  /// Shown to the sailor. Says what is missing, not what went wrong internally.
  String get sailorMessage => switch (failure) {
    ForecastFailure.unreachable =>
      'No forecast: could not reach the weather service.',
    ForecastFailure.refused =>
      'No forecast: the weather service declined the request.',
    ForecastFailure.unreadable =>
      'No forecast: the weather service sent something unreadable.',
  };

  @override
  String toString() => 'ForecastException($failure): $message';
}

/// Fetches a forecast for a position from Open-Meteo.
class OpenMeteoForecastService {
  const OpenMeteoForecastService({
    required this.client,
    this.forecastHost = 'api.open-meteo.com',
    this.marineHost = 'marine-api.open-meteo.com',
    this.timeout = const Duration(seconds: 12),
  });

  final http.Client client;

  /// Hosts are separate: wind and pressure come from the forecast API, waves from
  /// the marine one. Overridable so a paid endpoint can replace them without
  /// touching this logic.
  final String forecastHost;
  final String marineHost;

  final Duration timeout;

  /// Attribution required by CC BY 4.0, and shown offline.
  static const attribution = 'Weather data by Open-Meteo.com (CC BY 4.0)';

  Future<MarineForecast> fetch({
    required double latitude,
    required double longitude,
    DateTime? now,
  }) async {
    final fetchedAt = (now ?? DateTime.now()).toUtc();
    final weather = await _get(
      Uri.https(forecastHost, '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current':
            'wind_speed_10m,wind_direction_10m,wind_gusts_10m,'
            'pressure_msl,visibility,temperature_2m',
        // Knots at source, so no conversion can drift from what the provider
        // meant.
        'wind_speed_unit': 'kn',
        'timezone': 'UTC',
      }),
    );

    final current = weather['current'];
    if (current is! Map) {
      throw const ForecastException(
        ForecastFailure.unreadable,
        'no current block',
      );
    }
    final validAt = _parseTime(current['time']);

    // Waves are a separate request and a separate host. An inland position has no
    // wave data at all, and a marine service that is down should not take the
    // wind with it - so this failure is swallowed rather than propagated.
    Map<String, Object?>? wave;
    try {
      final marine = await _get(
        Uri.https(marineHost, '/v1/marine', {
          'latitude': latitude.toString(),
          'longitude': longitude.toString(),
          'current': 'wave_height,wave_direction,wave_period',
          'timezone': 'UTC',
        }),
      );
      final marineCurrent = marine['current'];
      if (marineCurrent is Map) {
        wave = Map<String, Object?>.from(marineCurrent);
      }
    } on Object {
      wave = null;
    }

    return MarineForecast(
      latitude: (weather['latitude'] as num?)?.toDouble() ?? latitude,
      longitude: (weather['longitude'] as num?)?.toDouble() ?? longitude,
      validAt: validAt,
      fetchedAt: fetchedAt,
      windSpeedKnots: _number(current['wind_speed_10m']),
      windGustKnots: _number(current['wind_gusts_10m']),
      windFromDegrees: _number(current['wind_direction_10m']),
      pressureHectopascals: _number(current['pressure_msl']),
      visibilityMeters: _number(current['visibility']),
      temperatureCelsius: _number(current['temperature_2m']),
      waveHeightMeters: _number(wave?['wave_height']),
      wavePeriodSeconds: _number(wave?['wave_period']),
      waveFromDegrees: _number(wave?['wave_direction']),
    );
  }

  Future<Map<String, Object?>> _get(Uri uri) async {
    final http.Response response;
    try {
      response = await client.get(uri).timeout(timeout);
    } on Object catch (error) {
      throw ForecastException(ForecastFailure.unreachable, '$error');
    }
    if (response.statusCode == 429 || response.statusCode == 402) {
      throw ForecastException(
        ForecastFailure.refused,
        'HTTP ${response.statusCode}',
      );
    }
    if (response.statusCode != 200) {
      throw ForecastException(
        ForecastFailure.unreachable,
        'HTTP ${response.statusCode}',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on Object catch (error) {
      throw ForecastException(ForecastFailure.unreadable, '$error');
    }
    if (decoded is! Map) {
      throw const ForecastException(
        ForecastFailure.unreadable,
        'not an object',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  static DateTime _parseTime(Object? raw) {
    if (raw is! String) {
      throw const ForecastException(
        ForecastFailure.unreadable,
        'missing valid time',
      );
    }
    // Requested in UTC, and the provider returns it without a zone suffix.
    final parsed = DateTime.tryParse(raw.endsWith('Z') ? raw : '${raw}Z');
    if (parsed == null) {
      throw ForecastException(
        ForecastFailure.unreadable,
        'unparseable time "$raw"',
      );
    }
    return parsed.toUtc();
  }

  static double? _number(Object? raw) => (raw as num?)?.toDouble();
}
