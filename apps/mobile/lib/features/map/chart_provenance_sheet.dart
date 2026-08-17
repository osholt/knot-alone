/// What the map is made of, stated plainly, on screen.
///
/// `docs/chart-providers.md` established that no free source for UK or
/// Mediterranean waters carries hydrographic authority. `ChartSource` and
/// `ChartCoverage` then made that expressible in code. This is where it becomes
/// visible, which is the only step that protects anybody.
///
/// The specific hazard is not a map that looks wrong. It is a map that looks
/// right: an OpenSeaMap seamark overlay on a decent basemap reads as a chart to
/// anyone who has not been told otherwise, and a sailor who believes they have
/// charted buoyage will plan a night entrance on it. So this surface says three
/// things and does not bury any of them:
///
/// 1. Nothing here is an official chart, and what that means for navigation.
/// 2. For each layer on screen: who made it, how old it is, and under what terms.
/// 3. For each layer *not* on screen: that it is not, and why.
///
/// Point 3 is easy to leave out and matters as much as the others. Depth is the
/// thing a sailor most wants and the thing this build does not have.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/chart_source.dart';
import '../../services/chart_coverage.dart';
import '../../services/marine_layers.dart';

/// Opens the provenance sheet.
Future<void> showChartProvenanceSheet(
  BuildContext context, {
  List<ChartCoverage> coverage = const [],
  DateTime? now,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) =>
      ChartProvenanceSheet(coverage: coverage, now: now ?? DateTime.now()),
);

class ChartProvenanceSheet extends StatelessWidget {
  const ChartProvenanceSheet({
    super.key,
    required this.now,
    this.coverage = const [],
    this.drawn,
    this.notInUse,
  });

  /// Injected rather than read from the clock, so an age can be tested.
  final DateTime now;

  /// Offline verdicts for the current area, where they have been assessed.
  /// Empty means nothing has been assessed, which the sheet says rather than
  /// presenting as "no problems".
  final List<ChartCoverage> coverage;

  /// Overridable for tests; defaults to what this build actually draws.
  final List<ChartSource>? drawn;
  final List<UnusedChartSource>? notInUse;

  List<ChartSource> get _drawn => drawn ?? MarineLayers.drawn;
  List<UnusedChartSource> get _notInUse => notInUse ?? MarineLayers.notInUse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anyOfficial = _drawn.any((source) => source.authority.isChart);
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        // The sheet is text, so it gets a readable measure instead of running
        // the full width of an iPad.
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          key: const Key('chart-provenance-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Chart sources', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 12),
              _AuthorityBanner(anyOfficial: anyOfficial),
              const SizedBox(height: 20),
              if (_drawn.isEmpty)
                const _Note(
                  key: Key('chart-provenance-none-drawn'),
                  text:
                      'No marine data layer is being drawn. The map is a '
                      'general-purpose basemap only.',
                )
              else ...[
                _SectionHeading('On the map now (${_drawn.length})'),
                for (final source in _drawn)
                  _SourceCard(source: source, now: now),
              ],
              if (_notInUse.isNotEmpty) ...[
                const SizedBox(height: 20),
                const _SectionHeading('Not shown'),
                for (final unused in _notInUse) _UnusedCard(unused: unused),
              ],
              const SizedBox(height: 20),
              const _SectionHeading('Offline'),
              _CoverageSection(coverage: coverage),
            ],
          ),
        ),
      ),
    );
  }
}

/// The headline fact, and it is a safety fact rather than a legal one.
class _AuthorityBanner extends StatelessWidget {
  const _AuthorityBanner({required this.anyOfficial});

