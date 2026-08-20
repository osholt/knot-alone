import 'marine_data.dart';

enum AisSourceKind { replay, localNmea, localSignalK }

enum AisConnectionState {
  stopped,
  connecting,
  connected,
  reconnecting,
  disconnected,
  replay,
}

class AisTarget {
  const AisTarget({
    required this.mmsi,
    required this.latitude,
    required this.longitude,
    required this.receivedAt,
    this.positionReportedAt,
    this.name,
    this.callSign,
    this.courseOverGroundDegrees,
    this.speedOverGroundKnots,
    this.headingDegrees,
    this.rateOfTurnDegreesPerMinute,
    this.navigationStatus,
    this.shipType,
  });

  final int mmsi;
  final String? name;
  final String? callSign;
  final double latitude;
  final double longitude;
  final double? courseOverGroundDegrees;
  final double? speedOverGroundKnots;
  final double? headingDegrees;
  final double? rateOfTurnDegreesPerMinute;
  final String? navigationStatus;
  final int? shipType;

  /// UTC assembled from the AIS report's second field and the receiver clock.
  /// Null when the message type did not carry a usable report time.
  final DateTime? positionReportedAt;
  final DateTime receivedAt;
}

class AisTargetSnapshot {
  AisTargetSnapshot({
    required this.sourceKind,
    required this.receivedAt,
    required this.source,
    required List<MarineDatum<AisTarget>> targets,
    this.connectionState = AisConnectionState.connected,
    this.warning,
  }) : targets = List.unmodifiable(targets);

  final AisSourceKind sourceKind;
  final DateTime receivedAt;
  final MarineDataSource source;
  final List<MarineDatum<AisTarget>> targets;
  final AisConnectionState connectionState;
  final String? warning;

  bool get connected =>
      connectionState == AisConnectionState.connected ||
      connectionState == AisConnectionState.replay;
}

abstract interface class AisTargetSource {
  AisSourceKind get kind;
  MarineDataSource get source;
  Stream<AisTargetSnapshot> get snapshots;
  Future<void> start();
  Future<void> stop();
}
