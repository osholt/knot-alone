import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../map/map_camera_guard.dart';

import '../../controllers/completed_voyages_controller.dart';
import '../../controllers/distance_unit_controller.dart';
import '../../domain/completed_voyage.dart';
import '../../domain/imported_route.dart';
import '../../services/basemap_configuration.dart';
import '../../services/completed_voyage_sharer.dart';
import '../../services/map_geojson.dart';
import '../../services/map_style_repository.dart';
import '../../services/measurement_formatter.dart';
import '../../services/voyage_summary_exporter.dart';
import '../../services/stored_route_library.dart';
import '../../services/trail_direction_arrows.dart';
import '../map/vessel_icon.dart';
import '../map/resolved_route_map_preview.dart'
    show embeddedMapGestureRecognizers;
import '../map/stored_route_picker.dart';
import 'voyage_recap_screen.dart';

class PreviousVoyagesScreen extends StatelessWidget {
  const PreviousVoyagesScreen({
    super.key,
    required this.completedVoyages,
    required this.distanceUnits,
  });

  final CompletedVoyagesController completedVoyages;
  final DistanceUnitController distanceUnits;

  static Future<StoredRouteSelection?> show(
    BuildContext context,
    CompletedVoyagesController completedVoyages,
    DistanceUnitController distanceUnits,
  ) => Navigator.of(context).push<StoredRouteSelection>(
    MaterialPageRoute<StoredRouteSelection>(
      builder: (_) => PreviousVoyagesScreen(
        completedVoyages: completedVoyages,
        distanceUnits: distanceUnits,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Previous voyages')),
    body: AnimatedBuilder(
      animation: completedVoyages,
      builder: (context, _) {
        final voyages = completedVoyages.voyages;
        if (voyages.isEmpty) {
          return const _EmptyArchive();
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
          itemCount: voyages.length + 1,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            if (index == 0) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'These records stay on this phone until you delete them. '
                  'Exported files are saved wherever you choose in the native '
                  'share sheet.',
                  style: TextStyle(color: Color(0xFFABB5C1), height: 1.4),
                ),
              );
            }
            final voyage = voyages[index - 1];
            return _VoyageTile(
              voyage: voyage,
              distance: MeasurementFormatter(
                distanceUnits.value,
              ).distance(voyage.totalDistanceMeters),
              onTap: () async {
                final selection = await Navigator.of(context).push(
                  MaterialPageRoute<StoredRouteSelection>(
                    builder: (_) => PreviousVoyageDetailScreen(
                      voyage: voyage,
                      completedVoyages: completedVoyages,
                      distanceUnits: distanceUnits,
                    ),
                  ),
                );
                if (selection != null && context.mounted) {
                  Navigator.of(context).pop(selection);
                }
              },
            );
          },
        );
      },
    ),
  );
}

class _EmptyArchive extends StatelessWidget {
  const _EmptyArchive();

  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.route_outlined, size: 52, color: Color(0xFF7F8A98)),
          SizedBox(height: 16),
          Text(
            'No previous voyages yet',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          SizedBox(height: 8),
          Text(
            'A real voyage will appear here after it ends or you leave it.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
        ],
      ),
    ),
  );
}

class _VoyageTile extends StatelessWidget {
  const _VoyageTile({
    required this.voyage,
    required this.distance,
    required this.onTap,
  });

  final CompletedVoyage voyage;
  final String distance;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      leading: const CircleAvatar(child: Icon(Icons.two_wheeler)),
      title: Text(voyage.title),
      subtitle: Text(
        '${_date(voyage.startedAt)} · $distance · ${voyage.sailorCount} sailors\n'
        '${voyage.traveledRoute == null
            ? 'No GPX trail recorded'
            : voyage.hasRecordingGaps
            ? 'Recorded trail has location gaps'
            : 'GPX ready'}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

class PreviousVoyageDetailScreen extends StatefulWidget {
  const PreviousVoyageDetailScreen({
    super.key,
    required this.voyage,
    required this.completedVoyages,
    required this.distanceUnits,
    this.sharer = const SystemCompletedVoyageSharer(),
  });

  final CompletedVoyage voyage;
  final CompletedVoyagesController completedVoyages;
  final DistanceUnitController distanceUnits;
  final CompletedVoyageSharer sharer;

