import 'package:flutter/material.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/internet_relay_controller.dart';
import '../../controllers/nearby_relay_controller.dart';
import '../../controllers/voyage_controller.dart';
import '../../services/basemap_configuration.dart';
import '../../services/voyage_summary_exporter.dart';
import '../internet/internet_relay_status_card.dart';
import '../nearby/relay_status_card.dart';
import 'voyage_recap_screen.dart';

class EndedVoyageScreen extends StatefulWidget {
  const EndedVoyageScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    this.nearbyRelayController,
    this.internetRelayController,
    this.summarySharer,
    this.onRemoveVoyage,
    this.onSetAside,
    this.relayCanCarryReopen = true,
    this.diagnostics,
  });

  final VoyageController controller;
  final DistanceUnitController distanceUnits;
  final NearbyRelayController? nearbyRelayController;
  final InternetRelayController? internetRelayController;
  final VoyageSummarySharer? summarySharer;
  final Future<void> Function()? onRemoveVoyage;

  /// Absent in a build with no catalogue service configured, and in tests that
  /// are not about ratings. When absent, no rating card is built at all.

  /// Leaves this screen without acting on the voyage.
  ///
  /// Required, in practice: without it this screen is the whole app and its only
  /// exit files the voyage (#207).
  final VoidCallback? onSetAside;

  /// The negotiated `voyage-reopen-v1` capability. False hides the action rather
  /// than offering a reopen that could not reach the rest of the group.
  final bool relayCanCarryReopen;

  /// The recorded diagnostics log for this voyage, if it was recorded (#456).
  ///
  /// A callback returning a future because the log may have to be read back from
  /// disk: this screen is also where a sailor lands after restoring a voyage that
  /// was recorded in a previous run of the app.
  ///
  /// The share here originally took no log at all, which made **Share voyage
  /// summary** — the obvious button once a voyage is over — the one door that
  /// silently dropped the evidence.
  final Future<String?> Function()? diagnostics;

  @override
  State<EndedVoyageScreen> createState() => _EndedVoyageScreenState();
}

class _EndedVoyageScreenState extends State<EndedVoyageScreen> {
  @override
  void initState() {
    super.initState();
  }

  /// The way off this screen that gives nothing up (#207).
  VoidCallback get _setAside =>
      widget.onSetAside ?? widget.controller.setEndedVoyageAside;

  bool _reopening = false;

  /// Only the skipper, only while the relay can carry it.
  ///
  /// The window is not checked here — [VoyageController.reopenVoyage] owns that, and
  /// it is the same 24 hours the ended voyage survives for anyway, so a screen that
  /// exists at all is inside it.
  bool get _canOfferReopen =>
      widget.relayCanCarryReopen && widget.controller.isLocalVoyageSkipper;

