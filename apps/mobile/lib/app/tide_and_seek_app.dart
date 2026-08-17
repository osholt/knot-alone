import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/distance_unit_controller.dart';
import '../controllers/completed_voyages_controller.dart';
import '../controllers/map_style_mode_controller.dart';
import '../controllers/voyage_code_preference_controller.dart';
import '../controllers/voyage_controller.dart';
import '../controllers/voyage_invitation_link_controller.dart';
import '../controllers/route_progress_display_controller.dart';
import '../controllers/sailor_profile_controller.dart';
import '../controllers/shared_route_controller.dart';
import '../controllers/voyage_diagnostics_controller.dart';
import '../controllers/spoken_guidance_controller.dart';
import '../controllers/test_control_controller.dart';
import '../domain/recorded_route_store.dart';
import '../features/home/home_screen.dart';
import 'voyage_invitation_link_gate.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/voyage/active_voyage_shell.dart';
import '../internet/plan_directory.dart';
import '../services/test_control_registry.dart';

class TideAndSeekApp extends StatelessWidget {
  const TideAndSeekApp({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.voyageCodePreference,
    required this.sailorProfile,
    required this.sharedRoutes,
    this.routeProgressDisplay,
    required this.recordedRoutes,
    required this.completedVoyages,
    this.voyageInvitationLinks,
    this.planDirectory,
    this.testControl,
    this.testControlRegistry,
    this.spokenGuidance,
    this.voyageDiagnostics,
    this.enableNativeServices = true,
    this.initializeController,
    this.startupFallbackAfter = const Duration(seconds: 2),
  });

  final VoyageController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final VoyageCodePreferenceController voyageCodePreference;
  final SailorProfileController sailorProfile;
  final SharedRouteController sharedRoutes;
  final RouteProgressDisplayController? routeProgressDisplay;
  final RecordedRouteStore recordedRoutes;
  final CompletedVoyagesController completedVoyages;
  final VoyageInvitationLinkController? voyageInvitationLinks;
  final PlanDirectory? planDirectory;

  /// Drives the end-of-voyage catalogued-road rating card (#159).

  /// Both null unless this build carries the test-control define. The settings
  /// row and the registry hand-off are the only two places they are used.
  final TestControlController? testControl;
  final TestControlRegistry? testControlRegistry;

  /// Whether turn instructions are spoken (#286). Off by default.
  final SpokenGuidanceController? spokenGuidance;

  /// Records what the app said beside what the bike did, when an instrumented
  /// build has it switched on (#419). Null in an ordinary build.
  final VoyageDiagnosticsController? voyageDiagnostics;

  final bool enableNativeServices;

  /// Production starts restoration after the first frame instead of holding the
  /// native launch screen until the voyage journal has loaded (#209).
  ///
  /// Tests and embedders that provide an already-initialized controller leave
  /// this null and retain the existing immediate behavior.
  final Future<void> Function()? initializeController;

  /// How long the dedicated restore screen may own the app before the normal
  /// home screen is exposed with the persisted voyage named there.
  final Duration startupFallbackAfter;

  @override
  Widget build(BuildContext context) => _VoyageRestoreGate(app: this);

