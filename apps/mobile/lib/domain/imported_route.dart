import 'dart:convert';

enum RoutePathKind { track, route }

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    this.elevationMeters,
    this.recordedAt,
  });

  final double latitude;
  final double longitude;
  final double? elevationMeters;
  final DateTime? recordedAt;

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    if (elevationMeters != null) 'elevationMeters': elevationMeters,
    if (recordedAt != null) 'recordedAt': recordedAt!.toUtc().toIso8601String(),
  };

  factory GeoPoint.fromJson(Map<String, Object?> json) {
    final latitude = _number(json, 'latitude');
    final longitude = _number(json, 'longitude');
    if (latitude < -90 || latitude > 90) {
      throw const FormatException('Route point latitude is outside -90..90.');
    }
    if (longitude < -180 || longitude > 180) {
      throw const FormatException(
        'Route point longitude is outside -180..180.',
      );
    }

    return GeoPoint(
      latitude: latitude,
      longitude: longitude,
      elevationMeters: (json['elevationMeters'] as num?)?.toDouble(),
      recordedAt: _optionalDateTime(json['recordedAt']),
    );
  }
}

class RoutePath {
  const RoutePath({required this.kind, required this.points, this.name});

  final RoutePathKind kind;
  final String? name;
  final List<GeoPoint> points;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (name != null) 'name': name,
    'points': points.map((point) => point.toJson()).toList(),
  };

  factory RoutePath.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'];
    final kind = RoutePathKind.values.where((item) => item.name == kindName);
    if (kind.isEmpty) {
      throw FormatException('Unsupported route path kind: $kindName');
    }
    final rawPoints = json['points'];
    if (rawPoints is! List) {
      throw const FormatException('Route path points must be a list.');
    }
    final points = rawPoints
        .map((point) {
          if (point is! Map) {
            throw const FormatException('Route point must be an object.');
          }
          return GeoPoint.fromJson(Map<String, Object?>.from(point));
        })
        .toList(growable: false);
    if (points.isEmpty) {
      throw const FormatException('Route paths cannot be empty.');
    }

    return RoutePath(
      kind: kind.single,
      name: _optionalString(json['name']),
      points: points,
    );
  }
}

class RouteWaypoint {
  const RouteWaypoint({
    required this.point,
    this.name,
    this.description,
    this.symbol,
  });

  final GeoPoint point;
  final String? name;
  final String? description;
  final String? symbol;

  Map<String, Object?> toJson() => {
    'point': point.toJson(),
    if (name != null) 'name': name,
    if (description != null) 'description': description,
    if (symbol != null) 'symbol': symbol,
  };

  factory RouteWaypoint.fromJson(Map<String, Object?> json) {
    final rawPoint = json['point'];
    if (rawPoint is! Map) {
      throw const FormatException('Waypoint point must be an object.');
    }
    return RouteWaypoint(
      point: GeoPoint.fromJson(Map<String, Object?>.from(rawPoint)),
      name: _optionalString(json['name']),
      description: _optionalString(json['description']),
      symbol: _optionalString(json['symbol']),
    );
  }
}

/// A non-stopping control used to shape a passage leg.
///
/// Named waypoints remain the start, destination and deliberate stops. Shaping
/// points are stored separately so the app can render and drag them without
/// turning them into stops or group rendezvous points (#242).
class RouteShapingPoint {
  const RouteShapingPoint({
    required this.id,
    required this.point,
    required this.legIndex,
  });

  final String id;
  final GeoPoint point;

  /// The named-waypoint leg this point shapes: zero is between waypoints 0 and
  /// 1. Several points on one leg retain their list order.
  final int legIndex;

  RouteShapingPoint movedTo(GeoPoint next) =>
      RouteShapingPoint(id: id, point: next, legIndex: legIndex);

  Map<String, Object?> toJson() => {
    'id': id,
    'point': point.toJson(),
    'legIndex': legIndex,
  };

  factory RouteShapingPoint.fromJson(Map<String, Object?> json) {
    final rawPoint = json['point'];
    final legIndex = json['legIndex'];
    if (rawPoint is! Map || legIndex is! int || legIndex < 0) {
      throw const FormatException('Route shaping point is invalid.');
    }
    return RouteShapingPoint(
      id: _requiredString(json, 'id'),
      point: GeoPoint.fromJson(Map<String, Object?>.from(rawPoint)),
      legIndex: legIndex,
    );
  }
}

/// One reviewed marking position: a suggestion a person rejected, or a junction
/// the detector missed and a person added.
///
/// The position is recorded as well as the identifier because a manoeuvre
/// identifier is only an index into the route-engine reply. A reroute, or a
/// second recalculation of the same GPX, renumbers them. Matching on position
/// as well means a rejection still refers to the same place on the ground.
class MarkerReviewPoint {
  const MarkerReviewPoint({
    required this.id,
    required this.position,
    this.label,
  });

  final String id;
  final GeoPoint position;
  final String? label;

  Map<String, Object?> toJson() => {
    'id': id,
    'position': position.toJson(),
    if (label != null) 'label': label,
  };

