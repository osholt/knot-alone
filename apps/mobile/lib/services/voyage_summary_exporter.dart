import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/distance_unit.dart';
import '../domain/geo_point.dart' as geo;
import '../domain/imported_route.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_session.dart';
import 'geo_calculations.dart';
import 'gpx_exporter.dart';
import 'measurement_formatter.dart';
import 'voyage_lifecycle.dart';

typedef _TrailPoint = ({
  double latitude,
  double longitude,
  DateTime recordedAt,
});

class MarkerSessionSummary {
  const MarkerSessionSummary({
    required this.markerDeviceId,
    required this.startedAt,
    required this.endedAt,
    required this.uniquePassCount,
    required this.duration,
  });

  final String markerDeviceId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int uniquePassCount;
  final Duration duration;

  bool get isComplete => endedAt != null;
}

class VoyageSummary {
  const VoyageSummary({
    required this.voyageId,
    required this.voyageCode,
    required this.displayName,
    required this.startedAt,
    required this.endedAt,
    required this.generatedAt,
    required this.eventCount,
    required this.markerSessions,
    required this.sailorCount,
    required this.totalDistanceMeters,
  });

  final String voyageId;
  final String voyageCode;
  final String displayName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime generatedAt;
  final int eventCount;
  final List<MarkerSessionSummary> markerSessions;
  final int sailorCount;
  final double totalDistanceMeters;

  Duration get voyageDuration =>
      (endedAt ?? generatedAt).difference(startedAt).abs();

  Duration get totalMarkingDuration => markerSessions.fold(
    Duration.zero,
    (total, session) => total + session.duration,
  );

  int get totalConfirmedPasses => markerSessions.fold(
    0,
    (total, session) => total + session.uniquePassCount,
  );
}

class VoyageSummaryExporter {
  const VoyageSummaryExporter();

  /// Position reports normally arrive seconds apart. Past this interval the
  /// intervening path is unknown and must not be counted or drawn (#205).
  static const maximumContinuousTrailGap = Duration(minutes: 2);

  VoyageSummary summarize(
    VoyageSession session,
    Iterable<VoyageEvent> events, {
    required DateTime generatedAt,
  }) {
    final ordered = _sorted(events);
    final lifecycle = VoyageLifecycleReducer.fromEvents(
      voyageId: session.voyageId,
      inviteSecret: session.inviteSecret,
      events: ordered,
    );
    final startedAt =
        lifecycle.startedAt ??
        (ordered.isEmpty
            ? session.joinedAt
            : _earlier(session.joinedAt, ordered.first.createdAt));
    final activityEvents = lifecycle.startedAt == null
        ? ordered
        : ordered
              .where((event) => !event.createdAt.isBefore(startedAt))
              .toList(growable: false);
    final endedAt = ordered
        .where((event) => event.type == VoyageEventType.voyageEnded)
        .map((event) => event.createdAt)
        .lastOrNull;

    final completed = <MarkerSessionSummary>[];
    final active = <String, _MarkerAccumulator>{};
    for (final event in activityEvents) {
      switch (event.type) {
        case VoyageEventType.markerStarted:
          active.putIfAbsent(
            event.deviceId,
            () => _MarkerAccumulator(
              markerDeviceId: event.deviceId,
              startedAt: event.createdAt,
            ),
          );
        case VoyageEventType.markerPass:
          final sailorId = event.payload['sailorId'];
          if (sailorId is String && sailorId.isNotEmpty) {
            active[event.deviceId]?.sailorIds.add(sailorId);
          }
        case VoyageEventType.markerEnded:
          final accumulator = active.remove(event.deviceId);
          if (accumulator != null) {
            final rawRecordedPasses = event.payload['uniquePasses'];
            final recordedPasses = rawRecordedPasses is num
                ? rawRecordedPasses.toInt()
                : 0;
            completed.add(
              accumulator.finish(
                endedAt: event.createdAt,
                minimumPasses: math.max(recordedPasses, 0),
              ),
            );
          }
        default:
          break;
      }
    }
    for (final accumulator in active.values) {
      completed.add(accumulator.finish(endedAt: null, now: generatedAt));
    }
    completed.sort((left, right) => left.startedAt.compareTo(right.startedAt));

    final sailorIds = {
      session.localSailorId,
      ...ordered.map((e) => e.deviceId),
    };
    final trail = _ownTrail(
      session.localSailorId,
      ordered,
      notBefore: lifecycle.startedAt,
    );

    return VoyageSummary(
      voyageId: session.voyageId,
      voyageCode: session.voyageCode,
      displayName: session.displayName,
      startedAt: startedAt,
      endedAt: endedAt,
      generatedAt: generatedAt,
      eventCount: ordered.length,
      markerSessions: List.unmodifiable(completed),
      sailorCount: sailorIds.length,
      totalDistanceMeters: _trailDistanceMeters(trail),
    );
  }

