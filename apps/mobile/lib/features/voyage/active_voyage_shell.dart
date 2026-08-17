import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/foreground_location_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/observer_access_controller.dart';
import '../../controllers/pre_start_presence_controller.dart';
import '../../controllers/voyage_controller.dart';
import '../../controllers/route_progress_display_controller.dart';
import '../../controllers/voyage_push_notification_controller.dart';
import '../../controllers/voyage_simulation_controller.dart';
import '../../controllers/sailor_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../controllers/test_control_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../data/in_memory_event_store.dart';
import '../../data/json_file_route_store.dart';
import '../../data/secure_observer_grant_store.dart';
import '../../domain/event_store.dart';
import '../../domain/completed_voyage_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/map_style_mode.dart';
import '../../domain/quick_message.dart';
import '../../domain/voyage_coordination_mode.dart';
import '../../domain/voyage_event.dart';
import '../../domain/voyage_role.dart';
import '../../domain/voyage_session.dart';
import '../../domain/sailor_location.dart';
import '../../domain/sailor_color.dart';
import '../../domain/route_alert.dart';
import '../../domain/route_store.dart';
import '../../internet/internet_relay_client.dart';
import '../../internet/internet_relay_worker.dart';
import '../../internet/observer_access_client.dart';
import '../../internet/push_registration_client.dart';
import '../../internet/shared_preferences_internet_cursor_store.dart';
import '../../relay/live_presence.dart';
import '../../relay/native_nearby_transport.dart';
import '../../relay/relay_engine.dart';
import '../../relay/sqlite_relay_queue.dart';
import '../../services/geo_calculations.dart';
import '../../services/spoken_audio_mode.dart';
import '../../services/spoken_guidance_schedule.dart';
import '../../services/spoken_guidance.dart';
import '../../services/test_control_registry.dart';
import '../../services/demo_route_loader.dart';
import '../../services/device_location_source.dart';
import '../../services/gpx_import_source.dart';
import '../../services/skipper_voyage_status.dart';
import '../../services/measurement_formatter.dart';
import '../../services/native_push_token_source.dart';
import '../../services/position_report_policy.dart';
import '../../services/received_quick_message.dart';
import '../../services/navigation_guidance.dart';
import '../../services/voyage_completion_detector.dart';
import '../../services/route_progress.dart';
import '../../services/voyage_membership.dart';
import '../../services/voyage_screen_awake.dart';
import '../../controllers/voyage_diagnostics_controller.dart';
import '../../services/voyage_diagnostics_log_writer.dart';
import '../../services/voyage_diagnostics_recorder.dart';
import '../../services/voyage_diagnostics_transition.dart';
import '../../services/voyage_summary_exporter.dart';
import '../../services/sailor_contact_share.dart';
import '../../services/road_routing.dart';
import '../../services/voyage_connectivity_summary.dart';
import '../../services/sweeper_gap_trend.dart';
import '../../services/trail_display_simplifier.dart';
import '../map/maneuver_diagnostics.dart';
import '../map/maneuver_list_screen.dart';
import '../map/motorcycle_icon.dart';
import '../map/voyage_map.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/notification_preferences_sheet.dart';
import '../settings/unit_settings_sheet.dart';
import 'ice_share_inbox_sheet.dart';
import '../situational_awareness/situational_awareness_screen.dart';
import '../simulation/voyage_simulation_screen.dart';
import 'end_voyage_confirmation.dart';
import 'ended_voyage_screen.dart';
import 'observer_access_sheet.dart';
import 'voyage_dashboard.dart';
import 'voyage_roster_sheet.dart';

/// Whether a newly calculated route should wait before replacing the current
/// junction instruction.
///
/// Voyage 392725 produced a reroute 47 m before a roundabout. Applying it changed
/// the exit while the sailor was already committed, then announced a second
/// instruction at 0 m. A route can be calculated there, but it must not take
/// over until the sailor is clear.
@visibleForTesting
bool shouldDeferRejoinNavigation({
  required bool hasRoutedPlan,
  required double? distanceToCurrentManeuverMeters,
  required double? metersSincePreviousManeuver,
}) {
  if (!hasRoutedPlan) return false;
  final current = distanceToCurrentManeuverMeters;
  if (current != null && current <= guidanceJunctionClearanceMeters) {
    return true;
  }
  final since = metersSincePreviousManeuver;
  return since != null && since < guidanceJunctionClearanceMeters;
}

/// Junctions the virtual second bike may mark during Voyage Lab.
///
/// Navigation keeps a roundabout's paired exit step so it can derive the road
/// taken and draw the correct symbol. A marker belongs at the entry only, so
/// the simulation's junction list deliberately keeps decision steps alone.
@visibleForTesting
List<RoadRouteManeuver> simulationMarkerManeuvers(
  List<RoadRouteManeuver> maneuvers,
) => maneuvers
    .where((maneuver) => maneuver.requiresSecondBikeDrop)
    .toList(growable: false);

/// The only thing an observer link publishes.
///
/// Its argument list is the privacy boundary: an observer is a separate
/// authorisation decision (#36), so nothing that a sailor shared *inside* the
/// voyage is an input here. That covers the ICE contact, a rejoin breadcrumb
/// (#128) and a sailor's own phone number (#188) — none of them has a parameter
/// to populate, by accident or otherwise.
@visibleForTesting
ObserverPublishedSnapshot buildLocalObserverSnapshot({
  required VoyageSession session,
  required DateTime snapshotGeneratedAt,
  required String voyageStatus,
  required DateTime statusUpdatedAt,
  required DateTime assistanceUpdatedAt,
  required LocationSample? localLocation,
  required ObserverPublishedAssistance? assistance,
}) {
  return ObserverPublishedSnapshot(
    subjectName: session.displayName,
    snapshotGeneratedAt: snapshotGeneratedAt,
    voyageStatus: voyageStatus,
    statusUpdatedAt: statusUpdatedAt,
    assistanceUpdatedAt: assistanceUpdatedAt,
    position: localLocation == null
        ? null
        : ObserverPublishedPosition(
            latitude: localLocation.position.latitude,
            longitude: localLocation.position.longitude,
            accuracyMeters: localLocation.accuracyMeters,
            recordedAt: localLocation.recordedAt,
          ),
    assistance: assistance,
  );
}

/// The skipper-published, bounded whole-group watcher snapshot.
///
/// This deliberately accepts only the reconciled live roster, current rendered
/// positions and planned route. Durable events, trails, nearby identifiers,
/// contact/ICE state and voyage credentials are not inputs, so they cannot leak
/// into a watcher response by accident.
@visibleForTesting
ObserverPublishedSnapshot buildGroupObserverSnapshot({
  required VoyageSession session,
  required DateTime snapshotGeneratedAt,
  required String voyageStatus,
  required DateTime statusUpdatedAt,
  required DateTime assistanceUpdatedAt,
  required Iterable<VoyageParticipant> liveParticipants,
  required Iterable<SailorLocation> renderedPositions,
  required LocationSample? localLocation,
  required route_domain.ImportedRoute? route,
}) {
  final positionsBySailor = {
    for (final location in renderedPositions)
      location.sailorId: location.sample,
  };
  if (localLocation != null) {
    positionsBySailor[session.localSailorId] = localLocation;
  }
  final participants = liveParticipants
      .take(50)
      .map((participant) {
        final sample = positionsBySailor[participant.sailorId];
        final color = participant.sailorColor.color
            .toARGB32()
            .toRadixString(16)
            .padLeft(8, '0')
            .substring(2)
            .toUpperCase();
        return ObserverPublishedGroupParticipant(
          displayName: _boundedObserverText(participant.displayName, 80),
          role: participant.role.name,
          color: '#$color',
          position: sample == null
              ? null
              : ObserverPublishedPosition(
                  latitude: sample.position.latitude,
                  longitude: sample.position.longitude,
                  accuracyMeters: sample.accuracyMeters,
                  recordedAt: sample.recordedAt,
                ),
        );
      })
      .toList(growable: false);
  final routePoints = _boundedObserverRoutePoints(route);
  return ObserverPublishedSnapshot(
    scope: ObserverAccessScope.group,
    subjectName: _boundedObserverText(
      session.voyageName ?? 'Group voyage led by ${session.displayName}',
      80,
    ),
    snapshotGeneratedAt: snapshotGeneratedAt,
    voyageStatus: voyageStatus,
    statusUpdatedAt: statusUpdatedAt,
    assistanceUpdatedAt: assistanceUpdatedAt,
    participants: participants,
    route: route == null || routePoints.length < 2
        ? null
        : ObserverPublishedRoute(
            name: _boundedObserverText(route.name, 80),
            points: routePoints,
          ),
  );
}

String _boundedObserverText(String value, int maximumLength) {
  final trimmed = value.trim();
  if (trimmed.length <= maximumLength) return trimmed;
  return trimmed.substring(0, maximumLength);
}

List<ObserverPublishedRoutePoint> _boundedObserverRoutePoints(
  route_domain.ImportedRoute? route, {
  int maximum = 500,
}) {
  if (route == null || maximum < 2) return const [];
  final source = [
    for (final path in route.paths)
      for (final point in path.points) point,
    if (route.paths.isEmpty)
      for (final waypoint in route.waypoints) waypoint.point,
  ];
  if (source.length < 2) return const [];
  final indexes = source.length <= maximum
      ? List<int>.generate(source.length, (index) => index)
      : List<int>.generate(
          maximum,
          (index) => (index * (source.length - 1) / (maximum - 1)).round(),
        );
  return List.unmodifiable([
    for (final index in indexes)
      ObserverPublishedRoutePoint(
        latitude: source[index].latitude,
        longitude: source[index].longitude,
      ),
  ]);
}

/// Owns the active-voyage feature lifecycle and keeps each feature independently
/// testable. Native permissions are requested only by the installed app, not by
/// widget tests that construct [TideAndSeekApp].
class ActiveVoyageShell extends StatefulWidget {
  const ActiveVoyageShell({
    super.key,
    required this.voyageController,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.eventStore,
    required this.enableNativeServices,
    required this.sailorProfile,
    required this.sharedRoutes,
    this.routeProgressDisplay,
    this.completedVoyageStore,
    this.screenWakeLock = const WakelockPlusScreenWakeLock(),
    this.screenWakeReassertInterval = const Duration(seconds: 15),
    this.pushTokenSource,
    this.pushRegistrationApi,
    this.testControl,
    this.testControlRegistry,
    this.spokenGuidance,
    this.voyageDiagnostics,
    this.onJoinGroupRequested,
  });

  final VoyageController voyageController;

  /// Both null unless this build carries the test-control define. The shell
  /// forwards [testControl] to the settings sheet and publishes each
  /// situational-awareness controller it creates into [testControlRegistry], so
  /// the driven surface always talks to the live one.
  final TestControlController? testControl;
  final TestControlRegistry? testControlRegistry;

  /// Whether turn instructions are spoken. Null in surfaces that do not offer it,
  /// which is treated as off (#286).
  final SpokenGuidanceController? spokenGuidance;

  /// Records what the app said beside what the bike did (#419). Null, or off,
  /// in every ordinary build.
  final VoyageDiagnosticsController? voyageDiagnostics;

  /// Returns an unstarted solo sailor to the established group-join sheet.
  /// The shell owns leaving because it must stop its voyage-scoped services first;
  /// the app owns opening Home's sheet after this shell has been removed (#261).
  final VoidCallback? onJoinGroupRequested;

  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final EventStore eventStore;
  final bool enableNativeServices;
  final SailorProfileController sailorProfile;
  final SharedRouteController sharedRoutes;
  final RouteProgressDisplayController? routeProgressDisplay;
  final CompletedVoyageStore? completedVoyageStore;
  final ScreenWakeLock screenWakeLock;
  final Duration screenWakeReassertInterval;
  final PushTokenSource? pushTokenSource;
  final PushRegistrationApi? pushRegistrationApi;

  @override
  State<ActiveVoyageShell> createState() => _ActiveVoyageShellState();
}

/// Prevents an active voyage from mounting the map against its legacy global
/// fallback while the voyage-scoped route store is still opening.
///
/// Returning only the store for the current voyage type also ensures a genuinely
/// new voyage cannot inherit another voyage's selected route.
@visibleForTesting
RouteStore? activeVoyageMapStoreWhenReady({
  required bool initializing,
  required bool isSimulation,
  required RouteStore? voyageRouteStore,
  required RouteStore? simulationRouteStore,
}) {
  if (initializing) return null;
  return isSimulation ? simulationRouteStore : voyageRouteStore;
}

/// What the voyage map should present of the quick messages in the journal, and
/// the most urgent one per sender so their marker can say what they raised.
///
/// [ReceivedQuickMessageReducer] decides what is admissible; this decides what
/// is still *this sailor's* to act on, and works out where each sender is:
///
/// * another sailor's message stays until this phone acknowledges it, so a sailor
///   who glances away cannot lose it;
/// * this sailor's own message appears only once somebody has acknowledged it,
///   as a receipt — nobody needs their own alert read back to them;
/// * the sender's **live** fix is preferred, because where they are now is what
///   a skipper turning round needs, falling back to the fix relayed with the
///   message. A sailor stopped for fuel is not moving, and their location events
///   age out of the 30-minute retention band long before the two-hour message
///   does, so the relayed fix is what outlasts them.
///
/// Extracted so the decision a two-device test exercises is testable without
/// two devices (#151).
@visibleForTesting
({
  List<VoyageQuickMessageAlert> alerts,
  Map<String, ReceivedQuickMessage> bySender,
})
presentableQuickMessageAlerts({
  required Iterable<ReceivedQuickMessage> messages,
  required String localSailorId,
  required awareness_geo.GeoPoint? readerPosition,
  Map<String, awareness_geo.GeoPoint> livePositions = const {},
  List<awareness_geo.GeoPoint> route = const [],
}) {
  final alerts = <VoyageQuickMessageAlert>[];
  final bySender = <String, ReceivedQuickMessage>{};
  // The same sailor saying the same thing again is one fact, not another prompt.
  // Keyed by sender and the label the sailor actually reads, so someone who
  // raises `Stopped` three times is acknowledged once (#178), a `Stopped` and a
  // `Mechanical` from them stay separate because those are two things to know,
  // and a kind this build has never heard of still groups by its own words.
  final repeatsOfIndex = <({String senderSailorId, String label}), int>{};
  for (final message in messages) {
    if (message.raisedFromLocalSailor) {
      if (!message.isAcknowledged) continue;
    } else {
      if (message.acknowledgedBy(localSailorId)) continue;
      bySender.putIfAbsent(message.senderSailorId, () => message);
      final key = (
        senderSailorId: message.senderSailorId,
        label: message.label,
      );
      final existing = repeatsOfIndex[key];
      if (existing != null) {
        final kept = alerts[existing];
        alerts[existing] = VoyageQuickMessageAlert(
          message: kept.message,
          origin: kept.origin,
          repeats: [...kept.repeats, message],
        );
        continue;
      }
      repeatsOfIndex[key] = alerts.length;
    }
    final live = livePositions[message.senderSailorId];
    alerts.add(
      VoyageQuickMessageAlert(
        message: message,
        origin: QuickMessageOrigin.between(
          readerPosition: readerPosition,
          senderPosition: live ?? message.raisedAtPosition,
          route: route,
          positionIsLive: live != null,
        ),
      ),
    );
  }
  return (
    alerts: List.unmodifiable(alerts),
    bySender: Map.unmodifiable(bySender),
  );
}

/// Sailors holding the Sweeper role right now.
///
/// Resolved from the reconciled membership model rather than a location
/// snapshot, so a TEC who has joined but not yet reported a position still
/// counts as registered, and so the role disappearing (the TEC leaves the voyage
/// or moves to another role) is picked up mid-voyage without a restart. Only
/// sailors still included in the live roster count: a departed TEC is no TEC.
///
/// Voyage Lab drives its whole virtual group locally, so pass its roster as
/// [simulatedSailors] and it becomes the equivalent authority there.
@visibleForTesting
Set<String> registeredSweeperSailorIds({
  required Iterable<SimulatedSailorSnapshot>? simulatedSailors,
  required Iterable<VoyageParticipant> liveParticipants,
}) {
  if (simulatedSailors != null) {
    return simulatedSailors
        .where((sailor) => sailor.role == VoyageRole.sweeper)
        .map((sailor) => sailor.id)
        .toSet();
  }
  return liveParticipants
      .where(
        (participant) =>
            participant.role == VoyageRole.sweeper &&
            participant.isIncludedInLiveCount,
      )
      .map((participant) => participant.sailorId)
      .toSet();
}

/// The labelled action surface embedded directly in the Voyage destination.
///
/// These actions used to sit behind a hamburger on both the map and dashboard.
/// Keeping them on the page means there is no second navigation system to
/// discover, while the moving map keeps only its large riding-time controls.
class _VoyageActionsPanel extends StatelessWidget {
  const _VoyageActionsPanel({
    required this.canChangeRoute,
    required this.onAlertsAndReports,
    required this.onShareSummary,
    required this.onOpenRoster,
    required this.onShareRoster,
    required this.onChangeRoute,
    required this.maneuverCount,
    required this.onShowManeuvers,
    required this.onEmergencyInfo,
    required this.onNotifications,
    required this.canManageObserverAccess,
    required this.onObserverAccess,
    required this.canShareIceInfo,
    required this.onShareIceInfo,
    required this.receivedIceShareCount,
    required this.onViewIceShares,
    required this.hasOwnPhoneNumber,
    required this.ownPhoneNumberShared,
    required this.ownPhoneNumberRecipientLabel,
    required this.onShareOwnPhoneNumber,
    required this.voyagePaused,
    required this.canToggleVoyagePause,
    required this.onToggleVoyagePause,
    required this.onLeaveOrEndVoyage,
    required this.coordinationMode,
  });

  final bool canChangeRoute;
  final VoidCallback onAlertsAndReports;
  final VoidCallback onShareSummary;
  final VoidCallback onOpenRoster;
  final VoidCallback onShareRoster;
  final VoidCallback onChangeRoute;
  final int maneuverCount;
  final VoidCallback onShowManeuvers;
  final VoidCallback onEmergencyInfo;
  final VoidCallback onNotifications;
  final bool canManageObserverAccess;
  final VoidCallback onObserverAccess;
  final bool canShareIceInfo;
  final VoidCallback onShareIceInfo;
  final int receivedIceShareCount;
  final VoidCallback onViewIceShares;

  /// #188. The tile is always shown, because "you have not added a number" is
  /// worth saying: a sailor who never sees the control cannot know the option
  /// exists, and the emergency sheet's silence would look like a fault.
  final bool hasOwnPhoneNumber;
  final bool ownPhoneNumberShared;
  final String ownPhoneNumberRecipientLabel;
  final VoidCallback onShareOwnPhoneNumber;
  final bool voyagePaused;
  final bool canToggleVoyagePause;
  final VoidCallback onToggleVoyagePause;
  final VoidCallback onLeaveOrEndVoyage;

