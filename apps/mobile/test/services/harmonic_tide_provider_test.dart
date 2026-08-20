import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/services/harmonic_tide_provider.dart';

void main() {
  late BundledHarmonicTideProvider provider;

  setUpAll(() {
    provider = BundledHarmonicTideProvider.fromJson(
      File(BundledHarmonicTideProvider.assetPath).readAsStringSync(),
      clock: () => DateTime.utc(2026, 8, 19, 23),
    );
  });

  test('bundles only attributed LAT reference stations', () {
    expect(provider.stations.map((station) => station.name), [
      'Lymington',
      'Portsmouth',
      'Southampton',
    ]);
    for (final station in provider.stations) {
      expect(station.datum, 'LAT');
      expect(station.source.licence.name, 'CC BY 4.0');
      expect(station.source.kind, MarineDataKind.prediction);
      expect(station.source.licence.permitsOfflineCache, isTrue);
    }
  });

  test('nearest station selection is bounded and distance ordered', () async {
    final nearPortsmouth = await provider.stationsNear(
      latitude: 50.80,
      longitude: -1.10,
      limitKilometers: 35,
    );

    expect(nearPortsmouth.first.name, 'Portsmouth');
    expect(nearPortsmouth.map((station) => station.name), [
      'Portsmouth',
      'Southampton',
      'Lymington',
    ]);
    expect(
      await provider.stationsNear(
        latitude: 58,
        longitude: -4,
        limitKilometers: 10,
      ),
      isEmpty,
    );
  });

  test('matches pinned Neaps 0.11 timeline goldens', () async {
    const expected = <String, List<double>>{
      'Lymington': [
        1.6825662920121598,
        2.3544769104503795,
        1.6834728248477426,
        2.4975062214871273,
        1.590838384962257,
      ],
      'Portsmouth': [
        2.0060939392163637,
        3.264985200150829,
        2.0005816052561185,
        3.4397840294059,
        1.8930863485575846,
      ],
      'Southampton': [
        2.1447416280252276,
        3.5225650497596614,
        2.198825534352553,
        3.6378971093268966,
        2.110661267286313,
      ],
    };

    for (final station in provider.stations) {
      final prediction = await provider.predict(
        station: station,
        start: DateTime.utc(2026, 8, 20),
        end: DateTime.utc(2026, 8, 21),
        interval: const Duration(hours: 6),
      );
      expect(prediction.points, hasLength(5));
      for (var index = 0; index < prediction.points.length; index += 1) {
        expect(
          prediction.points[index].value.meters,
          closeTo(expected[station.name]![index], 1e-9),
          reason: '${station.name} point $index',
        );
      }
    }
  });

  test('calculates a useful offline curve and next high/low events', () async {
    final station = provider.stations.first;
    final prediction = await provider.predict(
      station: station,
      start: DateTime.utc(2026, 8, 20),
      end: DateTime.utc(2026, 8, 21),
    );

    expect(prediction.points, hasLength(145));
    expect(prediction.extremes, hasLength(4));
    expect(
      prediction.extremes.first.at
          .difference(DateTime.utc(2026, 8, 20, 4, 3, 13))
          .abs(),
      lessThan(const Duration(minutes: 1)),
    );
    expect(prediction.extremes.first.height.meters, closeTo(2.4691, 0.002));
    expect(
      prediction.points.first.qualityNote,
      contains('Not official or observed'),
    );
    expect(
      prediction.points.first.freshnessAt(DateTime.utc(2026, 8, 20)),
      MarineDataFreshness.current,
    );
  });
}