  factory MarkerReviewPoint.fromJson(Map<String, Object?> json) {
    final rawPosition = json['position'];
    if (rawPosition is! Map) {
      throw const FormatException('Marker review position must be an object.');
    }
    return MarkerReviewPoint(
      id: _requiredString(json, 'id'),
      position: GeoPoint.fromJson(Map<String, Object?>.from(rawPosition)),
      label: _optionalString(json['label']),
    );
  }
}

/// A person's decisions about the suggested marking positions for one route.
///
/// Marker assistance only ever suggests; the sailor confirms. Rejection is the
/// missing half of that (#179), and adding is the other half again: the
/// detector misses junctions as well as over-suggesting, so a review surface
/// that could only remove suggestions would be half a tool.
///
/// This voyages with the route rather than in a side store, so a rejection sticks
/// for that route through save, restart and hand-off, and so the web planner
/// can read and write the same JSON without a second source of truth.
class MarkerPlanReview {
  const MarkerPlanReview({this.rejected = const [], this.added = const []});

  final List<MarkerReviewPoint> rejected;
  final List<MarkerReviewPoint> added;

  static const empty = MarkerPlanReview();

  bool get isEmpty => rejected.isEmpty && added.isEmpty;
  bool get isNotEmpty => !isEmpty;

  bool rejectsId(String id) => rejected.any((point) => point.id == id);

  /// A compact identity for the decisions this review holds, so a caller that
  /// caches work derived from a route can tell that the review changed.
  String get signature =>
      '${rejected.map((point) => point.id).join(',')}'
      '/${added.map((point) => point.id).join(',')}';

  MarkerPlanReview rejecting(MarkerReviewPoint point) => MarkerPlanReview(
    rejected: [...rejected.where((existing) => existing.id != point.id), point],
    added: added
        .where((existing) => existing.id != point.id)
        .toList(growable: false),
  );

  /// Undoes a rejection, and removes a manually added position of the same
  /// identifier. One control on the review surface, one method here.
  MarkerPlanReview restoring(String id) => MarkerPlanReview(
    rejected: rejected.where((point) => point.id != id).toList(growable: false),
    added: added.where((point) => point.id != id).toList(growable: false),
  );

  MarkerPlanReview adding(MarkerReviewPoint point) => MarkerPlanReview(
    rejected: rejected
        .where((existing) => existing.id != point.id)
        .toList(growable: false),
    added: [...added.where((existing) => existing.id != point.id), point],
  );

  Map<String, Object?> toJson() => {
    if (rejected.isNotEmpty)
      'rejected': rejected.map((point) => point.toJson()).toList(),
    if (added.isNotEmpty)
      'added': added.map((point) => point.toJson()).toList(),
  };

  factory MarkerPlanReview.fromJson(Map<String, Object?> json) =>
      MarkerPlanReview(
        rejected: _reviewPoints(json['rejected']),
        added: _reviewPoints(json['added']),
      );

  static List<MarkerReviewPoint> _reviewPoints(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const FormatException('Marker review entries must be a list.');
    }
    return raw
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException(
              'Marker review entry must be an object.',
            );
          }
          return MarkerReviewPoint.fromJson(Map<String, Object?>.from(entry));
        })
        .toList(growable: false);
  }
}

class ImportedRoute {
  const ImportedRoute({
    required this.id,
    required this.name,
    required this.importedAt,
    required this.sourceFileName,
    required this.paths,
    required this.waypoints,
    this.shapingPoints = const [],
    this.markerReview = MarkerPlanReview.empty,
    this.description,
    this.plannedDuration,
  });

  static const schemaVersion = 1;

  final String id;
  final String name;
  final String? description;
  final DateTime importedAt;
  final String sourceFileName;
  final List<RoutePath> paths;
  final List<RouteWaypoint> waypoints;
  final List<RouteShapingPoint> shapingPoints;

  /// The routing engine's expected duration for the complete planned route.
  ///
  /// Null is honest for an imported or recorded track whose source supplied no
  /// timing. Keeping this on the persisted route lets ETA exist before the
  /// first moving GPS fix and after an app restart (#413).
  final Duration? plannedDuration;

  /// Which suggested marking positions a person has rejected or added.
  final MarkerPlanReview markerReview;

  ImportedRoute withMarkerReview(MarkerPlanReview review) => ImportedRoute(
    id: id,
    name: name,
    description: description,
    importedAt: importedAt,
    sourceFileName: sourceFileName,
    paths: paths,
    waypoints: waypoints,
    shapingPoints: shapingPoints,
    markerReview: review,
    plannedDuration: plannedDuration,
  );

  Iterable<GeoPoint> get allPoints sync* {
    for (final path in paths) {
      yield* path.points;
    }
    for (final waypoint in waypoints) {
      yield waypoint.point;
    }
  }

  int get pathPointCount =>
      paths.fold(0, (total, path) => total + path.points.length);