  final bool anyOfficial;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Deliberately not conditional on much: while nothing official is drawn,
    // this is the most important sentence on the surface.
    final (title, body, colour, icon) = anyOfficial
        ? (
            'Official chart data in use',
            'Check the edition and Notices to Mariners for each chart before '
                'relying on it.',
            const Color(0xFF6ED89A),
            Icons.verified_outlined,
          )
        : (
            'Not for navigation',
            'No layer here is issued by a hydrographic office. There is no '
                'chart edition and no Notices to Mariners behind any of it. '
                'Carry official charts for the waters you are sailing and use '
                'this as an aid to them, not instead of them.',
            const Color(0xFFE8A33D),
            Icons.warning_amber_outlined,
          );
    return Container(
      key: const Key('chart-provenance-authority-banner'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colour),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(color: colour),
                ),
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source, required this.now});

  final ChartSource source;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = source.licence.url;
    return Card(
      key: Key('chart-source-${source.id}'),
      margin: const EdgeInsets.only(top: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    source.displayName,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                _AuthorityChip(authority: source.authority),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _freshness(source, now),
              key: Key('chart-source-${source.id}-freshness'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(source.authority.caveat, style: theme.textTheme.bodyMedium),
            if (source.coverageNote case final note?) ...[
              const SizedBox(height: 8),
              Text(note, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 10),
            // Attribution is a condition of use for every source here, so it is
            // shown rather than summarised.
            Text(
              source.licence.attribution,
              style: theme.textTheme.bodySmall?.copyWith(
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 2),
            Text(source.licence.name, style: theme.textTheme.bodySmall),
            if (url != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: Key('chart-source-${source.id}-licence-link'),
                  onPressed: () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('Licence and terms'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The freshness line, which never claims more than the provider states.
  static String _freshness(ChartSource source, DateTime now) {
    if (source.continuouslyUpdated) {
      return 'Updated continuously — no edition or publication date exists for '
          'this source.';
    }
    final age = source.ageAt(now);
    if (age == null) {
      return 'The provider does not say when this was last updated.';
    }
    final edition = source.edition;
    final published = '${_ageLabel(age)} old';
    return edition == null ? published : '$edition · $published';
  }

  static String _ageLabel(Duration age) {
    final days = age.inDays;
    if (days < 1) return 'less than a day';
    if (days < 60) return '$days day${days == 1 ? '' : 's'}';
    final months = days ~/ 30;
    if (months < 24) return '$months months';
    final years = days ~/ 365;
    final remainder = (days - years * 365) ~/ 30;
    return remainder == 0
        ? '$years year${years == 1 ? '' : 's'}'
        : '$years year${years == 1 ? '' : 's'} $remainder months';
  }
}

class _AuthorityChip extends StatelessWidget {
  const _AuthorityChip({required this.authority});

  final ChartAuthority authority;

  @override
  Widget build(BuildContext context) {
    final colour = switch (authority) {
      ChartAuthority.official => const Color(0xFF6ED89A),
      ChartAuthority.surveyDerived => const Color(0xFF7FB2E5),
      ChartAuthority.crowdSourced => const Color(0xFFE8A33D),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colour.withValues(alpha: 0.5)),
      ),
      child: Text(
        authority.label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colour),
      ),
    );
  }
}

class _UnusedCard extends StatelessWidget {
  const _UnusedCard({required this.unused});

  final UnusedChartSource unused;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      key: Key('chart-source-unused-${unused.source.id}'),
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.layers_clear_outlined, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  unused.source.displayName,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(unused.reason, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The offline verdict, which says "not assessed" rather than implying "fine".
class _CoverageSection extends StatelessWidget {
  const _CoverageSection({required this.coverage});

  final List<ChartCoverage> coverage;

  @override
  Widget build(BuildContext context) {
    if (coverage.isEmpty) {
      return const _Note(
        key: Key('chart-provenance-coverage-unassessed'),
        text:
            'No area has been checked for offline use. Until an area is '
            'downloaded and verified, assume the map needs a connection.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in coverage)
          Padding(
            key: Key('chart-coverage-${entry.source.id}'),
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      entry.usableOffline
                          ? Icons.offline_pin_outlined
                          : Icons.cloud_off_outlined,
                      size: 18,
                      color: entry.usableOffline
                          ? const Color(0xFF6ED89A)
                          : const Color(0xFFE8A33D),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        entry.source.displayName,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Every reason, not just the most severe one: a sailor deciding
                // whether to trust an area offline needs the full list, and
                // fixing one reason does not fix the others.
                if (entry.usableOffline)
                  Text(
                    'Downloaded and within its usable life '
                    '(${entry.presentTiles} of ${entry.requiredTiles} tiles).',
                    style: Theme.of(context).textTheme.bodySmall,
                  )
                else
                  for (final shortfall in entry.shortfalls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        '• ${shortfall.message}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(
      color: const Color(0xFFABB5C1),
      letterSpacing: 0.4,
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodyMedium);
}
