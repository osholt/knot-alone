import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/domain/wind_field.dart';
import 'package:tide_and_seek/features/map/wind_field_panel.dart';
import 'package:tide_and_seek/services/open_meteo_wind_field.dart';

void main() {
  testWidgets('labels the grid as forecast and exposes time controls', (
    tester,
  ) async {
    var previous = 0;
    var next = 0;
    var now = 0;
    final validAt = DateTime.utc(2026, 8, 20, 13);
    final field = WindField(
      points: [
        WindFieldPoint(
          latitude: 50.8,
          longitude: -1.1,
          wind: MarineDatum(
            value: const WindVector(
              speedKnots: 14,
              fromDegrees: 270,
              gustKnots: 20,
            ),
            source: OpenMeteoWindFieldService.windSource,
            validAt: validAt,
            receivedAt: validAt,
            staleAfter: const Duration(hours: 2),
            unit: 'kn, degrees from',
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WindFieldPanel(
            field: field,
            failure: null,
            selectedAt: validAt,
            loading: false,
            onPrevious: () => previous += 1,
            onNext: () => next += 1,
            onNow: () => now += 1,
          ),
        ),
      ),
    );

    expect(find.textContaining('model forecast'), findsOneWidget);
    expect(find.text('14 kn'), findsOneWidget);
    expect(find.text('gust 20'), findsOneWidget);
    expect(find.textContaining('Open-Meteo.com'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wind-time-previous')));
    await tester.tap(find.byKey(const Key('wind-time-next')));
    await tester.tap(find.byKey(const Key('wind-time-now')));
    expect((previous, next, now), (1, 1, 1));
  });
}
