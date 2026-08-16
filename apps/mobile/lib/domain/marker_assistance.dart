import 'geo_point.dart';

enum DecisionPointSource { routeGeometry, waypoint }

class RouteDecisionPoint {
  const RouteDecisionPoint({
    required this.id,
    required this.position,
    required this.source,
    this.label,
  });

  final String id;
  final GeoPoint position;
  final DecisionPointSource source;
  final String? label;
}

enum MarkerSuggestionState {
  unavailable,
  monitoring,
  stoppedNearDecision,
  suggested,
  cooldown,
  markerActive,
}

class MarkerSuggestion {
  const MarkerSuggestion({
    required this.decisionPoint,
    required this.suggestedAt,
    required this.distanceMeters,
    required this.progressingRiderCount,
  });

  final RouteDecisionPoint decisionPoint;
  final DateTime suggestedAt;
  final double distanceMeters;
  final int progressingRiderCount;
}

class MarkerSuggestionEvaluation {
  const MarkerSuggestionEvaluation({
    required this.state,
    required this.message,
    this.suggestion,
    this.cooldownUntil,
  });

  final MarkerSuggestionState state;
  final String message;
  final MarkerSuggestion? suggestion;
  final DateTime? cooldownUntil;
}

class MarkerPassEvidence {
  const MarkerPassEvidence({
    required this.riderId,
    required this.locationEventId,
    required this.observedAt,
    required this.roleName,
  });

  final String riderId;
  final String locationEventId;
  final DateTime observedAt;
  final String roleName;
}

class MarkerSessionSummary {
  const MarkerSessionSummary({
    required this.sessionId,
    required this.markerDeviceId,
    required this.startedAt,
    required this.mode,
    required this.uniquePassCount,
    required this.uniqueRiderIds,
    required this.verifiedPassCount,
    required this.verifiedRiderIds,
    this.endedAt,
    this.decisionPointId,
    this.tecPassedAt,
  });

  final String sessionId;
  final String markerDeviceId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String mode;
  final String? decisionPointId;
  final int uniquePassCount;
  final List<String> uniqueRiderIds;
  final int verifiedPassCount;
  final List<String> verifiedRiderIds;
  final DateTime? tecPassedAt;

  bool get completed => endedAt != null;

  Duration durationAt(DateTime now) {
    final end = endedAt ?? now;
    final duration = end.difference(startedAt);
    return duration.isNegative ? Duration.zero : duration;
  }

  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'markerDeviceId': markerDeviceId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt?.toUtc().toIso8601String(),
    'mode': mode,
    'decisionPointId': decisionPointId,
    'uniquePassCount': uniquePassCount,
    'uniqueRiderIds': uniqueRiderIds,
    'verifiedPassCount': verifiedPassCount,
    'verifiedRiderIds': verifiedRiderIds,
    'tecPassedAt': tecPassedAt?.toUtc().toIso8601String(),
  };

  factory MarkerSessionSummary.fromJson(Map<String, Object?> json) =>
      MarkerSessionSummary(
        sessionId: json['sessionId']! as String,
        markerDeviceId: json['markerDeviceId']! as String,
        startedAt: DateTime.parse(json['startedAt']! as String).toLocal(),
        endedAt: switch (json['endedAt']) {
          final String value => DateTime.parse(value).toLocal(),
          _ => null,
        },
        mode: json['mode']! as String,
        decisionPointId: json['decisionPointId'] as String?,
        uniquePassCount: (json['uniquePassCount']! as num).toInt(),
        uniqueRiderIds: (json['uniqueRiderIds']! as List).cast<String>(),
        verifiedPassCount: (json['verifiedPassCount']! as num).toInt(),
        verifiedRiderIds: (json['verifiedRiderIds']! as List).cast<String>(),
        tecPassedAt: switch (json['tecPassedAt']) {
          final String value => DateTime.parse(value).toLocal(),
          _ => null,
        },
      );
}

class RideMarkingSummary {
  const RideMarkingSummary({required this.sessions, required this.asOf});

  final List<MarkerSessionSummary> sessions;
  final DateTime asOf;

  int get completedSessionCount =>
      sessions.where((session) => session.completed).length;
  int get verifiedPassCount =>
      sessions.fold(0, (total, session) => total + session.verifiedPassCount);
  int get tecPassageCount =>
      sessions.where((session) => session.tecPassedAt != null).length;
  Duration get totalMarkingTime => sessions.fold(
    Duration.zero,
    (total, session) => total + session.durationAt(asOf),
  );

  MarkerSessionSummary? get activeSession {
    for (final session in sessions.reversed) {
      if (!session.completed) return session;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'asOf': asOf.toUtc().toIso8601String(),
    'sessions': sessions.map((session) => session.toJson()).toList(),
    'completedSessionCount': completedSessionCount,
    'verifiedPassCount': verifiedPassCount,
    'tecPassageCount': tecPassageCount,
    'totalMarkingSeconds': totalMarkingTime.inSeconds,
  };

  factory RideMarkingSummary.fromJson(Map<String, Object?> json) =>
      RideMarkingSummary(
        asOf: DateTime.parse(json['asOf']! as String).toLocal(),
        sessions: (json['sessions']! as List)
            .map(
              (session) => MarkerSessionSummary.fromJson(
                Map<String, Object?>.from(session as Map),
              ),
            )
            .toList(growable: false),
      );
}
