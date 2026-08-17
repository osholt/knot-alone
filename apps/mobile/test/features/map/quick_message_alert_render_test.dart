import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/distance_unit.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/domain/quick_message.dart';
import 'package:tide_and_seek/domain/route_store.dart';
import 'package:tide_and_seek/domain/route_alert.dart';
import 'package:tide_and_seek/features/map/voyage_map.dart';
import 'package:tide_and_seek/services/basemap_configuration.dart';
import 'package:tide_and_seek/services/gpx_import_source.dart';
import 'package:tide_and_seek/services/skipper_voyage_status.dart';
import 'package:tide_and_seek/services/offline_tile_cache.dart';
import 'package:tide_and_seek/services/received_quick_message.dart';
import 'package:tide_and_seek/services/route_importer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rasterised frames of #151's alert surfaces, for a person to look at.
///
/// Assertions have twice this week passed on a surface a phone then disagreed
/// with, so every priority level and both orientations are written out here and
/// read. Regenerate with
/// `flutter test test/features/map/quick_message_alert_render_test.dart`.
///
/// The basemap is deliberately **not** configured, so the map behind the chrome
/// is the local route-only fallback and the development "route-only offline map"
/// badge is present. These frames are evidence about the alert chrome, not about
/// the basemap.
final _imageDirectory = Directory('build/quick-message-alerts');

/// A real font, when the machine running the test has one, so the frames a
/// person looks at carry the actual words rather than the test font's blocks.
///
/// Optional on purpose: CI has no such file, falls back to the block font, and
/// every assertion in this file is about geometry and presence, never glyphs.
const _readableFontCandidates = [
  '/System/Library/Fonts/Supplemental/Arial.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
];
const _readableFontFamily = 'RenderCheck';
String? _loadedFontFamily;

const _portrait = Size(393, 852);
const _landscape = Size(852, 393);
const _renderKey = Key('quick-message-render-boundary');

