import 'package:flutter/material.dart';

import '../../controllers/voyage_controller.dart';

/// The one confirmation for ending a voyage, wherever it is reached from.
///
/// Ending a voyage is the app's most destructive action — it stops the group, not
/// just this phone. It used to be offered independently by the voyage menu and
/// dashboard header, with different dialogs saying different things (#306).
///
/// The two were not merely worded differently. Only the voyage menu's told the
/// skipper whether the voyage could be resumed, including the sentence "this
/// action cannot be undone for the group" when the relay cannot carry a reopen.
/// Only the dashboard's showed the marking summary and offered to share it
/// first. **So whether a skipper learned that ending the voyage was irreversible
/// depended on which button they happened to press.**
///
/// This is the union of the two, not the intersection: nothing either of them
/// said was lost. The consolidation now routes the map and Voyage actions through
/// one combined Leave-or-end decision before this confirmation.
/// Whether this sailor may end the voyage for everyone.
///
/// One named decision for every surface that offers it, because there were
/// three separate expressions of it and two were wrong. `VoyageController.endVoyage`
/// accepts `isLocalVoyageSkipper`, and the voyage menu offers the action on the same
/// — but the shell's end-voyage guard and the map's exit dialog both read
/// `session?.role == VoyageRole.skipper`, which is **false while the skipper is acting
/// as the marker**. So a skipper marking a junction was refused an action the
/// controller would have accepted: End voyage did nothing at all, and LEAVE showed
/// the follower's dialog with no "End for everyone" (#306).
bool canEndVoyageForEveryone(VoyageController controller) =>
    controller.isLocalVoyageSkipper;

Future<bool> confirmEndVoyage(
  BuildContext context, {
  required VoyageController controller,
  required bool relayCanCarryReopen,
  Future<void> Function()? onShareSummary,
}) async {
  // Offering an action and then silently refusing it is worse than not
  // offering it; see [canEndVoyageForEveryone].
  if (!canEndVoyageForEveryone(controller)) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('End this voyage?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            endVoyageConsequence(
              relayCanCarryReopen: relayCanCarryReopen,
              isSolo: !controller.coordinationMode.isGroup,
            ),
          ),
        ],
      ),
      actions: [
        if (onShareSummary != null)
          TextButton.icon(
            key: const Key('end-voyage-share-summary'),
            onPressed: () => onShareSummary(),
            icon: const Icon(Icons.summarize_outlined),
            label: const Text('Share summary'),
          ),
        TextButton(
          key: const Key('cancel-end-voyage'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-end-voyage'),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('End voyage'),
        ),
      ],
    ),
  );
  if (!(confirmed ?? false)) return false;
  await controller.endVoyage();
  return true;
}

/// What ending the voyage actually does, in one place so the two entry points
/// cannot disagree about whether it can be undone.
///
/// The irreversibility sentence is the half that was missing from the dashboard
/// dialog, and it is the half a skipper needs most.
String endVoyageConsequence({
  required bool relayCanCarryReopen,
  bool isSolo = false,
}) {
  // A solo voyage has no group to end it for and no other phones to fail to
  // resume it on. Saying so anyway told a sailor alone on a road that they were
  // about to affect people who were not there (#362).
  if (isSolo) {
    return 'This ends your voyage. Location sharing stops on this phone, and '
        'relay recovery stays available for final queued events until you '
        'file the ended voyage.\n\n'
        '${relayCanCarryReopen ? 'You can resume it within 24 hours without changing the voyage code.' : 'This relay cannot resume an ended voyage. This action cannot be undone.'}';
  }
  return 'This ends the group voyage for everyone. Location sharing stops on '
      'this phone, and relay recovery stays available for final queued events '
      'until you file the ended voyage.\n\n'
      '${relayCanCarryReopen ? 'You can resume it within 24 hours without changing the voyage code.' : 'This relay cannot resume an ended voyage on the other phones. This action cannot be undone for the group.'}';
}