  /// The sailor's own recorded path as a GPX-exportable track, or null if too
  /// few position fixes were recorded to plot a meaningful trail.
  ImportedRoute? traveledRoute(
    VoyageSession session,
    Iterable<VoyageEvent> events, {
    required DateTime generatedAt,
  }) {
    final ordered = _sorted(events);
    final lifecycle = VoyageLifecycleReducer.fromEvents(
      voyageId: session.voyageId,
      inviteSecret: session.inviteSecret,
      events: ordered,
    );
    final trail = _ownTrail(
      session.localSailorId,
      ordered,
      notBefore: lifecycle.startedAt,
    );
    if (trail.length < 2) return null;
    final segments = _continuousTrailSegments(trail);
    final trackName = session.voyageName ?? 'Voyage ${session.voyageCode}';
    return ImportedRoute(
      id: session.voyageId,
      name: trackName,
      importedAt: generatedAt,
      sourceFileName: '${session.voyageCode}.gpx',
      paths: [
        for (final (index, segment) in segments.indexed)
          RoutePath(
            kind: RoutePathKind.track,
            name: segments.length == 1
                ? trackName
                : '$trackName · segment ${index + 1}',
            points: [
              for (final point in segment)
                GeoPoint(
                  latitude: point.latitude,
                  longitude: point.longitude,
                  recordedAt: point.recordedAt,
                ),
            ],
          ),
      ],
      waypoints: const [],
    );
  }

  String toPlainText(
    VoyageSummary summary, {
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
  }) {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(summary.totalDistanceMeters);
    final buffer = StringBuffer()
      ..writeln('Tide and Seek summary · ${summary.voyageCode}')
      ..writeln('Sailor: ${summary.displayName}')
      ..writeln('Sailors on this voyage: ${summary.sailorCount}')
      ..writeln('Started: ${summary.startedAt.toLocal().toIso8601String()}')
      ..writeln(
        'Ended: ${summary.endedAt?.toLocal().toIso8601String() ?? 'voyage still active'}',
      )
      ..writeln('Voyage time: ${_duration(summary.voyageDuration)}')
      ..writeln('Distance covered: $distance')
      ..writeln('Events recorded: ${summary.eventCount}')
      ..writeln('Marker sessions: ${summary.markerSessions.length}')
      ..writeln(
        'Time spent marking: ${_duration(summary.totalMarkingDuration)}',
      )
      ..writeln('Confirmed marker passes: ${summary.totalConfirmedPasses}');
    for (var index = 0; index < summary.markerSessions.length; index += 1) {
      final marker = summary.markerSessions[index];
      buffer.writeln(
        'Marker ${index + 1}: ${_duration(marker.duration)}, '
        '${marker.uniquePassCount} passes${marker.isComplete ? '' : ' (active)'}.',
      );
    }
    return buffer.toString().trimRight();
  }

