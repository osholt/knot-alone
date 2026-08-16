import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/ride_controller.dart';
import '../../domain/ice_share.dart';

/// Shows ICE (in-case-of-emergency) info other riders have shared into this
/// ride, and the read-receipt status of any the local rider has sent.
/// Opening this marks everything currently shown as viewed, so the sharer
/// can see it was seen; calling or texting a contact marks that share as
/// used, which is what exempts it from the ride-end purge.
class IceShareInboxSheet extends StatefulWidget {
  const IceShareInboxSheet({super.key, required this.rideController});

  final RideController rideController;

  static Future<void> show(
    BuildContext context,
    RideController rideController,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => IceShareInboxSheet(rideController: rideController),
  );

  @override
  State<IceShareInboxSheet> createState() => _IceShareInboxSheetState();
}

class _IceShareInboxSheetState extends State<IceShareInboxSheet> {
  @override
  void initState() {
    super.initState();
    for (final share in widget.rideController.receivedIceShares) {
      unawaited(widget.rideController.markIceInfoViewed(share.eventId));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.rideController,
    builder: (context, _) {
      final received = widget.rideController.receivedIceShares;
      final sent = widget.rideController.sentIceShares;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          22,
          4,
          22,
          28 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Shared emergency contacts',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Only for this ride - a leader-received contact clears itself '
              'once the ride ends, unless you called or texted it.',
              style: TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 20),
            if (received.isEmpty)
              const Text(
                'Nothing has been shared with you yet.',
                style: TextStyle(color: Color(0xFF98A3B1)),
              )
            else
              for (final share in received) ...[
                _ReceivedIceShareCard(
                  share: share,
                  onUsed: () =>
                      widget.rideController.markIceShareUsed(share.eventId),
                ),
                const SizedBox(height: 12),
              ],
            if (sent.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'YOUR SHARES',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF8D98A7),
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 10),
              for (final share in sent) ...[
                _SentIceShareTile(share: share),
                const SizedBox(height: 4),
              ],
            ],
          ],
        ),
      );
    },
  );
}

class _ReceivedIceShareCard extends StatelessWidget {
  const _ReceivedIceShareCard({required this.share, required this.onUsed});

  final IceShare share;
  final VoidCallback onUsed;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFF2A2E38)),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'From ${share.sharedByDisplayName}'
          '${share.toWholeGroup ? '' : ' (shared with the leader)'}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        if (share.contactName.isNotEmpty) Text('Contact: ${share.contactName}'),
        if (share.contactPhone.isNotEmpty) Text(share.contactPhone),
        if (share.medicalNotes.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            share.medicalNotes,
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            if (share.contactPhone.isNotEmpty) ...[
              FilledButton.icon(
                key: Key('ice-share-call-${share.eventId}'),
                onPressed: () => _launch(context, 'tel', share.contactPhone),
                icon: const Icon(Icons.call, size: 18),
                label: const Text('Call'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: Key('ice-share-text-${share.eventId}'),
                onPressed: () => _launch(context, 'sms', share.contactPhone),
                icon: const Icon(Icons.sms_outlined, size: 18),
                label: const Text('Text'),
              ),
            ],
          ],
        ),
      ],
    ),
  );

  Future<void> _launch(
    BuildContext context,
    String scheme,
    String phone,
  ) async {
    onUsed();
    final opened = await launchUrl(Uri(scheme: scheme, path: phone));
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open that app.')));
    }
  }
}

class _SentIceShareTile extends StatelessWidget {
  const _SentIceShareTile({required this.share});

  final IceShare share;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Icon(
          share.viewedAt != null
              ? Icons.done_all
              : Icons.hourglass_top_outlined,
          size: 18,
          color: share.viewedAt != null
              ? const Color(0xFF54E1C4)
              : const Color(0xFF8D98A7),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            share.toWholeGroup
                ? 'Shared with the group - '
                      '${share.viewedAt != null ? 'seen' : 'not yet seen'}'
                : 'Shared with the leader - '
                      '${share.viewedAt != null ? 'seen' : 'not yet seen'}',
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
        ),
      ],
    ),
  );
}
