import 'voyage_event.dart';

class MobFix {
  const MobFix({
    this.latitude,
    this.longitude,
    this.recordedAt,
    this.accuracyMeters,
    required this.source,
    required this.stale,
  });

  final double? latitude;
  final double? longitude;
  final DateTime? recordedAt;
  final double? accuracyMeters;
  final String source;
  final bool stale;

  bool get hasPosition =>
      latitude?.isFinite == true && longitude?.isFinite == true;
}

enum MobResolution { recovered, falseAlarm }

class MobIncident {
  const MobIncident({
    required this.activationEventId,
    required this.activatedAt,
    required this.activatedByDeviceId,
    required this.fix,
  });

  final String activationEventId;
  final DateTime activatedAt;
  final String activatedByDeviceId;
  final MobFix fix;
}

class MobState {
  const MobState({this.activeIncident});

  final MobIncident? activeIncident;
  bool get active => activeIncident != null;
}

abstract final class MobReducer {
  static MobState reduce(Iterable<VoyageEvent> events) {
    final ordered = events.toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    MobIncident? active;
    for (final event in ordered) {
      switch (event.type) {
        case VoyageEventType.mobActivated:
          active = MobIncident(
            activationEventId: event.id,
            activatedAt: event.createdAt,
            activatedByDeviceId: event.deviceId,
            fix: _fix(event.payload),
          );
        case VoyageEventType.mobResolved:
          if (event.payload['activationEventId'] == active?.activationEventId) {
            active = null;
          }
        default:
          break;
      }
    }
    return MobState(activeIncident: active);
  }

  static MobFix _fix(Map<String, Object?> payload) => MobFix(
    latitude: (payload['latitude'] as num?)?.toDouble(),
    longitude: (payload['longitude'] as num?)?.toDouble(),
    recordedAt: switch (payload['positionRecordedAt']) {
      final String value => DateTime.tryParse(value)?.toUtc(),
      _ => null,
    },
    accuracyMeters: (payload['accuracyMeters'] as num?)?.toDouble(),
    source: payload['positionSource'] as String? ?? 'none',
    stale: payload['fixStale'] as bool? ?? true,
  );
}
