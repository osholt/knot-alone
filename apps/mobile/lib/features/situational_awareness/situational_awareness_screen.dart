import 'package:flutter/material.dart';

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/situational_awareness_controller.dart';
import '../../domain/route_alert.dart';
import '../../services/device_location_source.dart';
import '../map/route_trail_style.dart';

class SituationalAwarenessScreen extends StatelessWidget {
  const SituationalAwarenessScreen({
    super.key,
    required this.controller,
    this.showAppBar = true,
    this.locationController,
    this.voyageStarted = true,
    this.onLocationStopped,
    this.rejoinGuidance,
  });

  final SituationalAwarenessController controller;
  final bool showAppBar;
  final ForegroundLocationController? locationController;
  final bool voyageStarted;
  final Future<void> Function()? onLocationStopped;

  /// Issue #102: advisory rejoin guidance for the local sailor, or null when
  /// they are on route. Shown verbatim - it already says when routing is
  /// unavailable and never names a manoeuvre.
  final String? rejoinGuidance;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: showAppBar ? AppBar(title: const Text('Alerts')) : null,
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
            children: [
              if (controller.errorMessage case final message?) ...[
                _ErrorBanner(
                  message: message,
                  onDismiss: controller.clearError,
                ),
                const SizedBox(height: 12),
              ],
              if (controller.routeAlerts.isNotEmpty ||
                  rejoinGuidance != null) ...[
                _RouteStatusCard(
                  controller: controller,
                  rejoinGuidance: rejoinGuidance,
                ),
                const SizedBox(height: 12),
              ],
              if (!voyageStarted) ...[
                const _PreStartLocationCard(),
                if (locationController case final locationController?) ...[
                  const SizedBox(height: 12),
                  ForegroundLocationCard(
                    controller: locationController,
                    preStart: true,
                    onStopped: onLocationStopped,
                  ),
                ],
              ],
              if (controller.routeAlerts.isNotEmpty) ...[
                const SizedBox(height: 20),
                const _SectionHeader(title: 'RIDERS NEEDING ATTENTION'),
                const SizedBox(height: 10),
                ...controller.routeAlerts.map((alert) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: SailorStatusCard(
                      displayName: alert.displayName,
                      alert: alert,
                      onAcknowledge: alert.acknowledged
                          ? null
                          : () => controller.acknowledgeAlert(alert.sailorId),
                    ),
                  );
                }),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _PreStartLocationCard extends StatelessWidget {
  const _PreStartLocationCard();

  @override
  Widget build(BuildContext context) => const Card(
    child: ListTile(
      leading: Icon(Icons.location_off_outlined, color: Color(0xFFFFC857)),
      title: Text('Current position only before departure'),
      subtitle: Text(
        'If you enable location, the group can see only your latest fresh '
        'position. Tracks, route progress and voyage statistics begin when the '
        'skipper starts the voyage.',
      ),
    ),
  );
}

class ForegroundLocationCard extends StatelessWidget {
  const ForegroundLocationCard({
    super.key,
    required this.controller,
    this.preStart = false,
    this.onStopped,
  });

  final ForegroundLocationController controller;
  final bool preStart;
  final Future<void> Function()? onStopped;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final status = controller.status;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Icon(
                controller.sharing
                    ? Icons.my_location
                    : Icons.location_disabled_outlined,
                color: controller.sharing
                    ? const Color(0xFF6ED89A)
                    : const Color(0xFF8EA7C4),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preStart
                          ? 'Your assembly position'
                          : 'Your voyage location',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      status.message,
                      style: const TextStyle(color: Color(0xFF9CA7B5)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                key: const Key('location-sharing-button'),
                onPressed:
                    status.state == DeviceLocationState.permissionDeniedForever
                    ? null
                    : controller.sharing
                    ? () async {
                        await controller.stop();
                        await onStopped?.call();
                      }
                    : controller.requestAndStart,
                child: Text(controller.sharing ? 'Stop' : _actionLabel(status)),
              ),
            ],
          ),
        ),
      );
    },
  );

  static String _actionLabel(DeviceLocationStatus status) =>
      switch (status.state) {
        DeviceLocationState.permissionDenied ||
        DeviceLocationState.idle => 'Enable',
        DeviceLocationState.permissionDeniedForever => 'Blocked',
        DeviceLocationState.serviceDisabled => 'Retry',
        DeviceLocationState.ready || DeviceLocationState.failed => 'Start',
        DeviceLocationState.sampling => 'Stop',
      };
}

