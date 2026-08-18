import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/map/marine_forecast_panel.dart';
import 'package:tide_and_seek/services/marine_forecast.dart';

/// #12. The panel's job is to be honest about a number nobody measured: it is all
/// model output, its run time is not published, and it can be hours old.
void main() {
  final now = DateTime.utc(2026, 8, 18, 15, 30);

  MarineForecast forecastAt({
    Duration age = const Duration(minutes: 15),
    double? wind = 7.8,
    double? gust = 16.9,
    double? direction = 267,
    double? wave = 0.8,
    double? visibility = 35660,
  }) => MarineForecast(
    latitude: 50.72,
    longitude: -1.45,
    validAt: now.subtract(age),
    fetchedAt: now,
    windSpeedKnots: wind,
    windGustKnots: gust,
    windFromDegrees: direction,
    pressureHectopascals: 1010.9,
    visibilityMeters: visibility,
    temperatureCelsius: 26.2,
    waveHeightMeters: wave,
    wavePeriodSeconds: wave == null ? null : 4.1,
    waveFromDegrees: wave == null ? null : 237,
  );

  Future<void> pump(
    WidgetTester tester, {
    MarineForecast? forecast,
    ForecastException? failure,
  }) async {
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarineForecastPanel(
              forecast: forecast,
              failure: failure,
              now: now,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // The two claims this panel must never make.
  group('honesty about what this is', () {
    testWidgets('says it is a forecast, not an observation', (tester) async {
      await pump(tester, forecast: forecastAt());
      expect(
        find.byKey(const Key('marine-forecast-not-observed')),
        findsOneWidget,
      );
      expect(find.textContaining('not an observation'), findsOneWidget);
    });

    testWidgets('says the forecast run is not published', (tester) async {
      // Checked against the live API: only a validity time is available.
      await pump(tester, forecast: forecastAt());
      expect(
        find.byKey(const Key('marine-forecast-no-run-time')),
        findsOneWidget,
      );
    });

    testWidgets('attributes Open-Meteo, as CC BY 4.0 requires', (tester) async {
      await pump(tester, forecast: forecastAt());
      expect(find.textContaining('Open-Meteo'), findsOneWidget);
      expect(find.textContaining('CC BY 4.0'), findsOneWidget);
    });
  });

  group('wind', () {
    testWidgets('reads from a compass point, in knots and Beaufort', (
      tester,
    ) async {
      await pump(tester, forecast: forecastAt());
      // 267 degrees is a westerly; 7.8 knots is a force 3. Asserted on the wind
      // line itself, because the wave line also reads "from WSW".
      final wind = tester.widget<Text>(
        find.byKey(const Key('marine-forecast-wind')),
      );
      expect(wind.data, 'from W · 8 kn · force 3');
    });

    testWidgets('gusts get their own line', (tester) async {
      // 18 knots gusting 30 is the difference between a good sail and a reef.
      await pump(tester, forecast: forecastAt(wind: 18, gust: 30));
      expect(find.text('gusting 30 kn'), findsOneWidget);
    });

    testWidgets('a forecast without wind says so', (tester) async {
      await pump(tester, forecast: forecastAt(wind: null, gust: null));
      expect(find.byKey(const Key('marine-forecast-no-wind')), findsOneWidget);
    });
  });

  group('sea state', () {
    testWidgets('is labelled as a modelled wave, with its limits', (
      tester,
    ) async {
      await pump(tester, forecast: forecastAt());
      expect(find.text('FORECAST WAVE'), findsOneWidget);
      expect(find.textContaining('0.8 m'), findsOneWidget);
      // The caveat that matters near a lee shore or in a tide race.
      expect(find.textContaining('tide race'), findsOneWidget);
    });

    testWidgets('absence is ordinary, not a fault', (tester) async {
      await pump(tester, forecast: forecastAt(wave: null));
      expect(
        find.byKey(const Key('marine-forecast-no-sea-state')),
        findsOneWidget,
      );
      // The wind survives the waves being missing.
      expect(find.byKey(const Key('marine-forecast-wind')), findsOneWidget);
    });
  });

  group('age', () {
    testWidgets('a recent forecast reports its age plainly', (tester) async {
      await pump(tester, forecast: forecastAt());
      expect(find.text('Valid 15 min ago'), findsOneWidget);
    });

    testWidgets('an old forecast is flagged rather than quietly shown', (
      tester,
    ) async {
      await pump(tester, forecast: forecastAt(age: const Duration(hours: 7)));
      final age = tester.widget<Text>(
        find.byKey(const Key('marine-forecast-age')),
      );
      expect(age.style?.color, const Color(0xFFE8A33D));
      expect(age.style?.fontWeight, FontWeight.w700);
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    });
  });

  group('visibility', () {
    testWidgets('reads in miles offshore and metres in fog', (tester) async {
      await pump(tester, forecast: forecastAt(visibility: 35660));
      expect(find.text('19 NM'), findsOneWidget);

      await pump(tester, forecast: forecastAt(visibility: 400));
      expect(find.text('400 m'), findsOneWidget);
    });
  });

  group('no forecast at all', () {
    testWidgets('an unreachable provider is reported in plain words', (
      tester,
    ) async {
      await pump(
        tester,
        failure: const ForecastException(
          ForecastFailure.unreachable,
          'SocketException',
        ),
      );
      expect(
        find.byKey(const Key('marine-forecast-unavailable')),
        findsOneWidget,
      );
      expect(find.textContaining('could not reach'), findsOneWidget);
      // No figures invented in its place.
      expect(find.byKey(const Key('marine-forecast-wind')), findsNothing);
    });

    testWidgets('a refusal says so without blaming the sailor', (tester) async {
      await pump(
        tester,
        failure: const ForecastException(ForecastFailure.refused, '429'),
      );
      expect(find.textContaining('declined the request'), findsOneWidget);
    });
  });
}
