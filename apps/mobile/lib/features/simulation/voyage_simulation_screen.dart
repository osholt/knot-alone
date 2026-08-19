import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/voyage_simulation_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/voyage_role.dart';
import '../../domain/voyage_session.dart';
import '../../services/measurement_formatter.dart';
import '../map/voyage_layout.dart';
import '../map/marine_glyphs.dart';

class VoyageSimulationScreen extends StatelessWidget {
  const VoyageSimulationScreen({
    super.key,
    required this.controller,
    this.distanceUnit = DistanceUnit.nauticalMiles,
    required this.onRestart,
    required this.onExit,
    required this.onRoleChanged,
    required this.onToggleMarker,
    required this.onGetUnderWay,
    required this.onSailorCountChanged,
    this.markerPassCount = 0,
    this.sweeperPassedMarker = false,
  });

  final VoyageSimulationController controller;
  final DistanceUnit distanceUnit;
  final Future<void> Function() onRestart;
  final Future<void> Function() onExit;
  final Future<void> Function(VoyageRole role) onRoleChanged;
  final Future<void> Function() onToggleMarker;
  final Future<void> Function() onGetUnderWay;
  final Future<void> Function(int sailorCount) onSailorCountChanged;
  final int markerPassCount;
  final bool sweeperPassedMarker;

  @override
  Widget build(BuildContext context) {
    final layout = VoyageLayout.of(context);
    final landscape = layout.isLandscape;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: layout.toolbarHeight,
        title: const Text('Voyage Lab'),
        actions: [
          IconButton(
            tooltip: 'Restart simulation',
            onPressed: () => unawaited(onRestart()),
            icon: const Icon(Icons.replay),
          ),
          IconButton(
            tooltip: 'Exit simulation',
            onPressed: () => unawaited(onExit()),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) {
            final controls = _SimulationControls(
              controller: controller,
              onRoleChanged: onRoleChanged,
              onToggleMarker: onToggleMarker,
              onGetUnderWay: onGetUnderWay,
              onSailorCountChanged: onSailorCountChanged,
              markerPassCount: markerPassCount,
              sweeperPassedMarker: sweeperPassedMarker,
            );
            final fleet = _FleetCard(
              controller: controller,
              distanceUnit: distanceUnit,
            );
            if (landscape) {
              return Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SingleChildScrollView(child: controls)),
                    const SizedBox(width: 10),
                    Expanded(child: SingleChildScrollView(child: fleet)),
                  ],
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 28),
              children: [controls, const SizedBox(height: 12), fleet],
            );
          },
        ),
      ),
    );
  }
}

class _SimulationControls extends StatelessWidget {
  const _SimulationControls({
    required this.controller,
    required this.onRoleChanged,
    required this.onToggleMarker,
    required this.onGetUnderWay,
    required this.onSailorCountChanged,
    required this.markerPassCount,
    required this.sweeperPassedMarker,
  });

  final VoyageSimulationController controller;
  final Future<void> Function(VoyageRole role) onRoleChanged;
  final Future<void> Function() onToggleMarker;
  final Future<void> Function() onGetUnderWay;
  final Future<void> Function(int sailorCount) onSailorCountChanged;
  final int markerPassCount;
  final bool sweeperPassedMarker;

