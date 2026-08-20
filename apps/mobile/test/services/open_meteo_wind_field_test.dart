import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/services/open_meteo_wind_field.dart';

void main() {
  test('fetches a capped grid at the nearest forecast hour', () async {
    Uri? requested;
    final service = OpenMeteoWindFieldService(
      client: MockClient((request) async {
        requested = request.url;
        final coordinates = request.url.queryParameters['latitude']!.split(',');
        return http.Response(
          jsonEncode([
            for (var index = 0; index < coordinates.length; index += 1)
              {
                'latitude': 50.7 + index * 0.01,
                'longitude': -1.5 + index * 0.01,
                'hourly': {
                  'time': ['2026-08-20T12:00', '2026-08-20T13:00'],
                  'wind_speed_10m': [10 + index, 20 + index],
                  'wind_direction_10m': [270, 280],
                  'wind_gusts_10m': [15 + index, 25 + index],
                },
              },
          ]),
          200,
        );
      }),
      clock: () => DateTime.utc(2026, 8, 20, 11, 55),
    );

    final field = await service.fetch(
      south: 50.7,
      west: -1.6,
      north: 50.9,
      east: -1.2,
      validAt: DateTime.utc(2026, 8, 20, 12, 31),
    );

    expect(field.points, hasLength(9));
    expect(field.validAt, DateTime.utc(2026, 8, 20, 13));
    expect(field.points.first.wind.value.speedKnots, 20);
    expect(field.points.first.wind.value.fromDegrees, 280);
    expect(field.points.first.wind.source.kind, MarineDataKind.forecast);
    expect(field.points.first.wind.unit, 'kn, degrees from');
    expect(requested!.queryParameters['wind_speed_unit'], 'kn');
    expect(requested!.queryParameters['timezone'], 'UTC');
    expect(requested!.queryParameters['start_date'], '2026-08-20');
  });

  test('reuses a fetched hour without another network request', () async {
    var calls = 0;
    final service = OpenMeteoWindFieldService(
      client: MockClient((request) async {
        calls += 1;
        return http.Response(
          jsonEncode({
            'latitude': 50.8,
            'longitude': -1.1,
            'hourly': {
              'time': ['2026-08-20T12:00'],
              'wind_speed_10m': [12],
              'wind_direction_10m': [90],
              'wind_gusts_10m': [18],
            },
          }),
          200,
        );
      }),
    );

    final first = await service.fetch(
      south: 50.8,
      west: -1.1,
      north: 50.8,
      east: -1.1,
      validAt: DateTime.utc(2026, 8, 20, 12),
    );
    final second = await service.fetch(
      south: 50.8,
      west: -1.1,
      north: 50.8,
      east: -1.1,
      validAt: DateTime.utc(2026, 8, 20, 12, 20),
    );

    expect(second, same(first));
    expect(calls, 1);
  });
}
