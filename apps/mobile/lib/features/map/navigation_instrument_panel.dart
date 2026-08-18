/// The instrument panel: COG, SOG, bearing and distance to the mark, cross-track
/// error, VMG and the age of the fix they all rest on.
///
/// ## The one property this surface exists for
///
/// A stale fix must degrade everything derived from it, **visibly and at once**.
/// A frozen SOG still reading 5.2 kn because the last fix was four minutes ago is
/// the failure `PLAN.md` names: the number looks exactly as trustworthy as it did
/// when it was true. So when the fix is stale every value here dims, and a single
/// banner says how old it is — once, rather than a badge per row that a sailor
/// reads past.
///
/// ## Why the basis is shown
///
/// Each value says whether it was measured by the receiver or calculated from the
/// plan. It is the difference between "you are doing 4.2 knots" and "if the plan
/// is right you will arrive at 14:20", and a navigator deciding whether to trust
/// a number needs to know which kind it is.
///
/// ## Not shown
///
/// Nothing here recommends a course. Cross-track error names the side to steer
/// *toward*, which is a fact about geometry; what to actually steer depends on
/// the stream, the wind and what the sailor can see.
library;

import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_instruments.dart';
import 'passage_leg_table.dart' show formatCourse, formatPassageDuration;
import 'voyage_layout.dart';

class NavigationInstrumentPanel extends StatelessWidget {
  const NavigationInstrumentPanel({
    super.key,
    required this.instruments,
    this.distanceUnit = DistanceUnit.nauticalMiles,
  });

  final NavigationInstruments instruments;
  final DistanceUnit distanceUnit;

  @override
  Widget build(BuildContext context) {
    final formatter = MeasurementFormatter(distanceUnit);
    final layout = VoyageLayout.of(context);
    final stale = instruments.fixIsStale;

    return Container(
      key: const Key('navigation-instrument-panel'),
      padding: EdgeInsets.all(layout.isCompactHeight ? 10 : 14),
      decoration: BoxDecoration(
        color: const Color(0xF2141A22),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (stale)
            _StaleBanner(age: instruments.fixAge)
          else
            _FixAgeLine(age: instruments.fixAge),
          const SizedBox(height: 10),
          // Own motion first: it is measured, and it is true whether or not there
          // is a passage.
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              _Reading(
                label: 'COG',
                instrument: instruments.courseOverGround,
                format: formatCourse,
                stale: stale,
              ),
              _Reading(
                label: 'SOG',
                instrument: instruments.speedOverGround,
                format: formatter.speed,
                stale: stale,
              ),
              if (instruments.hasActiveLeg) ...[
                _Reading(
                  label: 'BTW',
                  instrument: instruments.bearingToMark,
                  format: formatCourse,
                  stale: stale,
                ),
                _Reading(
                  label: 'DTW',
                  instrument: instruments.distanceToMark,
                  format: formatter.distance,
                  stale: stale,
                ),
                _Reading(
                  label: 'VMG',
                  instrument: instruments.velocityMadeGood,
                  format: formatter.speed,
                  stale: stale,
                ),
                _CrossTrackReading(
                  instrument: instruments.crossTrackError,
                  side: instruments.offTrackSide,
                  formatter: formatter,
                  stale: stale,
                ),
              ],
            ],
          ),
          if (instruments.hasActiveLeg) ...[
            const SizedBox(height: 12),
            _MarkLine(instruments: instruments, stale: stale),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              'No passage. Add marks to see bearings and cross-track error.',
              key: const Key('navigation-instruments-no-passage'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.age});

  final Duration age;

  @override
  Widget build(BuildContext context) => Row(
    key: const Key('navigation-instruments-stale'),
    children: [
      const Icon(Icons.gps_off_outlined, size: 16, color: Color(0xFFE8A33D)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          // Named once, plainly. Every figure below rests on this fix.
          'Fix is ${formatPassageDuration(age)} old — everything below is out '
          'of date',
          style: const TextStyle(
            color: Color(0xFFE8A33D),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ),
    ],
  );
}

class _FixAgeLine extends StatelessWidget {
  const _FixAgeLine({required this.age});

  final Duration age;

  @override
  Widget build(BuildContext context) => Text(
    age.inSeconds <= 1 ? 'Fix current' : 'Fix ${age.inSeconds}s old',
    key: const Key('navigation-instruments-fix-age'),
    style: Theme.of(context).textTheme.bodySmall,
  );
}

/// One reading, with its label, value and basis.
class _Reading extends StatelessWidget {
  const _Reading({
    required this.label,
    required this.instrument,
    required this.format,
    required this.stale,
  });

  final String label;
  final Instrument instrument;
  final String Function(double) format;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = instrument.isAvailable;
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF98A3B1),
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 4),
              _BasisDot(basis: instrument.basis),
            ],
          ),
          Text(
            available ? format(instrument.value!) : '—',
            key: Key('instrument-$label'),
            style: theme.textTheme.titleMedium?.copyWith(
              // Dimmed together when the fix is stale, so no single number can
              // look fresher than the fix it came from.
              color: stale || !available
                  ? const Color(0xFF6B7684)
                  : const Color(0xFFE8EEF5),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (!available && instrument.reason != null)
            Text(
              instrument.reason!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: const Color(0xFF6B7684),
              ),
            ),
        ],
      ),
    );
  }
}