  @override
  State<PreviousVoyageDetailScreen> createState() =>
      _PreviousVoyageDetailScreenState();
}

class _PreviousVoyageDetailScreenState
    extends State<PreviousVoyageDetailScreen> {
  bool _sharing = false;

  @override
  Widget build(BuildContext context) {
    final voyage = widget.voyage;
    final formatter = MeasurementFormatter(widget.distanceUnits.value);
    return Scaffold(
      appBar: AppBar(
        title: Text(voyage.title),
        actions: [
          IconButton(
            tooltip: 'Delete voyage',
            onPressed: _confirmDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 28),
        children: [
          SizedBox(
            height: 320,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: ArchivedVoyageMap(
                plannedRoute: voyage.plannedRoute,
                traveledRoute: voyage.traveledRoute,
              ),
            ),
          ),
          if (_legendKeys(voyage) case final keys when keys.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              key: const Key('archived-voyage-legend'),
              alignment: WrapAlignment.center,
              spacing: 18,
              runSpacing: 8,
              children: keys,
            ),
          ],
          const SizedBox(height: 18),
          if (voyage.hasRecordingGaps) ...[
            Card(
              key: const Key('archived-voyage-recording-gap'),
              color: const Color(0xFF342B17),
              child: const ListTile(
                leading: Icon(Icons.location_disabled_outlined),
                title: Text('This recording has gaps'),
                subtitle: Text(
                  'Location stopped for part of the voyage. Missing sections are '
                  'left blank rather than shown as straight lines, and are not '
                  'included in the distance.',
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                runSpacing: 14,
                spacing: 24,
                children: [
                  _Metric(label: 'Date', value: _date(voyage.startedAt)),
                  _Metric(label: 'Duration', value: _duration(voyage.duration)),
                  _Metric(
                    label: 'Distance',
                    value: formatter.distance(voyage.totalDistanceMeters),
                  ),
                  _Metric(label: 'Sailors', value: '${voyage.sailorCount}'),
                  _Metric(label: 'Role', value: voyage.localRole.name),
                  _Metric(label: 'Voyage code', value: voyage.voyageCode),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('archived-voyage-again'),
            onPressed:
                voyage.plannedRoute == null && voyage.traveledRoute == null
                ? null
                : _voyageAgain,
            icon: const Icon(Icons.route_outlined),
            label: const Text('Voyage again'),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _sharing ? null : () => _shareSummary(),
            icon: const Icon(Icons.ios_share),
            label: const Text('Share summary'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('archived-voyage-export-gpx'),
            onPressed: _sharing || voyage.traveledRoute == null
                ? null
                : _exportGpx,
            icon: const Icon(Icons.file_upload_outlined),
            label: Text(
              voyage.traveledRoute == null
                  ? 'No recorded GPX trail'
                  : 'Export GPX',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _openRecap,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Share recap image'),
          ),
          const SizedBox(height: 14),
          const Text(
            'Voyage history is stored locally on this phone. Tide and Seek '
            'does not upload a permanent copy. The native share destination '
            'determines where an exported GPX is saved.',
            style: TextStyle(color: Color(0xFF8994A2), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _shareSummary() => _runShare(
    () => widget.sharer.shareSummary(
      widget.voyage,
      distanceUnit: widget.distanceUnits.value,
      sharePositionOrigin: _shareOrigin(),
    ),
  );

  Future<void> _voyageAgain() async {
    final voyage = widget.voyage;
    final candidates = <StoredRouteCandidate>[
      if (voyage.plannedRoute case final route?)
        StoredRouteCandidate(
          id: 'voyage:${voyage.voyageId}:plan',
          origin: StoredRouteOrigin.previousVoyagePlan,
          title: voyage.title,
          storedAt: voyage.startedAt,
          geometry: route,
          voyageCode: voyage.voyageCode,
        ),
      if (voyage.traveledRoute case final route?)
        StoredRouteCandidate(
          id: 'voyage:${voyage.voyageId}:track',
          origin: StoredRouteOrigin.previousVoyageTrack,
          title: voyage.title,
          storedAt: voyage.startedAt,
          geometry: route,
          voyageCode: voyage.voyageCode,
        ),
    ];
    if (candidates.isEmpty) return;
    // A plan is the default because it describes the intended voyage. The track
    // remains an explicit choice where both exist.
    var candidate = candidates.first;
    if (candidates.length > 1) {
      final chosen = await showModalBottomSheet<StoredRouteCandidate>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('Which route should be reused?'),
                subtitle: Text(
                  'The planned route is recommended. The recorded track '
                  'includes where the bike actually went.',
                ),
              ),
              for (final option in candidates)
                ListTile(
                  key: Key('voyage-again-${option.origin.name}'),
                  leading: Icon(
                    option.origin == StoredRouteOrigin.previousVoyagePlan
                        ? Icons.route_outlined
                        : Icons.timeline_outlined,
                  ),
                  title: Text(
                    option.origin == StoredRouteOrigin.previousVoyagePlan
                        ? 'Planned route · recommended'
                        : 'Recorded track',
                  ),
                  onTap: () => Navigator.pop(sheetContext, option),
                ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      candidate = chosen;
    }
    final selection = await showModalBottomSheet<StoredRouteSelection>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StoredRouteOptionsSheet(
        candidate: candidate,
        distanceUnit: widget.distanceUnits.value,
      ),
    );
    if (selection != null && mounted) {
      Navigator.of(context).pop(selection);
    }
  }

  Future<void> _exportGpx() => _runShare(
    () => widget.sharer.exportGpx(
      widget.voyage,
      sharePositionOrigin: _shareOrigin(),
    ),
  );

  Future<void> _runShare(Future<void> Function() action) async {
    setState(() => _sharing = true);
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not share: $error')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Rect? _shareOrigin() {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
  }

  Future<void> _openRecap() async {
    final voyage = widget.voyage;
    final summary = VoyageSummary(
      voyageId: voyage.voyageId,
      voyageCode: voyage.voyageCode,
      displayName: voyage.localDisplayName,
      startedAt: voyage.startedAt,
      endedAt: voyage.endedAt,
      generatedAt: voyage.archivedAt,
      eventCount: voyage.eventCount,
      markerSessions: [
        for (final (index, marker) in voyage.markerSessions.indexed)
          MarkerSessionSummary(
            markerDeviceId: 'archived-marker-$index',
            startedAt: marker.startedAt,
            endedAt: marker.endedAt,
            uniquePassCount: marker.uniquePassCount,
            duration: (marker.endedAt ?? voyage.endedAt)
                .difference(marker.startedAt)
                .abs(),
          ),
      ],
      sailorCount: voyage.sailorCount,
      totalDistanceMeters: voyage.totalDistanceMeters,
    );
    await VoyageRecapScreen.show(
      context,
      // The real configuration, not the empty default: without a style there is
      // no basemap to snapshot and the recap falls back to the outline (#157).
      basemapConfiguration: BasemapConfiguration.fromEnvironment(),
      summary: summary,
      routePoints:
          voyage.traveledRoute?.paths.expand((path) => path.points).toList() ??
          voyage.plannedRoute?.paths.expand((path) => path.points).toList() ??
          const [],
      distanceUnit: widget.distanceUnits.value,
    );
  }

  static List<Widget> _legendKeys(CompletedVoyage voyage) {
    final legend = archivedVoyageLegend(voyage);
    final hasDirection = legend.traveled || legend.planned;
    return [
      if (legend.planned)
        const _Legend(color: Color(0xFFFF7A1A), label: 'Planned route'),
      if (legend.traveled)
        const _Legend(color: Color(0xFF42C9E8), label: 'Your recorded trail'),
      if (hasDirection) ...const [
        _EndpointLegend(color: Color(0xFF63D98B), label: 'Start'),
        _EndpointLegend(color: Color(0xFFFF6470), label: 'Finish'),
      ],
    ];
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this voyage?'),
        content: const Text(
          'Its local summary and recorded geometry will be removed from this '
          'phone. Files you previously exported are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.completedVoyages.delete(widget.voyage.voyageId);
    if (mounted) Navigator.of(context).pop();
  }
}

class ArchivedVoyageMap extends StatefulWidget {
  const ArchivedVoyageMap({
    super.key,
    required this.plannedRoute,
    required this.traveledRoute,
    this.basemapConfiguration,
    this.mapStyleString,
  });

  final ImportedRoute? plannedRoute;
  final ImportedRoute? traveledRoute;
  final BasemapConfiguration? basemapConfiguration;
  final String? mapStyleString;

  @override
  State<ArchivedVoyageMap> createState() => _ArchivedVoyageMapState();
}

class _ArchivedVoyageMapState extends State<ArchivedVoyageMap> {
  static const _plannedSource = 'archived-planned-source';
  static const _trackSource = 'archived-track-source';
  static const _directionSource = 'archived-direction-source';
  static const _directionImage = 'archived-direction-arrow';
  ml.MapLibreMapController? _controller;
  List<_ArchivedEndpointScreenMarker> _endpointMarkers = const [];
  bool _styleReady = false;
  bool _initialFitComplete = false;
  late final Future<String> _mapStyle = _resolveMapStyle();

  ArchivedVoyageDirectionOverlay? get _directionOverlay =>
      archivedVoyageDirectionOverlay(
        plannedRoute: widget.plannedRoute,
        traveledRoute: widget.traveledRoute,
      );

  List<GeoPoint> get _points => [
    ...?widget.plannedRoute?.allPoints,
    ...?widget.traveledRoute?.allPoints,
  ];

  @override
  Widget build(BuildContext context) {
    final points = _points;
    if (points.isEmpty) {
      return const ColoredBox(
        color: Color(0xFF151E28),
        child: Center(child: Text('No route geometry was recorded')),
      );
    }
    final configuration =
        widget.basemapConfiguration ??
        BasemapConfiguration.fromEnvironment().forBrightness(dark: true);
    final first = points.first;
    return FutureBuilder<String>(
      future: _mapStyle,
      builder: (context, snapshot) {
        final style = snapshot.data;
        if (style == null) {
          return const ColoredBox(
            color: Color(0xFF111820),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Stack(
          children: [
            Positioned.fill(
              child: ml.MapLibreMap(
                key: const Key('archived-voyage-map'),
                styleString: style,
                initialCameraPosition: ml.CameraPosition(
                  target: ml.LatLng(first.latitude, first.longitude),
                  zoom: points.length == 1 ? 14 : 10,
                ),
                onMapCreated: (controller) => _controller = controller,
                onStyleLoadedCallback: () => unawaited(_prepareStyle()),
                onCameraMove: (_) => _hideEndpointMarkers(),
                onCameraIdle: () => unawaited(_updateEndpointMarkers()),
                onMapIdle: () => unawaited(_fitInitialVoyage()),
                gestureRecognizers: embeddedMapGestureRecognizers,
                logoEnabled: false,
                compassEnabled: true,
                minMaxZoomPreference: ml.MinMaxZoomPreference(
                  3,
                  configuration.maximumNativeZoom.toDouble(),
                ),
              ),
            ),
            for (final marker in _endpointMarkers)
              Positioned(
                left: marker.position.dx - 17,
                top: marker.position.dy - 34,
                child: IgnorePointer(
                  child: _ArchivedMapEndpointMarker(
                    color: marker.color,
                    label: marker.label,
                  ),
                ),
              ),
            const Positioned(
              right: 6,
              bottom: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0xB3000000)),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    'OpenFreeMap · © OSM',
                    style: TextStyle(color: Colors.white, fontSize: 8),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 8,
              top: 8,
              child: Material(
                color: const Color(0xD9182029),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('archived-voyage-fit-route'),
                  tooltip: 'Fit the whole voyage',
                  onPressed: _fit,
                  color: Colors.white,
                  icon: const Icon(Icons.fit_screen),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<String> _resolveMapStyle() async {
    final supplied = widget.mapStyleString;
    if (supplied != null) return supplied;
    final configuration =
        widget.basemapConfiguration ??
        BasemapConfiguration.fromEnvironment().forBrightness(dark: true);
    final repository = await MapStyleRepository.openDefault(configuration);
    try {
      // As in `resolved_route_map_preview.dart`: a history thumbnail has
      // nowhere to report a basemap failure, so the outcome is dropped on
      // purpose rather than overlooked (#281).
      return (await repository.resolve()).style;
    } finally {
      repository.dispose();
    }
  }

  Future<void> _prepareStyle() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      await controller.addGeoJsonSource(
        _plannedSource,
        MapGeoJson.route(widget.plannedRoute),
      );
      await controller.addLineLayer(
        _plannedSource,
        'archived-planned-line',
        const ml.LineLayerProperties(
          lineColor: '#FF7A1A',
          lineWidth: 4,
          lineOpacity: 0.8,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      await controller.addGeoJsonSource(
        _trackSource,
        MapGeoJson.route(widget.traveledRoute),
      );
      await controller.addLineLayer(
        _trackSource,
        'archived-track-line',
        const ml.LineLayerProperties(
          lineColor: '#42C9E8',
          lineWidth: 5,
          lineCap: 'round',
          lineJoin: 'round',
        ),
        enableInteraction: false,
      );
      final overlay = _directionOverlay;
      if (overlay != null) {
        await controller.addImage(
          _directionImage,
          await rasterizeIconGlyphPng(Icons.navigation_rounded),
          true,
        );
        await controller.addGeoJsonSource(
          _directionSource,
          archivedVoyageDirectionGeoJson(overlay),
        );
        await controller.addSymbolLayer(
          _directionSource,
          'archived-direction-arrows',
          const ml.SymbolLayerProperties(
            iconImage: _directionImage,
            iconColor: ['get', 'color'],
            iconHaloColor: '#10151C',
            iconHaloWidth: 2,
            iconSize: 0.14,
            iconRotate: ['get', 'bearing'],
            iconRotationAlignment: 'map',
            iconPitchAlignment: 'map',
            iconAllowOverlap: true,
            iconIgnorePlacement: true,
          ),
          enableInteraction: false,
        );
      }
      _styleReady = true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _fitInitialVoyage();
    } on Object {
      // Summary and exports remain usable if a style cannot be loaded.
    }
  }

  void _hideEndpointMarkers() {
    if (_endpointMarkers.isEmpty || !mounted) return;
    setState(() => _endpointMarkers = const []);
  }

  Future<void> _fitInitialVoyage() async {
    if (!_styleReady || _initialFitComplete || !mounted) return;
    _initialFitComplete = true;
    await _fit();
  }

  Future<void> _updateEndpointMarkers() async {
    final controller = _controller;
    final overlay = _directionOverlay;
    if (controller == null || overlay == null || !mounted) return;
    try {
      final locations = await controller.toScreenLocationBatch([
        ml.LatLng(overlay.start.latitude, overlay.start.longitude),
        ml.LatLng(overlay.finish.latitude, overlay.finish.longitude),
      ]);
      if (!mounted || locations.length != 2) return;
      final pixelScale = defaultTargetPlatform == TargetPlatform.android
          ? MediaQuery.devicePixelRatioOf(context)
          : 1.0;
      setState(
        () => _endpointMarkers = [
          _ArchivedEndpointScreenMarker(
            position: Offset(
              locations[0].x / pixelScale,
              locations[0].y / pixelScale,
            ),
            color: const Color(0xFF63D98B),
            label: 'Start',
          ),
          _ArchivedEndpointScreenMarker(
            position: Offset(
              locations[1].x / pixelScale,
              locations[1].y / pixelScale,
            ),
            color: const Color(0xFFFF6470),
            label: 'Finish',
          ),
        ],
      );
    } on Object {
      // Direction arrows and the endpoint legend remain available if the
      // platform cannot project an annotation into Flutter coordinates.
    }
  }

  Future<void> _fit() async {
    final controller = _controller;
    final points = _points;
    if (controller == null || points.isEmpty) return;
    if (points.length == 1) {
      final only = ml.LatLng(points.single.latitude, points.single.longitude);
      // An archived voyage is replayed from stored coordinates, so a bad one
      // outlives the voyage that produced it and crashes the screen every time it
      // is opened (#359).
      if (!mapLibreCameraIsUsable(only, zoom: 14)) return;
      await controller.animateCamera(ml.CameraUpdate.newLatLngZoom(only, 14));
      return;
    }
    final bounds = archivedVoyageBounds(points);
    if (!bounds.isUsableCamera) return;
    await controller.animateCamera(
      ml.CameraUpdate.newLatLngBounds(
        bounds,
        left: 28,
        top: 28,
        right: 28,
        bottom: 28,
      ),
      duration: const Duration(milliseconds: 450),
    );
    await _updateEndpointMarkers();
  }
}

class _ArchivedEndpointScreenMarker {
  const _ArchivedEndpointScreenMarker({
    required this.position,
    required this.color,
    required this.label,
  });

  final Offset position;
  final Color color;
  final String label;
}

class _ArchivedMapEndpointMarker extends StatelessWidget {
  const _ArchivedMapEndpointMarker({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Stack(
      alignment: Alignment.topCenter,
      children: [
        const Icon(
          Icons.location_on_rounded,
          size: 34,
          color: Color(0xFF10151C),
        ),
        Icon(Icons.location_on_rounded, size: 28, color: color),
      ],
    ),
  );
}

/// Which legend keys the archived-voyage map warrants.
///
/// A key is only honest when the line it describes is on the map. A voyage started
/// without a route used to show a Planned route key with no orange line under
/// it, which sends the sailor hunting for geometry that was never there (#211).
///
/// The `length >= 2` test deliberately mirrors `MapGeoJson.lines`, which is what
/// decides whether a line exists at all; the two have to move together.
@visibleForTesting
({bool planned, bool traveled}) archivedVoyageLegend(CompletedVoyage voyage) =>
    (
      planned: _hasDrawableLine(voyage.plannedRoute),
      traveled: _hasDrawableLine(voyage.traveledRoute),
    );

bool _hasDrawableLine(ImportedRoute? route) =>
    route?.paths.any((path) => path.points.length >= 2) ?? false;

class ArchivedVoyageDirectionOverlay {
  const ArchivedVoyageDirectionOverlay({
    required this.start,
    required this.finish,
    required this.lineColor,
    required this.arrows,
  });

  final GeoPoint start;
  final GeoPoint finish;
  final String lineColor;
  final List<TrailDirectionArrow> arrows;
}

/// Direction cues use the recording when it contains a line, because that is
/// where the bike actually went. A planned route is the honest fallback for a
/// voyage whose location recording is absent. One-fix fragments remain stored,
/// but cannot establish a direction and do not become a detached endpoint.
@visibleForTesting
ArchivedVoyageDirectionOverlay? archivedVoyageDirectionOverlay({
  required ImportedRoute? plannedRoute,
  required ImportedRoute? traveledRoute,
  TrailDirectionArrowSampler sampler = const TrailDirectionArrowSampler(
    spacingMeters: 900,
    minimumTrailMeters: 30,
    maximumArrows: 40,
  ),
}) {
  final traveledPaths = _drawablePaths(traveledRoute);
  final plannedPaths = _drawablePaths(plannedRoute);
  final paths = traveledPaths.isNotEmpty ? traveledPaths : plannedPaths;
  if (paths.isEmpty) return null;
  return ArchivedVoyageDirectionOverlay(
    start: paths.first.first,
    finish: paths.last.last,
    lineColor: traveledPaths.isNotEmpty ? '#42C9E8' : '#FF7A1A',
    arrows: sampler.sample(paths),
  );
}

List<List<GeoPoint>> _drawablePaths(ImportedRoute? route) =>
    route?.paths
        .where((path) => path.points.length >= 2)
        .map((path) => path.points)
        .toList(growable: false) ??
    const [];

@visibleForTesting
Map<String, dynamic> archivedVoyageDirectionGeoJson(
  ArchivedVoyageDirectionOverlay overlay,
) => MapGeoJson.points(
  overlay.arrows.indexed.map(
    (entry) => MapGeoJsonPoint(
      id: 'archived-direction-${entry.$1}',
      point: entry.$2.point,
      properties: {
        'bearing': entry.$2.bearingDegrees,
        'color': overlay.lineColor,
      },
    ),
  ),
);

@visibleForTesting
ml.LatLngBounds archivedVoyageBounds(List<GeoPoint> points) {
  if (points.isEmpty) {
    throw ArgumentError.value(points, 'points', 'Must not be empty');
  }
  var south = points.first.latitude;
  var north = points.first.latitude;
  var west = points.first.longitude;
  var east = points.first.longitude;
  for (final point in points.skip(1)) {
    south = math.min(south, point.latitude);
    north = math.max(north, point.latitude);
    west = math.min(west, point.longitude);
    east = math.max(east, point.longitude);
  }
  return ml.LatLngBounds(
    southwest: ml.LatLng(south, west),
    northeast: ml.LatLng(north, east),
  );
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 18,
        height: 4,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11)),
    ],
  );
}

class _EndpointLegend extends StatelessWidget {
  const _EndpointLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
        ),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12)),
    ],
  );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 130,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF8994A2),
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

String _date(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')}/${local.year}';
}

String _duration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  return hours == 0 ? '${minutes}m' : '${hours}h ${minutes}m';
}