  Widget _buildApp({
    required bool restorationComplete,
    required bool showRestorationFallback,
    required Object? restorationError,
    required VoidCallback retryRestoration,
    required bool openJoinGroup,
    required VoidCallback requestJoinGroup,
    required VoidCallback consumeJoinGroupRequest,
  }) {
    const background = Color(0xFF0D1117);
    const surface = Color(0xFF171D25);
    const orange = Color(0xFFFF7A1A);

    final voyageSurface = AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        distanceUnits,
        mapStyleMode,
        completedVoyages,
        sharedRoutes,
        sailorProfile,
        ?routeProgressDisplay,
      ]),
      builder: (context, _) {
        if (!restorationComplete && !showRestorationFallback) {
          return const _VoyageRestoreScreen();
        }
        if (!restorationComplete) {
          return HomeScreen(
            controller: controller,
            distanceUnits: distanceUnits,
            mapStyleMode: mapStyleMode,
            voyageCodePreference: voyageCodePreference,
            sailorProfile: sailorProfile,
            sharedRoutes: sharedRoutes,
            routeProgressDisplay: routeProgressDisplay,
            recordedRoutes: recordedRoutes,
            completedVoyages: completedVoyages,
            planDirectory: planDirectory,
            testControl: testControl,
            spokenGuidance: spokenGuidance,
            voyageDiagnostics: voyageDiagnostics,
            restoringVoyageCode: controller.session?.voyageCode,
            restorationError: restorationError,
            onRetryRestoration: retryRestoration,
            openJoinGroup: openJoinGroup,
            onJoinGroupOpened: consumeJoinGroupRequest,
            enableNativeServices: enableNativeServices,
          );
        }
        // An ended voyage the sailor has stepped away from stays on the phone and
        // stays archived; it just stops owning the whole screen (#207).
        if (controller.hasActiveVoyage && !controller.endedVoyageSetAside) {
          return ActiveVoyageShell(
            key: ValueKey(controller.session!.voyageId),
            voyageController: controller,
            distanceUnits: distanceUnits,
            mapStyleMode: mapStyleMode,
            eventStore: controller.eventStore,
            enableNativeServices: enableNativeServices,
            sailorProfile: sailorProfile,
            sharedRoutes: sharedRoutes,
            routeProgressDisplay: routeProgressDisplay,
            completedVoyageStore: completedVoyages,
            testControl: testControl,
            testControlRegistry: testControlRegistry,
            spokenGuidance: spokenGuidance,
            voyageDiagnostics: voyageDiagnostics,
            onJoinGroupRequested: requestJoinGroup,
          );
        }
        if (sailorProfile.needsOnboarding) {
          return OnboardingScreen(sailorProfile: sailorProfile);
        }
        return HomeScreen(
          controller: controller,
          distanceUnits: distanceUnits,
          mapStyleMode: mapStyleMode,
          voyageCodePreference: voyageCodePreference,
          sailorProfile: sailorProfile,
          sharedRoutes: sharedRoutes,
          routeProgressDisplay: routeProgressDisplay,
          recordedRoutes: recordedRoutes,
          completedVoyages: completedVoyages,
          planDirectory: planDirectory,
          testControl: testControl,
          spokenGuidance: spokenGuidance,
          voyageDiagnostics: voyageDiagnostics,
          openJoinGroup: openJoinGroup,
          onJoinGroupOpened: consumeJoinGroupRequest,
          enableNativeServices: enableNativeServices,
        );
      },
    );
    final links = voyageInvitationLinks;

    return MaterialApp(
      title: 'Tide and Seek',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: orange,
          brightness: Brightness.dark,
          surface: surface,
        ),
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
          headlineMedium: TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
          titleLarge: TextStyle(fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontWeight: FontWeight.w700),
        ),
        cardTheme: const CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111720),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF2A3441)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            side: const BorderSide(color: Color(0xFF3B4654)),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      home: links == null
          ? voyageSurface
          : VoyageInvitationLinkGate(
              links: links,
              voyageController: controller,
              voyageCodePreference: voyageCodePreference,
              sailorProfile: sailorProfile,
              ready: restorationComplete,
              child: voyageSurface,
            ),
    );
  }
}

class _VoyageRestoreGate extends StatefulWidget {
  const _VoyageRestoreGate({required this.app});

  final TideAndSeekApp app;

  @override
  State<_VoyageRestoreGate> createState() => _VoyageRestoreGateState();
}

class _VoyageRestoreGateState extends State<_VoyageRestoreGate> {
  Timer? _fallbackTimer;
  bool _restorationComplete = false;
  bool _showRestorationFallback = false;
  Object? _restorationError;
  int _attempt = 0;
  bool _openJoinGroup = false;

  @override
  void initState() {
    super.initState();
    _restorationComplete = widget.app.initializeController == null;
    if (!_restorationComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _beginRestoration();
      });
    }
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  void _beginRestoration() {
    final initialize = widget.app.initializeController;
    if (initialize == null) return;
    final attempt = ++_attempt;
    _fallbackTimer?.cancel();
    setState(() {
      _restorationComplete = false;
      _showRestorationFallback = false;
      _restorationError = null;
    });
    _fallbackTimer = Timer(widget.app.startupFallbackAfter, () {
      if (!mounted || attempt != _attempt) return;
      setState(() => _showRestorationFallback = true);
    });
    Future<void>.sync(initialize).then(
      (_) {
        if (!mounted || attempt != _attempt) return;
        _fallbackTimer?.cancel();
        setState(() {
          _restorationComplete = true;
          _showRestorationFallback = false;
        });
      },
      onError: (Object error, StackTrace _) {
        if (!mounted || attempt != _attempt) return;
        _fallbackTimer?.cancel();
        setState(() {
          _restorationError = error;
          _showRestorationFallback = true;
        });
      },
    );
  }

  void _requestJoinGroup() {
    if (mounted) setState(() => _openJoinGroup = true);
  }

  void _consumeJoinGroupRequest() {
    if (mounted && _openJoinGroup) setState(() => _openJoinGroup = false);
  }

  @override
  Widget build(BuildContext context) => widget.app._buildApp(
    restorationComplete: _restorationComplete,
    showRestorationFallback: _showRestorationFallback,
    restorationError: _restorationError,
    retryRestoration: _beginRestoration,
    openJoinGroup: _openJoinGroup,
    requestJoinGroup: _requestJoinGroup,
    consumeJoinGroupRequest: _consumeJoinGroupRequest,
  );
}

class _VoyageRestoreScreen extends StatelessWidget {
  const _VoyageRestoreScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag_outlined, size: 42, color: Color(0xFFFF7A1A)),
            SizedBox(height: 18),
            Text(
              'Restoring your voyage…',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 18),
            CircularProgressIndicator(),
          ],
        ),
      ),
    ),
  );
}
