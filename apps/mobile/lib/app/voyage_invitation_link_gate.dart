import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/voyage_code_preference_controller.dart';
import '../controllers/voyage_controller.dart';
import '../controllers/voyage_invitation_link_controller.dart';
import '../controllers/sailor_profile_controller.dart';

/// Presents one native App/Universal Link as a deliberate join action.
///
/// This sits above both the home and active-voyage surfaces. A link can arrive at
/// cold start or while the map is open, but it must never silently replace the
/// voyage whose journal, role and safety state are already active on the phone.
class VoyageInvitationLinkGate extends StatefulWidget {
  const VoyageInvitationLinkGate({
    super.key,
    required this.links,
    required this.voyageController,
    required this.voyageCodePreference,
    required this.sailorProfile,
    required this.ready,
    required this.child,
  });

  final VoyageInvitationLinkController links;
  final VoyageController voyageController;
  final VoyageCodePreferenceController voyageCodePreference;
  final SailorProfileController sailorProfile;
  final bool ready;
  final Widget child;

  @override
  State<VoyageInvitationLinkGate> createState() =>
      _VoyageInvitationLinkGateState();
}

class _VoyageInvitationLinkGateState extends State<VoyageInvitationLinkGate> {
  bool _scheduled = false;
  bool _handling = false;

  @override
  void initState() {
    super.initState();
    widget.links.addListener(_schedule);
    widget.sailorProfile.addListener(_schedule);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant VoyageInvitationLinkGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.links, widget.links)) {
      oldWidget.links.removeListener(_schedule);
      widget.links.addListener(_schedule);
    }
    if (!identical(oldWidget.sailorProfile, widget.sailorProfile)) {
      oldWidget.sailorProfile.removeListener(_schedule);
      widget.sailorProfile.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void dispose() {
    widget.links.removeListener(_schedule);
    widget.sailorProfile.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (!mounted ||
        _scheduled ||
        _handling ||
        !widget.ready ||
        widget.sailorProfile.needsOnboarding ||
        !widget.links.hasNotice) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_handlePending());
    });
  }

  Future<void> _handlePending() async {
    if (_handling || !widget.ready || !widget.links.hasNotice) return;
    _handling = true;
    try {
      final malformed = widget.links.errorMessage;
      if (malformed != null) {
        await _showMessage(
          title: 'Cannot open invitation',
          message: malformed,
          action: 'Close',
        );
        widget.links.clear();
        return;
      }

      final invitation = widget.links.pending;
      if (invitation == null) return;

      final current = widget.voyageController.session;
      if (current != null) {
        final sameVoyage = current.voyageCode == invitation.voyageCode;
        await _showMessage(
          title: sameVoyage
              ? 'Already in this voyage'
              : 'A voyage is already open',
          message: sameVoyage
              ? 'This phone is already in voyage ${current.voyageCode}.'
              : 'Voyage ${current.voyageCode} is still open on this phone. For '
                    'safety, another invitation cannot replace it silently. '
                    'Leave or end the current voyage from Voyage actions, then tap '
                    'the new invitation again.',
          action: 'Keep current voyage',
        );
        widget.links.clear();
        return;
      }

      final shouldJoin = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          key: const Key('voyage-invitation-link-dialog'),
          icon: const Icon(Icons.group_add_outlined),
          title: Text('Join voyage ${invitation.voyageCode}?'),
          content: const Text(
            'This private invitation will connect you to the group. Only join '
            'if you recognise the person who shared it.',
          ),
          actions: [
            TextButton(
              key: const Key('decline-voyage-invitation-link'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            FilledButton(
              key: const Key('accept-voyage-invitation-link'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Join voyage'),
            ),
          ],
        ),
      );
      if (shouldJoin != true || !mounted) {
        widget.links.clear();
        return;
      }

      final profile = widget.sailorProfile;
      await widget.voyageController.joinVoyage(
        invitation.voyageCode,
        profile.displayName,
        joinToken: invitation.joinToken,
        vesselStyle: profile.vesselStyle,
        sailorSymbol: profile.sailorSymbol,
        sailorColor: profile.sailorColor,
      );
      if (!mounted) return;

      final joined =
          widget.voyageController.session?.voyageCode == invitation.voyageCode;
      if (joined) {
        await widget.voyageCodePreference.rememberSuccessfulJoin(
          invitation.voyageCode,
        );
        widget.links.clear();
        return;
      }

      final retry = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          key: const Key('voyage-invitation-link-error-dialog'),
          icon: const Icon(Icons.link_off_outlined),
          title: const Text('Could not join this voyage'),
          content: Text(
            widget.voyageController.errorMessage ??
                'That invitation could not be checked. Ask the skipper to '
                    'share a new one.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
            if (widget.voyageController.errorIsRetryable)
              FilledButton(
                key: const Key('retry-voyage-invitation-link'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Try again'),
              ),
          ],
        ),
      );
      if (retry != true) widget.links.clear();
    } finally {
      _handling = false;
      _schedule();
    }
  }

  Future<void> _showMessage({
    required String title,
    required String message,
    required String action,
  }) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const Key('voyage-invitation-link-message-dialog'),
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(action),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => widget.child;
}