  String toCsv(VoyageSummary summary) {
    final rows = <List<Object?>>[
      ['voyage_code', summary.voyageCode],
      ['voyage_id', summary.voyageId],
      ['sailor', summary.displayName],
      ['started_at_utc', summary.startedAt.toUtc().toIso8601String()],
      ['ended_at_utc', summary.endedAt?.toUtc().toIso8601String()],
      ['generated_at_utc', summary.generatedAt.toUtc().toIso8601String()],
      ['voyage_duration_seconds', summary.voyageDuration.inSeconds],
      ['event_count', summary.eventCount],
      ['sailor_count', summary.sailorCount],
      ['distance_meters', summary.totalDistanceMeters.round()],
      [],
      [
        'marker_device_id',
        'started_at_utc',
        'ended_at_utc',
        'duration_seconds',
        'unique_passes',
        'complete',
      ],
      for (final marker in summary.markerSessions)
        [
          marker.markerDeviceId,
          marker.startedAt.toUtc().toIso8601String(),
          marker.endedAt?.toUtc().toIso8601String(),
          marker.duration.inSeconds,
          marker.uniquePassCount,
          marker.isComplete,
        ],
    ];
    return '${rows.map(_csvRow).join('\r\n')}\r\n';
  }

  String fileName(VoyageSummary summary) =>
      'tide-and-seek-${summary.voyageCode.toLowerCase()}-summary.csv';

  String trailFileName(VoyageSummary summary) =>
      'tide-and-seek-${summary.voyageCode.toLowerCase()}-trail.gpx';

  static List<VoyageEvent> _sorted(Iterable<VoyageEvent> events) =>
      events.toList(growable: false)..sort((left, right) {
        final time = left.createdAt.compareTo(right.createdAt);
        return time != 0 ? time : left.id.compareTo(right.id);
      });

  /// Reconstructs the local sailor's own position fixes from
  /// [VoyageEventType.sailorLocationUpdated] events, walking the raw payload
  /// defensively (rather than via `SailorLocation.fromJson`) since relayed
  /// events from other devices are untrusted and a malformed one shouldn't
  /// break the whole export.
  static List<_TrailPoint> _ownTrail(
    String localSailorId,
    List<VoyageEvent> ordered, {
    DateTime? notBefore,
  }) {
    final trail = <_TrailPoint>[];
    for (final event in ordered) {
      if (notBefore != null && event.createdAt.isBefore(notBefore)) continue;
      final point = _ownTrailPoint(event, localSailorId);
      if (point != null &&
          (notBefore == null || !point.recordedAt.isBefore(notBefore))) {
        trail.add(point);
      }
    }
    return trail;
  }

  static _TrailPoint? _ownTrailPoint(VoyageEvent event, String localSailorId) {
    if (event.type != VoyageEventType.sailorLocationUpdated) return null;
    if (event.deviceId != localSailorId) return null;
    final location = event.payload['location'];
    if (location is! Map) return null;
    final sample = location['sample'];
    if (sample is! Map) return null;
    final position = sample['position'];
    if (position is! Map) return null;
    final latitude = position['latitude'];
    final longitude = position['longitude'];
    if (latitude is! num || longitude is! num) return null;
    final recordedAt = sample['recordedAt'];
    return (
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      recordedAt: recordedAt is String
          ? (DateTime.tryParse(recordedAt)?.toLocal() ?? event.createdAt)
          : event.createdAt,
    );
  }

  static double _trailDistanceMeters(List<_TrailPoint> trail) {
    var total = 0.0;
    for (final segment in _continuousTrailSegments(trail)) {
      for (var index = 1; index < segment.length; index += 1) {
        total += GeoCalculations.distanceMeters(
          geo.GeoPoint(
            latitude: segment[index - 1].latitude,
            longitude: segment[index - 1].longitude,
          ),
          geo.GeoPoint(
            latitude: segment[index].latitude,
            longitude: segment[index].longitude,
          ),
        );
      }
    }
    return total;
  }