void main() {
  // Rasterising needs a real async gap, which lets the map's own
  // shared-preferences reads reach the plugin. An in-memory store is what a
  // test has instead.
  setUp(() => SharedPreferences.setMockInitialValues(const {}));

  setUpAll(() async {
    for (final path in _readableFontCandidates) {
      final file = File(path);
      if (!file.existsSync()) continue;
      final loader = FontLoader(_readableFontFamily)
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await loader.load();
      _loadedFontFamily = _readableFontFamily;
      break;
    }
    if (_imageDirectory.existsSync()) {
      _imageDirectory.deleteSync(recursive: true);
    }
    _imageDirectory.createSync(recursive: true);
  });

  for (final orientation in const {
    'portrait': _portrait,
    'landscape': _landscape,
  }.entries) {
    for (final scenario in _scenarios) {
      testWidgets('${scenario.name} renders in ${orientation.key}', (
        tester,
      ) async {
        tester.view.physicalSize = orientation.value;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final directory = Directory.systemTemp.createTempSync('quick-render');
        addTearDown(() => directory.deleteSync(recursive: true));
        final cache = OfflineTileCache(
          rootDirectory: directory,
          configuration: const BasemapConfiguration(),
          httpClient: MockClient((_) async => http.Response('', 404)),
        );
        final navigation = ValueNotifier<MapNavigationPosition?>(
          MapNavigationPosition(
            point: const GeoPoint(latitude: 53, longitude: -1.015),
            recordedAt: DateTime.utc(2026, 7, 26, 12),
            speedMetersPerSecond: 13,
            headingDegrees: 90,
            accuracyMeters: 5,
          ),
        );
        addTearDown(navigation.dispose);
        final skipperStatus = ValueNotifier<SkipperVoyageStatus?>(
          scenario.maximumOverlays
              ? const SkipperVoyageStatus(
                  sweeperName: 'Charlie',
                  distanceToSweeperMeters: 3200,
                  estimatedTimeToSweeper: Duration(minutes: 4),
                  sweeperLocationAge: Duration(seconds: 10),
                  offCourseAlerts: [
                    SkipperOffCourseAlert(
                      sailorId: 'sailor-alex',
                      displayName: 'Alex',
                      level: RouteAlertLevel.urgent,
                      distanceFromRouteMeters: 420,
                    ),
                  ],
                )
              : null,
        );
        addTearDown(skipperStatus.dispose);
        final alerts = ValueNotifier<List<VoyageQuickMessageAlert>>(
          scenario.alerts,
        );
        addTearDown(alerts.dispose);

        await tester.pumpWidget(
          RepaintBoundary(
            key: _renderKey,
            child: MaterialApp(
              theme: ThemeData.dark(
                useMaterial3: true,
              ).copyWith(textTheme: _renderTextTheme),
              home: VoyageMapScreen(
                routeStore: InMemoryRouteStore(_route),
                routeImporter: RouteImporter(source: const _NoFileSource()),
                offlineTileCache: cache,
                navigationPosition: navigation,
                skipperStatus: skipperStatus,
                groupSailorCount: scenario.maximumOverlays ? 3 : null,
                voyagePaused: scenario.maximumOverlays,
                distanceUnit: DistanceUnit.miles,
                quickMessageAlerts: alerts,
                onAcknowledgeQuickMessage: (_) async {},
                onOpenVoyageMenu: () async {},
                onEmergencyAlert: () async {},
                onLeaveVoyage: () async {},
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();

        if (scenario.dismissInterrupt) {
          await tester.tapAt(
            tester.getTopLeft(
                  find.byKey(const Key('quick-message-interrupt')),
                ) +
                const Offset(12, 12),
          );
          await tester.pumpAndSettle();
        }

        if (scenario.pressSos) {
          await tester.tap(find.byKey(const Key('emergency-alert-button')));
          await tester.pumpAndSettle();
          // Past the "alert sent" snack bar, which is transient and otherwise
          // sits over the action row in the frame.
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
        }

        // The surface under test is actually on screen in this frame. Without
        // this the image could be a picture of nothing and still be written.
        expect(
          find.byKey(Key(scenario.expectedKey)),
          findsOneWidget,
          reason: '${scenario.name} did not render in ${orientation.key}',
        );

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_renderKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          File(
            '${_imageDirectory.path}/'
            '${scenario.fileName}-${orientation.key}.png',
          ).writeAsBytesSync(png!.buffer.asUint8List());
        });

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    }
  }
}

TextTheme get _renderTextTheme => _loadedFontFamily == null
    ? ThemeData.dark(useMaterial3: true).textTheme
    : ThemeData.dark(
        useMaterial3: true,
      ).textTheme.apply(fontFamily: _loadedFontFamily);

class _Scenario {
  const _Scenario({
    required this.name,
    required this.fileName,
    required this.expectedKey,
    required this.alerts,
    this.maximumOverlays = false,
    this.pressSos = false,
    this.dismissInterrupt = false,
  });

  final String name;
  final String fileName;
  final String expectedKey;
  final List<VoyageQuickMessageAlert> alerts;

  /// Draws the alert on top of every other surface the map can show at once.
  final bool maximumOverlays;

  /// Raises this sailor's own alert first, so the SOS control's acknowledged
  /// state (#142's "alert acknowledged") is in the frame too.
  final bool pressSos;

  /// Closes the critical interrupt before the frame is taken, so the row it
  /// leaves behind - the persistence a sailor who glances away depends on - is
  /// rendered at its real critical priority rather than a downgraded one.
  final bool dismissInterrupt;
}

final _scenarios = <_Scenario>[
  _Scenario(
    name: 'a routine alert',
    fileName: '1-routine-fuel',
    expectedKey: 'quick-message-alert',
    alerts: [
      _alert(
        eventId: 'fuel-1',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
        origin: const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ],
  ),
  _Scenario(
    name: 'an important alert',
    fileName: '2-important-mechanical',
    expectedKey: 'quick-message-alert',
    alerts: [
      _alert(
        eventId: 'mech-1',
        message: QuickMessage.mechanical,
        senderDisplayName: 'Dee',
        origin: const QuickMessageOrigin(
          distanceMeters: 640,
          alongRoute: false,
          bearingDegrees: 225,
        ),
      ),
      _alert(
        eventId: 'fuel-1',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
        origin: const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ],
  ),
  _Scenario(
    name: 'a critical alert row behind its dismissed interrupt',
    fileName: '3-critical-row',
    expectedKey: 'quick-message-alert',
    dismissInterrupt: true,
    alerts: [
      _alert(
        eventId: 'help-1',
        message: QuickMessage.assistance,
        senderDisplayName: 'Ana',
        origin: const QuickMessageOrigin(
          distanceMeters: 2400,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ],
  ),
  _Scenario(
    name: 'a critical interrupt',
    fileName: '4-critical-interrupt',
    expectedKey: 'quick-message-interrupt',
    alerts: [
      _alert(
        eventId: 'help-1',
        message: QuickMessage.assistance,
        senderDisplayName: 'Ana',
        origin: const QuickMessageOrigin(
          distanceMeters: 2400,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ],
  ),
  _Scenario(
    name: 'the sender receipt',
    fileName: '5-sender-receipt',
    expectedKey: 'quick-message-alert',
    pressSos: true,
    alerts: [
      _alert(
        eventId: 'own-1',
        message: QuickMessage.emergencyStop,
        senderDisplayName: 'Me',
        raisedFromLocalSailor: true,
        acknowledgedBy: 'Ana',
      ),
    ],
  ),
  _Scenario(
    name: 'a routine alert at the maximum overlay count',
    fileName: '6-routine-maximum-overlays',
    expectedKey: 'quick-message-alert',
    maximumOverlays: true,
    alerts: [
      _alert(
        eventId: 'fuel-1',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
        origin: const QuickMessageOrigin(
          distanceMeters: 1931,
          alongRoute: true,
          senderIsBehind: true,
        ),
      ),
    ],
  ),
];

VoyageQuickMessageAlert _alert({
  required String eventId,
  required QuickMessage message,
  required String senderDisplayName,
  QuickMessageOrigin? origin,
  bool raisedFromLocalSailor = false,
  String? acknowledgedBy,
}) => VoyageQuickMessageAlert(
  message: ReceivedQuickMessage(
    eventId: eventId,
    senderSailorId: 'sailor-$eventId',
    senderDisplayName: senderDisplayName,
    label: message.label,
    priority: message.priority,
    raisedAt: DateTime.now().subtract(const Duration(minutes: 2)),
    raisedFromLocalSailor: raisedFromLocalSailor,
    message: message,
    acknowledgements: [
      if (acknowledgedBy != null)
        QuickMessageAcknowledgement(
          sailorId: 'sailor-ack',
          displayName: acknowledgedBy,
          acknowledgedAt: DateTime.now(),
        ),
    ],
  ),
  origin: origin,
);

final _route = ImportedRoute(
  id: 'quick-render',
  name: 'Quick render route',
  importedAt: DateTime.utc(2026, 7, 26),
  sourceFileName: 'quick-render.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 53, longitude: -1.02),
        GeoPoint(latitude: 53, longitude: -1.01),
        GeoPoint(latitude: 53, longitude: -1),
      ],
    ),
  ],
  waypoints: const [],
  maneuvers: const [
    RouteManeuver(
      position: GeoPoint(latitude: 53, longitude: -1.005),
      type: 'turn',
      modifier: 'right',
      name: 'Station Road',
      drivingSide: 'left',
    ),
  ],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}
