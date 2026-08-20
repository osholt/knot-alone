import 'dart:convert';

enum VoyageEventType {
  voyageCreated,
  sailorJoined,
  sailorLeft,
  roleChanged,
  voyageStarted,
  markerStarted,
  markerPass,
  markerEnded,
  statusMessage,
  sailorLocationUpdated,
  hazardReported,
  hazardCleared,
  routeDeviationChanged,
  routeAlertAcknowledged,
  routeRevisionChunk,
  routeRevisionPublished,
  routeCleared,
  voyagePaused,
  voyageResumed,
  voyageEnded,
  iceInfoShared,
  iceInfoViewed,

  // Appended, never reordered: an older build recognises a type by name and
  // skips the ones it does not know (see `relay_event_compatibility.dart`).
  /// The voyage skipper asks a named sailor to take the Sweeper role
  /// (issue #128 part 1). A request, not an assignment: the role only changes
  /// when the target answers.
  sweeperRoleRequested,

  /// The named target accepts or declines a [sweeperRoleRequested].
  sweeperRoleResponded,

  /// One sailor's advisory rejoin route, addressed to the voyage skipper
  /// (issue #128 part 2). Also carries the cleared form that expires it.
  rejoinRouteShared,

  /// A sailor's **own** phone number, offered so the voyage's coordination roles
  /// can ring or text them — and, when a coordination role shares, so a stopped
  /// sailor can ring them (issue #188).
  ///
  /// Deliberately not [iceInfoShared]. That event carries a sailor's next of kin:
  /// the person to ring *about* them. Ringing it to reach the skipper would ring
  /// the skipper's partner.
  sailorContactShared,

  /// The skipper says a voyage that ended has not finished after all (#206, #207).
  ///
  /// Deliberately not [voyageResumed], which is the other half of [voyagePaused] and
  /// means "the group is moving again". This one un-ends a voyage, and conflating
  /// the two would make a pause look like a resurrection to every reducer.
  ///
  /// The journal is append-only, so this does not remove the [voyageEnded] event.
  /// The later of the two decides whether the voyage has ended, exactly as
  /// [voyagePaused] and [voyageResumed] already decide whether it is paused.
  voyageReopened,

  /// A sailor manually marks a man-overboard last-known position. This is a
  /// local recovery aid, not a distress transmission or live casualty tracker.
  mobActivated,

  /// Explicitly ends one [mobActivated] recovery incident.
  mobResolved,
}

enum EventPriority { routine, important, critical }

class VoyageEvent {
  const VoyageEvent({
    required this.id,
    required this.voyageId,
    required this.deviceId,
    required this.type,
    required this.priority,
    required this.createdAt,
    required this.payload,
    required this.signature,
    this.expiresAt,
    this.acknowledged = false,
    this.schemaVersion = 1,
  });

  final String id;
  final String voyageId;
  final String deviceId;
  final VoyageEventType type;
  final EventPriority priority;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final Map<String, Object?> payload;
  final String signature;
  final bool acknowledged;
  final int schemaVersion;

  VoyageEvent copyWith({bool? acknowledged}) => VoyageEvent(
    id: id,
    voyageId: voyageId,
    deviceId: deviceId,
    type: type,
    priority: priority,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
    signature: signature,
    acknowledged: acknowledged ?? this.acknowledged,
    schemaVersion: schemaVersion,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'voyageId': voyageId,
    'deviceId': deviceId,
    'type': type.name,
    'priority': priority.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'payload': payload,
    'signature': signature,
    'acknowledged': acknowledged,
  };