  /// Whether this voyage has anyone else in it. A solo voyage is still led by the
  /// sailor, so every surface that branches on "am I the skipper" says group
  /// things to somebody riding alone unless it is told otherwise (#362).
  final VoyageCoordinationMode coordinationMode;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Voyage actions',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          const Text(
            'Route, group, sharing and voyage controls are all on this page.',
            style: TextStyle(color: Color(0xFF98A3B1)),
          ),
          const SizedBox(height: 8),
          ListTile(
            key: const Key('voyage-actions-alerts'),
            leading: const Icon(Icons.warning_amber_outlined),
            title: const Text('Alerts and reports'),
            subtitle: const Text(
              'Road alerts, off-route sailors and traffic alternatives',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: onAlertsAndReports,
          ),
          ListTile(
            key: const Key('voyage-actions-share-summary'),
            leading: const Icon(Icons.summarize_outlined),
            title: const Text('Share voyage summary'),
            subtitle: const Text('Current voyage details and recorded route'),
            onTap: onShareSummary,
          ),
          const Divider(height: 20),
          if (maneuverCount > 0)
            ListTile(
              key: const Key('voyage-menu-maneuvers'),
              leading: const Icon(Icons.list_alt),
              title: const Text('All turns'),
              subtitle: Text(
                '$maneuverCount instruction${maneuverCount == 1 ? '' : 's'} '
                'for this route',
              ),
              onTap: onShowManeuvers,
            ),
          ListTile(
            key: const Key('voyage-menu-open-roster'),
            leading: const Icon(Icons.groups_2_outlined),
            title: const Text('Voyage roster'),
            subtitle: const Text('Presence, freshness and relay evidence'),
            onTap: onOpenRoster,
          ),
          if (canChangeRoute)
            ListTile(
              key: const Key('voyage-menu-change-route'),
              leading: const Icon(Icons.edit_road_outlined),
              title: const Text('Change route'),
              subtitle: const Text(
                'Plan a destination, import a GPX file, or load the demo route',
              ),
              onTap: onChangeRoute,
            ),
          if (canManageObserverAccess)
            ListTile(
              key: const Key('voyage-menu-observer-access'),
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('Share watcher link'),
              subtitle: const Text(
                'Private, read-only web view for a trusted contact',
              ),
              onTap: onObserverAccess,
            ),
          ExpansionTile(
            key: const Key('voyage-more-options'),
            leading: const Icon(Icons.more_horiz),
            title: const Text('Contacts and other sharing'),
            subtitle: const Text('Less common voyage setup'),
            children: [
              ListTile(
                key: const Key('voyage-menu-share-roster'),
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Share sailor list'),
                subtitle: const Text(
                  'Names and roles, to paste into a group chat you create',
                ),
                onTap: onShareRoster,
              ),
              ListTile(
                key: const Key('voyage-menu-emergency-info'),
                leading: const Icon(Icons.medical_information_outlined),
                title: const Text('Emergency info'),
                subtitle: const Text('Edit your details and sharing settings'),
                onTap: onEmergencyInfo,
              ),
              ListTile(
                key: const Key('voyage-menu-notifications'),
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Voyage notifications'),
                subtitle: const Text(
                  'Background alert permission and preferences',
                ),
                onTap: onNotifications,
              ),
              if (canShareIceInfo)
                ListTile(
                  key: const Key('voyage-menu-share-ice-info'),
                  leading: const Icon(Icons.contact_emergency_outlined),
                  title: const Text('Share my emergency contact'),
                  subtitle: const Text('Shares it with the whole group, now'),
                  onTap: onShareIceInfo,
                ),
              ListTile(
                key: const Key('voyage-menu-share-own-number'),
                leading: const Icon(Icons.phone_forwarded_outlined),
                title: Text(
                  ownPhoneNumberShared
                      ? 'Your number is shared'
                      : 'Share my phone number',
                ),
                subtitle: Text(
                  !hasOwnPhoneNumber
                      ? 'Optional. Add your number first, so they can ring you '
                            'if you stop'
                      : ownPhoneNumberShared
                      ? 'Sent to $ownPhoneNumberRecipientLabel for this voyage. '
                            'Cleared when the voyage ends'
                      : 'Gives it to $ownPhoneNumberRecipientLabel for this '
                            'voyage only',
                ),
                onTap: onShareOwnPhoneNumber,
              ),
              ListTile(
                key: const Key('voyage-menu-view-ice-shares'),
                leading: Badge(
                  isLabelVisible: receivedIceShareCount > 0,
                  label: Text('$receivedIceShareCount'),
                  child: const Icon(Icons.contacts_outlined),
                ),
                title: const Text('Shared emergency contacts'),
                subtitle: const Text(
                  'From other sailors, for this voyage only',
                ),
                onTap: onViewIceShares,
              ),
            ],
          ),
          if (canToggleVoyagePause) const Divider(height: 20),
          if (canToggleVoyagePause)
            ListTile(
              key: const Key('voyage-menu-toggle-pause'),
              leading: Icon(voyagePaused ? Icons.play_arrow : Icons.pause),
              title: Text(voyagePaused ? 'Resume voyage' : 'Pause voyage'),
              subtitle: Text(
                coordinationMode.isGroup
                    ? 'Pauses tracking and progress for the whole group'
                    : 'Pauses tracking and progress',
              ),
              onTap: onToggleVoyagePause,
            ),
          ListTile(
            key: const Key('voyage-actions-leave-or-end'),
            leading: const Icon(Icons.logout),
            title: Text(
              coordinationMode.isGroup ? 'Leave or end voyage' : 'End voyage',
            ),
            subtitle: Text(
              coordinationMode.isGroup
                  ? 'Skippers can end it for everyone; other sailors leave alone'
                  : 'Ends your voyage and stops recording',
            ),
            onTap: onLeaveOrEndVoyage,
          ),
        ],
      ),
    );
  }
}

class _PreStartVoyagePanel extends StatelessWidget {
  const _PreStartVoyagePanel({
    required this.voyageCode,
    required this.participants,
    required this.coordinationMode,
    required this.isSkipper,
    required this.busy,
    required this.routeName,
    required this.onStartVoyage,
    required this.onChooseRoute,
    this.onJoinGroup,
  });

