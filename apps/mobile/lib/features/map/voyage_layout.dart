/// Size classes for the voyage surfaces.
///
/// This exists because the inherited code decided layout from
/// `MediaQuery.orientationOf`, and on a phone that works by accident: a phone in
/// landscape is exactly the case where vertical space is tight, so "landscape"
/// and "cramped" mean the same thing.
///
/// On a tablet they come apart. An iPad in landscape is 1024pt or more each way,
/// with more height than a phone has in portrait — so treating it as
/// "landscape" shrank the toolbar, compacted the controls and squeezed the
/// guidance card on the one device with room to spare.
///
/// So the two questions are separated. [isCompactHeight] asks whether vertical
/// space is tight, which is what almost all the sizing actually cares about.
/// [isLandscape] asks about shape, which only matters for arrangement — whether
/// controls stack or sit side by side.
library;

import 'package:flutter/widgets.dart';

/// Where the breakpoints sit, and why.
///
/// Deliberately expressed against the devices they are drawn from rather than
/// as round numbers, because a round number invites being "tidied" later.
abstract final class VoyageBreakpoints {
  /// A phone in landscape is about 390–430pt tall. An iPad in portrait is 1024.
  /// Anything under this has to fight for vertical room; anything over does not.
  static const compactHeight = 500.0;

  /// A phone is 320–440pt wide. The smallest iPad is 744pt in portrait.
  static const compactWidth = 600.0;

  /// Shortest side of the smallest current iPad in either orientation.
  static const tabletShortestSide = 600.0;
}

/// The layout facts a voyage surface needs, derived from one place.
@immutable
class VoyageLayout {
  const VoyageLayout({required this.size});

  factory VoyageLayout.of(BuildContext context) =>
      VoyageLayout(size: MediaQuery.sizeOf(context));

  final Size size;

  /// Vertical space is tight. This is what the chrome sizing should key off:
  /// smaller toolbar, compact density, tighter padding.
  bool get isCompactHeight => size.height < VoyageBreakpoints.compactHeight;

  /// Horizontal space is tight, so side-by-side arrangements will not fit.
  bool get isCompactWidth => size.width < VoyageBreakpoints.compactWidth;

  /// Wider than tall. Only for deciding *arrangement* — never for sizing, which
  /// is the mistake this class exists to stop.
  bool get isLandscape => size.width > size.height;

  /// A tablet-sized surface in either orientation.
  ///
  /// The device a boat actually runs navigation on, mounted at the chart table
  /// rather than held in one hand — so reach assumptions from a handheld phone
  /// do not transfer.
  bool get isTablet =>
      size.shortestSide >= VoyageBreakpoints.tabletShortestSide;

  /// Room for a persistent side panel beside the chart rather than a sheet over
  /// it. True only on a tablet in landscape.
  bool get canHostSidePanel => isTablet && isLandscape;

  /// Height for the map's top toolbar.
  double get toolbarHeight => isCompactHeight ? 42 : 52;

  /// Icon size for map chrome buttons.
  double get chromeIconSize => isCompactHeight ? 22 : 24;

  /// Whether controls should use Flutter's compact visual density.
  bool get usesCompactDensity => isCompactHeight;

  /// Size of the group overview inset.
  Size get groupMiniMapSize => switch ((isTablet, isLandscape)) {
    // A tablet has room for an overview worth reading rather than glancing at.
    (true, _) => const Size(260, 150),
    (false, true) => const Size(196, 116),
    (false, false) => const Size(150, 104),
  };

  /// Minimum tap target. Bumped on a tablet, where a mounted screen is used at
  /// arm's length on a moving boat rather than held steady in the hand.
  double get minimumTapTarget => isTablet ? 56 : 48;

  @override
  bool operator ==(Object other) => other is VoyageLayout && other.size == size;

  @override
  int get hashCode => size.hashCode;
}
