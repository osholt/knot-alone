import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/marine_data.dart';
import '../domain/wind_field.dart';
import 'marine_forecast.dart';

class OpenMeteoWindFieldService implements WindFieldProvider {
  OpenMeteoWindFieldService({
    required this.client,
    this.host = 'api.open-meteo.com',
    this.timeout = const Duration(seconds: 12),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final http.Client client;
  final String host;
  final Duration timeout;
  final DateTime Function() _clock;
  final Map<String, WindField> _cache = {};

  static const MarineDataSource windSource = MarineDataSource(
    id: 'open-meteo-wind-field',
    displayName: 'Open-Meteo wind forecast',
    kind: MarineDataKind.forecast,
    authority: MarineDataAuthority.provider,
    licence: MarineDataLicence(
      name: 'CC BY 4.0',
      attribution: 'Weather data by Open-Meteo.com (CC BY 4.0)',
      url: 'https://open-meteo.com/',
      permitsOfflineCache: true,
      permitsCrewShare: true,
    ),
    coverageNote: 'Model forecast sampled at up to nine chart-area points.',
  );

  @override
  MarineDataSource get source => windSource;

  @override
  Future<WindField> fetch({
    required double south,
    required double west,
    required double north,
    required double east,
    required DateTime validAt,
  }) async {
    if (![south, west, north, east].every((value) => value.isFinite) ||
        south < -90 ||
        north > 90 ||
        west < -180 ||
        east > 180 ||
        south > north ||
        west > east) {
      throw ArgumentError('Wind bounds must be finite and ordered.');
    }
    final hour = _nearestHour(validAt.toUtc());
    final latitudes = _axis(south, north);
    final longitudes = _axis(west, east);
    final coordinates = <(double, double)>[
      for (final latitude in latitudes)
        for (final longitude in longitudes) (latitude, longitude),
    ];
    final cacheKey =
        '${_formatHour(hour)}|'
        '${coordinates.map((item) => '${item.$1.toStringAsFixed(4)},${item.$2.toStringAsFixed(4)}').join(';')}';
    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final uri = Uri.https(host, '/v1/forecast', {
      'latitude': coordinates.map((item) => item.$1).join(','),
      'longitude': coordinates.map((item) => item.$2).join(','),
      'hourly': 'wind_speed_10m,wind_direction_10m,wind_gusts_10m',
      'wind_speed_unit': 'kn',
      'timezone': 'UTC',
      'start_date': _formatDate(hour),
      'end_date': _formatDate(hour),
    });

    http.Response response;
    try {
      response = await client.get(uri).timeout(timeout);
    } on Object catch (error) {
      throw ForecastException(ForecastFailure.unreachable, '$error');
    }
    if (response.statusCode == 401 ||
        response.statusCode == 403 ||
        response.statusCode == 429) {
      throw ForecastException(
        ForecastFailure.refused,
        'HTTP ${response.statusCode}',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ForecastException(
        ForecastFailure.unreachable,
        'HTTP ${response.statusCode}',
      );
    }

    try {
      final decoded = jsonDecode(response.body);
      final rows = decoded is List ? decoded : [decoded];
      if (rows.length != coordinates.length) {
        throw const FormatException('coordinate count mismatch');
      }
      final receivedAt = _clock().toUtc();
      final points = <WindFieldPoint>[];
      for (final row in rows) {
        if (row is! Map) throw const FormatException('row is not an object');
        final hourly = row['hourly'];
        if (hourly is! Map) throw const FormatException('no hourly block');
        final times = hourly['time'];
        final speeds = hourly['wind_speed_10m'];
        final directions = hourly['wind_direction_10m'];
        final gusts = hourly['wind_gusts_10m'];
        if (times is! List ||
            speeds is! List ||
            directions is! List ||
            gusts is! List) {
          throw const FormatException('hourly arrays missing');
        }
        final index = times.indexOf(_formatHour(hour));
        if (index < 0 ||
            index >= speeds.length ||
            index >= directions.length ||
            index >= gusts.length) {
          throw const FormatException('requested hour missing');
        }
        final latitude = _finiteNumber(row['latitude']);
        final longitude = _finiteNumber(row['longitude']);
        final speed = _finiteNumber(speeds[index]);
        final direction = _finiteNumber(directions[index]);
        final gust = _finiteNumber(gusts[index]);
        points.add(
          WindFieldPoint(
            latitude: latitude,
            longitude: longitude,
            wind: MarineDatum(
              value: WindVector(
                speedKnots: speed,
                fromDegrees: ((direction % 360) + 360) % 360,
                gustKnots: gust,
              ),
              source: windSource,
              validAt: hour,
              receivedAt: receivedAt,
              staleAfter: const Duration(hours: 2),
              unit: 'kn, degrees from',
              qualityNote:
                  'Model forecast, not an observation or routing instruction.',
            ),
          ),
        );
      }
      final field = WindField(points: points);
      _cache[cacheKey] = field;
      return field;
    } on ForecastException {
      rethrow;
    } on Object catch (error) {
      throw ForecastException(ForecastFailure.unreadable, '$error');
    }
  }
}

List<double> _axis(double minimum, double maximum) {
  if ((maximum - minimum).abs() < 0.0001) return [minimum];
  return [minimum, (minimum + maximum) / 2, maximum];
}

DateTime _nearestHour(DateTime value) {
  final start = DateTime.utc(value.year, value.month, value.day, value.hour);
  return value.minute >= 30 ? start.add(const Duration(hours: 1)) : start;
}

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _formatHour(DateTime value) =>
    '${_formatDate(value)}T${value.hour.toString().padLeft(2, '0')}:00';

double _finiteNumber(Object? value) {
  if (value is! num || !value.toDouble().isFinite) {
    throw const FormatException('forecast value is not finite');
  }
  return value.toDouble();
}