  factory VoyageEvent.fromJson(Map<String, Object?> json) {
    const allowedKeys = {
      'schemaVersion',
      'id',
      'voyageId',
      'deviceId',
      'type',
      'priority',
      'createdAt',
      'expiresAt',
      'payload',
      'signature',
      'acknowledged',
    };
    if (json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Event contains an unsupported field.');
    }
    final schemaVersion = _integer(json['schemaVersion'], 'schemaVersion');
    if (schemaVersion != 1) {
      throw const FormatException('Unsupported event schema version.');
    }
    final type = _enumValue(
      VoyageEventType.values,
      _string(json['type'], 'type', maximumLength: 48),
      'type',
    );
    final priority = _enumValue(
      EventPriority.values,
      _string(json['priority'], 'priority', maximumLength: 16),
      'priority',
    );
    final rawPayload = json['payload'];
    if (rawPayload is! Map<Object?, Object?>) {
      throw const FormatException('Event payload is invalid.');
    }
    if (rawPayload.keys.any((key) => key is! String)) {
      throw const FormatException('Event payload object is invalid.');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    _validateJson(payload, depth: 0);
    final encoded = utf8.encode(jsonEncode(json));
    if (encoded.length > _maximumSerializedBytes) {
      throw const FormatException('Event exceeds the size limit.');
    }
    final acknowledged = json['acknowledged'];
    if (acknowledged != null && acknowledged is! bool) {
      throw const FormatException('Event acknowledgement is invalid.');
    }
    return VoyageEvent(
      schemaVersion: schemaVersion,
      id: _string(json['id'], 'id', maximumLength: 128),
      voyageId: _string(json['voyageId'], 'voyageId', maximumLength: 128),
      deviceId: _string(json['deviceId'], 'deviceId', maximumLength: 128),
      type: type,
      priority: priority,
      createdAt: _date(json['createdAt'], 'createdAt'),
      expiresAt: switch (json['expiresAt']) {
        null => null,
        final Object value => _date(value, 'expiresAt'),
      },
      payload: payload,
      signature: _signature(json['signature']),
      acknowledged: acknowledged as bool? ?? false,
    );
  }

  static const _maximumSerializedBytes = 8 * 1024;
  static const _maximumJsonDepth = 16;
  static const _maximumCollectionEntries = 128;
  static final _signaturePattern = RegExp(r'^[0-9a-f]{64}$');

  static String _string(
    Object? value,
    String field, {
    required int maximumLength,
  }) {
    if (value is! String || value.isEmpty || value.length > maximumLength) {
      throw FormatException('Event $field is invalid.');
    }
    return value;
  }

  static int _integer(Object? value, String field) {
    if (value is! int) throw FormatException('Event $field is invalid.');
    return value;
  }

  static T _enumValue<T extends Enum>(
    List<T> values,
    String value,
    String field,
  ) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    throw FormatException('Event $field is unsupported.');
  }

  static DateTime _date(Object? value, String field) {
    final text = _string(value, field, maximumLength: 40);
    if (!text.contains('T') ||
        (!text.endsWith('Z') && !RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(text))) {
      throw FormatException('Event $field is invalid.');
    }
    try {
      return DateTime.parse(text).toLocal();
    } on FormatException {
      throw FormatException('Event $field is invalid.');
    }
  }

  static String _signature(Object? value) {
    final signature = _string(value, 'signature', maximumLength: 64);
    if (!_signaturePattern.hasMatch(signature)) {
      throw const FormatException('Event signature is invalid.');
    }
    return signature;
  }

  static void _validateJson(Object? value, {required int depth}) {
    if (depth > _maximumJsonDepth) {
      throw const FormatException('Event payload is too deeply nested.');
    }
    if (value == null || value is bool || value is String) return;
    if (value is num) {
      if (!value.isFinite) {
        throw const FormatException(
          'Event payload contains a non-finite number.',
        );
      }
      return;
    }
    if (value is List<Object?>) {
      if (value.length > _maximumCollectionEntries) {
        throw const FormatException('Event payload collection is too large.');
      }
      for (final item in value) {
        _validateJson(item, depth: depth + 1);
      }
      return;
    }
    if (value is Map<Object?, Object?>) {
      if (value.length > _maximumCollectionEntries ||
          value.keys.any((key) => key is! String || key.length > 128)) {
        throw const FormatException('Event payload object is invalid.');
      }
      for (final item in value.values) {
        _validateJson(item, depth: depth + 1);
      }
      return;
    }
    throw const FormatException('Event payload is invalid.');
  }
}