class SailorStatusCard extends StatelessWidget {
  const SailorStatusCard({
    super.key,
    required this.displayName,
    required this.alert,
    this.onAcknowledge,
  });

  final String displayName;
  final SailorRouteAlert? alert;
  final VoidCallback? onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final assessment = alert?.assessment;
    final level = assessment?.alertLevel ?? RouteAlertLevel.none;
    final color = _alertColor(level);
    return Card(
      child: ListTile(
        leading: Icon(_alertIcon(level), color: color),
        title: Text(displayName),
        subtitle: Text(assessment?.message ?? 'Location received.'),
        trailing: assessment?.coordinatorActionRequired == true
            ? TextButton(
                onPressed: onAcknowledge,
                child: Text(alert!.acknowledged ? 'Seen' : 'Acknowledge'),
              )
            : null,
      ),
    );
  }
}

class _RouteStatusCard extends StatelessWidget {
  const _RouteStatusCard({required this.controller, this.rejoinGuidance});

  final SituationalAwarenessController controller;
  final String? rejoinGuidance;

  @override
  Widget build(BuildContext context) {
    final alerts = controller.routeAlerts;
    final urgent = alerts.where(
      (alert) => alert.assessment.coordinatorActionRequired,
    );
    final returningToRoute = rejoinGuidance != null;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF171D25),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: urgent.isEmpty
              ? const Color(0xFF2B3542)
              : const Color(0xFFFF715B),
        ),
      ),
      child: Row(
        children: [
          Icon(
            urgent.isEmpty ? Icons.route_outlined : Icons.crisis_alert,
            color: urgent.isEmpty
                ? const Color(0xFF6ED89A)
                : const Color(0xFFFF715B),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  returningToRoute
                      ? 'Return to the route'
                      : '${alerts.length} route alert'
                            '${alerts.length == 1 ? '' : 's'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 3),
                if (!returningToRoute)
                  Text(
                    urgent.isEmpty
                        ? 'Check the sailor shown below.'
                        : 'The voyage coordinator may need to respond.',
                    style: const TextStyle(color: Color(0xFF9CA7B5)),
                  ),
                if (rejoinGuidance case final guidance?) ...[
                  const SizedBox(height: 8),
                  Text(
                    guidance,
                    key: const Key('rejoin-guidance-text'),
                    // The same cyan the breadcrumb is drawn in, from the one
                    // palette table, so the words and the line on the map read
                    // as one thing.
                    style: TextStyle(
                      color: RouteTrailStyle.rejoinBreadcrumb.color,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: const Color(0xFF8D98A7),
            letterSpacing: 1.1,
          ),
        ),
      ),
    ],
  );
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFF552821),
    borderRadius: BorderRadius.circular(14),
    child: ListTile(
      leading: const Icon(Icons.error_outline),
      title: Text(message),
      trailing: IconButton(
        tooltip: 'Dismiss',
        onPressed: onDismiss,
        icon: const Icon(Icons.close),
      ),
    ),
  );
}

Color _alertColor(RouteAlertLevel level) => switch (level) {
  RouteAlertLevel.none => const Color(0xFF6ED89A),
  RouteAlertLevel.watch => const Color(0xFFFFC857),
  RouteAlertLevel.urgent => const Color(0xFFFF9D4D),
  RouteAlertLevel.critical => const Color(0xFFFF715B),
};

IconData _alertIcon(RouteAlertLevel level) => switch (level) {
  RouteAlertLevel.none => Icons.check_circle_outline,
  RouteAlertLevel.watch => Icons.location_searching,
  RouteAlertLevel.urgent => Icons.wrong_location_outlined,
  RouteAlertLevel.critical => Icons.crisis_alert,
};
