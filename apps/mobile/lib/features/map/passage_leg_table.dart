/// The passage plan as a leg table.
///
/// This is the working document of a passage: for each mark, the course to steer,
/// the distance, and the time at the planned speed. It is the surface a navigator
/// reads before leaving and checks against underway.
///
/// ## Why the assumption is repeated rather than stated once
///
/// Every time here rests on one assumed speed made good, with no tidal stream, no
/// leeway and no weather. `PLAN.md` requires an ETA to distinguish measured from
/// assumed inputs, so the speed appears in the header *and* the totals row rather
/// than in a footnote: a table read at 03:00 is read a row at a time.
///
/// ## Why there is no "safe" language anywhere
///
/// The courses are straight lines between marks the sailor chose. They are not
/// checked against land, depth or traffic schemes, and the planner's own warnings
/// are shown at the top rather than tucked behind a disclosure. See
/// `passage_planning.dart`.
library;

import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../services/measurement_formatter.dart';
import '../../services/passage_legs.dart';
import 'voyage_layout.dart';

class PassageLegTable extends StatelessWidget {
  const PassageLegTable({
    super.key,
    required this.plan,
    this.distanceUnit = DistanceUnit.nauticalMiles,
    this.warnings = const [],
    this.onSelectLeg,
    this.selectedLegNumber,
    this.scrollable = true,
  });

  final PassagePlan plan;

  /// Nautical by default: a passage leg in miles or kilometres is the wrong unit.
  final DistanceUnit distanceUnit;

  /// From the planner, in its own words — what it has not checked.
  final List<String> warnings;

  /// Tapping a row centres that leg on the chart, where a surface supports it.
  final ValueChanged<PassageLeg>? onSelectLeg;
  final int? selectedLegNumber;

  /// Whether this owns the scrolling.
  ///
  /// True in a bottom sheet, which gives it a bounded height to scroll within.
  /// False when embedded in a screen that already scrolls — there the height is
  /// unbounded, and taking a flex share of infinity is a layout error rather
  /// than a long list.
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = MeasurementFormatter(distanceUnit);
    final layout = VoyageLayout.of(context);

    return Column(
      key: const Key('passage-leg-table'),
      mainAxisSize: scrollable ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text('Passage plan', style: theme.textTheme.titleMedium),
              ),
              // The assumption, next to the numbers it produced.
              Text(
                'at ${_speedLabel(plan.planningSpeedKnots)}',
                key: const Key('passage-plan-speed'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final warning in warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(top: 2, right: 8),
                          child: Icon(
                            Icons.warning_amber_outlined,
                            size: 16,
                            color: Color(0xFFE8A33D),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            warning,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        if (!plan.hasLegs)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              plan.isUntabulatedTrack
                  ? 'This is an imported track with no marks in it, so it has no '
                        'legs to list. Total distance '
                        '${formatter.distance(plan.totalDistanceMeters)}. Add '
                        'waypoints to plan it as legs.'
                  : 'No passage yet. Add at least two waypoints to see legs.',
              key: const Key('passage-plan-no-legs'),
              style: theme.textTheme.bodyMedium,
            ),
          )
        else if (!scrollable)
          // A Column, not a ListView, when the parent scrolls. A nested
          // scrollable would be invisible to the sailor but very visible to
          // anything walking the widget tree - it silently became the target of
          // `find.byType(Scrollable).last` in the review screen's own tests, and
          // it would take the same scroll gestures the parent wants.
          for (var index = 0; index < plan.legs.length; index += 1)
            _LegRow(
              leg: plan.legs[index],
              formatter: formatter,
              minimumHeight: layout.minimumTapTarget,
              selected: plan.legs[index].number == selectedLegNumber,
              onTap: onSelectLeg == null
                  ? null
                  : () => onSelectLeg!(plan.legs[index]),
            )
        else
          // Flexible with shrinkWrap: a two-leg passage should not leave two
          // thirds of the sheet empty, and a twenty-leg one still needs to
          // scroll within the height the sheet gives it.
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              key: const Key('passage-leg-list'),
              padding: EdgeInsets.only(bottom: layout.isCompactHeight ? 8 : 16),
              itemCount: plan.legs.length + 1,
              itemBuilder: (context, index) => index == plan.legs.length
                  ? _TotalsRow(plan: plan, formatter: formatter)
                  : _LegRow(
                      leg: plan.legs[index],
                      formatter: formatter,
                      minimumHeight: layout.minimumTapTarget,
                      selected: plan.legs[index].number == selectedLegNumber,
                      onTap: onSelectLeg == null
                          ? null
                          : () => onSelectLeg!(plan.legs[index]),
                    ),
            ),
          ),
        // The totals row belongs to the embedded form too; the scrolling form
        // renders it as the list's last item so it scrolls with the legs.
        if (!scrollable && plan.hasLegs)
          _TotalsRow(plan: plan, formatter: formatter),
      ],
    );
  }

  static String _speedLabel(double knots) {
    final rounded = knots.roundToDouble();
    final text = knots == rounded
        ? rounded.toStringAsFixed(0)
        : knots.toStringAsFixed(1);
    return '$text kn';
  }
}

