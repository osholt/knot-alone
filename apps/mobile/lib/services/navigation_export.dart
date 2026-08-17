/// Handing a planned passage to another navigation app.
///
/// ## Why this is GPX sharing and nothing else
///
/// The inherited version had two transports. Google Maps and Waze got
/// *direct links* — a URL built from the route's endpoints — and everything else
/// got the GPX share sheet. Both direct links are gone, and the transport
/// distinction went with them, because on the water they were worse than useless:
///
/// - The Google Maps link asked for `travelmode=driving` between the first and
///   last point of the route. Between two sea waypoints that returns a road route
///   over land, and it returns it confidently. A sailor tapping "Google Maps"
///   expecting to see their passage would be shown a driving route around a
///   coastline.
/// - The Waze link passed `vehicle_type=motorcycle` and carried only the final
///   destination, discarding the route.
///
/// So every target here transfers the full GPX and reaches its app through the
/// system share sheet. That is not a limitation being tolerated: GPX is how
/// marine navigation software actually accepts routes, and several of these apps
/// take it only as a file.
///
/// ## Why no marine app gets a direct link
///
/// The rule the inherited file stated and this one keeps: a provider-specific
/// integration belongs here only once its documented route exists and has been
/// physically tested. Navionics, Aqua Map and iSailor are not known to publish
/// documented URL schemes for route import, and guessing one produces a button
/// that silently fails. Named targets here are therefore share-sheet hints — they
/// tell the sailor which app to pick — and [NavigationTarget.shareGpx] is the one
/// that always works.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/imported_route.dart';
import 'gpx_exporter.dart';

enum NavigationTarget {
  shareGpx,
  navionics,
  aquaMap,
  iSailor,
  openCpn,
  garmin,
  savvyNavvy,
}

/// The amount of route information Tide and Seek can transfer to an external
/// navigation target. A receiving app may still change a GPX route on import.
///
/// Only [fullGpx] is reachable now. The other two described what a direct link
/// could manage, and are kept because they are the honest vocabulary for any
/// future integration that cannot carry a whole route.
enum NavigationRouteTransfer { fullGpx, sampledWaypoints, destinationOnly }

enum NavigationPlatform { android, iOS }

const allNavigationPlatforms = <NavigationPlatform>{
  NavigationPlatform.android,
  NavigationPlatform.iOS,
};

/// A single, explicit record of each supported handoff.
class NavigationHandoffCapability {
  const NavigationHandoffCapability({
    required this.target,
    required this.label,
    required this.routeTransfer,
    required this.platforms,
    required this.limitation,
  });

  final NavigationTarget target;
  final String label;
  final NavigationRouteTransfer routeTransfer;
  final Set<NavigationPlatform> platforms;

  /// What the sailor should expect, including where the app will not do what the
  /// name implies. Shown in the sheet rather than kept as a comment.
  final String limitation;

  bool supports(NavigationPlatform platform) => platforms.contains(platform);
}

const navigationHandoffCapabilities = <NavigationHandoffCapability>[
  NavigationHandoffCapability(
    target: NavigationTarget.shareGpx,
    label: 'Share GPX file',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Choose any GPX-compatible app, or save to Files',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.navionics,
    label: 'Navionics Boating',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Uses the GPX share sheet; choose Boating if installed',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.aquaMap,
    label: 'Aqua Map',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Uses the GPX share sheet; choose Aqua Map if installed',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.iSailor,
    label: 'iSailor',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Uses the GPX share sheet; choose iSailor if installed',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.openCpn,
    label: 'OpenCPN',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Save the GPX to Files, then import it on the chart computer',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.garmin,
    label: 'Garmin ActiveCaptain',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Uses the GPX share sheet to reach a Garmin chartplotter',
  ),
  NavigationHandoffCapability(
    target: NavigationTarget.savvyNavvy,
    label: 'savvy navvy',
    routeTransfer: NavigationRouteTransfer.fullGpx,
    platforms: allNavigationPlatforms,
    limitation: 'Uses the GPX share sheet; choose savvy navvy if installed',
  ),
];

Iterable<NavigationHandoffCapability> navigationCapabilitiesFor(
  NavigationPlatform platform,
) => navigationHandoffCapabilities.where(
  (capability) => capability.supports(platform),
);

extension NavigationTargetDetails on NavigationTarget {
  NavigationHandoffCapability get capability => navigationHandoffCapabilities
      .firstWhere((capability) => capability.target == this);

  String get label => capability.label;

  String get limitation => capability.limitation;
}

class NavigationExportResult {
  const NavigationExportResult({
    required this.message,
    required this.sharedGpx,
  });

  final String message;
  final bool sharedGpx;
}

abstract interface class GpxShareGateway {
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  });
}

class SystemGpxShareGateway implements GpxShareGateway {
  const SystemGpxShareGateway({this.exporter = const GpxExporter()});

  final GpxExporter exporter;

  @override
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  }) async {
    final fileName = exporter.fileName(route);
    final bytes = Uint8List.fromList(utf8.encode(exporter.export(route)));
    await SharePlus.instance.share(
      ShareParams(
        title: 'Export ${route.name}',
        subject: 'Tide and Seek route: ${route.name}',
        text: _shareInstruction(target),
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'application/gpx+xml',
            name: fileName,
          ),
        ],
        fileNameOverrides: [fileName],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  static String _shareInstruction(NavigationTarget target) => switch (target) {
    NavigationTarget.shareGpx => 'GPX 1.1 route exported from Tide and Seek.',
    _ =>
      'Choose ${target.label} in the share sheet if it is installed. '
          'Tide and Seek cannot preselect another app.',
  };
}

class NavigationExportCoordinator {
  const NavigationExportCoordinator({
    this.shareGateway = const SystemGpxShareGateway(),
  });

  final GpxShareGateway shareGateway;

  Future<NavigationExportResult> export(
    NavigationTarget target,
    ImportedRoute route, {
    Rect? sharePositionOrigin,
  }) async {
    await shareGateway.share(
      route: route,
      target: target,
      sharePositionOrigin: sharePositionOrigin,
    );
    return NavigationExportResult(
      message: target == NavigationTarget.shareGpx
          ? 'GPX route shared.'
          : '${target.label} uses the GPX share sheet; choose it if installed.',
      sharedGpx: true,
    );
  }
}
