import '../domain/voyage_event.dart';
import '../domain/voyage_session.dart';
import 'voyage_event_authenticator.dart';

typedef SituationClock = DateTime Function();
typedef SituationIdFactory = String Function();

class SituationEventFactory {
  const SituationEventFactory({
    required this.session,
    required this.clock,
    required this.idFactory,
  });

  final VoyageSession session;
  final SituationClock clock;
  final SituationIdFactory idFactory;

  VoyageEvent create({
    required VoyageEventType type,
    required Map<String, Object?> payload,
    EventPriority priority = EventPriority.routine,
    DateTime? expiresAt,
  }) {
    final event = VoyageEvent(
      id: idFactory(),
      voyageId: session.voyageId,
      deviceId: session.localSailorId,
      type: type,
      priority: priority,
      createdAt: clock(),
      expiresAt: expiresAt,
      payload: payload,
      signature: '',
      schemaVersion: 1,
    );
    return VoyageEvent(
      id: event.id,
      voyageId: event.voyageId,
      deviceId: event.deviceId,
      type: event.type,
      priority: event.priority,
      createdAt: event.createdAt,
      expiresAt: event.expiresAt,
      payload: event.payload,
      signature: sign(event, session.inviteSecret),
      schemaVersion: event.schemaVersion,
    );
  }

  static String sign(VoyageEvent event, String secret) =>
      VoyageEventAuthenticator.sign(event, secret);

  static bool verify(VoyageEvent event, String secret) =>
      VoyageEventAuthenticator.verify(event, secret);
}
