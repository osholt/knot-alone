import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/services/marine_forecast.dart';

/// #12. Fixtures are real Open-Meteo responses captured from the live API, so the
/// parsing is tested against what the provider actually sends rather than what a
/// hand-written fixture assumes.
void main() {
  final now = DateTime.utc(2026, 8, 18, 15, 30);

  // Captured from api.open-meteo.com for 50.72,-1.45 with wind_speed_unit=kn.
  const weatherBody =
      '{"latitude":50.70345,"longitude":-1.4499207,'
      '"generationtime_ms":0.629,"utc_offset_seconds":0,"timezone":"GMT",'
      '"current_units":{"time":"iso8601","interval":"seconds",'
      '"wind_speed_10m":"kn","wind_direction_10m":"°","wind_gusts_10m":"kn",'
      '"pressure_msl":"hPa","visibility":"m","temperature_2m":"°C"},'
      '"current":{"time":"2026-08-18T15:15","interval":900,'
      '"wind_speed_10m":7.8,"wind_direction_10m":267,"wind_gusts_10m":16.9,'
      '"pressure_msl":1010.9,"visibility":35660.00,"temperature_2m":26.2}}';

  // Captured from marine-api.open-meteo.com for the same position.
  const marineBody =
      '{"latitude":50.708336,"longitude":-1.4583282,'
      '"generationtime_ms":0.285,"utc_offset_seconds":0,"timezone":"GMT",'
      '"current_units":{"time":"iso8601","interval":"seconds",'
      '"wave_height":"m","wave_direction":"°","wave_period":"s"},'
      '"current":{"time":"2026-08-18T15:15","interval":900,'
      '"wave_height":0.80,"wave_direction":237,"wave_period":4.10}}';

  OpenMeteoForecastService serviceWith(
    Future<http.Response> Function(http.Request) handler,
  ) => OpenMeteoForecastService(client: MockClient(handler));

  OpenMeteoForecastService healthyService({List<Uri>? requested}) =>
      serviceWith((request) async {
        requested?.add(request.url);
        return http.Response(
          request.url.host.startsWith('marine') ? marineBody : weatherBody,
          200,
        );
      });

  group('a healthy forecast', () {
    test('reads wind, pressure, visibility and sea state', () async {
      final forecast = await healthyService().fetch(
        latitude: 50.72,
        longitude: -1.45,
        now: now,
      );

      expect(forecast.windSpeedKnots, 7.8);
      expect(forecast.windGustKnots, 16.9);
      expect(forecast.windFromDegrees, 267);
      expect(forecast.pressureHectopascals, 1010.9);
      expect(forecast.visibilityMeters, 35660);
      expect(forecast.temperatureCelsius, 26.2);

      expect(forecast.waveHeightMeters, 0.8);
      expect(forecast.wavePeriodSeconds, 4.1);
      expect(forecast.waveFromDegrees, 237);
      expect(forecast.hasSeaState, isTrue);
    });

    test('asks for knots at source rather than converting', () async {
      // A conversion here is a chance to disagree with what the provider meant.
      final requested = <Uri>[];
      await healthyService(
        requested: requested,
      ).fetch(latitude: 50.72, longitude: -1.45, now: now);

      final weather = requested.firstWhere(
        (uri) => !uri.host.startsWith('marine'),
      );
      expect(weather.queryParameters['wind_speed_unit'], 'kn');
      expect(weather.queryParameters['timezone'], 'UTC');
    });

    test(
      'carries the validity time and its age, not a server timing',
      () async {
        final forecast = await healthyService().fetch(
          latitude: 50.72,
          longitude: -1.45,
          now: now,
        );

        // 15:15 valid, fetched at 15:30.
        expect(forecast.validAt, DateTime.utc(2026, 8, 18, 15, 15));
        expect(forecast.ageAt(now), const Duration(minutes: 15));
        expect(forecast.fetchedAt, now);
      },
    );

    test(
      'a forecast valid slightly ahead of now is not negatively aged',
      () async {
        final forecast = await healthyService().fetch(
          latitude: 50.72,
          longitude: -1.45,
          now: DateTime.utc(2026, 8, 18, 15),
        );
        expect(forecast.ageAt(DateTime.utc(2026, 8, 18, 15)), Duration.zero);
      },
    );
  });

  group('sea state absent', () {
    test('an inland position keeps its wind when waves fail', () async {
      // The marine host has nothing for an inland point. Losing waves must not
      // lose the wind with them.
      final forecast = await serviceWith((request) async {
        if (request.url.host.startsWith('marine')) {
          return http.Response('{"error":true}', 400);
        }
        return http.Response(weatherBody, 200);
      }).fetch(latitude: 52.2, longitude: -1.5, now: now);

      expect(forecast.hasWind, isTrue);
      expect(forecast.windSpeedKnots, 7.8);
      expect(forecast.hasSeaState, isFalse);
      expect(forecast.waveHeightMeters, isNull);
    });

    test('a marine host that times out is also survivable', () async {
      final forecast = await serviceWith((request) async {
        if (request.url.host.startsWith('marine')) {
          throw const SocketExceptionStub();
        }
        return http.Response(weatherBody, 200);
      }).fetch(latitude: 50.72, longitude: -1.45, now: now);

      expect(forecast.hasWind, isTrue);
      expect(forecast.hasSeaState, isFalse);
    });
  });

  group('failures say which kind', () {
    test('an unreachable provider is ordinary, not an error state', () async {
      // No uptime guarantee on the free tier, and no signal at sea.
      await expectLater(
        serviceWith(
          (_) async => throw const SocketExceptionStub(),
        ).fetch(latitude: 50.72, longitude: -1.45, now: now),
        throwsA(
          isA<ForecastException>()
              .having((e) => e.failure, 'failure', ForecastFailure.unreachable)
              .having(
                (e) => e.sailorMessage,
                'message',
                contains('could not reach'),
              ),
        ),
      );
    });

    test('a rate-limited provider is reported as refused', () async {
      await expectLater(
        serviceWith(
          (_) async => http.Response('slow down', 429),
        ).fetch(latitude: 50.72, longitude: -1.45, now: now),
        throwsA(
          isA<ForecastException>().having(
            (e) => e.failure,
            'failure',
            ForecastFailure.refused,
          ),
        ),
      );
    });

    test('nonsense is reported as unreadable, not as unreachable', () async {
      for (final body in ['not json', '[]', '{"current":"nope"}']) {
        await expectLater(
          serviceWith(
            (_) async => http.Response(body, 200),
          ).fetch(latitude: 50.72, longitude: -1.45, now: now),
          throwsA(
            isA<ForecastException>().having(
              (e) => e.failure,
              'failure',
              ForecastFailure.unreadable,
            ),
          ),
          reason: body,
        );
      }
    });

    test('a missing or unparseable valid time is unreadable', () async {
      await expectLater(
        serviceWith(
          (_) async => http.Response('{"current":{"wind_speed_10m":5}}', 200),
        ).fetch(latitude: 50.72, longitude: -1.45, now: now),
        throwsA(isA<ForecastException>()),
      );
    });
  });

  group('reading the numbers aloud', () {
    test('Beaufort force follows the published bounds', () {
      MarineForecast at(double knots) => MarineForecast(
        latitude: 50,
        longitude: -1,
        validAt: now,
        fetchedAt: now,
        windSpeedKnots: knots,
      );

      // Against the published table: F1 is 1-3 kn, F2 is 4-6, F3 is 7-10,
      // F4 is 11-16, F5 is 17-21, F6 is 22-27, F8 is 34-40.
      expect(at(0).beaufortForce, 0, reason: 'calm');
      expect(at(0.9).beaufortForce, 0);
      expect(at(1).beaufortForce, 1);
      expect(at(3).beaufortForce, 1);
      expect(at(4).beaufortForce, 2);
      expect(at(10).beaufortForce, 3);
      expect(at(16).beaufortForce, 4);
      expect(at(21).beaufortForce, 5);
      // The one a sailor cares about: 22 knots is a six, reef before it.
      expect(at(22).beaufortForce, 6);
      expect(at(40).beaufortForce, 8);
      expect(at(64).beaufortForce, 12);
      expect(at(90).beaufortForce, 12);
    });

    test('a compass point is given for a direction', () {
      expect(MarineForecast.compassPoint(0), 'N');
      expect(MarineForecast.compassPoint(90), 'E');
      expect(MarineForecast.compassPoint(267), 'W');
      expect(MarineForecast.compassPoint(237), 'WSW');
      expect(MarineForecast.compassPoint(359), 'N');
      expect(MarineForecast.compassPoint(null), isNull);
    });

    test('attribution is present, because CC BY requires it', () {
      expect(OpenMeteoForecastService.attribution, contains('Open-Meteo'));
      expect(OpenMeteoForecastService.attribution, contains('CC BY 4.0'));
    });
  });
}

/// A stand-in for a network failure, so the tests do not depend on dart:io.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketExceptionStub';
}