class _LegRow extends StatelessWidget {
  const _LegRow({
    required this.leg,
    required this.formatter,
    required this.minimumHeight,
    required this.selected,
    this.onTap,
  });

  final PassageLeg leg;
  final MeasurementFormatter formatter;
  final double minimumHeight;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      key: Key('passage-leg-${leg.number}'),
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: minimumHeight),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.12)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text('${leg.number}', style: theme.textTheme.bodySmall),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    leg.toLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    'from ${leg.fromLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            // Course first: it is the thing that gets steered.
            _Figure(
              label: 'Course',
              value: formatCourse(leg.courseDegreesTrue),
              theme: theme,
            ),
            _Figure(
              label: 'Distance',
              value: formatter.distance(leg.distanceMeters),
              theme: theme,
            ),
            _Figure(
              label: 'Time',
              value: formatPassageDuration(leg.duration),
              theme: theme,
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalsRow extends StatelessWidget {
  const _TotalsRow({required this.plan, required this.formatter});

  final PassagePlan plan;
  final MeasurementFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('passage-plan-totals'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.6)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${plan.legs.length} legs',
              style: theme.textTheme.titleSmall,
            ),
          ),
          _Figure(
            label: 'Total',
            value: formatter.distance(plan.totalDistanceMeters),
            theme: theme,
            emphasised: true,
          ),
          _Figure(
            // Not "ETA": nothing here has measured a speed.
            label: 'At ${PassageLegTable._speedLabel(plan.planningSpeedKnots)}',
            value: formatPassageDuration(plan.totalDuration),
            theme: theme,
            emphasised: true,
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.value,
    required this.theme,
    this.emphasised = false,
  });

  final String label;
  final String value;
  final ThemeData theme;
  final bool emphasised;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: const Color(0xFF98A3B1),
            letterSpacing: 0.5,
          ),
        ),
        Text(
          value,
          style: emphasised
              ? theme.textTheme.titleSmall
              : theme.textTheme.bodyMedium,
        ),
      ],
    ),
  );
}

/// Three digits and a degree sign, as a course is written and spoken: 007, 181.
///
/// Zero-padded because "7" is a course misread waiting to happen, and because a
/// bearing is always given as three figures at sea.
String formatCourse(double degreesTrue) {
  // Rounded before normalising, not after: 359.6 rounds to 360, and a course of
  // 360 is written 000.
  final rounded = degreesTrue.round();
  final normalised = ((rounded % 360) + 360) % 360;
  return '${normalised.toString().padLeft(3, '0')}°T';
}

/// Passage times, in the units a passage is actually discussed in.
String formatPassageDuration(Duration duration) {
  if (duration.inMinutes < 1) return '<1 min';
  if (duration.inMinutes < 60) return '${duration.inMinutes} min';
  final hours = duration.inMinutes ~/ 60;
  final minutes = duration.inMinutes % 60;
  return minutes == 0 ? '${hours}h' : '${hours}h ${minutes}m';
}
