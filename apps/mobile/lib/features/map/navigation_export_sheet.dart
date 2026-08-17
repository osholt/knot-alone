import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/navigation_export.dart';

class NavigationExportSheet extends StatelessWidget {
  const NavigationExportSheet({super.key});

  static Future<NavigationTarget?> show(BuildContext context) =>
      showModalBottomSheet<NavigationTarget>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => const NavigationExportSheet(),
      );

  static NavigationPlatform get _currentPlatform =>
      switch (defaultTargetPlatform) {
        TargetPlatform.android => NavigationPlatform.android,
        _ => NavigationPlatform.iOS,
      };

  @override
  Widget build(BuildContext context) {
    // Filtered through the capability registry - not just for today's list
    // (every entry currently supports both platforms), but so a future
    // platform-exclusive integration is actually excluded here rather than
    // requiring someone to remember to update this sheet separately.
    final capabilities = navigationCapabilitiesFor(_currentPlatform).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          children: [
            Text(
              'Send this passage',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 5),
            const Text(
              'Every option transfers the full GPX route through the share '
              'sheet. Pick the app you want, or share the file and choose '
              'later.',
              style: TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 18),
            for (final capability in capabilities)
              _TargetTile(target: capability.target),
          ],
        ),
      ),
    );
  }
}

class _TargetTile extends StatelessWidget {
  const _TargetTile({required this.target});

  final NavigationTarget target;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    leading: CircleAvatar(
      backgroundColor: Theme.of(
        context,
      ).colorScheme.primary.withValues(alpha: 0.12),
      child: Icon(_icon(target)),
    ),
    title: Text(target.label),
    subtitle: Text(target.limitation),
    trailing: const Icon(Icons.ios_share_outlined, size: 20),
    onTap: () => Navigator.pop(context, target),
  );

  static IconData _icon(NavigationTarget target) => switch (target) {
    NavigationTarget.shareGpx => Icons.file_upload_outlined,
    NavigationTarget.navionics => Icons.sailing_outlined,
    NavigationTarget.aquaMap => Icons.water_outlined,
    NavigationTarget.iSailor => Icons.sailing_outlined,
    NavigationTarget.openCpn => Icons.computer_outlined,
    NavigationTarget.garmin => Icons.gps_fixed,
    NavigationTarget.savvyNavvy => Icons.explore_outlined,
  };
}