  final String voyageCode;
  final List<VoyageParticipant> participants;
  final VoyageCoordinationMode coordinationMode;
  final bool isSkipper;
  final bool busy;
  final String? routeName;
  final VoidCallback onStartVoyage;
  final VoidCallback onChooseRoute;
  final VoidCallback? onJoinGroup;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF17212B),
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  coordinationMode == VoyageCoordinationMode.solo
                      ? Icons.person_outline
                      : Icons.groups_outlined,
                  color: const Color(0xFFFFC857),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        coordinationMode == VoyageCoordinationMode.solo
                            ? 'Ready for solo voyage'
                            : 'Waiting to start',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        coordinationMode == VoyageCoordinationMode.solo
                            ? 'Tracking begins when you start'
                            : 'Voyage $voyageCode · Current positions only until the skipper starts',
                        style: const TextStyle(
                          color: Color(0xFFA9B4C2),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!isSkipper)
                  const Text(
                    'LEADER STARTS',
                    style: TextStyle(
                      color: Color(0xFFFFC857),
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
            if (isSkipper) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (coordinationMode == VoyageCoordinationMode.solo &&
                      onJoinGroup != null) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('join-group-before-start-button'),
                        onPressed: busy ? null : onJoinGroup,
                        icon: const Icon(Icons.group_add_outlined),
                        label: const Text('Join group'),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('start-voyage-button'),
                      onPressed: busy ? null : onStartVoyage,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start voyage'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 9),
            Row(
              children: [
                Icon(
                  routeName == null
                      ? Icons.route_outlined
                      : Icons.check_circle_outline,
                  size: 18,
                  color: routeName == null
                      ? const Color(0xFFFFC857)
                      : const Color(0xFF6ED89A),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    routeName == null
                        ? 'No route selected'
                        : 'Route: $routeName',
                    maxLines: 2,
                    style: const TextStyle(
                      color: Color(0xFFD4DCE6),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isSkipper)
                  TextButton(
                    key: const Key('pre-start-choose-route'),
                    onPressed: busy ? null : onChooseRoute,
                    child: Text(routeName == null ? 'Choose route' : 'Change'),
                  ),
              ],
            ),
            if (coordinationMode.isGroup) ...[
              const SizedBox(height: 4),
              Row(
                key: const Key('pre-start-roster'),
                children: [
                  const Icon(
                    Icons.people_outline,
                    size: 17,
                    color: Color(0xFFA9B4C2),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '${participants.length} ready'
                      '${participants.isEmpty ? '' : ' · ${participants.map((participant) => '${participant.displayName}${participant.isLocal ? ' (you)' : ''}').join(', ')}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFA9B4C2),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// One destination of the active voyage, named once.
///
/// The navigation bar, the landscape rail and the voyage menu all read this list,
/// so they cannot disagree about what exists or what it is called. That matters
/// because the voyage menu is the *only* way to reach these while the sailor is
/// moving (#404): a copy that drifted would strand the sailor at exactly the
/// moment the bar is gone.
class VoyageDestination {
  const VoyageDestination({
    required this.index,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  /// Position in the shell's `switch`, which differs between an ordinary voyage
  /// and a simulation because Voyage Lab is inserted at 1.
  final int index;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// The destinations of an active voyage, in bar order.
///
/// [simulation] inserts Voyage Lab, which shifts everything after it — which is
/// why the index is carried rather than inferred by a caller counting.
List<VoyageDestination> voyageDestinations({required bool simulation}) {
  var index = 0;
  VoyageDestination next(String label, IconData icon, IconData selectedIcon) =>
      VoyageDestination(
        index: index++,
        label: label,
        icon: icon,
        selectedIcon: selectedIcon,
      );
  return [
    next('Map', Icons.map_outlined, Icons.map),
    if (simulation) next('Voyage Lab', Icons.science_outlined, Icons.science),
    next('Voyage', Icons.two_wheeler_outlined, Icons.two_wheeler),
    next('Settings', Icons.settings_outlined, Icons.settings),
  ];
}

enum _StartVoyageDecision { cancel, chooseRoute, start }

enum _MissingSweeperDecision { cancel, assignSweeper, startAnyway }

@visibleForTesting
enum VoyageExitDecision { cancel, leave, endForEveryone }

@visibleForTesting
enum VoyageCompletionDecision { continueVoyage, endForEveryone }

@visibleForTesting
/// [isSolo] collapses the choice rather than rewording it. A sailor alone has no
/// group to leave and nobody to end anything *for*: "leave only this phone" and
/// "end for everyone" are the same act, and offering both asked them to choose
/// between two descriptions of it while telling them they were about to affect
/// people who were not there (#362).
Future<VoyageExitDecision?> showVoyageExitDialog(
  BuildContext context, {
  required bool isSkipper,
  bool isSolo = false,
}) => showDialog<VoyageExitDecision>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    title: Text(
      isSolo
          ? 'End this voyage?'
          : isSkipper
          ? 'Leave or end this voyage?'
          : 'Leave this voyage?',
    ),
    content: Text(
      isSolo
          ? 'Your voyage ends and location sharing stops on this phone.'
          : isSkipper
          ? 'Leave only this phone, or end the group voyage for everyone.'
          : 'Your location sharing will stop on this phone. The group voyage '
                'will continue for everyone else.',
    ),
    actions: [
      TextButton(
        onPressed: () =>
            Navigator.pop(dialogContext, VoyageExitDecision.cancel),
        child: const Text('Cancel'),
      ),
      if (!isSolo)
        TextButton(
          key: const Key('leave-only-this-phone'),
          onPressed: () =>
              Navigator.pop(dialogContext, VoyageExitDecision.leave),
          child: Text(isSkipper ? 'Leave only' : 'Leave voyage'),
        ),
      if (isSkipper)
        FilledButton(
          key: const Key('end-voyage-for-everyone'),
          onPressed: () =>
              Navigator.pop(dialogContext, VoyageExitDecision.endForEveryone),
          child: Text(isSolo ? 'End voyage' : 'End for everyone'),
        ),
    ],
  ),
);

@visibleForTesting
Future<VoyageCompletionDecision?> showVoyageCompletionDialog(
  BuildContext context, {
  required VoyageCompletionAssessment assessment,
  required bool relayCanCarryReopen,
}) => showDialog<VoyageCompletionDecision>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    key: const Key('voyage-completion-suggestion'),
    icon: const Icon(Icons.flag_circle_outlined),
    title: const Text('Has everyone finished?'),
    content: Text(
      '${assessment.arrivedSailorCount} of ${assessment.sailorCount} sailors have '
      'fresh positions within ${assessment.destinationRadiusMeters.round()} m '
      'of the destination, and '
      '${(assessment.routeProgressFraction * 100).clamp(0, 100).round()}% of '
      'the route has been completed.\n\n'
      '${relayCanCarryReopen ? 'If this is wrong, the skipper can resume this voyage within 24 hours without changing its code.' : 'This relay cannot resume an ended voyage on the other phones. Only end when the whole group is definitely finished.'}',
    ),
    actions: [
      TextButton(
        key: const Key('continue-completed-voyage'),
        onPressed: () => Navigator.pop(
          dialogContext,
          VoyageCompletionDecision.continueVoyage,
        ),
        child: const Text('Continue voyage'),
      ),
      FilledButton(
        key: const Key('confirm-completed-voyage'),
        onPressed: () => Navigator.pop(
          dialogContext,
          VoyageCompletionDecision.endForEveryone,
        ),
        child: const Text('End for everyone'),
      ),
    ],
  ),
);

class _ActiveVoyageShellState extends State<ActiveVoyageShell>
    with WidgetsBindingObserver {
  final _mapPosition = ValueNotifier<route_domain.GeoPoint?>(null);
  final _mapNavigationPosition = ValueNotifier<MapNavigationPosition?>(null);
  final _mapOverlays = ValueNotifier<List<MapOverlayMarker>>(const []);
  final _sailorTrails = ValueNotifier<List<MapOverlayTrace>>(const []);
  final _trailSimplifier = const TrailDisplaySimplifier();
  final _skipperStatus = ValueNotifier<SkipperVoyageStatus?>(null);

  /// Which way the gap to the TEC is going (#181). Owned here because a trend
  /// needs history, and this is where each skipper status is computed.
  final _sweeperGapTrendTracker = SweeperGapTrendTracker();
  final _sweeperGapTrend = ValueNotifier<SweeperGapTrend>(
    SweeperGapTrend.unknown,
  );
  String? _trendedSweeperSailorId;
  final _junctionMarkerOverlay = ValueNotifier<MapJunctionMarkerOverlay?>(null);

  /// The arrival being offered to the sailor, or null when there is nothing to
  /// offer. Replaces the modal that used to cover the map at the one moment a
  /// sailor still needed it (#380).
  final _voyageCompletionSuggestion =
      ValueNotifier<VoyageCompletionAssessment?>(null);

  /// Quick messages the voyage map should be presenting, most urgent first (#151).
  ///
  /// Already filtered to what this sailor still has to act on: another sailor's
  /// message drops out the moment this phone acknowledges it, and this sailor's
  /// own message only appears once somebody has acknowledged it, as a receipt.
  final _quickMessageAlerts = ValueNotifier<List<VoyageQuickMessageAlert>>(
    const [],
  );
  final _dismissedQuickMessageInterruptIds = <String>{};
  final _dismissedQuickMessageReceiptIds = <String>{};

  // The active-voyage tabs are a `switch` on the selected index, not an
  // IndexedStack, so moving to Voyage details and back disposes and rebuilds the
  // map. Anything the sailor has decided that lives in the map's own State is
  // therefore undone by a tab change - which is what a tester hit: cleared
  // enforcement alerts coming back, and an accepted route-start leg having to be
  // accepted again (#282). These live here because this shell outlives the tabs.
  route_domain.ImportedRoute? _routeStartConnector;

  /// The voice for turn prompts.
  ///
  /// This was declared and never assigned, so it was null for the whole life of
  /// every voyage and `_speakGuidance` returned at its first guard: a sailor who
  /// turned spoken guidance on got silence, with the setting saved and read and
  /// nothing behind it (#361).
  ///
  /// Built eagerly now, and safely: `SpokenGuidanceSpeaker` does not touch the
  /// engine until something is actually spoken, and it checks `enabled` first,
  /// so a sailor who leaves the option off still never has a speech engine
  /// initialised behind their back.
  SpokenGuidanceSpeaker? _spokenGuidance;

  /// Every staged prompt already spoken, so a stage is not repeated on each fix
  /// and the early one does not suppress the ones after it (#410).
  final _spokenGuidanceKeys = <String>{};

  /// The manoeuvre the sailor was last being guided towards, and where it was.
  ///
  /// Kept so "am I clear of the junction I just went through" can be answered
  /// without new progress plumbing: it is the straight-line distance from here to
  /// there, which is what #429's clearance rule needs.
  String? _guidanceManeuverIdentity;
  route_domain.GeoPoint? _passedManeuverPosition;
  route_domain.GeoPoint? _lastGuidanceManeuverPosition;

  /// Null unless an instrumented build has recording switched on (#419).
  ///
  /// Held rather than consulted through the controller on every fix so the
  /// hot paths below are one null check, not a preference read: the recorder
  /// must not change the timing it exists to measure.
  VoyageDiagnosticsRecorder? _diagnostics;

  /// Keeps the stored copy of [_diagnostics] in step (#456).
  ///
  /// Built lazily rather than in `initState` because it is keyed on the voyage id,
  /// and a shell can exist before its session does.
  VoyageDiagnosticsLogWriter? _diagnosticsWriter;
  final _trailRecorder = SailorTrailRecorder();
  final _publishedEventIds = <String>{};
  final _warnings = <String>{};
  static const _backgroundLocationWarning =
      'Background GPS is limited. In iPhone Settings, allow Location → Always '
      'before using another navigation app; otherwise your group position and '
      'recorded trail may pause.';
  final _voyageCompletionDetector = VoyageCompletionDetector();
  bool _completionPromptedForArrival = false;

  /// Progress along the active route, used only to arm the automatic voyage end.
  ///
  /// Deliberately the shell's own tracker rather than the map's: completion has
  /// to work when the map is not the visible tab, and the map's tracker is tied
  /// to that widget's lifecycle. Both are monotonic and fed the same fixes, so
  /// they agree.
  final _completionProgressTracker = RouteProgressTracker();

  /// Recorded travelled trails and, separately, the local sailor's advisory
  /// rejoin breadcrumb (#102). They share the map's one trail channel so the
  /// rejoin route inherits the same palette table and layer ordering, but they
  /// are composed apart because a rejoin route is not recorded history: it must
  /// survive a trail refresh and be dropped the moment the sailor is back on
  /// route.
  List<MapOverlayTrace> _recordedTrailTraces = const [];

  /// Issue #128 part 2. Other sailors' rejoin breadcrumbs, which only ever reach
  /// the skipper's own map: they are relayed addressed to the skipper, and the
  /// reducer drops anything this phone is not the recipient of. Held apart from
  /// [_recordedTrailTraces] for the same reason the local rejoin route is —
  /// they are intent, not recorded history.

  /// Bounds how often the local sailor's rejoin plan is relayed, independently of
  /// how often #102 recomputes it locally.

  /// TEC requests this phone has already put in front of the sailor, so an
  /// unanswered request does not reopen its dialog on every rebuild.
  final _promptedSweeperRequestIds = <String>{};
  bool _sweeperRequestPromptOpen = false;

  late final VoyageScreenAwakeCoordinator _screenAwakeCoordinator;

  SituationalAwarenessController? _awarenessController;

  ForegroundLocationController? _locationController;
  NearbyRelayController? _relayController;
  InternetRelayController? _internetRelayController;
  ObserverAccessController? _observerAccessController;
  VoyagePushNotificationController? _pushNotificationController;
  PreStartPresenceController? _preStartPresenceController;
  SharedPreferencesInternetCursorStore? _internetCursorStore;
  VoyageSimulationController? _simulationController;
  InMemoryRouteStore? _simulationRouteStore;
  RouteStore? _voyageRouteStore;
  StreamSubscription<VoyageEvent>? _receivedEventSubscription;
  StreamSubscription<VoyageEvent>? _internetReceivedEventSubscription;
  StreamSubscription<PushOpenRequest>? _pushOpenSubscription;
  Timer? _stalenessTimer;
  Timer? _simulationAwarenessTimer;
  int _observedNearbyPublishEventCount = -1;
  bool _nearbyPublishWorkPending = true;
  bool _nearbyPublishInFlight = false;
  String? _routeFingerprint;
  String? _trailLifecycleFingerprint;
  String? _appliedAuthoritativeRouteRevision;
  String? _simulationRouteFingerprint;
  route_domain.ImportedRoute? _activeRoute;
  int _routeGeneration = 0;
  int _selectedIndex = 0;
  Object? _changeRouteRequestToken;
  PickedGpxFile? _pendingSharedGpxFile;
  PendingInAppRoute? _pendingInAppRoute;
  DateTime? _lastSimulationNavigationUpdateAt;
  DateTime? _lastSimulationOverlayUpdateAt;
  LocationSample? _latestObserverLocationSample;

  /// Decides which device fixes become durable position reports (#166).
  ///
  /// It gates the journal only. The observer snapshot and the ephemeral presence
  /// channel above it see every fix, so a sailor stays continuously visible while
  /// the expensive half of reporting follows distance travelled.
  final PositionReportGate _positionReportGate = PositionReportGate();
  bool _loading = true;
  bool _relayConfigured = false;
  bool _publishingRouteChange = false;
  bool _voyageEndHandled = false;
  bool _autoEndingVoyage = false;
  bool _simulationPausedByVoyage = false;
  bool _observedVoyageStarted = false;
  bool _localVoyageStartInProgress = false;
  bool _voyageStartFlowInProgress = false;
  VoyageRole? _lastPushRole;

  bool get _isSimulation =>
      widget.voyageController.session?.isSimulation == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Headless and test surfaces have no audio to speak through, and must not
    // construct a platform speech engine.
    if (widget.voyageDiagnostics?.isOn ?? false) {
      _startDiagnostics(voyageDiagnosticsStartedNote);
    }
    // Read on every change, not once here: the switch used to be sampled in
    // `initState` alone, so turning recording on mid-voyage — through the voyage
    // menu, the door closest to hand while riding — showed it on and recorded
    // nothing (#457).
    widget.voyageDiagnostics?.addListener(_onVoyageDiagnosticsChanged);
    if (widget.enableNativeServices && widget.spokenGuidance != null) {
      _spokenGuidance = SpokenGuidanceSpeaker(
        widget.spokenGuidance!.createEngine(onOutput: _recordSpeechOutput),
      );
      widget.spokenGuidance!.addListener(_onSpokenGuidanceChanged);
    }
    _observedVoyageStarted =
        widget.voyageController.voyageStarted &&
        !widget.voyageController.voyageEnded;
    if (_observedVoyageStarted) unawaited(_warmNaturalVoiceIfNeeded());
    _screenAwakeCoordinator = VoyageScreenAwakeCoordinator(
      wakeLock: widget.screenWakeLock,
      reassertInterval: widget.screenWakeReassertInterval,
      onError: (error, _) {
        if (kDebugMode) {
          debugPrint('Could not enforce voyage wake lock: $error');
        }
      },
    )..start();
    widget.voyageController.addListener(_onVoyageControllerChanged);
    widget.sharedRoutes.addListener(_onSharedRoutesChanged);
    _capturePlannerLinkError();
    if (widget.sharedRoutes.pending case final file?) {
      if (widget.voyageController.isLocalVoyageSkipper) {
        _selectedIndex = 0;
        _changeRouteRequestToken = Object();
        _pendingSharedGpxFile = file;
      } else {
        _warnings.add('Only the voyage skipper can replace the group route.');
      }
      _clearSharedRoutePending();
    } else if (widget.sharedRoutes.pendingInAppRoute case final route?) {
      if (widget.voyageController.isLocalVoyageSkipper) {
        _selectedIndex = 0;
        _changeRouteRequestToken = Object();
        _pendingInAppRoute = route;
      } else {
        _warnings.add('Only the voyage skipper can replace the group route.');
      }
      _clearSharedRoutePending();
    }
    unawaited(_initialize());
  }

  /// A GPX file can arrive (via the platform's "Open in..." delivery) while
  /// this voyage is already on screen - e.g. resuming from background. Reuses
  /// the same request path as the Voyage page's "Change route", just with the
  /// file already in hand instead of asking the map to show its picker.
  void _onSharedRoutesChanged() {
    if (!mounted) return;
    final warningAdded = _capturePlannerLinkError();
    final file = widget.sharedRoutes.pending;
    final inAppRoute = widget.sharedRoutes.pendingInAppRoute;
    if (file == null && inAppRoute == null) {
      if (warningAdded) setState(() {});
      return;
    }
    if (!widget.voyageController.isLocalVoyageSkipper) {
      _warnings.add('Only the voyage skipper can replace the group route.');
      _clearSharedRoutePending();
      setState(() {});
      return;
    }
    setState(() {
      _selectedIndex = 0;
      _changeRouteRequestToken = Object();
      _pendingSharedGpxFile = file;
      _pendingInAppRoute = inAppRoute;
    });
    _clearSharedRoutePending();
  }

  bool _capturePlannerLinkError() {
    if (widget.sharedRoutes.plannerLinkStatus != PlannerLinkStatus.error) {
      return false;
    }
    final message = widget.sharedRoutes.plannerLinkMessage;
    if (message == null) return false;
    final code = widget.sharedRoutes.plannerLinkCode;
    return _warnings.add(
      'Shared route link: $message'
      '${code == null ? '' : ' You can still enter code $code from Change route → Load a planned route.'}',
    );
  }

  /// Deferred a frame so this never calls notifyListeners() back into
  /// SharedRouteController from inside its own listener dispatch (this method
  /// runs either from that listener, or from initState before the first
  /// frame - neither is a safe place to notify synchronously).
  void _clearSharedRoutePending() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.sharedRoutes.clearPending();
    });
  }

  Future<void> _initialize() async {
    route_domain.ImportedRoute? route;
    var publishStoredSkipperRoute = false;
    if (_isSimulation) {
      try {
        route = await const BundledDemoRouteLoader().load();
        _simulationRouteStore = InMemoryRouteStore(route);
        _warnings.add(
          'Voyage Lab is isolated: device GPS, internet relay and nearby radios '
          'are disabled.',
        );
      } on Object catch (error) {
        _warnings.add('The simulation route could not be loaded: $error');
      }
    } else if (widget.enableNativeServices) {
      try {
        final session = widget.voyageController.session;
        if (session != null) {
          _voyageRouteStore = await JsonFileRouteStore.openForVoyage(
            session.voyageId,
          ).timeout(_localRouteRestoreTimeout);
          route = await _voyageRouteStore!.loadActiveRoute().timeout(
            _localRouteRestoreTimeout,
          );
          final authoritative = widget.voyageController.authoritativeRouteState;
          _appliedAuthoritativeRouteRevision = authoritative.revisionId;
          if (authoritative.hasDecision) {
            route = authoritative.route;
            if (route == null) {
              await _voyageRouteStore!.clearActiveRoute();
            } else {
              await _voyageRouteStore!.saveActiveRoute(route);
            }
          } else if (session.role != VoyageRole.lead) {
            route = null;
            await _voyageRouteStore!.clearActiveRoute();
          } else {
            publishStoredSkipperRoute = route != null;
          }
        }
      } on Object catch (error) {
        // Never fall back to the legacy app-wide route file. A failed
        // voyage-scoped store should leave this voyage empty instead of reviving
        // a route chosen for an earlier voyage.
        _voyageRouteStore = InMemoryRouteStore();
        _warnings.add('Route storage could not be opened: $error');
        final authoritative = widget.voyageController.authoritativeRouteState;
        _appliedAuthoritativeRouteRevision = authoritative.revisionId;
        if (authoritative.hasDecision) route = authoritative.route;
      }
    }

    _activeRoute = route;
    if (!mounted) return;

    // The map depends only on its voyage-scoped route store. It must not leave a
    // full-screen spinner up while GPS, push, internet presence or nearby
    // transport start in the background. This frame is the escape hatch for a
    // transport plugin that never returns on a particular Android phone
    // (#209).
    setState(() => _loading = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    try {
      await _replaceAwarenessController(route);
    } on Object catch (error) {
      _warnings.add('Voyage map history could not be restored: $error');
    }
    if (_isSimulation) {
      try {
        await _replaceSimulationController(route);
      } on Object catch (error) {
        _warnings.add('Voyage Lab could not be restored: $error');
      }
    }
    if (publishStoredSkipperRoute && route != null) {
      try {
        await widget.voyageController.publishRoute(route);
        _appliedAuthoritativeRouteRevision =
            widget.voyageController.authoritativeRouteState.revisionId;
      } on Object catch (error) {
        _warnings.add('The stored group route could not be published: $error');
      }
    }
    if (!mounted) return;

    if (widget.enableNativeServices && !_isSimulation) {
      final session = widget.voyageController.session;
      final groupVoyage = widget.voyageController.coordinationMode.isGroup;
      if (groupVoyage && session?.role == VoyageRole.lead) {
        try {
          await widget.voyageController.publishVoyageCode();
        } on VoyageCodeDirectoryException catch (error) {
          _warnings.add('Voyage code is not ready yet: ${error.message}');
        }
      }
      _stalenessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        widget.voyageController.refreshMembershipFreshness();
        final awareness = _awarenessController;
        if (awareness != null) unawaited(awareness.refreshStaleness());
      });
      final locationController = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async {
          _latestObserverLocationSample = sample;
          _publishObserverSnapshot();
          // One decision, taken once, for both halves of reporting: distance
          // travelled, a turn, or the keep-alive timer (#166).
          final reported = _positionReportGate.consider(sample);
          // Every fix goes to the ephemeral presence channel, in both phases,
          // so this sailor stays continuously visible to the group. The durable
          // journal still only receives post-start fixes.
          final currentSession = widget.voyageController.session;
          if (currentSession != null) {
            _preStartPresenceController?.updateLocalPosition(
              SailorLocation(
                sailorId: currentSession.localSailorId,
                displayName: currentSession.displayName,
                role: currentSession.role,
                sample: sample,
                receivedAt: DateTime.now(),
                motorcycleStyle: currentSession.motorcycleStyle,
                sailorSymbol: currentSession.sailorSymbol,
                sailorColor: currentSession.sailorColor,
              ),
              // A withheld fix is still held as the newest position and still
              // goes out on the next presence tick; it just does not bring that
              // tick forward. Presence itself never waits for movement.
              publishImmediately: reported != null,
            );
          }
          final startedAt = widget.voyageController.voyageStartedAt;
          if (startedAt == null || sample.recordedAt.isBefore(startedAt)) {
            return;
          }
          // A withheld fix is not a lost fix: the presence channel above has it,
          // so the only thing not happening here is a journal event nobody
          // needed.
          if (reported == null) return;
          final awareness = _awarenessController;
          if (awareness != null) {
            await awareness.recordLocalLocation(sample);
          }
        },
        onSampleError: (error, stackTrace) {
          if (kDebugMode) {
            debugPrint(
              'Could not persist a location update; continuing: '
              '$error\n$stackTrace',
            );
          }
          final added = _warnings.add(
            'A location update could not be saved. Live GPS is continuing.',
          );
          if (added && mounted) setState(() {});
        },
      );
      _locationController = locationController;
      locationController.addListener(_onDeviceLocationChanged);
      try {
        await locationController.initialize();
      } on Object catch (error) {
        _warnings.add('Location capability check failed: $error');
      }
      if (widget.voyageController.voyageStarted &&
          !widget.voyageController.voyageEnded) {
        await _resumeLocationForActiveVoyage();
      } else {
        await _startLocationForPreStartMap();
      }

      if (session != null) {
        final cursorStore = SharedPreferencesInternetCursorStore();
        _internetCursorStore = cursorStore;
        final internetRelayController = InternetRelayController(
          InternetRelayWorker(
            api: HttpInternetRelayClient(
              configuration: InternetRelayConfiguration.fromEnvironment(),
              client: http.Client(),
            ),
            eventStore: widget.eventStore,
            cursorStore: cursorStore,
          ),
        );
        _internetRelayController = internetRelayController;
        _internetReceivedEventSubscription = internetRelayController
            .receivedEvents
            .listen(
              (event) => _onReceivedEvent(
                event,
                VoyageTransportEvidence.internetRelay,
              ),
            );
        await internetRelayController.start(session);
        final observerConfiguration =
            ObserverAccessConfiguration.fromEnvironment();
        if (observerConfiguration.configurationError == null) {
          _observerAccessController = ObserverAccessController(
            HttpObserverAccessClient(
              configuration: observerConfiguration,
              client: http.Client(),
            ),
            const SecureObserverGrantStore(),
          );
          await _observerAccessController!.attach(session);
          if (_observerAccessController!.hasActiveGrants) {
            await locationController.resumeIfAuthorized();
            _publishObserverSnapshot();
          }
        }
        if (groupVoyage) {
          final pushNotificationController = VoyagePushNotificationController(
            tokenSource:
                widget.pushTokenSource ??
                NativePushTokenSource(
                  NativePushConfiguration.fromEnvironment(),
                ),
            registrationApi:
                widget.pushRegistrationApi ??
                HttpPushRegistrationClient(
                  configuration: InternetRelayConfiguration.fromEnvironment(),
                  client: http.Client(),
                ),
            preferencesStore: await SharedPreferences.getInstance(),
          );
          _pushNotificationController = pushNotificationController;
          pushNotificationController.addListener(
            _onPushNotificationStatusChanged,
          );
          _pushOpenSubscription = pushNotificationController.openedNotifications
              .listen(_onPushNotificationOpened);
          await pushNotificationController.start(session);
          _lastPushRole = session.role;
          final preStartPresenceController = PreStartPresenceController(
            HttpPreStartPresenceClient(
              configuration: InternetRelayConfiguration.fromEnvironment(),
              client: http.Client(),
            ),
          );
          _preStartPresenceController = preStartPresenceController;
          preStartPresenceController.addListener(_onPreStartPresenceChanged);
          // Presence runs for the whole voyage, not only before the start. It is
          // what keeps a sailor visible across `voyageStarted` and what makes a
          // sailor who joins an already-started voyage appear immediately.
          if (!widget.voyageController.voyageEnded) {
            await preStartPresenceController.start(session);
          }
        }
      }
      if (groupVoyage && session != null && session.inviteSecret.length >= 16) {
        final relayController = NearbyRelayController(
          RelayEngine(
            transport: NativeNearbyTransport(),
            eventStore: widget.eventStore,
            queue: SqliteRelayQueue(),
          ),
        );
        _relayController = relayController;
        _receivedEventSubscription = relayController.receivedEvents.listen(
          (event) =>
              _onReceivedEvent(event, VoyageTransportEvidence.nearbyRelay),
        );
        try {
          await relayController.start(session);
          _relayConfigured = true;
          await _preStartPresenceController?.attachNearby(relayController);
        } on Object catch (error) {
          _warnings.add('Nearby relay could not start: $error');
        }
      }
    }

    if (!mounted) return;
    if (widget.voyageController.voyageEnded) {
      await _handleVoyageEnded();
    }
    _schedulePublish();
  }

  /// Route storage is local and normally opens in milliseconds. If the
  /// platform file-service call itself wedges, fall back to an empty in-memory
  /// store so the sailor gets controls rather than an indefinite map spinner.
  static const _localRouteRestoreTimeout = Duration(seconds: 2);

  Future<void> _replaceAwarenessController(
    route_domain.ImportedRoute? route, {
    bool notify = true,
  }) async {
    final fingerprint = route == null
        ? 'none'
        : '${route.id}:${route.importedAt.toUtc().toIso8601String()}:'
              // The marker review decides which decision points the live
              // detector may suggest, so rejecting one has to rebuild it (#179).
              '${route.pathPointCount}:${route.markerReview.signature}';
    final lifecycleFingerprint =
        widget.voyageController.voyageStartedAt?.toUtc().toIso8601String() ??
        'open';
    final effectiveFingerprint =
        '$fingerprint:$lifecycleFingerprint:'
        '${widget.voyageController.coordinationMode.name}';
    if (_awarenessController != null &&
        effectiveFingerprint == _routeFingerprint) {
      return;
    }
    final generation = ++_routeGeneration;
    final session = widget.voyageController.session;
    if (session == null) return;

    final routeSegments =
        route?.paths
            .where((path) => path.points.length >= 2)
            .map(
              (path) => path.points
                  .map(
                    (point) => awareness_geo.GeoPoint(
                      latitude: point.latitude,
                      longitude: point.longitude,
                    ),
                  )
                  .toList(growable: false),
            )
            .toList(growable: false) ??
        const <List<awareness_geo.GeoPoint>>[];
    // Synthetic position updates are intentionally ephemeral. Writing five
    // sailors to SQLite throughout a Voyage Lab run makes the durable event
    // history grow quickly, which in turn slows down the phone.
    final awarenessEventStore = _isSimulation
        ? InMemoryEventStore()
        : widget.eventStore;
    final controller = SituationalAwarenessController(
      awarenessEventStore,
      session,
      route: routeSegments.expand((segment) => segment).toList(growable: false),
      routeSegments: routeSegments,
      voyageStarted: widget.voyageController.voyageStarted,
      voyageStartedAt: widget.voyageController.voyageStartedAt,
      onEventStored: widget.voyageController.ingestStoredEvent,
    );
    await controller.initialize(restoredEvents: widget.voyageController.events);
    if (!mounted || generation != _routeGeneration) {
      controller.dispose();
      return;
    }
    // Publish only after the generation check: a controller built for a
    // superseded route is disposed above, and driving a disposed controller is
    // exactly the stale-reference bug TestControlRegistry exists to avoid.
    widget.testControlRegistry?.publish(controller);

    final previous = _awarenessController;
    previous?.removeListener(_onAwarenessChanged);
    _awarenessController = controller;
    _routeFingerprint = effectiveFingerprint;
    // Replacing the awareness controller usually only means the route changed -
    // a skipper reroute, say - and travelled history must survive that with no
    // gap or restart. Only a new voyage lifecycle discards it, which is also what
    // keeps the pre-start no-trace rule intact (#35/#51).
    if (lifecycleFingerprint != _trailLifecycleFingerprint) {
      _trailLifecycleFingerprint = lifecycleFingerprint;
      _trailRecorder.clear();
      _recordedTrailTraces = const [];
    }
    _pushSailorTrails();
    controller.addListener(_onAwarenessChanged);
    previous?.dispose();
    _updateMapOverlays();
    if (notify) setState(() {});
  }

  void _onRouteChanged(route_domain.ImportedRoute? route) {
    unawaited(_handleRouteChanged(route));
  }

  Future<void> _handleRouteChanged(route_domain.ImportedRoute? route) async {
    if (!_isSimulation && !widget.voyageController.isLocalVoyageSkipper) {
      _warnings.add('A sailor cannot replace the skipper’s group route.');
      await _applyAuthoritativeRouteDecision();
      if (mounted) setState(() {});
      return;
    }
    _publishingRouteChange = true;
    _activeRoute = route;
    try {
      await _replaceAwarenessController(route);
      if (_isSimulation) {
        await _replaceSimulationController(route);
        return;
      }
      if (route == null) {
        await widget.voyageController.clearRoute();
      } else {
        await widget.voyageController.publishRoute(route);
      }
      _appliedAuthoritativeRouteRevision =
          widget.voyageController.authoritativeRouteState.revisionId;
      final store = _voyageRouteStore;
      if (store != null) {
        if (route == null) {
          await store.clearActiveRoute();
        } else {
          await store.saveActiveRoute(route);
        }
      }
    } finally {
      _publishingRouteChange = false;
    }
  }

  Future<void> _applyAuthoritativeRouteDecision() async {
    if (_isSimulation || _publishingRouteChange) return;
    final state = widget.voyageController.authoritativeRouteState;
    if (!state.hasDecision ||
        state.revisionId == _appliedAuthoritativeRouteRevision) {
      return;
    }
    _appliedAuthoritativeRouteRevision = state.revisionId;
    final route = state.route;
    final store = _voyageRouteStore;
    if (store != null) {
      if (route == null) {
        await store.clearActiveRoute();
      } else {
        await store.saveActiveRoute(route);
      }
    }
    _activeRoute = route;
    await _replaceAwarenessController(route);
    if (mounted) setState(() {});
  }

  Future<void> _replaceSimulationController(
    route_domain.ImportedRoute? route, {
    bool notify = true,
  }) async {
    final fingerprint = route == null
        ? 'none'
        : '${route.id}:${route.importedAt.toUtc().toIso8601String()}:'
              // The marker review decides which decision points the live
              // detector may suggest, so rejecting one has to rebuild it (#179).
              '${route.pathPointCount}:${route.markerReview.signature}';
    final lifecycleFingerprint =
        widget.voyageController.voyageStartedAt?.toUtc().toIso8601String() ??
        'open';
    final effectiveFingerprint = '$fingerprint:$lifecycleFingerprint';
    if (_simulationController != null &&
        effectiveFingerprint == _simulationRouteFingerprint) {
      return;
    }
    final previous = _simulationController;
    _simulationController = null;
    _simulationRouteFingerprint = effectiveFingerprint;
    _lastSimulationNavigationUpdateAt = null;
    previous?.removeListener(_onSimulationVisualChanged);
    previous?.dispose();

    final awareness = _awarenessController;
    final session = widget.voyageController.session;
    final simulationRoute = _routeAsPoints(route);
    if (awareness == null ||
        session == null ||
        !session.isSimulation ||
        simulationRoute.length < 2) {
      if (notify && mounted) setState(() {});
      return;
    }
    final markerJunctions = await _simulationJunctions(route);

    final controller = VoyageSimulationController(
      awareness,
      session: session,
      route: simulationRoute,
      markerJunctions: markerJunctions,
      sailorCount: session.simulationSailorCount,
      voyageStarted: widget.voyageController.voyageStarted,
    );
    _simulationController = controller;
    controller.addListener(_onSimulationVisualChanged);
    await controller.initialize();
    if (!mounted || _simulationController != controller) {
      controller.dispose();
      return;
    }
    if (widget.voyageController.voyageStarted &&
        !widget.voyageController.voyagePaused &&
        !widget.voyageController.voyageEnded) {
      controller.start();
    }
    _onSimulationVisualChanged();
    if (notify) setState(() {});
  }

  Future<List<awareness_geo.GeoPoint>> _simulationJunctions(
    route_domain.ImportedRoute? route,
  ) async {
    if (route?.sourceFileName == 'demo_route.gpx') {
      try {
        return simulationMarkerManeuvers(
              await const BundledDemoRouteLoader().loadManeuvers(),
            )
            .map(
              (maneuver) => awareness_geo.GeoPoint(
                latitude: maneuver.position.latitude,
                longitude: maneuver.position.longitude,
              ),
            )
            .toList(growable: false);
      } on FormatException {
        // Keep the demo usable if a local asset is damaged. GPX waypoints are
        // a less detailed but still valid fallback for the simulation.
      }
    }
    return route?.waypoints
            .map(
              (waypoint) => awareness_geo.GeoPoint(
                latitude: waypoint.point.latitude,
                longitude: waypoint.point.longitude,
              ),
            )
            .toList(growable: false) ??
        const <awareness_geo.GeoPoint>[];
  }

  void _onSimulationVisualChanged() {
    if (!mounted || !_isSimulation) return;
    final now = DateTime.now();
    final updateNavigationPosition =
        _lastSimulationNavigationUpdateAt == null ||
        now.difference(_lastSimulationNavigationUpdateAt!) >=
            const Duration(milliseconds: 200);
    if (updateNavigationPosition) {
      _lastSimulationNavigationUpdateAt = now;
    }
    final updateOverlayMarkers =
        _lastSimulationOverlayUpdateAt == null ||
        now.difference(_lastSimulationOverlayUpdateAt!) >=
            const Duration(milliseconds: 250);
    if (updateOverlayMarkers) _lastSimulationOverlayUpdateAt = now;
    _updateMapOverlays(
      // The map status card is derived from the same authenticated synthetic
      // fixes as the overlays. Without this, a restarted skipper view could
      // keep saying that Charlie's location was unavailable.
      updateDerivedState: updateOverlayMarkers,
      updateOverlayMarkers: updateOverlayMarkers,
      updateNavigationPosition: updateNavigationPosition,
    );
  }

  void _onAwarenessChanged() {
    if (_isSimulation) {
      _scheduleSimulationAwarenessUpdate();
      return;
    }
    _updateMapOverlays();
    _schedulePublish();
  }

  void _scheduleSimulationAwarenessUpdate() {
    if (_simulationAwarenessTimer != null) return;
    _simulationAwarenessTimer = Timer(const Duration(milliseconds: 250), () {
      _simulationAwarenessTimer = null;
      if (!mounted) return;
      // Simulation awareness maintains its own in-memory location evidence.
      // Local marker actions update VoyageController directly, so reloading and
      // decoding the entire durable voyage history here is unnecessary.
      _updateMapOverlays(
        updateDerivedState: true,
        updateNavigationPosition: false,
      );
    });
  }

  void _updateMapOverlays({
    bool updateDerivedState = true,
    bool updateOverlayMarkers = true,
    bool updateNavigationPosition = true,
  }) {
    final awareness = _awarenessController;
    if (awareness == null) return;
    // One reconciled model for both voyage phases and both transports, so nobody
    // disappears at the `voyageStarted` transition, a late joiner appears at once,
    // and the count can never disagree with the drawn markers (#132).
    final livePresence = _isSimulation
        ? const <LiveSailorPresence>[]
        : _reconciledLivePresence();
    if (!_isSimulation) _publishLivePresence(livePresence);
    final liveView = widget.voyageController.liveView;
    final participants = {
      for (final participant in liveView.participants)
        participant.sailorId: participant,
    };
    final freshnessBySailor = {
      for (final presence in livePresence) presence.sailorId: presence,
    };
    final visibleSailorLocations = _isSimulation
        // Voyage Lab has an authenticated in-memory roster rather than relay
        // participants. Filtering its fixes through the empty real roster
        // made every virtual sailor disappear from the TEC status.
        ? List<SailorLocation>.unmodifiable(awareness.sailorLocations)
        : liveView.renderedPositions;
    final activeSailorIds = _isSimulation
        ? visibleSailorLocations.map((location) => location.sailorId).toSet()
        : participants.values
              .where((participant) => participant.isEligibleForRouteAlerts)
              .map((participant) => participant.sailorId)
              .toSet();
    final localLocation = visibleSailorLocations
        .where(
          (location) =>
              location.sailorId ==
              widget.voyageController.session?.localSailorId,
        )
        .firstOrNull;
    final simulatedSailors = _isSimulation
        ? _simulationController?.sailors
        : null;
    final simulatedLocal = simulatedSailors
        ?.where((sailor) => sailor.isLocal)
        .firstOrNull;
    // The authoritative post-start location journal must not ingest a fix
    // captured before the skipper started the voyage. The map can still retain
    // that foreground-only fix while it waits for the first post-start
    // movement sample, otherwise a stationary sailor disappears and Follow me
    // incorrectly looks like a permission failure.
    final activeDeviceSample = _isSimulation
        ? null
        : _locationController?.activeSample;
    final localMapSample = _newestLocationSample(
      localLocation?.sample,
      activeDeviceSample,
    );
    final mapPoint = simulatedLocal != null
        ? route_domain.GeoPoint(
            latitude: simulatedLocal.position.latitude,
            longitude: simulatedLocal.position.longitude,
          )
        : localMapSample == null
        ? null
        : route_domain.GeoPoint(
            latitude: localMapSample.position.latitude,
            longitude: localMapSample.position.longitude,
            recordedAt: localMapSample.recordedAt,
          );
    final navigationRecordedAt = simulatedLocal == null
        ? localMapSample?.recordedAt
        : DateTime.now();
    if (updateNavigationPosition) {
      // #419's pairing compares the app's bearings against the sailor's own
      // track, so it needs this phone's fixes — and only this phone's. Other
      // sailors' positions are someone else's data and are never recorded.
      if (mapPoint != null) {
        _diagnostics?.observePosition(
          point: awareness_geo.GeoPoint(
            latitude: mapPoint.latitude,
            longitude: mapPoint.longitude,
          ),
          headingDegrees:
              simulatedLocal?.headingDegrees ?? localMapSample?.headingDegrees,
        );
      }
      _mapNavigationPosition.value = mapPoint == null
          ? null
          : MapNavigationPosition(
              point: mapPoint,
              recordedAt: navigationRecordedAt!,
              speedMetersPerSecond:
                  simulatedLocal?.speedMetersPerSecond ??
                  localMapSample!.speedMetersPerSecond,
              headingDegrees:
                  simulatedLocal?.headingDegrees ??
                  localMapSample!.headingDegrees,
              accuracyMeters: localMapSample?.accuracyMeters,
            );
      _mapPosition.value = mapPoint;
    }

    // A simulation can finish between throttled overlay frames. Completion
    // needs to inspect the final GPS fixes even when no later overlay frame is
    // scheduled to arrive.
    unawaited(_maybeAutomaticallyEndVoyage(awareness, mapPoint));
    if (!updateOverlayMarkers) return;
    if (_isSimulation) {
      _updateSimulationSailorTrails(simulatedSailors ?? const []);
    } else if (updateDerivedState) {
      _updateSailorTrails(awareness);
    }

    // Issue #151. Resolved before the markers are built, because the sailor who
    // raised something is the sailor whose marker has to say so.
    final quickMessagesBySender = _refreshQuickMessageAlerts(
      localLocation: localLocation,
      visibleSailorLocations: visibleSailorLocations,
      route: awareness.route,
    );
    final overlays = <MapOverlayMarker>[
      ...(simulatedSailors == null
              ? visibleSailorLocations
                    .where(
                      (location) =>
                          location.sailorId != localLocation?.sailorId,
                    )
                    .map(
                      (location) => (
                        sailorId: location.sailorId,
                        displayName: location.displayName,
                        role: location.role,
                        motorcycleStyle: location.motorcycleStyle,
                        sailorSymbol: location.sailorSymbol,
                        sailorColor: location.sailorColor,
                        point: route_domain.GeoPoint(
                          latitude: location.sample.position.latitude,
                          longitude: location.sample.position.longitude,
                          recordedAt: location.sample.recordedAt,
                        ),
                      ),
                    )
              : simulatedSailors
                    .where((sailor) => !sailor.isLocal)
                    .map(
                      (sailor) => (
                        sailorId: sailor.id,
                        displayName: sailor.displayName,
                        role: sailor.role,
                        motorcycleStyle: sailor.motorcycleStyle,
                        sailorSymbol: sailor.sailorSymbol,
                        sailorColor: sailor.sailorColor,
                        point: route_domain.GeoPoint(
                          latitude: sailor.position.latitude,
                          longitude: sailor.position.longitude,
                        ),
                      ),
                    ))
          .map((location) {
            final alert = awareness.alertFor(location.sailorId);
            final needsAttention =
                alert != null &&
                alert.assessment.alertLevel.index >=
                    RouteAlertLevel.urgent.index;
            final isSweeper = _effectiveSweeperSailorIds.contains(
              location.sailorId,
            );
            final isLead = location.role == VoyageRole.lead;
            // A position past its freshness threshold is demoted explicitly in
            // the label. The identity fill remains stable across surfaces.
            final freshness =
                freshnessBySailor[location.sailorId]?.freshness ??
                PresenceFreshness.live;
            final ageSuffix = switch (freshness) {
              PresenceFreshness.live => null,
              PresenceFreshness.none => PresenceFreshness.none.label,
              _ =>
                freshnessBySailor[location.sailorId]?.freshnessLabel ??
                    freshness.label,
            };
            // Issue #151's map companion, kept deliberately minimal: the sailor
            // who raised something already has a marker, so it says what they
            // raised rather than inventing a second symbol beside it.
            final raised = quickMessagesBySender[location.sailorId];
            final roleSuffix = raised != null
                ? raised.label
                : needsAttention
                ? 'check route'
                : isSweeper
                ? 'TEC'
                : isLead
                ? 'Lead'
                : null;
            final label = [
              location.displayName,
              ?roleSuffix,
              ?ageSuffix,
            ].join(' · ');
            // The roster, both maps and trails share this one identity colour.
            // Role and alerts are already named in [label]; changing the fill
            // made one sailor look like different people across surfaces (#250).
            final baseColor = location.sailorColor.color;
            return MapOverlayMarker(
              id: 'sailor-${location.sailorId}',
              point: location.point,
              label: label,
              motorcycleStyle: location.motorcycleStyle,
              sailorSymbol: location.sailorSymbol,
              sailorDisplayName: location.displayName,
              color: baseColor,
            );
          }),
    ];
    _mapOverlays.value = List.unmodifiable(overlays);
    if (updateDerivedState && widget.voyageController.voyageStarted) {
      final session = widget.voyageController.session;
      _skipperStatus.value = session == null
          ? null
          : const SkipperVoyageStatusCalculator().calculate(
              localRole: session.role,
              localSailorId: session.localSailorId,
              localLocation: localLocation,
              sailorLocations: visibleSailorLocations,
              routeAlerts: awareness.routeAlerts
                  .where((alert) => activeSailorIds.contains(alert.sailorId))
                  .toList(growable: false),
              route: awareness.route,
              // Issue #102: a sailor inside the skipper's own track corridor is
              // following the skipper, not off course, and must not be counted.
              skipperTrail: awareness.skipperTrail,
              registeredSweeperSailorIds: _effectiveSweeperSailorIds,
              // Issue #128: two sailors can hold the role at once - one
              // self-selected, one asked - and the group needs one answer, so
              // the skipper's own accepted request breaks the tie.
              assignedSweeperSailorId: _assignedSweeperSailorId,
            );
      _updateSweeperGapTrend(awareness);
    } else if (!widget.voyageController.voyageStarted) {
      _skipperStatus.value = null;
      _sweeperGapTrendTracker.reset();
      _sweeperGapTrend.value = SweeperGapTrend.unknown;
    }
  }

  /// Publishes the quick messages the voyage map has to present, and returns the
  /// most urgent one per sender so their marker can say what they raised.
  ///
  /// The reducer decides what is admissible; this decides what is still *this
  /// sailor's* to act on, and works out where each sender is. Two position
  /// sources, in that order:
  ///
  /// * the sender's live fix, when they are still reporting one — where they are
  ///   now is what a skipper turning round needs;
  /// * otherwise the fix relayed with the message, which is where they were when
  ///   they raised it. A sailor stopped for fuel is not moving, and their location
  ///   events age out of the 30-minute band long before the message does.
  Map<String, ReceivedQuickMessage> _refreshQuickMessageAlerts({
    required SailorLocation? localLocation,
    required List<SailorLocation> visibleSailorLocations,
    required List<awareness_geo.GeoPoint> route,
  }) {
    final localSailorId = widget.voyageController.session?.localSailorId;
    if (localSailorId == null) {
      _quickMessageAlerts.value = const [];
      return const {};
    }
    final presented = presentableQuickMessageAlerts(
      messages: widget.voyageController.quickMessages,
      localSailorId: localSailorId,
      readerPosition: localLocation?.sample.position,
      livePositions: {
        for (final location in visibleSailorLocations)
          location.sailorId: location.sample.position,
      },
      route: route,
    );
    _quickMessageAlerts.value = presented.alerts;
    return presented.bySender;
  }

  /// Acknowledges the presented message *and* every repeat it stands for, so a
  /// sailor who cancels a `Stopped` is not asked again about the two identical
  /// ones behind it (#178).
  Future<void> _acknowledgeQuickMessage(ReceivedQuickMessage message) async {
    final alert = _quickMessageAlerts.value
        .where((candidate) => candidate.message.eventId == message.eventId)
        .firstOrNull;
    for (final outstanding in alert?.acknowledgeable ?? [message]) {
      await widget.voyageController.acknowledgeQuickMessage(outstanding);
    }
    _updateMapOverlays(updateNavigationPosition: false);
  }

  Set<String> get _registeredSweeperSailorIds => registeredSweeperSailorIds(
    simulatedSailors: _isSimulation ? _simulationController?.sailors : null,
    liveParticipants: widget.voyageController.liveParticipants,
  );

  /// The sailor the skipper's most recently accepted TEC request names, if any.
  /// Voyage Lab drives its own virtual roster and has no relayed requests.
  String? get _assignedSweeperSailorId => _isSimulation
      ? null
      : widget.voyageController.sweeperRoleAssignments.acceptedSweeperSailorId;

  /// One effective back-marker. A skipper-requested TEC wins over an older
  /// self-selection, so the roster, map, gap, rejoin and contact targets do not
  /// simultaneously treat two sailors as the back of one group (#128).
  Set<String> get _effectiveSweeperSailorIds {
    final registered = _registeredSweeperSailorIds;
    final assigned = _assignedSweeperSailorId;
    final assignedParticipant = assigned == null
        ? null
        : widget.voyageController.participantFor(assigned);
    if (assignedParticipant?.isIncludedInLiveCount == true) return {assigned!};
    return registered;
  }

  Future<void> _maybeAutomaticallyEndVoyage(
    SituationalAwarenessController awareness,
    route_domain.GeoPoint? localPosition,
  ) async {
    if (_autoEndingVoyage ||
        !widget.voyageController.voyageStarted ||
        widget.voyageController.voyageEnded ||
        widget.voyageController.voyagePaused) {
      return;
    }
    final session = widget.voyageController.session;
    // A real voyage remains skipper-owned. Voyage Lab drives the entire virtual
    // group locally, so completion must work from its skipper, follower and TEC
    // perspectives alike.
    if (session == null ||
        (!_isSimulation && session.role != VoyageRole.lead)) {
      return;
    }
    final route = _activeRoute;
    final destination = _routeDestination(route);
    if (destination == null) return;
    // Monotonic progress along the plan, not proximity to its last point. On a
    // loop the two are the same thing at the start line (#206).
    final progress = _completionProgressTracker.update(route, localPosition);
    final assessment = _voyageCompletionDetector.assess(
      destination: awareness_geo.GeoPoint(
        latitude: destination.latitude,
        longitude: destination.longitude,
      ),
      sailorLocations: awareness.sailorLocations,
      now: DateTime.now(),
      routeProgressFraction: progress.totalMeters <= 0
          ? 0
          : progress.progressMeters / progress.totalMeters,
    );
    if (!assessment.ready) {
      _completionPromptedForArrival = false;
      _voyageCompletionSuggestion.value = null;
      return;
    }
    // A dismissed suggestion stays dismissed while the group remains inside
    // the destination radius. Leaving and returning arms a fresh suggestion.
    if (_completionPromptedForArrival) return;
    _completionPromptedForArrival = true;
    // Offered, not imposed: the sailor keeps the map and the guidance, and acts
    // on this when they are ready. Nothing is awaited here, so arrival no
    // longer holds the voyage open behind a barrier.
    _voyageCompletionSuggestion.value = assessment;
  }

  /// The sailor waved the suggestion away.
  ///
  /// It stays away while the group remains inside the destination radius, which
  /// `_completionPromptedForArrival` already tracks; leaving and returning arms
  /// a fresh one, exactly as the modal behaved.
  void _dismissVoyageCompletionSuggestion() =>
      _voyageCompletionSuggestion.value = null;

  /// The sailor chose to end it for the group.
  ///
  /// Ending for everyone is irreversible for the group, so the confirmation
  /// carrying `endVoyageConsequence` stays. #380 was about the suggestion not
  /// blocking, not about removing the consequence.
  Future<void> _endVoyageFromCompletionSuggestion() async {
    if (_autoEndingVoyage) return;
    _autoEndingVoyage = true;
    try {
      if (!mounted) return;
      final decision = await showVoyageCompletionDialog(
        context,
        assessment: _voyageCompletionSuggestion.value ?? _emptyAssessment,
        relayCanCarryReopen: _relayCanCarryReopen,
      );
      if (decision == VoyageCompletionDecision.endForEveryone) {
        _voyageCompletionSuggestion.value = null;
        await widget.voyageController.endVoyage();
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not end the completed voyage: $error\n$stackTrace');
      }
    } finally {
      _autoEndingVoyage = false;
    }
  }

  static const _emptyAssessment = VoyageCompletionAssessment(
    routeProgressFraction: 0,
    minimumRouteProgressFraction: 0,
    destinationRadiusMeters: 0,
    sailorCount: 0,
    freshSailorCount: 0,
    arrivedSailorCount: 0,
  );

  static route_domain.GeoPoint? _routeDestination(
    route_domain.ImportedRoute? route,
  ) {
    if (route == null) return null;
    for (final path in route.paths.reversed) {
      if (path.points.isNotEmpty) return path.points.last;
    }
    return route.waypoints.isEmpty ? null : route.waypoints.last.point;
  }

  /// Voyage Lab drives the same trail model as a real voyage, so the simulator can
  /// no longer show a skipper track the live path never builds (#100).
  void _updateSimulationSailorTrails(
    List<SimulatedSailorSnapshot> sailors,
  ) => _publishSailorTrails([
    for (final sailor in sailors)
      SailorTrail(
        sailorId: sailor.id,
        displayName: sailor.displayName,
        kind: SailorTrailRecorder.kindFor(
          isSkipper: sailor.role == VoyageRole.lead,
          isOffRoute: sailor.isOffRoute,
        ),
        // Voyage Lab maintains its own ephemeral history; the same per-sailor
        // cap is applied here so the simulator and a real voyage agree.
        points: _trailRecorder.boundedTrail(_routePoints(sailor.travelTrail)),
      ),
  ]);

  /// Records and publishes every eligible sailor's travelled trail from position
  /// history alone.
  ///
  /// Route matching decides route progress and alerts; it never decides whether
  /// a trail is drawn. The skipper's trail also draws on the awareness
  /// controller's skipper history, which is rebuilt from the durable journal on
  /// restart, so it survives an app restart mid-voyage as far as the journal
  /// allows.
  void _updateSailorTrails(SituationalAwarenessController awareness) {
    if (!widget.voyageController.voyageStarted) {
      _trailRecorder.clear();
      _publishSailorTrails(const []);
      return;
    }
    final alerts = {
      for (final alert in awareness.routeAlerts) alert.sailorId: alert,
    };
    _publishSailorTrails(
      _trailRecorder.update([
        for (final location in awareness.sailorLocations)
          SailorTrailUpdate(
            sailorId: location.sailorId,
            displayName: location.displayName,
            position: route_domain.GeoPoint(
              latitude: location.sample.position.latitude,
              longitude: location.sample.position.longitude,
              recordedAt: location.sample.recordedAt,
            ),
            isSkipper: location.role == VoyageRole.lead,
            isOffRoute: _isOffRouteState(
              alerts[location.sailorId]?.assessment.state,
            ),
            isEligible:
                widget.voyageController
                    .participantFor(location.sailorId)
                    ?.isEligibleForLivePosition ==
                true,
            journalTrail: location.role == VoyageRole.lead
                ? [
                    for (final sample in awareness.skipperTrailSamples)
                      route_domain.GeoPoint(
                        latitude: sample.position.latitude,
                        longitude: sample.position.longitude,
                        recordedAt: sample.recordedAt,
                      ),
                  ]
                : null,
          ),
      ]),
    );
  }

  /// Feeds the current gap into the trend tracker.
  ///
  /// The history is dropped when the role moves to a different sailor: the
  /// previous TEC's gap says nothing about the new one's, and carrying it over
  /// would report a trend for a sailor who has only just been asked.
  void _updateSweeperGapTrend(SituationalAwarenessController awareness) {
    final status = _skipperStatus.value;
    if (status == null) {
      _sweeperGapTrendTracker.reset();
      _sweeperGapTrend.value = SweeperGapTrend.unknown;
      return;
    }
    if (status.sweeperSailorId != _trendedSweeperSailorId) {
      _trendedSweeperSailorId = status.sweeperSailorId;
      _sweeperGapTrendTracker.reset();
    }
    final sweeperPosition = status.sweeperSailorId == null
        ? null
        : awareness.sailorLocations
              .where((sailor) => sailor.sailorId == status.sweeperSailorId)
              .map((sailor) => sailor.sample.position)
              .firstOrNull;
    _sweeperGapTrend.value = _sweeperGapTrendTracker.update(
      availability: status.sweeperAvailability,
      gapMeters: status.distanceToSweeperMeters,
      sweeperPosition: sweeperPosition,
      now: DateTime.now(),
    );
  }

  static List<route_domain.GeoPoint> _routePoints(
    List<awareness_geo.GeoPoint> points,
  ) => [
    for (final point in points)
      route_domain.GeoPoint(
        latitude: point.latitude,
        longitude: point.longitude,
      ),
  ];

  void _publishSailorTrails(List<SailorTrail> trails) {
    _recordedTrailTraces = List.unmodifiable([
      for (final trail in trails.where((trail) => trail.isRenderable))
        for (final (index, points)
            in _trailRecorder
                .continuousSegments(trail.points)
                .where((segment) => segment.length >= 2)
                .indexed)
          MapOverlayTrace(
            id: index == 0
                ? 'trail-${trail.sailorId}'
                : 'trail-${trail.sailorId}-$index',
            points: points,
            label: switch (trail.kind) {
              SailorTrailKind.skipper => '${trail.displayName} skipper trail',
              SailorTrailKind.offRoute =>
                '${trail.displayName} off-route trace',
              SailorTrailKind.sailor => '${trail.displayName} trail',
              // SailorTrailRecorder only records where sailors have been, so it
              // never produces a rejoin route.
              SailorTrailKind.rejoin => '${trail.displayName} rejoin route',
            },
            kind: trail.kind,
          ),
    ]);
    _pushSailorTrails();
  }

  /// The rejoin breadcrumbs are appended last so they draw above the trails in
  /// the flutter_map fallback, matching the MapLibre layer order. Shared
  /// breadcrumbs from other sailors sit under the local sailor's own, which is the
  /// only one that is guidance for this phone.
  /// Every trace is simplified for display here, once per change, rather than
  /// in a renderer or on every frame: this is the single point both map
  /// implementations read from, so the bound cannot apply to only one of them
  /// (#165).
  void _pushSailorTrails() {
    _sailorTrails.value = List.unmodifiable([
      for (final trace in _recordedTrailTraces) _simplifiedForDisplay(trace),
    ]);
  }

  MapOverlayTrace _simplifiedForDisplay(MapOverlayTrace trace) {
    final simplified = _trailSimplifier.simplify(trace.points);
    if (simplified.length == trace.points.length) return trace;
    return MapOverlayTrace(
      id: trace.id,
      points: simplified,
      label: trace.label,
      kind: trace.kind,
    );
  }

  static bool _isOffRouteState(RouteTrackingState? state) =>
      state == RouteTrackingState.suspectedOffRoute ||
      state == RouteTrackingState.offRoute ||
      state == RouteTrackingState.recovering;

  /// The longest path of [route] as awareness-domain points.
  ///
  /// Two `GeoPoint` types exist in this app, so the conversion is explicit; the
  /// longest path is the travelled one.
  static List<awareness_geo.GeoPoint> _routeAsPoints(
    route_domain.ImportedRoute? route,
  ) {
    if (route == null || route.paths.isEmpty) return const [];
    final longestPath = route.paths.reduce(
      (current, candidate) =>
          candidate.points.length > current.points.length ? candidate : current,
    );
    return longestPath.points
        .map(
          (point) => awareness_geo.GeoPoint(
            latitude: point.latitude,
            longitude: point.longitude,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _onReceivedEvent(
    VoyageEvent event,
    VoyageTransportEvidence transport,
  ) async {
    widget.voyageController.noteTransportObservation(event.id, transport);
    if (_isSituationalEvent(event.type)) {
      final awareness = _awarenessController;
      if (awareness == null) {
        widget.voyageController.ingestStoredEvent(event);
        return;
      }
      try {
        await awareness.ingestRemoteEvent(event);
      } on Object catch (error, stackTrace) {
        if (kDebugMode) {
          debugPrint(
            'Rejected received situational event: $error\n$stackTrace',
          );
        }
      }
    } else {
      widget.voyageController.ingestStoredEvent(event);
    }
  }

  static bool _isSituationalEvent(VoyageEventType type) => switch (type) {
    VoyageEventType.sailorLocationUpdated ||
    VoyageEventType.hazardReported ||
    VoyageEventType.hazardCleared ||
    VoyageEventType.routeDeviationChanged ||
    VoyageEventType.routeAlertAcknowledged => true,
    _ => false,
  };

  void _onVoyageControllerChanged() {
    final session = widget.voyageController.session;
    final voyageStarted =
        widget.voyageController.voyageStarted &&
        !widget.voyageController.voyageEnded;
    final voyageJustStarted = voyageStarted && !_observedVoyageStarted;
    _observedVoyageStarted = voyageStarted;
    // The journal only accepts fixes from the start onwards, so the first fix
    // after the start has nothing to be measured against and must report
    // whatever the sailor has or has not moved since.
    if (voyageJustStarted) _positionReportGate.reset();
    if (voyageJustStarted) unawaited(_warmNaturalVoiceIfNeeded());
    if (session != null) {
      _awarenessController?.updateLocalSession(session);
      _observerAccessController?.updateSession(session);
      _updateMapOverlays();
      unawaited(_synchroniseVoyageControllers());
      if (voyageJustStarted && !_localVoyageStartInProgress) {
        unawaited(_resumeLocationForActiveVoyage());
      }
      if (_lastPushRole != session.role) {
        _lastPushRole = session.role;
        unawaited(_pushNotificationController?.refreshRegistration());
      }
      _publishObserverSnapshot();
      unawaited(_promptPendingSweeperRequest());
    }
    if (widget.voyageController.voyageEnded && !_voyageEndHandled) {
      unawaited(_handleVoyageEnded());
    }
    _schedulePublish();
  }

  /// Starts location for the map before the voyage does, so a sailor can see
  /// themselves while the group is still gathering (#300).
  ///
  /// Location used to start only once the voyage had, which left the pre-start map
  /// with no own position and no way to get one - reported as "before I started
  /// a voyage I couldn't see my own position and there was no way to get it".
  /// Gathering is exactly when a group is checking who has arrived and where
  /// they are.
  ///
  /// **Starting the stream does not start recording.** Fixes reach the map
  /// through `_onDeviceLocationChanged`, which only redraws overlays;
  /// `SituationalAwarenessController.recordLocalLocation` refuses every sample
  /// until `voyageStarted`, and relay publishing is driven by the event journal
  /// rather than by fixes. So nothing is journalled or shared before Start voyage,
  /// which is the half of the request that must not be broken.
  ///
  /// Deliberately not [_resumeLocationForActiveVoyage]: that resets the
  /// position-report gate, which paces *sharing*, and there is nothing to pace
  /// yet. A failure here is also silent rather than a warning banner - #262 asks
  /// for a calmer pre-start screen, and Follow me still surfaces a genuine
  /// permission problem when the sailor asks for it.
  Future<void> _startLocationForPreStartMap() async {
    final locationController = _locationController;
    if (locationController == null ||
        widget.voyageController.voyageStarted ||
        widget.voyageController.voyageEnded) {
      return;
    }
    try {
      await locationController.resumeIfAuthorized();
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint(
          'Could not start GPS before the voyage: $error\n$stackTrace',
        );
      }
    }
  }

  Future<void> _resumeLocationForActiveVoyage() async {
    final locationController = _locationController;
    if (locationController == null ||
        !widget.voyageController.voyageStarted ||
        widget.voyageController.voyageEnded) {
      return;
    }
    // The gap since the last report is not travel, so the next fix reports
    // unconditionally rather than being measured against wherever this sailor was
    // when sharing last stopped.
    _positionReportGate.reset();
    try {
      await locationController.resumeIfAuthorized();
    } on Object catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('Could not resume live GPS: $error\n$stackTrace');
      }
      final added = _warnings.add(
        'Live GPS could not resume automatically. Use Follow me or Safety '
        'to try again.',
      );
      if (added && mounted) setState(() {});
    }
  }

  Future<void> _synchroniseVoyageControllers() async {
    await _replaceAwarenessController(_activeRoute);
    if (!mounted) return;
    if (_isSimulation) {
      await _replaceSimulationController(_activeRoute);
    } else {
      await _applyAuthoritativeRouteDecision();
    }
    _applyVoyagePauseState();
  }

  void _applyVoyagePauseState() {
    if (!_isSimulation) return;
    final simulation = _simulationController;
    if (simulation == null) return;
    final voyageStarted =
        widget.voyageController.voyageStarted &&
        !widget.voyageController.voyageEnded;
    final simulationHadStarted = simulation.voyageStarted;
    simulation.setVoyageStarted(voyageStarted);
    if (!voyageStarted) {
      _simulationPausedByVoyage = false;
      return;
    }
    if (widget.voyageController.voyagePaused) {
      if (simulation.isRunning) {
        simulation.pause();
        _simulationPausedByVoyage = true;
      }
      return;
    }
    if (!simulationHadStarted || _simulationPausedByVoyage) {
      _simulationPausedByVoyage = false;
      simulation.start();
    }
  }

  Future<void> _handleVoyageEnded() async {
    if (_voyageEndHandled) return;
    _voyageEndHandled = true;
    _stalenessTimer?.cancel();
    _simulationAwarenessTimer?.cancel();
    _stalenessTimer = null;
    await _preStartPresenceController?.stop();
    await _pushNotificationController?.stop();
    await _locationController?.stop();
  }

  /// Hands the reconciled presence to the one model every surface reads, along
  /// with whether this device can receive positions at all — so a missing marker
  /// is attributed to the transport rather than silently to the sailor.
  void _publishLivePresence(List<LiveSailorPresence> presence) {
    widget.voyageController.observeLivePresence(
      presence,
      // The roster still names the sailors who have left, which is how their
      // record survives a departure even if their membership events never
      // reached this phone's journal (#144). It adds nobody to the live count.
      roster: _preStartPresenceController?.roster ?? const [],
      positionChannelUnavailable:
          _preStartPresenceController?.unavailableReason != null,
    );
  }

  void _onPreStartPresenceChanged() {
    if (!mounted) return;
    // Presence is the channel that does not depend on the bulk event batch, so
    // it is what tells the roster a sailor has joined.
    _publishLivePresence(_reconciledLivePresence());
    // A capability refusal, a rejected credential or an older peer used to turn
    // live positions off with no visible reason at all.
    var changed = false;
    for (final limitation
        in _preStartPresenceController?.limitations ?? const []) {
      if (_warnings.add(limitation.message)) changed = true;
    }
    _updateMapOverlays();
    if (changed && mounted) setState(() {});
  }

  /// One reconciled live-position model: the durable journal, the internet
  /// presence channel, the nearby presence channel and the relay's
  /// cursor-independent roster, merged newest-sample-wins.
  List<LiveSailorPresence> _reconciledLivePresence() {
    final session = widget.voyageController.session;
    if (session == null || _isSimulation) return const [];
    final presence = _preStartPresenceController;
    return const LivePresenceReconciler().reconcile(
      now: DateTime.now(),
      localSailorId: session.localSailorId,
      journal: _awarenessController?.sailorLocations ?? const [],
      internetPresence: presence?.internetLocations ?? const [],
      nearbyPresence: presence?.nearbyLocations ?? const [],
      roster: presence?.roster ?? const [],
      // A peer's position is aged on the relay's clock, not this phone's.
      relayClockOffset: presence?.relayClockOffset ?? Duration.zero,
    );
  }

  void _onDeviceLocationChanged() {
    if (!mounted) return;
    final status = _locationController?.status;
    final warningChanged =
        status != null && status.canSample && !status.backgroundCapable
        ? _warnings.add(_backgroundLocationWarning)
        : _warnings.remove(_backgroundLocationWarning);
    // The foreground map follows the newest device fix even if writing that
    // sample to the durable voyage journal is briefly delayed or fails. Only
    // the journal feeds trails, summaries and GPX recording.
    _updateMapOverlays(updateDerivedState: false, updateOverlayMarkers: false);
    if (warningChanged) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // Leaving the foreground is the last certain moment before the process may
      // be reclaimed, so the log is written out here rather than trusted to a
      // tidy end-of-voyage that may never arrive (#456).
      unawaited(_diagnosticsWriter?.flush());
      return;
    }
    unawaited(_locationController?.restartAfterForegroundResume());
  }

  void _schedulePublish() {
    final eventCount = widget.voyageController.eventCount;
    if (eventCount != _observedNearbyPublishEventCount) {
      _observedNearbyPublishEventCount = eventCount;
      _nearbyPublishWorkPending = true;
    }
    if (!_nearbyPublishWorkPending || _nearbyPublishInFlight) return;
    _nearbyPublishWorkPending = false;
    _nearbyPublishInFlight = true;
    unawaited(() async {
      var retryNeeded = false;
      try {
        retryNeeded = await _publishPendingEvents();
      } finally {
        _nearbyPublishInFlight = false;
        if (retryNeeded) {
          // A later controller or transport notification retries it. Do not
          // spin immediately against an unavailable radio.
          _nearbyPublishWorkPending = true;
        } else if (_nearbyPublishWorkPending) {
          // An event arrived while the scan was running.
          _schedulePublish();
        }
      }
    }());
  }

  /// Returns true when at least one event could not be handed to Nearby.
  Future<bool> _publishPendingEvents() async {
    _internetRelayController?.wake();
    final relay = _relayController;
    final session = widget.voyageController.session;
    if (!_relayConfigured || relay == null || session == null) return false;
    var retryNeeded = false;
    // VoyageController is updated one event at a time as the shared store is
    // written. Walking that in-memory view avoids querying and JSON-decoding
    // the complete SQLite voyage on every new position (#165).
    for (final event in widget.voyageController.events) {
      if (_publishedEventIds.contains(event.id)) continue;
      try {
        // Bounded, because this is an await on a transport from a chain that a
        // rejoin and a cold start both walk over the whole eligible backlog. A
        // publish that never returns would stall every later event behind it for
        // as long as the app is running, and a phone in that state is
        // indistinguishable from a hung app (#209).
        await relay
            .publish(event)
            .timeout(
              _nearbyPublishTimeout,
              onTimeout: () {
                throw TimeoutException('nearby publish', _nearbyPublishTimeout);
              },
            );
        _publishedEventIds.add(event.id);
      } on Object catch (error) {
        retryNeeded = true;
        if (kDebugMode) {
          debugPrint('Could not queue ${event.id} for nearby relay: $error');
        }
      }
    }
    return retryNeeded;
  }

  /// One nearby publish is a local hand-off to the transport, not a round trip,
  /// so seconds are already generous. The number exists to make "never" and
  /// "slow" different outcomes.
  static const _nearbyPublishTimeout = Duration(seconds: 5);

  @override
  Widget build(BuildContext context) {
    if (widget.voyageController.voyageEnded) {
      return EndedVoyageScreen(
        controller: widget.voyageController,
        distanceUnits: widget.distanceUnits,
        nearbyRelayController: _relayController,
        internetRelayController: _internetRelayController,
        onRemoveVoyage: _removeEndedVoyage,
        relayCanCarryReopen: _relayCanCarryReopen,
        // The share on this screen omitted the recorded log entirely, so a sailor
        // who ended the voyage and pressed the obvious button lost it (#456).
        diagnostics: _endedVoyageDiagnostics,
      );
    }
    final selectedBody = _isSimulation
        ? switch (_selectedIndex) {
            0 => _buildMap(),
            1 => _buildSimulation(),
            2 => _buildDetails(),
            _ => _buildSettings(),
          }
        : switch (_selectedIndex) {
            0 => _buildMap(),
            1 => _buildDetails(),
            _ => _buildSettings(),
          };
    final session = widget.voyageController.session!;
    final body = widget.voyageController.voyageStarted
        ? selectedBody
        : Column(
            children: [
              _PreStartVoyagePanel(
                voyageCode: session.voyageCode,
                // Who is here, not who has been here: the waiting-to-start
                // lobby is a live list, and a sailor who has left keeps their
                // record in the voyage roster instead (#144).
                participants: widget.voyageController.liveParticipants,
                coordinationMode: widget.voyageController.coordinationMode,
                isSkipper: session.role == VoyageRole.lead,
                busy: widget.voyageController.busy || _loading,
                routeName: _activeRoute?.name,
                onStartVoyage: _confirmStartVoyage,
                onChooseRoute: _requestRouteChange,
                onJoinGroup: widget.onJoinGroupRequested == null
                    ? null
                    : _joinGroupBeforeStart,
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: selectedBody,
                ),
              ),
            ],
          );

    return ValueListenableBuilder<MapNavigationPosition?>(
      valueListenable: _mapNavigationPosition,
      builder: (context, navigationPosition, _) {
        final landscape =
            MediaQuery.orientationOf(context) == Orientation.landscape;
        // The native map flashes when a bottom bar is repeatedly inserted as
        // GPS speed dips at lights. Once there is a navigation fix, preserve
        // the map viewport until the sailor deliberately leaves the map tab.
        final hideWhileMoving =
            widget.voyageController.voyageStarted &&
            _selectedIndex == 0 &&
            _activeRoute != null &&
            (navigationPosition != null ||
                _junctionMarkerOverlay.value != null);
        final destinations = [
          for (final destination in _voyageDestinations)
            NavigationDestination(
              icon: Icon(destination.icon),
              selectedIcon: Icon(destination.selectedIcon),
              label: destination.label,
            ),
        ];
        // Whatever hides the navigation also has to offer the way back, and it
        // has to be this shell that does: the map cannot be relied on for it.
        // It renders a spinner until its style loads, and a sailor whose bar is
        // already gone would have nothing at all until that finished — which is
        // exactly the state a widget test lands in, and the state a slow phone
        // lands in on a cold start.
        final ridingBody = hideWhileMoving
            ? Stack(
                children: [
                  Positioned.fill(child: body),
                  // The one thing #133 puts in the upper leading corner, in the
                  // same place, so a sailor reaches for it where the voyage menu
                  // has always been.
                  Positioned(
                    left: 12,
                    top:
                        MediaQuery.paddingOf(context).top +
                        (landscape ? 12 : portraitVoyageMenuTopOffset),
                    child: FloatingActionButton.small(
                      key: const Key('voyage-menu-button'),
                      heroTag: 'tide-and-seek-shell-menu',
                      tooltip: 'Voyage actions',
                      onPressed: _openVoyageMenu,
                      backgroundColor: const Color(0xE6252E39),
                      foregroundColor: Colors.white,
                      child: const Icon(Icons.menu),
                    ),
                  ),
                ],
              )
            : body;
        if (landscape && !hideWhileMoving) {
          return Scaffold(
            body: Row(
              children: [
                SafeArea(
                  right: false,
                  child: NavigationRail(
                    key: const Key('landscape-navigation-rail'),
                    // Wider than the 56 it was, to carry the words. Same
                    // reasoning as the portrait bar: this rail is hidden while
                    // the sailor is moving, so its cost is paid only at a
                    // standstill, and four unlabelled icons are what #306 is
                    // about.
                    minWidth: 72,
                    groupAlignment: -0.7,
                    labelType: NavigationRailLabelType.all,
                    selectedIndex: _selectedIndex,
                    onDestinationSelected: (index) =>
                        setState(() => _selectedIndex = index),
                    destinations: [
                      for (final destination in destinations)
                        NavigationRailDestination(
                          icon: destination.icon,
                          selectedIcon: destination.selectedIcon,
                          label: Text(destination.label),
                        ),
                    ],
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          );
        }
        return Scaffold(
          // Both orientations arrive here when the chrome is hidden: the
          // landscape rail above is only taken while it is showing.
          body: ridingBody,
          bottomNavigationBar: hideWhileMoving
              ? null
              : NavigationBar(
                  height: landscape ? 60 : 68,
                  // Named, not four bare icons.
                  //
                  // #306: "no feature reachable only through an unlabelled
                  // icon", after a shipped feature was concluded missing
                  // because its only affordance was one. This bar is the app's
                  // primary navigation and it was hiding what its four
                  // destinations are.
                  //
                  // It costs nothing where it matters: the whole bar is already
                  // hidden while the sailor is moving (`hideWhileMoving`), so
                  // labels only ever appear at a standstill, which is exactly
                  // the surface that can afford words.
                  labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                  selectedIndex: _selectedIndex,
                  onDestinationSelected: (index) =>
                      setState(() => _selectedIndex = index),
                  destinations: destinations,
                ),
        );
      },
    );
  }

  Widget _buildMap() {
    if (!widget.enableNativeServices && !_isSimulation) {
      return Scaffold(
        appBar: AppBar(title: const Text('Navigation')),
        body: const Center(child: Text('Navigation map')),
      );
    }
    final routeStore = activeVoyageMapStoreWhenReady(
      initializing: _loading,
      isSimulation: _isSimulation,
      voyageRouteStore: _voyageRouteStore,
      simulationRouteStore: _simulationRouteStore,
    );
    if (routeStore == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return VoyageMapFeature.fromEnvironment(
      key: ValueKey(
        'voyage-map:${_appliedAuthoritativeRouteRevision ?? 'local'}:'
        '${_activeRoute?.id ?? 'none'}',
      ),
      currentPosition: _mapPosition,
      completedVoyageStore: widget.completedVoyageStore,
      navigationPosition: _mapNavigationPosition,
      overlayMarkers: _mapOverlays,
      sailorTrails: _sailorTrails,
      skipperStatus: _skipperStatus,
      sweeperGapTrend: _sweeperGapTrend,
      groupSailorCount: widget.voyageController.liveParticipants.length,
      onOpenRoster: _openRoster,
      // Deliberately not `onOpenVoyageMenu`. The control that reaches the other
      // tabs is rendered by this shell instead — see _openVoyageMenu and #404.
      junctionMarkerOverlay: _junctionMarkerOverlay,
      voyageCompletionSuggestion: _voyageCompletionSuggestion,
      onEndVoyageForEveryone: _endVoyageFromCompletionSuggestion,
      onDismissVoyageCompletion: _dismissVoyageCompletionSuggestion,
      quickMessageAlerts: _quickMessageAlerts,
      onAcknowledgeQuickMessage: _acknowledgeQuickMessage,
      dismissedQuickMessageInterruptIds: _dismissedQuickMessageInterruptIds,
      dismissedQuickMessageReceiptIds: _dismissedQuickMessageReceiptIds,
      onDismissQuickMessageInterrupt: _dismissedQuickMessageInterruptIds.add,
      onDismissQuickMessageReceipt: _dismissedQuickMessageReceiptIds.add,
      initialRouteStartConnector: _routeStartConnector,
      onRouteStartConnectorChanged: (connector) =>
          _routeStartConnector = connector,
      emergencyContacts: _emergencyContacts,
      onEmergencyAlert: _sendEmergencyMapAlert,
      onEmergencyIssue: _sendEmergencyMapIssue,
      onEmergencyContactUsed: _onEmergencyContactUsed,
      voyagePaused: widget.voyageController.voyagePaused,
      voyageHasNoSkipper: widget.voyageController.voyageHasNoSkipper,
      voyageStarted: widget.voyageController.voyageStarted,
      onLeaveVoyage: _confirmLeaveVoyageFromMap,
      onRouteCommitted: _onRouteChanged,
      onNavigationGuidanceChanged: _onNavigationGuidanceChanged,
      changeRouteRequestToken: _changeRouteRequestToken,
      onChangeRouteRequestHandled: _clearChangeRouteRequest,
      pendingSharedGpxFile: _pendingSharedGpxFile,
      pendingInAppRoute: _pendingInAppRoute,
      acquireCurrentPosition: _isSimulation
          ? () async => _mapPosition.value
          : _acquireCurrentPosition,
      routeStore: routeStore,
      canEditRoute:
          _isSimulation || widget.voyageController.isLocalVoyageSkipper,
      distanceUnit: widget.distanceUnits.value,
      showRouteProgress: widget.routeProgressDisplay?.enabled ?? true,
      darkMapStyle: widget.mapStyleMode.resolveDark(
        MediaQuery.platformBrightnessOf(context),
      ),
      restrainedLightMapStyle:
          widget.mapStyleMode.dayStyle == DayMapStyle.restrained,
      localMotorcycleStyle:
          widget.voyageController.session?.motorcycleStyle ??
          motorcycleIconStyleDefault,
      localSailorSymbol:
          widget.voyageController.session?.sailorSymbol ?? sailorSymbolDefault,
      localDisplayName: widget.voyageController.session?.displayName ?? 'You',
      localBadgeColor: _localBadgeColor,
    );
  }

  void _onNavigationGuidanceChanged(NavigationGuidance? guidance) {
    _recordManoeuvreDiagnostics(guidance);
    _speakGuidance(guidance);
    _updateMapOverlays(updateDerivedState: false);
  }

  /// The audio mode in force: what the sailor chose, quietened while off route.
  ///
  /// Off route, turn-by-turn names junctions that are not coming, so it drops to
  /// alerts only — but a sailor who chose silence stays silent, because an
  /// explicit choice outranks an automatic one (#415).
  SpokenAudioMode get _spokenAudioMode {
    final chosen = widget.spokenGuidance?.mode ?? SpokenAudioMode.silent;
    return chosen;
  }

  void _onSpokenGuidanceChanged() {
    unawaited(_warmNaturalVoiceIfNeeded());
  }

  /// Pulls the expensive model load out of the first camera or turn prompt.
  /// Silent audio and a voyage that has not started remain zero-work paths.
  Future<void> _warmNaturalVoiceIfNeeded() async {
    final controller = widget.spokenGuidance;
    final speaker = _spokenGuidance;
    if (controller == null || speaker == null) return;
    final voyageActive =
        widget.voyageController.voyageStarted &&
        !widget.voyageController.voyageEnded;
    final naturalEnabled =
        controller.naturalVoicePack.enabled &&
        controller.naturalVoicePack.modelDirectory != null;
    try {
      await speaker.warmUp(
        enabled: voyageActive && controller.enabled && naturalEnabled,
      );
    } on Object catch (error, stackTrace) {
      // OS speech remains configured as the fail-safe. A model-load problem is
      // useful in diagnostics but must never block or end a voyage.
      _diagnostics?.recordNote('Natural voice warm-up failed: $error');
      if (kDebugMode) {
        debugPrint('Natural voice warm-up failed: $error\n$stackTrace');
      }
    }
  }

  void _recordSpeechOutput(String phrase, SpokenGuidanceOutput output) {
    _diagnostics?.recordSpeechDelivery(phrase: phrase, output: output);
  }

  void _recordManoeuvreDiagnostics(NavigationGuidance? guidance) {
    final diagnostics = _diagnostics;
    if (diagnostics == null || guidance == null) return;
    final instruction = guidance.instruction;
    diagnostics.recordManoeuvre(
      // The manoeuvre's identity, matching the key `_speakGuidance` uses, so
      // re-deriving the same turn on every fix does not write it down again.
      key: instruction.maneuver.identity,
      position: awareness_geo.GeoPoint(
        latitude: instruction.maneuver.position.latitude,
        longitude: instruction.maneuver.position.longitude,
      ),
      shownAs: instruction.direction.label,
      diagnostics: maneuverDiagnosticsReport(instruction),
    );
  }

  /// Speaks the instruction the phone banner and the car rows are already showing
  /// (#286).
  ///
  /// Deliberately driven from here rather than from its own timer or a second
  /// derivation of the route. This is the one place the current instruction
  /// changes, so audio cannot disagree with the screen - and a sailor who hears
  /// one thing and sees another will trust neither.
  ///
  /// [ManeuverInstruction.standaloneText] is the wording, for the reason it
  /// already exists: it is what surfaces with no symbol beside them use, which is
  /// exactly what audio is. A roundabout says so out loud, where the banner can
  /// leave it to the drawn glyph.
  void _speakGuidance(NavigationGuidance? guidance) {
    if (guidance == null) return;
    final controller = widget.voyageController;
    final identity = guidance.instruction.maneuver.identity;

    // The instruction has moved on, so the one before it is now behind the sailor
    // and its position is what the clearance rule measures against (#429).
    if (identity != _guidanceManeuverIdentity) {
      if (_guidanceManeuverIdentity != null) {
        _passedManeuverPosition = _lastGuidanceManeuverPosition;
      }
      _guidanceManeuverIdentity = identity;
    }
    _lastGuidanceManeuverPosition = guidance.instruction.maneuver.position;

    final speaker = _spokenGuidance;
    if (speaker == null) return;

    final navigation = _mapNavigationPosition.value;
    final passed = _passedManeuverPosition;
    final sailor = navigation?.point;
    final metersSincePrevious = passed == null || sailor == null
        ? null
        : GeoCalculations.distanceMeters(
            awareness_geo.GeoPoint(
              latitude: sailor.latitude,
              longitude: sailor.longitude,
            ),
            awareness_geo.GeoPoint(
              latitude: passed.latitude,
              longitude: passed.longitude,
            ),
          );

    // What to say and when, decided apart from the saying so the timing can be
    // driven by a synthetic approach in a test (#409, #410, #429).
    final announcement = nextGuidanceAnnouncement(
      maneuverIdentity: identity,
      instructionText: guidance.instruction.standaloneText,
      distanceToManeuverMeters: guidance.distanceMeters,
      speedMetersPerSecond: navigation?.speedMetersPerSecond,
      alreadySpokenKeys: _spokenGuidanceKeys,
      metersSincePreviousManeuver: metersSincePrevious,
      distanceFormatter: MeasurementFormatter(
        widget.distanceUnits.value,
      ).distance,
      // The pair the banner is already showing (#163). Speech was given this and
      // ignored it, which is why a junction close behind another was only ever
      // announced at the junction itself (#460).
      followingInstructionText: guidance.followingInstruction?.standaloneText,
    );
    if (announcement == null) return;

    // Marked spoken before the await, so a slow speech engine cannot let the
    // same stage fire again on the next fix.
    _spokenGuidanceKeys.add(announcement.key);
    // #409 is about *when* this is said, so the distance to the junction at the
    // moment it left the speaker is the measurement.
    _diagnostics?.recordSpokenPrompt(
      phrase: announcement.phrase,
      distanceToManoeuvreMeters: guidance.distanceMeters,
    );
    unawaited(
      speaker.speakManoeuvre(
        // Per stage, not per manoeuvre: keyed on the manoeuvre alone, the early
        // prompt would suppress the two after it.
        key: announcement.key,
        phrase: announcement.phrase,
        // Navigation, so alerts-only silences this and keeps the warnings.
        enabled: spokenAudioAllows(
          _spokenAudioMode,
          SpokenAudioClass.navigation,
        ),
        voyageActive:
            controller.voyageStarted &&
            !controller.voyageEnded &&
            !controller.voyagePaused,
      ),
    );
  }

  /// Records the one durable start transition and contains
  /// storage/authentication failures, so an uncaught Future error from a button
  /// callback cannot escape Flutter's UI path.
  Future<bool> _commitVoyageStart() async {
    _localVoyageStartInProgress = true;
    try {
      await widget.voyageController.startVoyage();
      return true;
    } on Object catch (error, stackTrace) {
      _diagnostics?.recordNote(
        'start voyage failed: ${error.runtimeType}: $error',
      );
      if (kDebugMode) {
        debugPrint('Could not start the voyage: $error\n$stackTrace');
      }
      const message = 'The voyage could not start. Please try again.';
      final added = _warnings.add(message);
      if (added && mounted) setState(() {});
      if (mounted) _showVoyageSnackBar(message);
      return false;
    } finally {
      _localVoyageStartInProgress = false;
    }
  }

  Color get _localBadgeColor {
    final session = widget.voyageController.session;
    if (session == null) return sailorColorDefault.color;
    return session.sailorColor.color;
  }

  /// The skipper and TEC, with a phone number attached only where that sailor has
  /// explicitly shared their own (#188).
  ///
  /// The number comes from `receivedSailorContacts` and nowhere else. It is never
  /// taken from an ICE share — that is the sailor's next of kin — and never from
  /// the roster, a location event or the device. A role with nothing attached is
  /// still listed: the emergency sheet says so plainly rather than hiding it.
  List<MapEmergencyContact> get _emergencyContacts {
    final contacts = <String, MapEmergencyContact>{};
    final sharedNumbers = widget.voyageController.receivedSailorContacts;
    final session = widget.voyageController.session;
    if (session != null &&
        (session.role == VoyageRole.lead ||
            session.role == VoyageRole.sweeper)) {
      contacts[session.localSailorId] = MapEmergencyContact(
        sailorId: session.localSailorId,
        displayName: session.displayName,
        role: session.role,
      );
    }
    for (final sailor in _awarenessController?.sailorLocations ?? const []) {
      if (sailor.role != VoyageRole.lead && sailor.role != VoyageRole.sweeper) {
        continue;
      }
      final shared = sharedNumbers[sailor.sailorId];
      contacts[sailor.sailorId] = MapEmergencyContact(
        sailorId: sailor.sailorId,
        displayName: sailor.displayName,
        role: sailor.role,
        phoneNumber: shared?.phoneNumber,
        contactShareEventId: shared?.eventId,
      );
    }
    return contacts.values.toList(growable: false);
  }

  /// A dialled number is a used share, so it survives the voyage-end purge for the
  /// same reason a called ICE contact does: a sailor who has just phoned somebody
  /// may need to phone them again.
  void _onEmergencyContactUsed(MapEmergencyContact contact) {
    final eventId = contact.contactShareEventId;
    if (eventId != null) widget.voyageController.markSailorContactUsed(eventId);
  }

  Future<void> _sendEmergencyMapAlert() async {
    await _sendEmergencyQuickMessage(QuickMessage.emergencyStop);
    await _autoShareIceWithSkipperIfEnabled();
  }

  Future<void> _sendEmergencyMapIssue(QuickMessage message) =>
      _sendEmergencyQuickMessage(message);

  Future<void> _sendEmergencyQuickMessage(QuickMessage message) async {
    final session = widget.voyageController.session;
    final recipients = _emergencyContacts
        .where((contact) => contact.sailorId != session?.localSailorId)
        .map((contact) => contact.sailorId)
        .toList(growable: false);
    await widget.voyageController.sendQuickMessage(
      message,
      recipientSailorIds: recipients,
      // Where the sailor is standing, relayed with the message: "Bill needs fuel"
      // is not actionable without "1.2 miles back" (#151).
      position: _localQuickMessagePosition,
    );
    await _recordLocalObserverQuickMessage(message);
  }

  Future<void> _sendLocalQuickMessage(QuickMessage message) async {
    await widget.voyageController.sendQuickMessage(
      message,
      position: _localQuickMessagePosition,
    );
    await _recordLocalObserverQuickMessage(message);
  }

  /// The best fix this phone has for itself, journal-first and falling back to
  /// the foreground sample a pre-movement sailor has but has not yet recorded.
  awareness_geo.GeoPoint? get _localQuickMessagePosition =>
      _awarenessController?.localLocation?.sample.position ??
      _locationController?.activeSample?.position;

  Future<void> _recordLocalObserverQuickMessage(QuickMessage message) async {
    if (message == QuickMessage.assistance ||
        message == QuickMessage.emergencyStop ||
        message == QuickMessage.resolved) {
      await _observerAccessController?.recordLocalAssistance(
        message == QuickMessage.resolved ? null : message.name,
      );
      if (mounted) setState(() {});
      _publishObserverSnapshot();
    }
  }

  /// The opt-in "share with the skipper by default" setting, fired alongside
  /// the emergency-stop alert so it still happens if the sailor can't take a
  /// further step. A no-op if the setting is off, there's nothing to share,
  /// or the local sailor is themselves the skipper.
  Future<void> _autoShareIceWithSkipperIfEnabled() async {
    if (!widget.sailorProfile.shareIceWithSkipperByDefault ||
        !widget.sailorProfile.hasEmergencyInfo) {
      return;
    }
    final session = widget.voyageController.session;
    final skipperId = _currentSkipperSailorId;
    if (session == null ||
        skipperId == null ||
        skipperId == session.localSailorId) {
      return;
    }
    await widget.voyageController.shareEmergencyInfo(
      contactName: widget.sailorProfile.emergencyContactName,
      contactPhone: widget.sailorProfile.emergencyContactPhone,
      medicalNotes: widget.sailorProfile.medicalNotes,
      recipientSailorIds: [skipperId],
    );
  }

  /// An explicit sailor action: shares ICE info with everyone in the voyage,
  /// including the phone number, regardless of the default-share setting.
  Future<void> _shareIceInfoWithGroup() async {
    await widget.voyageController.shareEmergencyInfo(
      contactName: widget.sailorProfile.emergencyContactName,
      contactPhone: widget.sailorProfile.emergencyContactPhone,
      medicalNotes: widget.sailorProfile.medicalNotes,
      recipientSailorIds: const [],
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Emergency contact shared with the group.')),
    );
  }

  Future<void> _openIceShareInbox() =>
      IceShareInboxSheet.show(context, widget.voyageController);

  /// Who this sailor's own number would go to if they shared it now (#188).
  ///
  /// An ordinary sailor addresses it to the skipper and the TEC and to nobody
  /// else. A sailor who holds either role is sharing so the sailors they are
  /// leading can reach them, which is the case in the request, so theirs goes to
  /// the voyage. Reversing that is a one-line change in
  /// [SailorContactRecipients.resolve].
  SailorContactRecipients get _ownContactRecipients {
    final session = widget.voyageController.session;
    if (session == null) return const SailorContactRecipients.addressed([]);
    final skipperId = _currentSkipperSailorId;
    return SailorContactRecipients.resolve(
      localRole: session.role,
      skipperSailorId: skipperId == session.localSailorId ? null : skipperId,
      sweeperSailorIds: _effectiveSweeperSailorIds.where(
        (sailorId) => sailorId != session.localSailorId,
      ),
    );
  }

  /// Shares this sailor's own number. An explicit action, never automatic: there
  /// is no path that shares a number as a side effect of anything else, and a
  /// sailor who shares nothing keeps a fully working app.
  Future<void> _shareOwnPhoneNumber() async {
    if (!widget.sailorProfile.hasOwnPhoneNumber) {
      await EmergencyInfoSheet.show(context, widget.sailorProfile);
      return;
    }
    // A new event type is rejected outright by an older build, so an older relay
    // that will not carry it has to be named rather than allowed to look like a
    // successful share.
    final relayCanCarry =
        _internetRelayController?.supportsCapability(
          RelayProtocolCapabilities.sailorContactSharing,
        ) ??
        true;
    if (!relayCanCarry) {
      _showVoyageSnackBar(
        PresenceLimitation.sailorContactSharingUnsupportedByService.message,
      );
      return;
    }
    final recipients = _ownContactRecipients;
    if (recipients.isEmpty) {
      _showVoyageSnackBar(
        'Nobody is holding the skipper or the Sweeper role yet, so there '
        'is nobody to give your number to. Nothing has been shared.',
      );
      return;
    }
    final shared = await widget.voyageController.shareOwnContactNumber(
      phoneNumber: widget.sailorProfile.ownPhoneNumber,
      recipients: recipients,
    );
    if (!mounted) return;
    _showVoyageSnackBar(
      shared
          ? (recipients.toVoyageGroup
                ? 'Your number is now available to this voyage, for this voyage '
                      'only.'
                : 'Your number has gone to the skipper and the Sweeper, and '
                      'to nobody else.')
          : 'Your number was not shared. '
                    '${widget.voyageController.errorMessage ?? ''}'
                .trim(),
    );
  }

  void _showVoyageSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _onPushNotificationStatusChanged() {
    if (mounted) setState(() {});
  }

  void _onPushNotificationOpened(PushOpenRequest request) {
    final session = widget.voyageController.session;
    if (!mounted || session == null || request.voyageId != session.voyageId) {
      return;
    }
    _internetRelayController?.wake();
    final safetyAlert = request.category == 'safety';
    setState(
      () => _selectedIndex = switch ((_isSimulation, safetyAlert)) {
        (true, true) => 3,
        (true, false) => 2,
        (false, true) => 2,
        (false, false) => 1,
      },
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Opened the authenticated voyage alert.')),
      );
  }

  Future<void> _openNotificationPreferences() async {
    final controller = _pushNotificationController;
    if (controller == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notification settings are still loading.'),
        ),
      );
      return;
    }
    await NotificationPreferencesSheet.show(context, controller);
  }

  String? get _currentSkipperSailorId {
    final session = widget.voyageController.session;
    if (session?.role == VoyageRole.lead) return session!.localSailorId;
    for (final sailor in _awarenessController?.sailorLocations ?? const []) {
      if (sailor.role == VoyageRole.lead) return sailor.sailorId;
    }
    return null;
  }

  Future<void> _toggleVoyagePause() async {
    if (widget.voyageController.voyagePaused) {
      await widget.voyageController.resumeVoyage();
    } else {
      await widget.voyageController.pauseVoyage();
    }
  }

  Future<void> _confirmStartVoyage() async {
    // Recorded before the gate, not after (#441). The report is that this
    // control "does nothing", and no path in this file explains it — so the
    // first thing to establish is whether the tap arrives at all, and if it
    // does, which of the two early returns swallows it. An entry here and no `start decision` after it means
    // the gate; no entry at all means the tap never reached Dart.
    final controller = widget.voyageController;
    _diagnostics?.recordNote(
      'start voyage tapped on the phone: '
      'role=${controller.session?.role.name ?? 'none'} '
      'started=${controller.voyageStarted} '
      'busy=${controller.busy} '
      'route=${_activeRoute == null ? 'none' : 'selected'}',
    );
    if (_voyageStartFlowInProgress) {
      _diagnostics?.recordNote(
        'start voyage refused before the dialog: another start flow is active',
      );
      return;
    }
    _voyageStartFlowInProgress = true;
    try {
      if (controller.session?.role != VoyageRole.lead ||
          controller.voyageStarted) {
        _diagnostics?.recordNote(
          'start voyage refused before the dialog: not the skipper, or already '
          'started',
        );
        return;
      }
      final route = _activeRoute;
      final decision = await showDialog<_StartVoyageDecision>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Start this voyage?'),
          content: Text(
            route == null
                ? 'No route is selected. You can choose one now, or start '
                      'without navigation. Live location sharing and voyage '
                      'recording begin only after you start.'
                : 'Route: ${route.name}\n\nLive location sharing, route '
                      'progress, off-course alerts and voyage recording will '
                      'begin for the group.',
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, _StartVoyageDecision.cancel),
              child: const Text('Cancel'),
            ),
            if (route == null) ...[
              TextButton(
                key: const Key('start-without-route-button'),
                onPressed: () =>
                    Navigator.pop(dialogContext, _StartVoyageDecision.start),
                child: const Text('Start without route'),
              ),
              FilledButton.icon(
                key: const Key('choose-route-before-start-button'),
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _StartVoyageDecision.chooseRoute,
                ),
                icon: const Icon(Icons.route_outlined),
                label: const Text('Choose route'),
              ),
            ] else
              FilledButton.icon(
                key: const Key('confirm-start-voyage-button'),
                onPressed: () =>
                    Navigator.pop(dialogContext, _StartVoyageDecision.start),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start voyage'),
              ),
          ],
        ),
      );
      _diagnostics?.recordNote(
        'start voyage decision: ${decision?.name ?? 'dismissed'}',
      );
      if (decision == _StartVoyageDecision.chooseRoute) {
        _requestRouteChange();
        return;
      }
      if (decision == _StartVoyageDecision.start) {
        if (!await _confirmStartWithoutSweeper()) return;
        if (await _commitVoyageStart()) {
          try {
            // The confirmation is an explicit user action and promises that
            // live sharing begins now, so it is the correct place to request
            // permission when the skipper has not granted it yet.
            await _locationController?.requestAndStart();
          } on Object catch (error, stackTrace) {
            if (kDebugMode) {
              debugPrint('Could not start live GPS: $error\n$stackTrace');
            }
            final added = _warnings.add(
              'The voyage started, but live GPS could not start. Use Follow me '
              'or Safety to try again.',
            );
            if (added && mounted) setState(() {});
          }
        }
      }
    } finally {
      _voyageStartFlowInProgress = false;
      if (mounted) _updateMapOverlays(updateDerivedState: false);
    }
  }

  /// Warns the skipper once, before the voyage starts, that nobody is Tail End
  /// Charlie, and returns whether they chose to voyage anyway.
  ///
  /// This is deliberately a warning and not a block: a two-sailor voyage or a
  /// solo scouting voyage is legitimate. It only ever runs inside the start
  /// confirmation, so it cannot nag during the voyage.
  Future<bool> _confirmStartWithoutSweeper() async {
    if (widget.voyageController.coordinationMode ==
        VoyageCoordinationMode.solo) {
      return true;
    }
    if (_effectiveSweeperSailorIds.isNotEmpty) return true;
    final decision = await showDialog<_MissingSweeperDecision>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('no-sweeper-warning'),
        icon: const Icon(Icons.warning_amber_rounded, color: Color(0xFFFFC857)),
        title: const Text('No Sweeper'),
        content: const Text(
          'Nobody in this voyage holds the Sweeper role, so starting '
          'now means:\n\n'
          '· no back-marker to confirm the group is complete\n'
          '· no distance to the back of the group for you\n'
          '· no TEC for a sailor who falls a long way behind to aim for\n\n'
          'A sailor takes the role from their own Voyage tab. Fine for a small '
          'or solo voyage — worth fixing for a group.',
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _MissingSweeperDecision.cancel),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('assign-sweeper-button'),
            onPressed: () => Navigator.pop(
              dialogContext,
              _MissingSweeperDecision.assignSweeper,
            ),
            child: const Text('Assign a TEC'),
          ),
          FilledButton(
            key: const Key('start-without-sweeper-button'),
            onPressed: () => Navigator.pop(
              dialogContext,
              _MissingSweeperDecision.startAnyway,
            ),
            child: const Text('Start anyway'),
          ),
        ],
      ),
    );
    if (decision == _MissingSweeperDecision.assignSweeper && mounted) {
      _openRoster();
    }
    return decision == _MissingSweeperDecision.startAnyway;
  }

  Future<void> _confirmLeaveVoyageFromMap() async {
    final isSkipper = canEndVoyageForEveryone(widget.voyageController);
    final decision = await showVoyageExitDialog(
      context,
      isSkipper: isSkipper,
      isSolo: !widget.voyageController.coordinationMode.isGroup,
    );
    switch (decision) {
      case VoyageExitDecision.leave:
        await _leaveVoyage();
        return;
      case VoyageExitDecision.endForEveryone:
        await _confirmEndVoyage();
        return;
      case VoyageExitDecision.cancel:
      case null:
        return;
    }
  }

  Future<void> _confirmEndVoyage() async {
    // One shared dialog, so the words a skipper reads do not depend on whether
    // they came from the Voyage page or the map's Leave control (#306).
    await confirmEndVoyage(
      context,
      controller: widget.voyageController,
      relayCanCarryReopen: _relayCanCarryReopen,
      onShareSummary: _shareCurrentVoyageSummary,
    );
  }

  Widget _buildVoyageActions() => _VoyageActionsPanel(
    coordinationMode: widget.voyageController.coordinationMode,
    canChangeRoute:
        _isSimulation || widget.voyageController.isLocalVoyageSkipper,
    onAlertsAndReports: _openAlertsAndReports,
    onShareSummary: _shareCurrentVoyageSummary,
    onOpenRoster: _openRoster,
    onShareRoster: _shareRoster,
    onChangeRoute: _requestRouteChange,
    maneuverCount: const NavigationGuidancePlanner()
        .instructions(_activeRoute)
        .length,
    onShowManeuvers: _openManeuverList,
    onEmergencyInfo: () =>
        EmergencyInfoSheet.show(context, widget.sailorProfile),
    onNotifications: _openNotificationPreferences,
    canManageObserverAccess: _observerAccessController != null,
    onObserverAccess: _openObserverAccess,
    canShareIceInfo: widget.sailorProfile.hasEmergencyInfo,
    onShareIceInfo: _shareIceInfoWithGroup,
    receivedIceShareCount: widget.voyageController.receivedIceShares.length,
    onViewIceShares: _openIceShareInbox,
    hasOwnPhoneNumber: widget.sailorProfile.hasOwnPhoneNumber,
    ownPhoneNumberShared: widget.voyageController.hasSharedOwnContactNumber,
    ownPhoneNumberRecipientLabel: _ownContactRecipients.toVoyageGroup
        ? 'this voyage'
        : 'the skipper and the Sweeper',
    onShareOwnPhoneNumber: () => unawaited(_shareOwnPhoneNumber()),
    voyagePaused: widget.voyageController.voyagePaused,
    canToggleVoyagePause:
        !_isSimulation &&
        widget.voyageController.voyageStarted &&
        widget.voyageController.session?.role == VoyageRole.lead,
    onToggleVoyagePause: _toggleVoyagePause,
    onLeaveOrEndVoyage: _confirmLeaveVoyageFromMap,
  );

  void _openAlertsAndReports() {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (_) => _buildAwareness())),
    );
  }

  Future<void> _shareCurrentVoyageSummary() async {
    final session = widget.voyageController.session;
    if (session == null) return;
    try {
      final renderObject = context.findRenderObject();
      final origin = renderObject is RenderBox && renderObject.hasSize
          ? renderObject.localToGlobal(Offset.zero) & renderObject.size
          : null;
      await const SystemVoyageSummarySharer().share(
        session,
        widget.voyageController.events,
        distanceUnit: widget.distanceUnits.value,
        sharePositionOrigin: origin,
        // Attached only when an instrumented build was recording, and only ever
        // to a recipient the sailor picks in the share sheet (#419).
        diagnostics: _renderedDiagnostics,
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share voyage summary: $error')),
      );
    }
  }

  /// The same identity the relay receives, so a report can be tied to the build
  /// that produced it.
  static String get _diagnosticsBuildLabel {
    final descriptor = RelayClientDescriptor.current();
    return '${descriptor.appVersion}+${descriptor.appBuild}';
  }

  /// The recorded log as it would be shared, or null when nothing was recorded.
  ///
  /// One rendering, used by both the share sheet and the stored copy, so a log on
  /// disk cannot differ from the one that was handed over (#456).
  String? get _renderedDiagnostics {
    final recorder = _diagnostics;
    final session = widget.voyageController.session;
    if (recorder == null || session == null || recorder.isEmpty) return null;
    return recorder.render(
      voyageCode: session.voyageCode,
      appBuild: _diagnosticsBuildLabel,
    );
  }

  void _startDiagnostics(String note) {
    _diagnostics = VoyageDiagnosticsRecorder(
      // Each entry keeps the stored log in step, so a force-quit costs nothing
      // (#456). Coalesced inside the writer, not written once per entry.
      onEntry: _markDiagnosticsDirty,
    );
    _diagnostics!.recordNote(note);
  }

  /// The switch moved. Recording follows it, whenever it happens (#457).
  void _onVoyageDiagnosticsChanged() {
    final recorder = _diagnostics;
    switch (voyageDiagnosticsTransition(
      switchedOn: widget.voyageDiagnostics?.isOn ?? false,
      hasRecorder: recorder != null,
      isRecording: recorder?.isRecording ?? false,
    )) {
      case VoyageDiagnosticsTransition.start:
        _startDiagnostics(voyageDiagnosticsStartedMidVoyageNote);
      case VoyageDiagnosticsTransition.resume:
        recorder!.resumeRecording();
      case VoyageDiagnosticsTransition.stop:
        recorder!.stopRecording();
        // Written out now: a sailor who switches off has usually just captured the
        // thing they were after, and the next thing they do may be to quit.
        unawaited(_diagnosticsWriter?.flush());
      case VoyageDiagnosticsTransition.nothing:
        break;
    }
  }

  /// Keeps the stored log in step, building the writer the first time there is
  /// both something to write and a voyage to key it on.
  void _markDiagnosticsDirty() {
    (_diagnosticsWriter ??= _buildDiagnosticsWriter())?.markDirty();
  }

  VoyageDiagnosticsLogWriter? _buildDiagnosticsWriter() {
    final store = widget.voyageDiagnostics?.logStore;
    final recorder = _diagnostics;
    final session = widget.voyageController.session;
    // Returning null leaves the field null, so this is retried on the next entry
    // rather than deciding once — a shell can record its first note before its
    // session exists.
    if (store == null || recorder == null || session == null) return null;
    return VoyageDiagnosticsLogWriter(
      store: store,
      voyageId: session.voyageId,
      render: () => recorder.render(
        voyageCode: session.voyageCode,
        appBuild: _diagnosticsBuildLabel,
      ),
    );
  }

  /// The log for the voyage just ended, for the share on the summary screen.
  ///
  /// Falls back to the stored copy: the recorder is still in memory here, but the
  /// same screen is reached from a restored voyage whose recording happened in a
  /// previous run of the app.
  Future<String?> _endedVoyageDiagnostics() async {
    final inMemory = _renderedDiagnostics;
    if (inMemory != null) return inMemory;
    final store = widget.voyageDiagnostics?.logStore;
    final session = widget.voyageController.session;
    if (store == null || session == null) return null;
    return store.read(session.voyageId);
  }

  bool get _relayCanCarryReopen =>
      _internetRelayController?.supportsCapability(
        RelayProtocolCapabilities.voyageReopen,
      ) ??
      true;

  List<VoyageDestination> get _voyageDestinations =>
      voyageDestinations(simulation: _isSimulation);

  /// The way off the map while the navigation bar is hidden.
  ///
  /// #404: once a voyage is under way on the map tab, with a route and a
  /// navigation fix, `hideWhileMoving` removes the whole bar — and the
  /// condition includes `_selectedIndex == 0`, so hiding the only control that
  /// can change the index kept it hidden for the rest of the voyage. Voyage and
  /// Settings became unreachable, and the map's own corner menu could not
  /// help because [VoyageMapFeature.onOpenVoyageMenu] was never supplied here: the
  /// button #133 added rendered in widget tests and never in the app.
  ///
  /// A sheet rather than restoring the bar, because the bar is hidden for a
  /// real reason — it flashed the native map as it was inserted and removed
  /// while GPS speed dipped at lights. This appears only when the sailor asks
  /// for it.
  Future<void> _openVoyageMenu() async {
    final destinations = _voyageDestinations;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // #415's control, and the reason it lives here rather than in the
            // action cluster: SOS, LEAVE and REPORT are a measured arrangement
            // (#133, #142) sized to a 280 px landscape rail, and a fourth target
            // in it would reflow the row a sailor learns by feel. This is one
            // press of a fixed-corner control away, and it says in words what it
            // will do — which is what "I didn't spot the controls to mute" asked
            // for.
            if (widget.spokenGuidance case final guidance?)
              AnimatedBuilder(
                animation: guidance,
                builder: (context, _) => ListTile(
                  key: const Key('voyage-menu-voice'),
                  leading: Icon(switch (guidance.mode) {
                    SpokenAudioMode.everything => Icons.volume_up,
                    SpokenAudioMode.alertsOnly => Icons.notifications_active,
                    SpokenAudioMode.silent => Icons.volume_off,
                  }),
                  title: Text(spokenAudioModeLabel(guidance.mode)),
                  subtitle: Text(
                    'Tap for ${spokenAudioModeLabel(guidance.nextMode).toLowerCase()}',
                  ),
                  onTap: () => unawaited(guidance.cycleMode()),
                ),
              ),
            const Divider(height: 1),
            for (final destination in destinations)
              ListTile(
                key: Key('voyage-menu-destination-${destination.index}'),
                leading: Icon(
                  destination.index == _selectedIndex
                      ? destination.selectedIcon
                      : destination.icon,
                ),
                // Words, not a bare icon (#306), and the same words the bar
                // uses so a sailor is not learning a second vocabulary.
                title: Text(destination.label),
                selected: destination.index == _selectedIndex,
                onTap: () => Navigator.of(context).pop(destination.index),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _selectedIndex = selected);
    }
  }

  void _openRoster() {
    unawaited(
      VoyageRosterSheet.show(
        context,
        widget.voyageController,
        relayCanCarrySweeperRequest:
            _internetRelayController?.supportsCapability(
              RelayProtocolCapabilities.sweeperRoleAssignment,
            ) ??
            true,
        legacyPeerSailorIds: _legacyPeerSailorIds,
      ),
    );
  }

  /// Sailors the live presence channel has already identified as running an
  /// older build. Such a build predates the TEC-request event entirely, so it
  /// will skip it — which is why the skipper is told by name before asking rather
  /// than watching the request sit unanswered.
  Set<String> get _legacyPeerSailorIds => {
    for (final limitation
        in _preStartPresenceController?.limitations ?? const [])
      if (limitation.kind == PresenceLimitationKind.peerAppOlder &&
          limitation.sailorId != null)
        limitation.sailorId!,
  };

  /// Issue #128 part 1: puts an unanswered TEC request in front of the sailor it
  /// names, once.
  ///
  /// The whole point of a request rather than a silent assignment is that the
  /// sailor knows. A request the sailor never sees would be worse than no TEC,
  /// because the skipper would believe the back was covered.
  Future<void> _promptPendingSweeperRequest() async {
    if (_isSimulation || _sweeperRequestPromptOpen || !mounted) return;
    final request =
        widget.voyageController.pendingSweeperRoleRequestForLocalSailor;
    if (request == null) return;
    if (!_promptedSweeperRequestIds.add(request.requestId)) return;
    _sweeperRequestPromptOpen = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('sweeper-role-request'),
          icon: const Icon(
            Icons.shield_moon_outlined,
            color: Color(0xFFB58CFF),
          ),
          title: const Text('Be the Sweeper?'),
          content: const Text(
            'The voyage skipper has asked you to voyage at the back as the Sweeper.\n\n'
            'It means you are the back-marker: the group is complete when you '
            'are there, the skipper sees the distance back to you, and a sailor '
            'who falls a long way behind is routed to you.\n\n'
            'Nobody covers the back until you accept.',
          ),
          actions: [
            TextButton(
              key: const Key('decline-sweeper-role-button'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not me'),
            ),
            FilledButton(
              key: const Key('accept-sweeper-role-button'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('I will take it'),
            ),
          ],
        ),
      );
      if (accepted == null) {
        // Dismissed without answering: the request is still open, so let it be
        // offered again rather than silently swallowing it.
        _promptedSweeperRequestIds.remove(request.requestId);
        return;
      }
      await widget.voyageController.respondToSweeperRoleRequest(
        requestId: request.requestId,
        accepted: accepted,
      );
    } finally {
      _sweeperRequestPromptOpen = false;
    }
  }

  /// Opens the route's manoeuvre list while the map is in navigation mode and
  /// its own menu is hidden. It reads persisted route data only.
  void _openManeuverList() {
    unawaited(
      ManeuverListScreen.show(
        context,
        route: _activeRoute,
        distanceUnit: widget.distanceUnits.value,
        sailorPosition: _mapPosition.value,
      ),
    );
  }

  Future<void> _openObserverAccess() async {
    final controller = _observerAccessController;
    if (controller == null) return;
    await ObserverAccessSheet.show(
      context,
      controller,
      canShareGroup:
          widget.voyageController.coordinationMode.isGroup &&
          widget.voyageController.isLocalVoyageSkipper,
    );
    if (!mounted || !controller.hasActiveGrants) return;
    await _locationController?.requestAndStart();
    _publishObserverSnapshot();
  }

  void _publishObserverSnapshot() {
    final controller = _observerAccessController;
    final session = widget.voyageController.session;
    if (controller == null || session == null || !controller.hasActiveGrants) {
      return;
    }
    final sample = _latestObserverLocationSample;
    final generatedAt = controller.nextSnapshotGeneratedAt();
    final voyageStatus = widget.voyageController.voyageEnded
        ? 'ended'
        : widget.voyageController.voyagePaused
        ? 'paused'
        : widget.voyageController.voyageStarted
        ? 'active'
        : 'waiting';
    final statusUpdatedAt = _observerStatusUpdatedAt();
    final assistanceUpdatedAt = controller.localAssistanceUpdatedAt;
    final liveView = widget.voyageController.liveView;
    controller.publishSnapshots(
      sailor: buildLocalObserverSnapshot(
        session: session,
        snapshotGeneratedAt: generatedAt,
        voyageStatus: voyageStatus,
        statusUpdatedAt: statusUpdatedAt,
        assistanceUpdatedAt: assistanceUpdatedAt,
        localLocation: sample,
        assistance: controller.localAssistance,
      ),
      group:
          widget.voyageController.coordinationMode.isGroup &&
              widget.voyageController.isLocalVoyageSkipper
          ? buildGroupObserverSnapshot(
              session: session,
              snapshotGeneratedAt: generatedAt,
              voyageStatus: voyageStatus,
              statusUpdatedAt: statusUpdatedAt,
              assistanceUpdatedAt: assistanceUpdatedAt,
              liveParticipants: liveView.liveParticipants,
              renderedPositions: liveView.renderedPositions,
              localLocation: sample,
              route: _activeRoute,
            )
          : null,
    );
  }

  DateTime _observerStatusUpdatedAt() {
    for (final event in widget.voyageController.events.reversed) {
      if (event.type == VoyageEventType.voyageStarted ||
          event.type == VoyageEventType.voyagePaused ||
          event.type == VoyageEventType.voyageResumed ||
          event.type == VoyageEventType.voyageEnded) {
        return event.createdAt;
      }
    }
    return widget.voyageController.session?.joinedAt ?? DateTime.now();
  }

  /// Switches to the map tab and asks it to open its route picker. The route
  /// picker itself lives entirely in [VoyageMapScreen] (it alone owns the
  /// on-disk route file), so this only ever hands it a fresh token to react
  /// to - never duplicates its import/demo-route/destination logic here.
  /// Explicitly clears any pending shared file: without that, a stale one
  /// from an earlier "Open in..." delivery would silently skip the picker
  /// this menu action is supposed to show.
  void _requestRouteChange() {
    setState(() {
      _selectedIndex = 0;
      _changeRouteRequestToken = Object();
      _pendingSharedGpxFile = null;
      _pendingInAppRoute = null;
    });
  }

  /// The map screen is rebuilt from scratch every time the tab switch leaves
  /// and returns to it (no keep-alive), so it cannot remember "already
  /// handled" across that round trip. Only this State survives, so it alone
  /// can safely null the token back out once the request has been actioned.
  void _clearChangeRouteRequest() {
    if (_changeRouteRequestToken != null) {
      setState(() {
        _changeRouteRequestToken = null;
        _pendingSharedGpxFile = null;
        _pendingInAppRoute = null;
      });
    }
  }

  /// The app deliberately never collects phone numbers (anonymous voyage
  /// codes, no accounts), so it can't create a WhatsApp/Signal/iMessage
  /// group directly. This gives the skipper a ready-to-paste roster for
  /// whichever group they create themselves.
  void _shareRoster() {
    final session = widget.voyageController.session;
    if (session == null) return;
    final sailors = <String>[];
    String labelFor(String name, VoyageRole role) => switch (role) {
      VoyageRole.lead => '$name (Lead)',
      VoyageRole.sweeper => '$name (Sweeper)',
      _ => name,
    };
    sailors.add(labelFor(session.displayName, session.role));
    if (_isSimulation) {
      for (final sailor in _simulationController?.sailors ?? const []) {
        if (!sailor.isLocal) {
          sailors.add(labelFor(sailor.displayName, sailor.role));
        }
      }
    } else {
      for (final sailor in _awarenessController?.sailorLocations ?? const []) {
        if (sailor.sailorId != session.localSailorId) {
          sailors.add(labelFor(sailor.displayName, sailor.role));
        }
      }
    }
    final title = session.voyageName ?? 'Tide and Seek voyage';
    final text = [
      title,
      'Voyage code: ${session.voyageCode}',
      '',
      ...sailors,
    ].join('\n');
    unawaited(
      SharePlus.instance.share(
        ShareParams(text: text, subject: 'Sailors on $title'),
      ),
    );
  }

  Widget _buildSimulation() {
    final controller = _simulationController;
    if (_loading || controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return VoyageSimulationScreen(
      controller: controller,
      distanceUnit: widget.distanceUnits.value,
      onRestart: _restartSimulation,
      onExit: _leaveVoyage,
      onRoleChanged: _setSimulationRole,
      onToggleMarker: () async {
        if (controller.automaticMarkerActive) return;
        controller.setMarkerMode(!controller.markerMode);
      },
      onGetUnderWay: () async => controller.getUnderWay(),
      onSailorCountChanged: _restartSimulationWithSailorCount,
      markerPassCount: controller.sailorsPassedMarker,
    );
  }

  Future<void> _setSimulationRole(VoyageRole role) async {
    final controller = _simulationController;
    if (controller == null || controller.markerMode) return;
    controller.setLocalRole(role);
    await widget.voyageController.setRole(role);
  }

  Future<void> _restartSimulation() async {
    _simulationController?.pause();
    await widget.voyageController.restartSimulationVoyage();
  }

  Future<void> _restartSimulationWithSailorCount(int sailorCount) async {
    final simulation = _simulationController;
    if (simulation == null || sailorCount == simulation.sailorCount) return;
    simulation.pause();
    await widget.voyageController.restartSimulationVoyage(
      sailorCount: sailorCount,
    );
  }

  Widget _buildDetails() => VoyageDashboard(
    controller: widget.voyageController,
    distanceUnits: widget.distanceUnits,
    voyageActions: _buildVoyageActions(),
    onOpenRoster: _openRoster,
    relayController: _relayController,
    internetRelayController: _internetRelayController,
    onSendQuickMessage: _sendLocalQuickMessage,
    localObserverAssistanceActive:
        _observerAccessController?.localAssistance != null,
    serviceWarning: _warnings.isEmpty ? null : _warnings.join('\n'),
    connectivity: _connectivitySummary,
  );

  Widget _buildSettings() => SafeArea(
    child: UnitSettingsSheet(
      controller: widget.distanceUnits,
      mapStyleMode: widget.mapStyleMode,
      sailorProfile: widget.sailorProfile,
      routeProgressDisplay: widget.routeProgressDisplay,
      currentVoyageActive: true,
      lastRelaySync: _internetRelayController?.status.lastSuccessfulSync,
      testControl: widget.testControl,
      spokenGuidance: widget.spokenGuidance,
      voyageDiagnostics: widget.voyageDiagnostics,
      embedded: true,
    ),
  );

  /// The one connectivity answer, built here because this is the only place that
  /// sees both channels: the event batch's own status and the presence channel's
  /// verdict on live positions (#174).
  VoyageConnectivitySummary? get _connectivitySummary {
    final internet = _internetRelayController;
    if (internet == null) return null;
    final status = internet.status;
    return VoyageConnectivitySummary.from(
      transportActive:
          status.phase != InternetRelayPhase.unconfigured &&
          status.phase != InternetRelayPhase.stopped,
      positionsPaused: widget.voyageController.positionChannelUnavailable,
      queuedEventCount: status.pendingEventCount,
      lastSuccessfulSync: status.lastSuccessfulSync,
      now: DateTime.now(),
    );
  }

  Future<route_domain.GeoPoint?> _acquireCurrentPosition() async {
    final existing = _mapPosition.value;
    if (existing != null) return existing;
    final locationController = _locationController;
    if (locationController == null) return null;

    final completer = Completer<route_domain.GeoPoint?>();
    void onPosition() {
      final position = _mapPosition.value;
      if (position != null && !completer.isCompleted) {
        completer.complete(position);
      }
    }

    _mapPosition.addListener(onPosition);
    try {
      await locationController.requestAndStart();
      // requestAndStart can resume an already-active iOS stream whose latest
      // fix has not changed far enough to trigger the 10 m distance filter.
      // Rebuild the map from that retained fix instead of waiting for movement.
      _updateMapOverlays();
      onPosition();
      if (!locationController.status.canSample && !completer.isCompleted) {
        return null;
      }
      return await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () => _mapPosition.value,
      );
    } finally {
      _mapPosition.removeListener(onPosition);
    }
  }

  Widget _buildAwareness() {
    final awareness = _awarenessController;
    if (_loading || awareness == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return SituationalAwarenessScreen(
      controller: awareness,
      voyageStarted: widget.voyageController.voyageStarted,
      locationController: widget.enableNativeServices && !_isSimulation
          ? _locationController
          : null,
      onLocationStopped: _clearPreStartPresence,
    );
  }

  Future<void> _clearPreStartPresence() async {
    if (!widget.voyageController.voyageStarted) {
      await _preStartPresenceController?.clearLocalPosition();
    }
  }

  Future<void> _removeEndedVoyage() async {
    final voyageId = widget.voyageController.session?.voyageId;
    if (voyageId != null) await _internetCursorStore?.clear(voyageId);
    await widget.voyageController.clearEndedVoyage();
  }

  Future<void> _leaveVoyage() async {
    _simulationController?.pause();
    await _preStartPresenceController?.stop();
    await _pushNotificationController?.stop();
    final voyageId = widget.voyageController.session?.voyageId;
    if (voyageId != null) await _internetCursorStore?.clear(voyageId);
    await widget.voyageController.leaveVoyage(
      publishDeparture: (departure) async {
        await _relayController?.publish(departure);
        await _internetRelayController?.synchronizeNow();
      },
    );
  }

  Future<void> _joinGroupBeforeStart() async {
    final onRequested = widget.onJoinGroupRequested;
    final controller = widget.voyageController;
    if (onRequested == null ||
        controller.voyageStarted ||
        controller.busy ||
        controller.coordinationMode != VoyageCoordinationMode.solo ||
        controller.session?.role != VoyageRole.lead) {
      return;
    }
    await _leaveVoyage();
    // Leaving rebuilds the app without this voyage-scoped shell. The callback is
    // captured first so it remains safe to invoke after that disposal.
    onRequested();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Setting an ended voyage aside tears this shell down, and with it the only
    // copy of the log that was ever in memory (#456).
    unawaited(_diagnosticsWriter?.flush());
    widget.voyageDiagnostics?.removeListener(_onVoyageDiagnosticsChanged);
    widget.spokenGuidance?.removeListener(_onSpokenGuidanceChanged);
    unawaited(_screenAwakeCoordinator.stop());
    widget.voyageController.removeListener(_onVoyageControllerChanged);
    widget.sharedRoutes.removeListener(_onSharedRoutesChanged);
    _simulationController?.removeListener(_onSimulationVisualChanged);
    _simulationController?.dispose();
    _preStartPresenceController?.removeListener(_onPreStartPresenceChanged);
    unawaited(_spokenGuidance?.stop());
    _awarenessController?.removeListener(_onAwarenessChanged);
    if (_awarenessController case final awareness?) {
      widget.testControlRegistry?.withdraw(awareness);
    }
    _awarenessController?.dispose();
    unawaited(_receivedEventSubscription?.cancel());
    unawaited(_internetReceivedEventSubscription?.cancel());
    unawaited(_pushOpenSubscription?.cancel());
    _stalenessTimer?.cancel();
    _locationController?.removeListener(_onDeviceLocationChanged);
    _locationController?.dispose();
    unawaited(_relayController?.close());
    unawaited(_internetRelayController?.close());
    unawaited(_preStartPresenceController?.close());
    _pushNotificationController?.removeListener(
      _onPushNotificationStatusChanged,
    );
    unawaited(_pushNotificationController?.close());
    _observerAccessController?.dispose();
    _mapPosition.dispose();
    _mapNavigationPosition.dispose();
    _mapOverlays.dispose();
    _sailorTrails.dispose();
    _quickMessageAlerts.dispose();
    _skipperStatus.dispose();
    _sweeperGapTrend.dispose();
    _junctionMarkerOverlay.dispose();
    _voyageCompletionSuggestion.dispose();
    super.dispose();
  }
}

LocationSample? _newestLocationSample(
  LocationSample? journalSample,
  LocationSample? deviceSample,
) {
  if (journalSample == null) return deviceSample;
  if (deviceSample == null) return journalSample;
  return deviceSample.recordedAt.isAfter(journalSample.recordedAt)
      ? deviceSample
      : journalSample;
}