  Future<void> _confirmReopen(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Resume this voyage?'),
        content: const Text(
          'The voyage goes back to running for everyone, on the same voyage code. '
          'Sailors who already left stay out until they rejoin.\n\n'
          'One thing does not come back: emergency contact details other '
          'sailors shared with you were cleared when the voyage ended.',
        ),
        actions: [
          TextButton(
            key: const Key('cancel-reopen-voyage-button'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Leave it ended'),
          ),
          FilledButton(
            key: const Key('confirm-reopen-voyage-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Resume voyage'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    setState(() => _reopening = true);
    final outcome = await widget.controller.reopenVoyage(
      relayCanCarryReopen: widget.relayCanCarryReopen,
    );
    if (mounted) setState(() => _reopening = false);
    if (outcome == VoyageReopenOutcome.reopened || !context.mounted) return;
    // Anything short of success is said out loud. A skipper must never be left
    // believing the group is riding again when it is not.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_reopenFailure(outcome))));
  }

  static String _reopenFailure(
    VoyageReopenOutcome outcome,
  ) => switch (outcome) {
    VoyageReopenOutcome.notSkipper =>
      'Only the voyage skipper can resume a voyage.',
    VoyageReopenOutcome.windowExpired =>
      'This voyage ended too long ago to resume. Start a new one.',
    VoyageReopenOutcome.relayUnsupported =>
      'The voyage service cannot carry a resume yet, so the rest of the group '
          'would not see it. Start a new voyage instead.',
    VoyageReopenOutcome.notEnded => 'This voyage is already running.',
    VoyageReopenOutcome.failed || VoyageReopenOutcome.reopened =>
      'Could not resume the voyage. Please try again.',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Voyage ended'),
      leading: IconButton(
        key: const Key('leave-ended-voyage-screen-button'),
        tooltip: 'Back to the map',
        onPressed: _setAside,
        icon: const Icon(Icons.close),
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        // Above everything, including who ended the voyage. Recording the voyage is
        // the premise of the app; a sailor who has lost one needs to know before
        // they read its summary, not after (#299).
        if (widget.controller.voyageArchiveError case final message?)
          Padding(
            key: const Key('voyage-archive-failed-notice'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF3A2126),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFF8A6B)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.save_as_outlined, color: Color(0xFFFF8A6B)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'This voyage was not saved',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          message,
                          style: const TextStyle(
                            color: Color(0xFFE6C3BB),
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        // Named, prominent, and first. A tester read an unexplained end as a
        // crash (#283): the screen said the voyage had ended but not that somebody
        // had ended it, nor who, so it was indistinguishable from the app
        // falling over. "Voyage summary ready" is the wrong first thing to say to
        // a sailor who did not ask for the voyage to stop.
        if (widget.controller.voyageEndedBy case final endedBy?
            when !endedBy.isLocalSailor)
          Padding(
            key: const Key('voyage-ended-by-notice'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF2A2136),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFFA76B)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFFFC79B)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          endedBy.displayName == null
                              ? 'The voyage skipper ended this voyage for everyone'
                              : '${endedBy.displayName} ended this voyage for '
                                    'everyone',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(color: const Color(0xFFFFF1E4)),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'The app did not stop on its own and nothing has gone '
                          'wrong. Your position is no longer being shared with '
                          'the group.',
                          style: TextStyle(
                            color: Color(0xFFE3CBB6),
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        Text(
          'Voyage summary ready',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        const Text(
          'Location sharing is stopped. Relay recovery stays available so the '
          'final marker and voyage-ended events can still be delivered after a '
          'temporary loss of signal.',
          style: TextStyle(color: Color(0xFFABB5C1), height: 1.45),
        ),
        const SizedBox(height: 8),
        const Text(
          'This voyage is already saved in Previous voyages. You can leave this '
          'screen any time — nothing here has to be done now.',
          style: TextStyle(color: Color(0xFF7F8A98), height: 1.45),
        ),
        const SizedBox(height: 16),
        // The way out, **above** everything that can grow.
        //
        // It used to be eighth in this list, below two relay status cards and the
        // road-rating card. In a test none of those three is supplied, so the
        // button was on screen and a passing test said the exit worked. On a real
        // voyage all three are present and it went off the bottom — which is
        // precisely what was reported: the shares worked and nothing dismissed the
        // screen (#440). The shares are directly above where it used to be.
        //
        // Filled, not outlined: it is the ordinary thing to do here. Filing the
        // voyage is the deliberate one and it stays at the bottom.
        FilledButton.icon(
          key: const Key('leave-ended-voyage-button'),
          onPressed: _setAside,
          icon: const Icon(Icons.map_outlined),
          // "the map", not "home": #426 made the home screen a free-roam map, and
          // the report was that there was "no way back to the map".
          label: const Text('Back to the map'),
        ),
        const SizedBox(height: 18),
        if (widget.nearbyRelayController case final nearby?) ...[
          RelayStatusCard(controller: nearby),
          const SizedBox(height: 12),
        ],
        if (widget.internetRelayController case final internet?) ...[
          InternetRelayStatusCard(controller: internet),
          const SizedBox(height: 18),
        ],
        FilledButton.icon(
          onPressed: () => _shareSummary(context),
          icon: const Icon(Icons.ios_share),
          label: const Text('Share voyage summary'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('share-recap-image-entry-button'),
          onPressed: () => _openRecap(context),
          icon: const Icon(Icons.image_outlined),
          label: const Text('Share voyage recap image'),
        ),
        // Above the shares and the filing, because a skipper who is here by
        // mistake is mid-voyage and has a group waiting (#206).
        if (_canOfferReopen) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('reopen-ended-voyage-button'),
            onPressed: _reopening ? null : () => _confirmReopen(context),
            icon: const Icon(Icons.play_arrow_outlined),
            label: const Text("This voyage hasn't finished — resume it"),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('file-ended-voyage-button'),
          onPressed: () => _confirmFile(context),
          // Not a delete icon: this files the voyage, and the icon is read before
          // the label (#156).
          icon: const Icon(Icons.inventory_2_outlined),
          label: const Text('Finish and file in Previous voyages'),
        ),
      ],
    ),
  );

  Future<void> _shareSummary(BuildContext context) async {
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    try {
      final diagnostics = await widget.diagnostics?.call();
      await (widget.summarySharer ?? const SystemVoyageSummarySharer()).share(
        widget.controller.session!,
        widget.controller.events,
        distanceUnit: widget.distanceUnits.value,
        sharePositionOrigin: origin,
        diagnostics: diagnostics == null || diagnostics.isEmpty
            ? null
            : diagnostics,
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not share voyage summary: $error')),
      );
    }
  }

  Future<void> _openRecap(BuildContext context) async {
    const exporter = VoyageSummaryExporter();
    final generatedAt = DateTime.now();
    final summary = exporter.summarize(
      widget.controller.session!,
      widget.controller.events,
      generatedAt: generatedAt,
    );
    final route = exporter.traveledRoute(
      widget.controller.session!,
      widget.controller.events,
      generatedAt: generatedAt,
    );
    await VoyageRecapScreen.show(
      context,
      // The real configuration, not the empty default: without a style there is
      // no basemap to snapshot and the recap falls back to the outline (#157).
      basemapConfiguration: BasemapConfiguration.fromEnvironment(),
      summary: summary,
      routePoints: route?.paths.single.points ?? const [],
      distanceUnit: widget.distanceUnits.value,
    );
  }

  /// The confirmation is kept, but it no longer describes a deletion.
  ///
  /// Filing a voyage is harmless - it is archived to Previous voyages first and only
  /// the live working copy is cleared - so a scary modal is not warranted. What
  /// is warranted is one sentence, because the single real consequence cannot be
  /// undone: a phone that has not yet received another sailor's last few events
  /// stops trying for them. A sailor who presses this thirty seconds after the
  /// voyage ends can lose the TEC's final marker count. That is small, and it is
  /// still a loss, and it is invisible unless said.
  Future<void> _confirmFile(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('File this voyage in Previous voyages?'),
        content: const Text(
          'The voyage stays on this phone, in Previous voyages, with its summary '
          'and recorded route.\n\n'
          'One thing stops: if another sailor\'s last few events have not '
          'reached this phone yet, it will stop waiting for them.',
        ),
        actions: [
          TextButton(
            key: const Key('keep-ended-voyage-open-button'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            key: const Key('confirm-file-ended-voyage-button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('File voyage'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      await (widget.onRemoveVoyage?.call() ??
          widget.controller.clearEndedVoyage());
    }
  }
}
