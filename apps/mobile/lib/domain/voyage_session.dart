import 'dart:convert';
import 'dart:math';

import '../features/map/vessel_icon.dart';
import 'voyage_coordination_mode.dart';
import 'voyage_role.dart';
import 'sailor_color.dart';

class VoyageSession {
  static const minimumSimulationSailorCount = 4;
  static const maximumSimulationSailorCount = 30;
  static const defaultSimulationSailorCount = 5;

  const VoyageSession({
    required this.voyageId,
    required this.voyageCode,
    required this.inviteSecret,
    required this.joinToken,
    required this.localSailorId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.isSimulation = false,
    this.simulationSailorCount = defaultSimulationSailorCount,
    this.vesselStyle = vesselIconStyleDefault,
    this.sailorSymbol = sailorSymbolDefault,
    this.sailorColor = sailorColorDefault,
    this.coordinationMode = VoyageCoordinationMode.crew,
    this.voyageName,
  }) : assert(
         !isSimulation ||
             (simulationSailorCount >= minimumSimulationSailorCount &&
                 simulationSailorCount <= maximumSimulationSailorCount),
       );

  final String voyageId;
  final String voyageCode;
  final String inviteSecret;

  /// A high-entropy credential paired with [voyageCode] on the internet relay.
  /// The six-digit code alone is brute-forceable over the public internet;
  /// resolving the invite secret from the relay requires this too. Only
  /// carried in the "Share" text and a smart-paste, never displayed on its
  /// own - the six digits remain what a sailor reads or types.
  final String joinToken;
  final String localSailorId;
  final String displayName;
  final VoyageRole role;
  final DateTime joinedAt;
  final bool isSimulation;
  final int simulationSailorCount;
  final VesselIconStyle vesselStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;
  final VoyageCoordinationMode coordinationMode;

  /// Optional, skipper-chosen at creation. Never required: voyages are always
  /// identifiable by their six-digit code even with no name set.
  final String? voyageName;

  VoyageSession copyWith({
    VoyageRole? role,
    String? voyageCode,
    int? simulationSailorCount,
    VoyageCoordinationMode? coordinationMode,
  }) => VoyageSession(
    voyageId: voyageId,
    voyageCode: voyageCode ?? this.voyageCode,
    inviteSecret: inviteSecret,
    joinToken: joinToken,
    localSailorId: localSailorId,
    displayName: displayName,
    role: role ?? this.role,
    joinedAt: joinedAt,
    isSimulation: isSimulation,
    simulationSailorCount: simulationSailorCount ?? this.simulationSailorCount,
    vesselStyle: vesselStyle,
    sailorSymbol: sailorSymbol,
    sailorColor: sailorColor,
    coordinationMode: coordinationMode ?? this.coordinationMode,
    voyageName: voyageName,
  );

  Map<String, Object?> toJson() => {
    'voyageId': voyageId,
    'voyageCode': voyageCode,
    'inviteSecret': inviteSecret,
    'joinToken': joinToken,
    'localSailorId': localSailorId,
    'displayName': displayName,
    'role': role.name,
    'joinedAt': joinedAt.toUtc().toIso8601String(),
    if (isSimulation) 'isSimulation': true,
    if (isSimulation) 'simulationSailorCount': simulationSailorCount,
    'vesselStyle': vesselStyle.name,
    'sailorSymbol': sailorSymbol.storageValue,
    'sailorColor': sailorColor.name,
    'coordinationMode': coordinationMode.name,
    if (voyageName != null) 'voyageName': voyageName,
  };

  factory VoyageSession.fromJson(Map<String, Object?> json) => VoyageSession(
    voyageId: json['voyageId']! as String,
    voyageCode: json['voyageCode']! as String,
    inviteSecret: json['inviteSecret']! as String,
    joinToken: _joinTokenOrFallback(json['joinToken']),
    localSailorId: json['localSailorId']! as String,
    displayName: json['displayName']! as String,
    role: VoyageRole.values.byName(json['role']! as String),
    joinedAt: DateTime.parse(json['joinedAt']! as String).toLocal(),
    isSimulation: json['isSimulation'] as bool? ?? false,
    simulationSailorCount: _simulationSailorCount(
      json['simulationSailorCount'],
    ),
    vesselStyle: vesselIconStyleFromName(json['vesselStyle'] as String?),
    sailorSymbol: SailorSymbol.fromStorageValue(
      json['sailorSymbol'] as String?,
    ),
    sailorColor: sailorColorFromName(json['sailorColor'] as String?),
    coordinationMode: VoyageCoordinationMode.fromName(
      json['coordinationMode'] as String?,
    ),
    voyageName: json['voyageName'] as String?,
  );

  static int _simulationSailorCount(Object? value) {
    if (value is! int) return defaultSimulationSailorCount;
    return value
        .clamp(minimumSimulationSailorCount, maximumSimulationSailorCount)
        .toInt();
  }

  /// A voyage session persisted before the join token existed has none stored.
  /// Generating a fresh one keeps old local sessions loadable; a lead in
  /// that state simply re-publishes its voyage code with the new token.
  static String _joinTokenOrFallback(Object? value) {
    if (value is String && value.length >= 16) return value;
    return base64Url
        .encode(List<int>.generate(20, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
  }
}