/// Cross-track error reads as a distance plus the side to steer toward, because
/// the distance on its own does not tell a sailor which way to put the helm.
class _CrossTrackReading extends StatelessWidget {
  const _CrossTrackReading({
    required this.instrument,
    required this.side,
    required this.formatter,
    required this.stale,
  });

  final Instrument instrument;
  final TrackSide? side;
  final MeasurementFormatter formatter;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final available = instrument.isAvailable;
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                'XTE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: const Color(0xFF98A3B1),
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 4),
              _BasisDot(basis: instrument.basis),
            ],
          ),
          Text(
            !available
                ? '—'
                : side == null
                ? 'on track'
                : '${formatter.distance(instrument.value!)} — '
                      'steer ${side!.opposite.label}',
            key: const Key('instrument-XTE'),
            style: theme.textTheme.titleMedium?.copyWith(
              color: stale || !available
                  ? const Color(0xFF6B7684)
                  : const Color(0xFFE8EEF5),
            ),
          ),
          if (!available && instrument.reason != null)
            Text(
              instrument.reason!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: const Color(0xFF6B7684),
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkLine extends StatelessWidget {
  const _MarkLine({required this.instruments, required this.stale});

  final NavigationInstruments instruments;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final leg = instruments.activeLeg!;
    final toMark = instruments.timeToMark;
    return Text(
      toMark == null
          // Not closing: say that rather than showing a time that would have to
          // be negative.
          ? 'Making for ${leg.toLabel} — not closing'
          : 'Making for ${leg.toLabel} — '
                '${formatPassageDuration(toMark)} at this rate',
      key: const Key('navigation-instruments-mark'),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: stale ? const Color(0xFF6B7684) : null,
      ),
    );
  }
}

/// A small mark showing whether a value was measured or calculated.
class _BasisDot extends StatelessWidget {
  const _BasisDot({required this.basis});

  final InstrumentBasis basis;

  @override
  Widget build(BuildContext context) {
    final (colour, tooltip) = switch (basis) {
      InstrumentBasis.measured => (
        const Color(0xFF6ED89A),
        'Measured by the GPS',
      ),
      InstrumentBasis.calculated => (
        const Color(0xFF7FB2E5),
        'Calculated from your passage',
      ),
      InstrumentBasis.assumed => (
        const Color(0xFFE8A33D),
        'Rests on an assumption',
      ),
      InstrumentBasis.unavailable => (const Color(0xFF6B7684), 'Not available'),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      ),
    );
  }
}
