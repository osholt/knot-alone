import 'package:flutter/material.dart';

import '../../controllers/marker_assistance_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/marker_assistance.dart';
import '../../services/measurement_formatter.dart';

class MarkerAssistancePrompt extends StatelessWidget {
  const MarkerAssistancePrompt({
    super.key,
    required this.controller,
    this.distanceUnit = DistanceUnit.kilometres,
  });

  final MarkerAssistanceController controller;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final suggestion = controller.suggestion;
    if (suggestion == null) return const SizedBox.shrink();
    return Container(
      key: const Key('marker-assistance-prompt'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF322719),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFC857)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.signpost_outlined, color: Color(0xFFFFC857)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Possible marker opportunity',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Stopped ${MeasurementFormatter(distanceUnit).distance(suggestion.distanceMeters)} from a '
                      'route decision while ${suggestion.progressingRiderCount} '
                      'rider${suggestion.progressingRiderCount == 1 ? '' : 's'} '
                      'continued.',
                      style: const TextStyle(color: Color(0xFFD4C7B5)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'DEVELOPMENT ALPHA · This is a suggestion, not an automatic role '
            'change. Check the junction and traffic before confirming.',
            style: TextStyle(
              color: Color(0xFFFFC857),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('review-marker-suggestion'),
            onPressed: () => _confirm(context),
            icon: const Icon(Icons.touch_app_outlined),
            label: const Text('Review marker mode'),
          ),
          TextButton(
            key: const Key('dismiss-marker-suggestion'),
            onPressed: controller.dismissSuggestion,
            child: const Text('Not this junction'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Start marker mode?'),
        content: const Text(
          'Confirm only when you are safely stopped and intend to mark this '
          'junction. The app will count verified rider location passages, but '
          'you remain responsible for visual checks.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const Key('confirm-assisted-marker'),
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.signpost_outlined),
            label: const Text('Start marking'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await controller.confirmSuggestion();
    }
  }
}

class MarkerStatisticsCard extends StatelessWidget {
  const MarkerStatisticsCard({super.key, required this.summary});

  final RideMarkingSummary summary;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MARKING STATS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  value: '${summary.sessions.length}',
                  label: 'sessions',
                ),
              ),
              Expanded(
                child: _Stat(
                  value: formatMarkerDuration(summary.totalMarkingTime),
                  label: 'marking',
                ),
              ),
              Expanded(
                child: _Stat(
                  value: '${summary.verifiedPassCount}',
                  label: 'verified passes',
                ),
              ),
            ],
          ),
          if (summary.activeSession case final active?) ...[
            const Divider(height: 26),
            Text(
              active.tecPassedAt == null
                  ? 'Waiting for verified TEC passage'
                  : 'TEC passage verified · finish when safe',
              style: TextStyle(
                color: active.tecPassedAt == null
                    ? const Color(0xFF9CA7B5)
                    : const Color(0xFF6ED89A),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class EndRideMarkingSummary extends StatelessWidget {
  const EndRideMarkingSummary({super.key, required this.summary});

  final RideMarkingSummary summary;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFF111720),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ride marking summary',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        Text(
          '${summary.sessions.length} session'
          '${summary.sessions.length == 1 ? '' : 's'} · '
          '${formatMarkerDuration(summary.totalMarkingTime)} marking · '
          '${summary.verifiedPassCount} verified passes · '
          '${summary.tecPassageCount} TEC passages',
          key: const Key('end-ride-marking-summary'),
          style: const TextStyle(color: Color(0xFFB8C2CF)),
        ),
      ],
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(value, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 2),
      Text(
        label,
        style: const TextStyle(color: Color(0xFF8D98A7), fontSize: 11),
      ),
    ],
  );
}

String formatMarkerDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${seconds}s';
  return '${seconds}s';
}