  @override
  Widget build(BuildContext context) {
    final status = switch (controller.state) {
      VoyageSimulationState.ready => 'READY',
      VoyageSimulationState.running => 'RUNNING',
      VoyageSimulationState.paused => 'PAUSED',
      VoyageSimulationState.completed => 'FINISHED',
    };
    final statusColor = switch (controller.state) {
      VoyageSimulationState.running => const Color(0xFF6ED89A),
      VoyageSimulationState.completed => Theme.of(context).colorScheme.primary,
      _ => const Color(0xFFFFC857),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined, color: statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'SYNTHETIC VOYAGE',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _Pill(label: status, color: statusColor),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${controller.sailorCount} virtual boats use the real navigation, '
              'Sweeper and off-course logic. Device GPS, internet relay and '
              'nearby '
              'radios are off.',
              style: const TextStyle(color: Color(0xFFADB7C4), height: 1.35),
            ),
            if (controller.automaticMarkerActive) ...[
              const SizedBox(height: 14),
              _AutomaticMarkerViewport(
                controller: controller,
                onGetUnderWay: onGetUnderWay,
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'YOUR VIEW',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: const Color(0xFF8F9BAA),
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<VoyageRole>(
              key: const Key('simulation-role'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: VoyageRole.skipper,
                  icon: MarineGlyphIcon(MarineGlyph.skipper),
                  label: Text('Skipper'),
                ),
                ButtonSegment(
                  value: VoyageRole.sailor,
                  icon: MarineGlyphIcon(MarineGlyph.sailor),
                  label: Text('Follower'),
                ),
                ButtonSegment(
                  value: VoyageRole.sweeper,
                  icon: MarineGlyphIcon(MarineGlyph.sweeper),
                  label: Text('Sweeper'),
                ),
              ],
              selected: {controller.localRole},
              onSelectionChanged:
                  controller.markerMode &&
                      (!controller.automaticMarkerActive ||
                          controller.automaticMarkerIsLocal)
                  ? null
                  : (selection) => unawaited(onRoleChanged(selection.single)),
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(value: controller.progress),
            const SizedBox(height: 8),
            Text(
              '${(controller.progress * 100).round()}% route · '
              '${_duration(controller.simulatedElapsed)} simulated',
              style: const TextStyle(color: Color(0xFF8F9BAA)),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Virtual sailors',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                DropdownButton<int>(
                  key: const Key('simulation-sailor-count'),
                  value: controller.sailorCount,
                  items: [
                    for (
                      var count = VoyageSession.minimumSimulationSailorCount;
                      count <= VoyageSession.maximumSimulationSailorCount;
                      count += 1
                    )
                      DropdownMenuItem(
                        value: count,
                        child: Text('$count sailors'),
                      ),
                  ],
                  onChanged: (count) {
                    if (count != null && count != controller.sailorCount) {
                      unawaited(onSailorCountChanged(count));
                    }
                  },
                ),
              ],
            ),
            const Text(
              'Changing the fleet starts a clean simulation.',
              style: TextStyle(color: Color(0xFF8F9BAA), fontSize: 12),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('simulation-play-pause'),
                    onPressed:
                        !controller.voyageStarted ||
                            controller.state == VoyageSimulationState.completed
                        ? null
                        : controller.isRunning
                        ? controller.pause
                        : controller.start,
                    icon: Icon(
                      controller.isRunning ? Icons.pause : Icons.play_arrow,
                    ),
                    label: Text(
                      !controller.voyageStarted
                          ? 'Waiting for start'
                          : controller.isRunning
                          ? 'Pause'
                          : 'Run',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: 'Simulation time scale',
                  child: DropdownButton<double>(
                    key: const Key('simulation-speed'),
                    value: controller.timeScale,
                    items: const [1.0, 4.0, 8.0, 16.0]
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text('${value.toInt()}×'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) controller.setTimeScale(value);
                    },
                  ),
                ),
              ],
            ),
            const Divider(height: 28),
            SwitchListTile.adaptive(
              key: const Key('simulation-off-route'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Send Alex off route'),
              subtitle: const Text(
                'Builds the magenta trail and skipper alert',
              ),
              value: controller.alexOffRoute,
              onChanged: controller.setAlexOffRoute,
            ),
            SwitchListTile.adaptive(
              key: const Key('simulation-sweeper-delay'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Delay Sweeper'),
              subtitle: const Text('Increases the lead-to-sweeper gap'),
              value: controller.sweeperDelayed,
              onChanged: controller.setSweeperDelayed,
            ),
            const SizedBox(height: 8),
            if (!controller.automaticMarkerActive)
              FilledButton.tonalIcon(
                key: const Key('simulation-marker-mode'),
                onPressed: () => unawaited(onToggleMarker()),
                icon: Icon(
                  controller.markerMode ? Icons.stop_circle : Icons.pin_drop,
                ),
                label: Text(
                  controller.markerMode
                      ? 'Finish marker mode'
                      : 'Simulate marker mode',
                ),
              ),
            if (controller.markerMode && !controller.automaticMarkerActive) ...[
              const SizedBox(height: 8),
              Text(
                'MARKER ACTIVE · $markerPassCount passed · '
                '${sweeperPassedMarker ? 'sweeper passed' : 'waiting for sweeper'}',
                key: const Key('simulation-marker-status'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: sweeperPassedMarker
                      ? const Color(0xFF6ED89A)
                      : const Color(0xFFFFC857),
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Open the Map tab to watch the production UI respond.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF7F8A98), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _AutomaticMarkerViewport extends StatelessWidget {
  const _AutomaticMarkerViewport({
    required this.controller,
    required this.onGetUnderWay,
  });

  final VoyageSimulationController controller;
  final Future<void> Function() onGetUnderWay;

  @override
  Widget build(BuildContext context) {
    final phase = controller.markerPhase;
    final color = switch (phase) {
      SimulationMarkerPhase.waitingForSailors => const Color(0xFFFFC857),
      SimulationMarkerPhase.sweeperApproaching => const Color(0xFFFFA24C),
      SimulationMarkerPhase.readyToGetUnderWay => const Color(0xFF6ED89A),
      SimulationMarkerPhase.riding => const Color(0xFF8F9BAA),
    };
    final sweeperDistance = controller.sweeperDistanceToMarkerMeters;
    return Container(
      key: const Key('simulation-auto-marker-viewport'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.alt_route, color: color),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'JUNCTION MARKER',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              _Pill(label: 'AUTO', color: color),
            ],
          ),
          const SizedBox(height: 8),
          if (!controller.automaticMarkerIsLocal)
            Text(
              '${controller.automaticMarkerSailorName ?? 'Second bike'} is '
              'marking this junction.',
              style: const TextStyle(color: Color(0xFFB9C4D1), fontSize: 12),
            ),
          if (!controller.automaticMarkerIsLocal) const SizedBox(height: 6),
          Text(
            'Sailors passed: ${controller.sailorsPassedMarker}/'
            '${controller.sailorsExpectedToPass}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (sweeperDistance != null && !controller.canGetUnderWay)
            Text(
              'Sweeper ${sweeperDistance.round()} m away',
              style: const TextStyle(color: Color(0xFFB9C4D1), fontSize: 12),
            ),
          const SizedBox(height: 6),
          Text(
            controller.markerInstruction,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
          if (phase == SimulationMarkerPhase.sweeperApproaching) ...[
            const SizedBox(height: 10),
            const Text(
              'GET READY TO GET UNDER WAY',
              key: Key('simulation-get-ready-to-voyage-off'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFFFC857),
                fontWeight: FontWeight.w900,
                letterSpacing: 0.7,
              ),
            ),
          ],
          if (controller.canGetUnderWay) ...[
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('simulation-voyage-off'),
              onPressed: () => unawaited(onGetUnderWay()),
              icon: const Icon(Icons.play_arrow),
              label: Text(
                controller.automaticMarkerIsLocal
                    ? 'Get under way and return to navigation'
                    : 'Send ${controller.automaticMarkerSailorName ?? 'second bike'} '
                          'back to navigation',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FleetCard extends StatelessWidget {
  const _FleetCard({required this.controller, required this.distanceUnit});

  final VoyageSimulationController controller;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('VIRTUAL FLEET', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          for (final sailor in controller.sailors) ...[
            Row(
              children: [
                Icon(
                  sailor.isLocal ? Icons.navigation : Icons.sailing_outlined,
                  color: sailor.isOffRoute
                      ? const Color(0xFFFF4FA3)
                      : const Color(0xFF6ED89A),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sailor.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${sailor.role.label} · '
                        '${MeasurementFormatter(distanceUnit).speed(sailor.speedMetersPerSecond)}',
                        style: const TextStyle(
                          color: Color(0xFF8F9BAA),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (sailor.isOffRoute)
                  const _Pill(label: 'OFF ROUTE', color: Color(0xFFFF4FA3))
                else
                  Text('${(sailor.progress * 100).round()}%'),
              ],
            ),
            const SizedBox(height: 7),
            LinearProgressIndicator(value: sailor.progress, minHeight: 3),
            const SizedBox(height: 13),
          ],
        ],
      ),
    ),
  );
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11),
    ),
  );
}
