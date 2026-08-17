import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'app/tide_and_seek_app.dart';
import 'controllers/distance_unit_controller.dart';
import 'controllers/completed_voyages_controller.dart';
import 'controllers/map_style_mode_controller.dart';
import 'controllers/voyage_code_preference_controller.dart';
import 'controllers/voyage_diagnostics_controller.dart';
import 'controllers/voyage_controller.dart';
import 'controllers/voyage_invitation_link_controller.dart';
import 'controllers/route_progress_display_controller.dart';
import 'controllers/sailor_profile_controller.dart';
import 'controllers/shared_route_controller.dart';
import 'controllers/spoken_guidance_controller.dart';
import 'controllers/test_control_controller.dart';
import 'data/json_file_recorded_route_store.dart';
import 'data/json_file_completed_voyage_store.dart';
import 'data/shared_preferences_session_store.dart';
import 'data/sqlite_event_store.dart';
import 'services/nearby_bridge.dart';
import 'services/test_control_registry.dart';
import 'services/test_control_session.dart';
import 'services/test_control_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // maplibre_gl's compiled default is false, contrary to its own dartdoc, and
  // only takes effect if set before the first MapLibreMap is created. Without
  // it Android platform views (the full map plus the landscape mini-map) can
  // render blank or drift out of sync with Flutter's compositor; iOS has no
  // equivalent composition mode and is unaffected either way.
  MapLibreMap.useHybridComposition = true;

  // Nothing here paints until every one of these has finished, so the launch
  // sequence is exactly as slow as their sum and hangs if any one of them hangs.
  // A tester's phone came back up after a crash and stopped at a spinner (#209),
  // and a serial chain of nine disk and preference reads is the shape of startup
  // that produces that. Only the genuine dependencies stay ordered.
  final (
    (
      sailorProfile,
      distanceUnits,
      mapStyleMode,
      voyageCodePreference,
      sharedRoutes,
      recordedRoutes,
      completedVoyageStore,
    ),
    // Returns immediately without touching storage in a build that has no
    // test-control define, so it costs an ordinary build nothing. Nested
    // because Dart's parallel-wait extension stops at nine futures, and this
    // must not become a tenth serial await - see the #209 note above.
    testControl,
    spokenGuidance,
    voyageInvitationLinks,
    routeProgressDisplay,
  ) = await (
    (
      SailorProfileController.load(),
      DistanceUnitController.load(
        locale: WidgetsBinding.instance.platformDispatcher.locale,
      ),
      MapStyleModeController.load(),
      VoyageCodePreferenceController.load(),
      SharedRouteController.load(),
      JsonFileRecordedRouteStore.openDefault(),
      JsonFileCompletedVoyageStore.openDefault(),
    ).wait,
    TestControlController.load(),
    SpokenGuidanceController.load(),
    VoyageInvitationLinkController.load(),
    RouteProgressDisplayController.load(),
  ).wait;

  final completedVoyages = await CompletedVoyagesController.load(
    completedVoyageStore,
  );
  // Loaded after the parallel batch rather than inside it, for the same reason
  // the #209 note gives for test control: the batch is already at its limit, and
  // this returns without touching storage in a build with no diagnostics define,
  // so it costs an ordinary build nothing.
  final voyageDiagnostics = await VoyageDiagnosticsController.load();
  final controller = VoyageController(
    SqliteEventStore(),
    SharedPreferencesSessionStore(),
    const NearbyBridge(),
    installationId: sailorProfile.installationId,
    completedVoyageStore: completedVoyages,
  );

  // The registry is created unconditionally - it is one nullable field - but the
  // server only binds a port when the define is present and the in-app switch is
  // on. Kept here rather than inside the widget tree so the port's lifetime is
  // the process's, not a widget's.
  final testControlRegistry = TestControlRegistry();
  final testControlServer = TestControlServer(
    testControl,
    controller,
    testControlRegistry,
  );
  // Owns the port's lifetime, the screen wake lock while the surface is on, and
  // the idle clock across suspension. See TestControlSession for why the last two
  // are not optional for a multi-device run.
  TestControlSession(testControl, testControlServer).start();

  runApp(
    TideAndSeekApp(
      controller: controller,
      distanceUnits: distanceUnits,
      mapStyleMode: mapStyleMode,
      voyageCodePreference: voyageCodePreference,
      sailorProfile: sailorProfile,
      sharedRoutes: sharedRoutes,
      routeProgressDisplay: routeProgressDisplay,
      recordedRoutes: recordedRoutes,
      completedVoyages: completedVoyages,
      voyageInvitationLinks: voyageInvitationLinks,
      testControl: testControl,
      testControlRegistry: testControlRegistry,
      spokenGuidance: spokenGuidance,
      voyageDiagnostics: voyageDiagnostics,
      initializeController: controller.initialize,
    ),
  );
}
