import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/ais_target.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/services/ais_nmea.dart';

void main() {
  final fixture = File('assets/replay/solent_ais.nmea')
      .readAsLinesSync()
      .where((line) => line.startsWith('!'))
      .toList(growable: false);

  test('decodes fragmented static data and Class A/B positions', () {
    final decoder = AisNmeaDecoder.replay();
    final start = DateTime.utc(2026, 8, 20, 12);
    for (final (index, sentence) in fixture.indexed) {
      decoder.ingest(sentence, receivedAt: start.add(Duration(seconds: index)));
    }

    final snapshot = decoder.snapshot(
      receivedAt: start.add(const Duration(seconds: 12)),
    );
    expect(snapshot.connectionState, AisConnectionState.connected);
    expect(snapshot.targets, hasLength(3));
    expect(snapshot.warning, contains('Received AIS targets only'));

    final ferry = snapshot.targets
        .map((datum) => datum.value)
        .singleWhere((target) => target.mmsi == 235000111);
    expect(ferry.name, 'SOLENT FERRY');
    expect(ferry.callSign, 'MFA111');
    expect(ferry.shipType, 60);
    expect(ferry.latitude, closeTo(50.8012, 0.000001));
    expect(ferry.longitude, closeTo(-1.2960, 0.000001));
    expect(ferry.speedOverGroundKnots, 12.5);
    expect(ferry.courseOverGroundDegrees, 92);
    expect(ferry.headingDegrees, 91);
    expect(ferry.navigationStatus, 'Under way using engine');
    expect(ferry.positionReportedAt, isNotNull);

    final sailingBoat = snapshot.targets
        .map((datum) => datum.value)
        .singleWhere((target) => target.mmsi == 235000222);
    expect(sailingBoat.name, 'SEA BREEZE');
    expect(sailingBoat.callSign, 'MFA222');
    expect(sailingBoat.shipType, 36);
    expect(sailingBoat.latitude, closeTo(50.7888, 0.000001));
    expect(sailingBoat.longitude, closeTo(-1.2720, 0.000001));
  });

  test('rejects corrupt input, duplicates, and out-of-order positions', () {
    final decoder = AisNmeaDecoder.replay();
    final start = DateTime.utc(2026, 8, 20, 12);
    final older = fixture[6];
    final newer = fixture[9];

    expect(
      decoder.ingest(newer, receivedAt: start.add(const Duration(minutes: 2))),
      isTrue,
    );
    expect(
      decoder.ingest(older, receivedAt: start.add(const Duration(minutes: 1))),
      isFalse,
    );
    expect(
      decoder.ingest(newer, receivedAt: start.add(const Duration(minutes: 2))),
      isFalse,
    );
    expect(
      decoder.ingest(
        '${newer.substring(0, newer.length - 2)}00',
        receivedAt: start.add(const Duration(minutes: 3)),
      ),
      isFalse,
    );

    final target = decoder
        .snapshot(receivedAt: start.add(const Duration(minutes: 2)))
        .targets
        .single
        .value;
    expect(target.latitude, closeTo(50.8012, 0.000001));
    expect(target.longitude, closeTo(-1.2960, 0.000001));
  });

  test('marks disconnected targets stale and expires old targets', () {
    final decoder = AisNmeaDecoder.localNmea();
    final start = DateTime.utc(2026, 8, 20, 12);
    expect(decoder.ingest(fixture[6], receivedAt: start), isTrue);

    final disconnected = decoder.snapshot(
      connectionState: AisConnectionState.disconnected,
      receivedAt: start.add(const Duration(seconds: 1)),
    );
    expect(disconnected.connected, isFalse);
    expect(
      disconnected.targets.single.freshnessAt(
        start.add(const Duration(seconds: 1)),
      ),
      MarineDataFreshness.stale,
    );
    expect(disconnected.targets.single.qualityNote, contains('not live'));

    final expired = decoder.snapshot(
      connectionState: AisConnectionState.connected,
      receivedAt: start.add(const Duration(minutes: 11)),
    );
    expect(expired.targets, isEmpty);
  });

  test('replay source emits deterministic synthetic targets', () async {
    final source = ReplayAisTargetSource(
      loadFixture: () async =>
          File('assets/replay/solent_ais.nmea').readAsString(),
      interval: const Duration(milliseconds: 1),
    );
    addTearDown(source.dispose);
    final complete = source.snapshots.firstWhere(
      (snapshot) => snapshot.targets.length == 3,
    );

    await source.start();
    final snapshot = await complete.timeout(const Duration(seconds: 2));

    expect(snapshot.sourceKind, AisSourceKind.replay);
    expect(snapshot.connectionState, AisConnectionState.replay);
    expect(snapshot.source.displayName, 'Bundled AIS replay');
    await source.stop();
  });

  test(
    'local TCP source connects and reconnects without an internet feed',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      var connectionCount = 0;
      server.listen((socket) async {
        connectionCount += 1;
        socket.writeln(fixture[6]);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await socket.close();
      });
      final source = NmeaTcpAisTargetSource(
        configuration: AisNmeaTcpConfiguration(
          host: InternetAddress.loopbackIPv4.address,
          port: server.port,
        ),
        reconnectDelay: const Duration(milliseconds: 10),
      );
      addTearDown(source.dispose);
      final states = <AisConnectionState>[];
      final reconnected = Completer<void>();
      final subscription = source.snapshots.listen((snapshot) {
        states.add(snapshot.connectionState);
        if (states
                    .where((state) => state == AisConnectionState.connected)
                    .length >=
                3 &&
            !reconnected.isCompleted) {
          reconnected.complete();
        }
      });
      addTearDown(subscription.cancel);

      await source.start();
      await reconnected.future.timeout(const Duration(seconds: 2));

      expect(connectionCount, greaterThanOrEqualTo(1));
      expect(states, contains(AisConnectionState.disconnected));
      expect(states, contains(AisConnectionState.reconnecting));
      await source.stop();
    },
  );
}
