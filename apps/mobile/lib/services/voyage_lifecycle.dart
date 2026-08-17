import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import 'voyage_event_authenticator.dart';

enum VoyagePhase { open, started, ended }

class VoyageLifecycle {
  const VoyageLifecycle({this.startEvent});

  final VoyageEvent? startEvent;

  bool get started => startEvent != null;
  DateTime? get startedAt => startEvent?.createdAt;
}

/// Reconstructs the authoritative voyage start from the signed event journal.
///
/// Events are ordered by timestamp and then ID so every device chooses the
/// same start after offline delivery, retries, or duplicate start taps. A
/// start is accepted only from a sailor whose latest signed role at that point
/// is lead, and the event must identify its author as that skipper.
class VoyageLifecycleReducer {
  const VoyageLifecycleReducer._();

  static VoyageLifecycle fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.voyageId == voyageId &&
                  VoyageEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(compareEvents);
    final roles = <String, VoyageRole>{};

    for (final event in ordered) {
      switch (event.type) {
        case VoyageEventType.voyageCreated:
        case VoyageEventType.sailorJoined:
        case VoyageEventType.roleChanged:
          final role = _roleFromPayload(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
          break;
        case VoyageEventType.voyageStarted:
          if (roles[event.deviceId] == VoyageRole.lead &&
              event.payload['skipperSailorId'] == event.deviceId) {
            return VoyageLifecycle(startEvent: event);
          }
        case VoyageEventType.markerStarted:
        case VoyageEventType.sailorLeft:
        case VoyageEventType.markerPass:
        case VoyageEventType.markerEnded:
        case VoyageEventType.statusMessage:
        case VoyageEventType.sailorLocationUpdated:
        case VoyageEventType.hazardReported:
        case VoyageEventType.hazardCleared:
        case VoyageEventType.routeDeviationChanged:
        case VoyageEventType.routeAlertAcknowledged:
        case VoyageEventType.routeRevisionChunk:
        case VoyageEventType.routeRevisionPublished:
        case VoyageEventType.routeCleared:
        case VoyageEventType.voyagePaused:
        case VoyageEventType.voyageResumed:
        case VoyageEventType.voyageEnded:
        case VoyageEventType.voyageReopened:
        case VoyageEventType.iceInfoShared:
        case VoyageEventType.iceInfoViewed:
        case VoyageEventType.sweeperRoleRequested:
        case VoyageEventType.sweeperRoleResponded:
        case VoyageEventType.rejoinRouteShared:
        case VoyageEventType.sailorContactShared:
          break;
      }
    }
    return const VoyageLifecycle();
  }

  static int compareEvents(VoyageEvent left, VoyageEvent right) {
    final byTime = left.createdAt.compareTo(right.createdAt);
    return byTime != 0 ? byTime : left.id.compareTo(right.id);
  }

  static VoyageRole? _roleFromPayload(Object? value) {
    if (value is! String) return null;
    try {
      return VoyageRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }
}
