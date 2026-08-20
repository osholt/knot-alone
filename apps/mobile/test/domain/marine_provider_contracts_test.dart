import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/ais_target.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/domain/tide.dart';
import 'package:tide_and_seek/domain/wind_field.dart';

const _source = MarineDataSource(
  id: 'test',
  displayName: 'Test source',
  kind: MarineDataKind.prediction,
  authority: MarineDataAuthority.provider,
  licence: MarineDataLicence(name: 'Test licence', attribution: 'Test data'),
);

void main() {
  test('prediction and field collections cannot be mutated by callers', () {
    final tidePoints = <MarineDatum<TideHeight>>[];
    final prediction = TidePrediction(
      station: const TideStation(
        id: 'station',
        name: 'Station',
        latitude: 50,
        longitude: -1,
        datum: 'Chart Datum',
        source: _source,
      ),
      points: tidePoints,
      extremes: const [],
    );
    tidePoints.add(
      MarineDatum(
        value: const TideHeight(meters: 2),
        source: _source,
        validAt: DateTime.utc(2026),
        receivedAt: DateTime.utc(2026),
        staleAfter: const Duration(minutes: 20),
      ),
    );

    final windPoints = <WindFieldPoint>[];
    final field = WindField(points: windPoints);
    windPoints.add(
      WindFieldPoint(
        latitude: 50,
        longitude: -1,
        wind: MarineDatum(
          value: const WindVector(speedKnots: 12, fromDegrees: 270),
          source: _source,
          validAt: DateTime.utc(2026),
          receivedAt: DateTime.utc(2026),
          staleAfter: const Duration(hours: 2),
        ),
      ),
    );

    expect(prediction.points, isEmpty);
    expect(field.points, isEmpty);
  });

  test('AIS targets preserve COG, SOG and heading as distinct values', () {
    final target = AisTarget(
      mmsi: 232000000,
      name: 'TEST VESSEL',
      latitude: 50.8,
      longitude: -1.1,
      courseOverGroundDegrees: 92,
      speedOverGroundKnots: 6.5,
      headingDegrees: 87,
      receivedAt: DateTime.utc(2026),
    );

    expect(target.courseOverGroundDegrees, 92);
    expect(target.speedOverGroundKnots, 6.5);
    expect(target.headingDegrees, 87);
  });
}