  ImportedRoute withShapingPoints(List<RouteShapingPoint> points) =>
      ImportedRoute(
        id: id,
        name: name,
        description: description,
        importedAt: importedAt,
        sourceFileName: sourceFileName,
        paths: paths,
        waypoints: waypoints,
        shapingPoints: List.unmodifiable(points),
        markerReview: markerReview,
        plannedDuration: plannedDuration,
      );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'name': name,
    if (description != null) 'description': description,
    'importedAt': importedAt.toUtc().toIso8601String(),
    'sourceFileName': sourceFileName,
    'paths': paths.map((path) => path.toJson()).toList(),
    'waypoints': waypoints.map((waypoint) => waypoint.toJson()).toList(),
    if (shapingPoints.isNotEmpty)
      'shapingPoints': shapingPoints.map((point) => point.toJson()).toList(),
    if (markerReview.isNotEmpty) 'markerReview': markerReview.toJson(),
    if (plannedDuration case final duration?)
      'plannedDurationSeconds': duration.inSeconds,
  };

  String toJsonString() => jsonEncode(toJson());

  factory ImportedRoute.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw FormatException(
        'Unsupported route schema version: ${json['schemaVersion']}',
      );
    }
    final rawPaths = json['paths'];
    final rawWaypoints = json['waypoints'];
    final rawShapingPoints = json['shapingPoints'] ?? const [];
    if (rawPaths is! List ||
        rawWaypoints is! List ||
        rawShapingPoints is! List) {
      throw const FormatException(
        'Route paths, waypoints and shaping points must be lists.',
      );
    }
    final paths = rawPaths
        .map((path) {
          if (path is! Map) {
            throw const FormatException('Route path must be an object.');
          }
          return RoutePath.fromJson(Map<String, Object?>.from(path));
        })
        .toList(growable: false);
    final waypoints = rawWaypoints
        .map((waypoint) {
          if (waypoint is! Map) {
            throw const FormatException('Route waypoint must be an object.');
          }
          return RouteWaypoint.fromJson(Map<String, Object?>.from(waypoint));
        })
        .toList(growable: false);
    final shapingPoints = rawShapingPoints
        .map((point) {
          if (point is! Map) {
            throw const FormatException(
              'Route shaping point must be an object.',
            );
          }
          return RouteShapingPoint.fromJson(Map<String, Object?>.from(point));
        })
        .toList(growable: false);
    if (paths.isEmpty && waypoints.isEmpty) {
      throw const FormatException('A route must contain geometry.');
    }
    final markerReview = switch (json['markerReview']) {
      null => MarkerPlanReview.empty,
      final Map<Object?, Object?> value => MarkerPlanReview.fromJson(
        Map<String, Object?>.from(value),
      ),
      _ => throw const FormatException(
        'Route marker review must be an object.',
      ),
    };

    final sourceFileName = _requiredString(json, 'sourceFileName');
    final description = _optionalString(json['description']);
    return ImportedRoute(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      description: description,
      importedAt: DateTime.parse(_requiredString(json, 'importedAt')).toUtc(),
      sourceFileName: sourceFileName,
      paths: paths,
      waypoints: waypoints,
      shapingPoints: shapingPoints,
      markerReview: markerReview,
      plannedDuration:
          _optionalDuration(json['plannedDurationSeconds']) ??
          _legacyPlannedDuration(
            sourceFileName: sourceFileName,
            description: description,
          ),
    );
  }

  factory ImportedRoute.fromJsonString(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Persisted route must be a JSON object.');
    }
    return ImportedRoute.fromJson(Map<String, Object?>.from(decoded));
  }
}

Duration? _optionalDuration(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value <= 0) {
    throw const FormatException(
      'plannedDurationSeconds must be a positive finite number.',
    );
  }
  return Duration(seconds: value.round());
}

/// Build 60 and earlier persisted app-planned routes without their structured
/// duration, but did retain the planner's duration in this fixed description.
/// Restrict the migration to Tide and Seek destination filenames and copy so an
/// arbitrary imported GPX description can never be mistaken for route timing.
Duration? _legacyPlannedDuration({
  required String sourceFileName,
  required String? description,
}) {
  if (!sourceFileName.startsWith('tide-and-seek-destination-') ||
      description == null ||
      !description.startsWith('Passage generated by Tide and Seek.')) {
    return null;
  }
  final match = RegExp(
    r', (?:(\d+) hr(?: (\d+) min)?|(\d+) min)\.',
  ).firstMatch(description);
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '') ?? 0;
  final minutes =
      int.tryParse(match.group(2) ?? '') ??
      int.tryParse(match.group(3) ?? '') ??
      0;
  if (hours == 0 && minutes == 0) return null;
  return Duration(hours: hours, minutes: minutes);
}

double _number(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number.');
  }
  return value.toDouble();
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = _optionalString(json[key]);
  if (value == null) {
    throw FormatException('$key must be a non-empty string.');
  }
  return value;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Expected a string value.');
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _optionalDateTime(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw const FormatException('Expected a date-time string.');
  }
  return DateTime.parse(value).toUtc();
}
