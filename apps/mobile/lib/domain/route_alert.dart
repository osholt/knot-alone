enum RouteTrackingState {
  unavailable,
  onRoute,
  suspectedOffRoute,
  offRoute,
  recovering,
  gpsStale,
}

enum RouteAlertLevel { none, watch, urgent, critical }

enum RouteAlertAudience { rider, coordinators, allRiders }

class RouteDeviationAssessment {
  const RouteDeviationAssessment({
    required this.state,
    required this.alertLevel,
    required this.audience,
    required this.evaluatedAt,
    required this.message,
    this.distanceFromRouteMeters,
    this.offRouteSince,
  });

  final RouteTrackingState state;
  final RouteAlertLevel alertLevel;
  final RouteAlertAudience audience;
  final DateTime evaluatedAt;
  final String message;
  final double? distanceFromRouteMeters;
  final DateTime? offRouteSince;

  bool get coordinatorActionRequired =>
      audience != RouteAlertAudience.rider &&
      alertLevel.index >= RouteAlertLevel.urgent.index;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'alertLevel': alertLevel.name,
    'audience': audience.name,
    'evaluatedAt': evaluatedAt.toUtc().toIso8601String(),
    'message': message,
    'distanceFromRouteMeters': distanceFromRouteMeters,
    'offRouteSince': offRouteSince?.toUtc().toIso8601String(),
  };

  factory RouteDeviationAssessment.fromJson(Map<String, Object?> json) =>
      RouteDeviationAssessment(
        state: RouteTrackingState.values.byName(json['state']! as String),
        alertLevel: RouteAlertLevel.values.byName(
          json['alertLevel']! as String,
        ),
        audience: RouteAlertAudience.values.byName(json['audience']! as String),
        evaluatedAt: DateTime.parse(json['evaluatedAt']! as String).toLocal(),
        message: json['message']! as String,
        distanceFromRouteMeters: (json['distanceFromRouteMeters'] as num?)
            ?.toDouble(),
        offRouteSince: switch (json['offRouteSince']) {
          final String value => DateTime.parse(value).toLocal(),
          _ => null,
        },
      );
}

class RiderRouteAlert {
  const RiderRouteAlert({
    required this.riderId,
    required this.displayName,
    required this.assessment,
    this.acknowledged = false,
    this.acknowledgedBy,
    this.acknowledgedAt,
  });

  final String riderId;
  final String displayName;
  final RouteDeviationAssessment assessment;
  final bool acknowledged;
  final String? acknowledgedBy;
  final DateTime? acknowledgedAt;

  RiderRouteAlert copyWithAcknowledgement({
    required String acknowledgedBy,
    required DateTime acknowledgedAt,
  }) => RiderRouteAlert(
    riderId: riderId,
    displayName: displayName,
    assessment: assessment,
    acknowledged: true,
    acknowledgedBy: acknowledgedBy,
    acknowledgedAt: acknowledgedAt,
  );

  Map<String, Object?> toJson() => {
    'riderId': riderId,
    'displayName': displayName,
    'assessment': assessment.toJson(),
    'acknowledged': acknowledged,
    'acknowledgedBy': acknowledgedBy,
    'acknowledgedAt': acknowledgedAt?.toUtc().toIso8601String(),
  };

  factory RiderRouteAlert.fromJson(Map<String, Object?> json) =>
      RiderRouteAlert(
        riderId: json['riderId']! as String,
        displayName: json['displayName']! as String,
        assessment: RouteDeviationAssessment.fromJson(
          Map<String, Object?>.from(json['assessment']! as Map),
        ),
        acknowledged: json['acknowledged'] as bool? ?? false,
        acknowledgedBy: json['acknowledgedBy'] as String?,
        acknowledgedAt: switch (json['acknowledgedAt']) {
          final String value => DateTime.parse(value).toLocal(),
          _ => null,
        },
      );
}
