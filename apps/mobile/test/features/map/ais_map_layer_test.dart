import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/ais_target.dart';
import 'package:tide_and_seek/domain/marine_data.dart';
import 'package:tide_and_seek/domain/route_store.dart';
import 'package:tide_and_seek/features/map/voyage_map.dart';
import 'package:tide_and_seek/services/basemap_configuration.dart';
import 'package:tide_and_seek/services/gpx_import_source.dart';
import 'package:tide_and_seek/services/offline_tile_cache.dart';
import 'package:tide_and_seek/services/route_importer.dart';

void main() {
  testWidgets('received AIS targets show source, age, detail, and disconnect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _cache();
    addTearDown(() {
      cache.dispose();
      cache.rootDirectory.deleteSync(recursive: true);
    });
    final source = _FakeAisSource();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: VoyageMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          canEditRoute: false,
          aisTargetSource: source,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(source.started, isTrue);
    expect(find.byKey(const Key('ais-status-pill')), findsOneWidget);
    expect(find.byKey(const Key('ais-target-layer')), findsOneWidget);
    expect(find.byKey(const ValueKey('ais-target-235001234')), findsOneWidget);

    await _tapTarget(tester);
    await tester.pumpAndSettle();
    expect(find.text('TEST VESSEL'), findsOneWidget);
    expect(find.textContaining('RECEIVED · age'), findsOneWidget);
    expect(find.textContaining('no CPA/TCPA'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const Key('ais-target-freshness'))),
    ).pop();
    await tester.pumpAndSettle();

    source.emit(connected: false);
    await tester.pumpAndSettle();
    expect(find.textContaining('AIS DISCONNECTED'), findsOneWidget);
    await _tapTarget(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('STALE · age'), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const Key('ais-target-freshness'))),
    ).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('ais-status-pill')));
    await tester.pumpAndSettle();
    expect(find.text('Received AIS'), findsOneWidget);
    expect(find.textContaining('AIS is incomplete'), findsOneWidget);
    Navigator.of(tester.element(find.text('Received AIS'))).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bundled AIS replay is visibly synthetic and can be stopped', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _cache();
    addTearDown(() {
      cache.dispose();
      cache.rootDirectory.deleteSync(recursive: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: VoyageMapScreen(
          routeStore: InMemoryRouteStore(),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          canEditRoute: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('map-layer-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Start AIS replay demo'), findsOneWidget);
    await tester.tap(find.text('Start AIS replay demo'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 8));

    expect(find.textContaining('AIS REPLAY · 3'), findsOneWidget);
    expect(find.byKey(const Key('ais-target-layer')), findsOneWidget);

    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).first),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ais-status-pill')));
    await tester.pumpAndSettle();
    expect(find.text('AIS replay demo'), findsOneWidget);
    expect(
      find.text('These are synthetic test vessels, not live traffic.'),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.text('AIS replay demo'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('map-layer-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop AIS replay demo'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ais-status-pill')), findsNothing);
    expect(find.byKey(const Key('ais-target-layer')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _tapTarget(WidgetTester tester) async {
  final target = find.byKey(const ValueKey('ais-target-235001234'));
  final gesture = find.descendant(
    of: target,
    matching: find.byType(GestureDetector),
  );
  await tester.tap(gesture.last);
}

OfflineTileCache _cache() {
  final directory = Directory.systemTemp.createTempSync('ais-map-layer');
  return OfflineTileCache(
    rootDirectory: directory,
    configuration: const BasemapConfiguration(),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
}

class _FakeAisSource implements AisTargetSource {
  final _snapshots = StreamController<AisTargetSnapshot>.broadcast();
  bool started = false;

  static const _source = MarineDataSource(
    id: 'test-local-ais',
    displayName: 'Test on-board AIS',
    kind: MarineDataKind.observation,
    authority: MarineDataAuthority.onboard,
    licence: MarineDataLicence(
      name: 'Local test data',
      attribution: 'Test receiver',
    ),
  );

  @override
  AisSourceKind get kind => AisSourceKind.localNmea;

  @override
  MarineDataSource get source => _source;

  @override
  Stream<AisTargetSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> start() async {
    started = true;
    emit(connected: true);
  }

  @override
  Future<void> stop() async => started = false;

  void emit({required bool connected}) {
    final now = DateTime.now().toUtc();
    final target = AisTarget(
      mmsi: 235001234,
      name: 'TEST VESSEL',
      callSign: 'MFA123',
      latitude: 50.8,
      longitude: -1.28,
      speedOverGroundKnots: 7.4,
      courseOverGroundDegrees: 120,
      headingDegrees: 118,
      navigationStatus: 'Under way sailing',
      positionReportedAt: now,
      receivedAt: now,
    );
    _snapshots.add(
      AisTargetSnapshot(
        sourceKind: AisSourceKind.localNmea,
        receivedAt: now,
        source: _source,
        connectionState: connected
            ? AisConnectionState.connected
            : AisConnectionState.disconnected,
        warning: 'Received AIS targets only.',
        targets: [
          MarineDatum(
            value: target,
            source: _source,
            validAt: now,
            receivedAt: now,
            staleAfter: connected ? const Duration(minutes: 2) : Duration.zero,
          ),
        ],
      ),
    );
  }

  Future<void> dispose() async => _snapshots.close();
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