  static List<List<_TrailPoint>> _continuousTrailSegments(
    List<_TrailPoint> trail,
  ) {
    if (trail.isEmpty) return const [];
    final segments = <List<_TrailPoint>>[
      <_TrailPoint>[trail.first],
    ];
    for (final point in trail.skip(1)) {
      final gap = point.recordedAt.difference(segments.last.last.recordedAt);
      if (gap > maximumContinuousTrailGap) {
        segments.add(<_TrailPoint>[]);
      }
      segments.last.add(point);
    }
    return segments;
  }

  static String _csvRow(List<Object?> values) =>
      values.map((value) => _csvCell(value?.toString() ?? '')).join(',');

  static String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';

  static String _duration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  static DateTime _earlier(DateTime left, DateTime right) =>
      left.isBefore(right) ? left : right;
}

class _MarkerAccumulator {
  _MarkerAccumulator({required this.markerDeviceId, required this.startedAt});

  final String markerDeviceId;
  final DateTime startedAt;
  final Set<String> sailorIds = {};

  MarkerSessionSummary finish({
    required DateTime? endedAt,
    DateTime? now,
    int minimumPasses = 0,
  }) {
    final effectiveEnd = endedAt ?? now ?? startedAt;
    return MarkerSessionSummary(
      markerDeviceId: markerDeviceId,
      startedAt: startedAt,
      endedAt: endedAt,
      uniquePassCount: math.max(sailorIds.length, minimumPasses),
      duration: effectiveEnd.difference(startedAt).abs(),
    );
  }
}

abstract interface class VoyageSummarySharer {
  Future<void> share(
    VoyageSession session,
    Iterable<VoyageEvent> events, {
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
    Rect? sharePositionOrigin,
    String? diagnostics,
  });
}

class SystemVoyageSummarySharer implements VoyageSummarySharer {
  const SystemVoyageSummarySharer({
    this.exporter = const VoyageSummaryExporter(),
  });

  final VoyageSummaryExporter exporter;

  @override
  Future<void> share(
    VoyageSession session,
    Iterable<VoyageEvent> events, {
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
    Rect? sharePositionOrigin,
    // Present only when an instrumented build was recording (#419). One more
    // attachment on the share a sailor already does, rather than a second flow
    // and a second decision at the end of a voyage.
    String? diagnostics,
  }) async {
    final generatedAt = DateTime.now();
    final summary = exporter.summarize(
      session,
      events,
      generatedAt: generatedAt,
    );
    final route = exporter.traveledRoute(
      session,
      events,
      generatedAt: generatedAt,
    );
    final csvFileName = exporter.fileName(summary);
    final gpxFileName = exporter.trailFileName(summary);
    final diagnosticsFileName =
        'tail-end-charlie-diagnostics-'
        '${summary.voyageCode}.txt';
    await SharePlus.instance.share(
      ShareParams(
        title: 'Voyage summary ${summary.voyageCode}',
        subject: 'Tide and Seek summary ${summary.voyageCode}',
        text: exporter.toPlainText(summary, distanceUnit: distanceUnit),
        files: [
          XFile.fromData(
            Uint8List.fromList(utf8.encode(exporter.toCsv(summary))),
            mimeType: 'text/csv',
            name: csvFileName,
          ),
          if (route != null)
            XFile.fromData(
              Uint8List.fromList(
                utf8.encode(const GpxExporter().export(route)),
              ),
              mimeType: 'application/gpx+xml',
              name: gpxFileName,
            ),
          if (diagnostics != null)
            XFile.fromData(
              Uint8List.fromList(utf8.encode(diagnostics)),
              mimeType: 'text/plain',
              name: diagnosticsFileName,
            ),
        ],
        fileNameOverrides: [
          csvFileName,
          if (route != null) gpxFileName,
          if (diagnostics != null) diagnosticsFileName,
        ],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }
}
