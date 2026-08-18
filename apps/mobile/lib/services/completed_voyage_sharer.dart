import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

import '../domain/completed_voyage.dart';
import '../domain/distance_unit.dart';
import 'gpx_exporter.dart';
import 'measurement_formatter.dart';

abstract interface class CompletedVoyageSharer {
  Future<void> shareSummary(
    CompletedVoyage voyage, {
    DistanceUnit distanceUnit,
    Rect? sharePositionOrigin,
  });

  Future<void> exportGpx(CompletedVoyage voyage, {Rect? sharePositionOrigin});
}

class SystemCompletedVoyageSharer implements CompletedVoyageSharer {
  const SystemCompletedVoyageSharer({this.gpxExporter = const GpxExporter()});

  final GpxExporter gpxExporter;

  @override
  Future<void> shareSummary(
    CompletedVoyage voyage, {
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
    Rect? sharePositionOrigin,
  }) async {
    final distance = MeasurementFormatter(
      distanceUnit,
    ).distance(voyage.totalDistanceMeters);
    final text = [
      'Tide and Seek voyage · ${voyage.title}',
      'Voyage code: ${voyage.voyageCode}',
      'Sailor: ${voyage.localDisplayName} (${voyage.localRole.name})',
      'Started: ${voyage.startedAt.toLocal().toIso8601String()}',
      'Ended: ${voyage.endedAt.toLocal().toIso8601String()}',
      'Duration: ${_duration(voyage.duration)}',
      'Distance: $distance',
      'Sailors: ${voyage.sailorCount}',
      'Marker sessions: ${voyage.markerSessions.length}',
    ].join('\n');
    await SharePlus.instance.share(
      ShareParams(
        subject: voyage.title,
        text: text,
        sharePositionOrigin: sharePositionOrigin,
      ),
    );
  }

  @override
  Future<void> exportGpx(
    CompletedVoyage voyage, {
    Rect? sharePositionOrigin,
  }) async {
    final route = voyage.traveledRoute;
    if (route == null) {
      throw StateError('This voyage has no recorded local trail to export.');
    }
    final fileName = gpxExporter.fileName(route);
    final bytes = Uint8List.fromList(utf8.encode(gpxExporter.export(route)));
    await SharePlus.instance.share(
      ShareParams(
        title: 'Export ${voyage.title}',
        subject: 'Tide and Seek GPX: ${voyage.title}',
        text:
            'Choose Files, Downloads or a GPX-compatible app in the share sheet.',
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

  static String _duration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    return hours == 0 ? '${minutes}m' : '${hours}h ${minutes}m';
  }
}
