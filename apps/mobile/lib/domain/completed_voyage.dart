import 'imported_route.dart';
import 'voyage_role.dart';

class CompletedMarkerSession {
  const CompletedMarkerSession({
    required this.startedAt,
    required this.endedAt,
    required this.uniquePassCount,
  });

  final DateTime startedAt;
  final DateTime? endedAt;
  final int uniquePassCount;

  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
    'uniquePassCount': uniquePassCount,
  };

  factory CompletedMarkerSession.fromJson(Map<String, Object?> json) =>
      CompletedMarkerSession(
        startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
        endedAt: switch (json['endedAt']) {
          final String value => DateTime.parse(value).toUtc(),
          _ => null,
        },
        uniquePassCount: (json['uniquePassCount'] as num?)?.toInt() ?? 0,
      );
}

/// A secret-free, immutable local record derived from a completed voyage.
///
/// Invitation credentials, sailor identifiers, event payloads and other
/// sailors' location trails are deliberately excluded.
class CompletedVoyage {
  const CompletedVoyage({
    required this.voyageId,
    required this.voyageCode,
    required this.voyageName,
    required this.localDisplayName,
    required this.localRole,
    required this.startedAt,
    required this.endedAt,
    required this.archivedAt,
    required this.sailorCount,
    required this.eventCount,
    required this.totalDistanceMeters,
    required this.markerSessions,
    required this.plannedRoute,
    required this.traveledRoute,
  });

  static const schemaVersion = 1;

  final String voyageId;
  final String voyageCode;
  final String? voyageName;
  final String localDisplayName;
  final VoyageRole localRole;
  final DateTime startedAt;
  final DateTime endedAt;
  final DateTime archivedAt;
  final int sailorCount;
  final int eventCount;
  final double totalDistanceMeters;
  final List<CompletedMarkerSession> markerSessions;
  final ImportedRoute? plannedRoute;
  final ImportedRoute? traveledRoute;

  String get title => voyageName?.trim().isNotEmpty == true
      ? voyageName!.trim()
      : 'Voyage $voyageCode';

  Duration get duration => endedAt.difference(startedAt).abs();

  /// More than one recorded track means the location stream stopped long
  /// enough that joining the fixes would invent a straight line (#205).
  bool get hasRecordingGaps =>
      (traveledRoute?.paths
              .where((path) => path.kind == RoutePathKind.track)
              .length ??
          0) >
      1;

  Iterable<GeoPoint> get mapPoints sync* {
    if (plannedRoute case final route?) yield* route.allPoints;
    if (traveledRoute case final route?) yield* route.allPoints;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'voyageId': voyageId,
    'voyageCode': voyageCode,
    if (voyageName != null) 'voyageName': voyageName,
    'localDisplayName': localDisplayName,
    'localRole': localRole.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'archivedAt': archivedAt.toUtc().toIso8601String(),
    'sailorCount': sailorCount,
    'eventCount': eventCount,
    'totalDistanceMeters': totalDistanceMeters,
    'markerSessions': markerSessions.map((value) => value.toJson()).toList(),
    if (plannedRoute != null) 'plannedRoute': plannedRoute!.toJson(),
    if (traveledRoute != null) 'traveledRoute': traveledRoute!.toJson(),
  };

  factory CompletedVoyage.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported completed voyage schema: ${json['schemaVersion']}',
      );
    }
    return CompletedVoyage(
      voyageId: json['voyageId']! as String,
      voyageCode: json['voyageCode']! as String,
      voyageName: json['voyageName'] as String?,
      localDisplayName: json['localDisplayName']! as String,
      localRole: VoyageRole.values.byName(json['localRole']! as String),
      startedAt: DateTime.parse(json['startedAt']! as String).toUtc(),
      endedAt: DateTime.parse(json['endedAt']! as String).toUtc(),
      archivedAt: DateTime.parse(json['archivedAt']! as String).toUtc(),
      sailorCount: (json['sailorCount'] as num?)?.toInt() ?? 1,
      eventCount: (json['eventCount'] as num?)?.toInt() ?? 0,
      totalDistanceMeters:
          (json['totalDistanceMeters'] as num?)?.toDouble() ?? 0,
      markerSessions: switch (json['markerSessions']) {
        final List values =>
          values
              .whereType<Map>()
              .map(
                (value) => CompletedMarkerSession.fromJson(
                  Map<String, Object?>.from(value),
                ),
              )
              .toList(growable: false),
        _ => const [],
      },
      plannedRoute: _optionalRoute(json['plannedRoute']),
      traveledRoute: _optionalRoute(json['traveledRoute']),
    );
  }

  static ImportedRoute? _optionalRoute(Object? value) {
    if (value is! Map) return null;
    try {
      return ImportedRoute.fromJson(Map<String, Object?>.from(value));
    } on FormatException {
      // Preserve useful summary metadata when optional geometry is damaged.
      return null;
    }
  }
}
