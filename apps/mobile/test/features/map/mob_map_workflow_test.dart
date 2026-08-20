import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/mob_state.dart';
import 'package:tide_and_seek/domain/route_store.dart';
import 'package:tide_and_seek/features/map/voyage_map.dart';
import 'package:tide_and_seek/services/basemap_configuration.dart';
import 'package:tide_and_seek/services/gpx_import_source.dart';
import 'package:tide_and_seek/services/offline_tile_cache.dart';
import 'package:tide_and_seek/services/route_importer.dart';

void main() {
  testWidgets('MOB is guarded, fixed on the chart, and explicitly resolved', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _cache();
    addTearDown(() {
      cache.dispose();
      cache.rootDirectory.deleteSync(recursive: true);
    });
    final navigation = ValueNotifier<MapNavigationPosition?>(
      MapNavigationPosition(
        point: const GeoPoint(latitude: 50.801, longitude: -1.284),
        recordedAt: DateTime.now().toUtc(),
        accuracyMeters: 6,
      ),
    );
    addTearDown(navigation.dispose);
    MobFix? activatedFix;
    MobResolution? resolution;

    await tester.pumpWidget(
      MaterialApp(
        home: _MobHarness(
          cache: cache,
          navigation: navigation,
          onActivated: (fix) => activatedFix = fix,
          onResolved: (value) => resolution = value,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mob-button')));
    await tester.pumpAndSettle();

    expect(find.text('Mark man overboard?'), findsOneWidget);
    expect(
      find.textContaining('does not send a distress alert'),
      findsOneWidget,
    );
    expect(activatedFix, isNull);

    await tester.tap(find.byKey(const Key('confirm-mob-activation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(activatedFix?.source, 'gnss');
    expect(activatedFix?.stale, isFalse);
    expect(activatedFix?.accuracyMeters, 6);
    expect(find.byKey(const Key('mob-marker-layer')), findsOneWidget);
    expect(find.byKey(const Key('mob-recovery-card')), findsOneWidget);
    expect(find.textContaining('No distress alert was sent'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('resolve-mob-button')));
    await tester.tap(find.byKey(const Key('resolve-mob-button')));
    await tester.pumpAndSettle();
    expect(find.text('Resolve MOB incident?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('resolve-mob-false-alarm')));
    await tester.pumpAndSettle();

    expect(resolution, MobResolution.falseAlarm);
    expect(find.byKey(const Key('mob-recovery-card')), findsNothing);
    expect(find.byKey(const Key('mob-marker-layer')), findsNothing);
  });

  testWidgets('MOB still records honestly when no position is available', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(844, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cache = _cache();
    addTearDown(() {
      cache.dispose();
      cache.rootDirectory.deleteSync(recursive: true);
    });
    MobFix? activatedFix;

    await tester.pumpWidget(
      MaterialApp(
        home: _MobHarness(
          cache: cache,
          onActivated: (fix) => activatedFix = fix,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mob-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No position is available'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-mob-activation')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(activatedFix?.source, 'none');
    expect(activatedFix?.stale, isTrue);
    expect(activatedFix?.hasPosition, isFalse);
    expect(find.byKey(const Key('mob-recovery-card')), findsOneWidget);
    expect(find.byKey(const Key('mob-marker-layer')), findsNothing);
    expect(
      find.text('No chart position was available when MOB was marked.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('resolve-mob-button')));
    await tester.tap(find.byKey(const Key('resolve-mob-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('resolve-mob-recovered')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

OfflineTileCache _cache() {
  final directory = Directory.systemTemp.createTempSync('mob-map-workflow');
  return OfflineTileCache(
    rootDirectory: directory,
    configuration: const BasemapConfiguration(),
    httpClient: MockClient((_) async => http.Response('', 404)),
  );
}

class _MobHarness extends StatefulWidget {
  const _MobHarness({
    required this.cache,
    required this.onActivated,
    this.navigation,
    this.onResolved,
  });

  final OfflineTileCache cache;
  final ValueNotifier<MapNavigationPosition?>? navigation;
  final ValueChanged<MobFix> onActivated;
  final ValueChanged<MobResolution>? onResolved;

  @override
  State<_MobHarness> createState() => _MobHarnessState();
}

class _MobHarnessState extends State<_MobHarness> {
  MobState _mobState = const MobState();

  @override
  Widget build(BuildContext context) => VoyageMapScreen(
    routeStore: InMemoryRouteStore(),
    routeImporter: RouteImporter(source: const _NoFileSource()),
    offlineTileCache: widget.cache,
    navigationPosition: widget.navigation,
    canEditRoute: false,
    voyageStarted: true,
    mobState: _mobState,
    onActivateMob: (fix) async {
      widget.onActivated(fix);
      setState(() {
        _mobState = MobState(
          activeIncident: MobIncident(
            activationEventId: 'mob-event',
            activatedAt: DateTime.now().toUtc(),
            activatedByDeviceId: 'local-sailor',
            fix: fix,
          ),
        );
      });
      return true;
    },
    onResolveMob: (resolution) async {
      widget.onResolved?.call(resolution);
      setState(() => _mobState = const MobState());
      return true;
    },
  );
}

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
