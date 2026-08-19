/// The alterations of course a passage asks for, in order.
///
/// Replaces the road manoeuvre list (#63). That one was built from OSRM steps —
/// turn left, third exit, get in lane — and since #19 removed the engine behind
/// them it could only ever say "no turn prompts for this route".
///
/// This reads `PassageManeuverPlan`, which is derived from the marks the sailor
/// chose, so it needs no service, cannot be stale, and works offline.
library;

import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../services/measurement_formatter.dart';
import '../../services/passage_maneuvers.dart';
import 'passage_leg_table.dart';

class PassageManeuverList extends StatelessWidget {
  const PassageManeuverList({
    super.key,
    required this.plan,
    required this.distanceUnit,
  });

  final PassageManeuverPlan plan;
  final DistanceUnit distanceUnit;

  static Future<void> show(
    BuildContext context, {
    required PassageManeuverPlan plan,
    required DistanceUnit distanceUnit,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          PassageManeuverList(plan: plan, distanceUnit: distanceUnit),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final formatter = MeasurementFormatter(distanceUnit);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          plan.hasManeuvers
              ? 'Alterations (${plan.maneuvers.length})'
              : 'Alterations',
        ),
      ),
      body: SafeArea(
        child: plan.hasManeuvers
            ? ListView(
                key: const Key('passage-maneuver-list'),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  _Preamble(plan: plan),
                  const SizedBox(height: 12),
                  for (final maneuver in plan.maneuvers)
                    _ManeuverCard(
                      maneuver: maneuver,
                      formatter: formatter,
                      planningSpeedKnots: plan.planningSpeedKnots,
                    ),
                ],
              )
            : _NoAlterations(plan: plan),
      ),
    );
  }
}

/// What the list is and is not, said once at the top rather than per row.
class _Preamble extends StatelessWidget {
  const _Preamble({required this.plan});

  final PassageManeuverPlan plan;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Courses are true and rhumb-line, taken from the marks you chose. '
            'They are not checked against land, depth, hazards or traffic '
            'schemes.',
            style: TextStyle(color: Color(0xFF98A3B1)),
          ),
          const SizedBox(height: 8),
          // Stated because the list is otherwise silently shorter than the
          // number of marks, and a navigator would be left wondering what was
          // dropped.
          if (plan.markCountWithoutAlteration > 0)
            Text(
              '${plan.markCountWithoutAlteration} '
              '${plan.markCountWithoutAlteration == 1 ? 'mark carries' : 'marks carry'} '
              'an alteration under '
              '${PassageManeuverPlan.minimumAlterationDegrees.round()}° and is '
              'not listed. Every leg course is in the leg table.',
              style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
            ),
          const SizedBox(height: 8),
          const Text(
            'Nothing here says which side to leave a mark. That needs buoyage '
            'this build does not have.',
            style: TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class _ManeuverCard extends StatelessWidget {
  const _ManeuverCard({
    required this.maneuver,
    required this.formatter,
    required this.planningSpeedKnots,
  });

  final PassageManeuver maneuver;
  final MeasurementFormatter formatter;
  final double planningSpeedKnots;

  @override
  Widget build(BuildContext context) => Card(
    key: Key('passage-maneuver-${maneuver.number}'),
    margin: const EdgeInsets.only(bottom: 10),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(radius: 16, child: Text('${maneuver.number}')),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // The instruction as it would be said aloud.
                      'Alter ${maneuver.alterationDegrees.round()}° to '
                      '${maneuver.side.label} onto '
                      '${formatCourse(maneuver.outboundCourseDegreesTrue)}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'at ${maneuver.markLabel}',
                      style: const TextStyle(color: Color(0xFF98A3B1)),
                    ),
                  ],
                ),
              ),
              if (maneuver.isMajorAlteration)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.priority_high,
                    size: 18,
                    color: Color(0xFFF0B24A),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              _Figure(
                label: 'FROM',
                value: formatCourse(maneuver.inboundCourseDegreesTrue),
              ),
              _Figure(
                label: 'TO RUN',
                value: formatter.distance(maneuver.distanceFromPreviousMeters),
              ),
              _Figure(
                label: 'AT ${planningSpeedKnots.round()} KN',
                value: formatPassageDuration(maneuver.timeFromPrevious),
              ),
              _Figure(
                label: 'FROM START',
                value: formatter.distance(maneuver.cumulativeDistanceMeters),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: const TextStyle(
          color: Color(0xFF8D98A7),
          fontSize: 11,
          letterSpacing: 0.8,
        ),
      ),
      const SizedBox(height: 2),
      Text(value, style: Theme.of(context).textTheme.titleSmall),
    ],
  );
}

/// A passage can legitimately have no alterations, and there are three different
/// reasons why. Saying which one is the difference between an empty screen and
/// an answer.
class _NoAlterations extends StatelessWidget {
  const _NoAlterations({required this.plan});

  final PassageManeuverPlan plan;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.straighten, size: 48, color: Color(0xFF98A3B1)),
          const SizedBox(height: 16),
          Text('No alterations', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            plan.markCountWithoutAlteration > 0
                ? 'Every mark on this passage turns by less than '
                      '${PassageManeuverPlan.minimumAlterationDegrees.round()}°, '
                      'which is closer than a helm can hold. The leg table has '
                      'the course for each leg.'
                : 'This passage runs on one course, or has too few marks to '
                      'alter between. The leg table has the figures.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
        ],
      ),
    ),
  );
}
