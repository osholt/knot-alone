import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';

void main() {
  test('voyage events survive JSON round trips', () {
    final event = VoyageEvent(
      id: 'event-1',
      voyageId: 'voyage-1',
      deviceId: 'sailor-1',
      type: VoyageEventType.statusMessage,
      priority: EventPriority.critical,
      createdAt: DateTime.utc(2026, 7, 16, 12),
      expiresAt: DateTime.utc(2026, 7, 16, 14),
      payload: const {'message': 'assistance', 'attempt': 1},
      signature: 'a' * 64,
    );

    final decoded = VoyageEvent.fromJson(event.toJson());

    expect(decoded.id, event.id);
    expect(decoded.type, VoyageEventType.statusMessage);
    expect(decoded.priority, EventPriority.critical);
    expect(decoded.payload, event.payload);
    expect(decoded.expiresAt?.isAtSameMomentAs(event.expiresAt!), isTrue);
  });

  test('rejects unsupported or oversized relay event input', () {
    final event = VoyageEvent(
      id: 'event-1',
      voyageId: 'voyage-1',
      deviceId: 'sailor-1',
      type: VoyageEventType.statusMessage,
      priority: EventPriority.critical,
      createdAt: DateTime.utc(2026, 7, 16, 12),
      payload: const {'message': 'assistance'},
      signature: 'a' * 64,
    );
    final unsupportedSchema = event.toJson()..['schemaVersion'] = 2;
    final unknownField = event.toJson()..['unexpected'] = true;
    final oversizedPayload = event.toJson()
      ..['payload'] = {'message': 'x' * (9 * 1024)};

    expect(
      () => VoyageEvent.fromJson(unsupportedSchema),
      throwsFormatException,
    );
    expect(() => VoyageEvent.fromJson(unknownField), throwsFormatException);
    expect(() => VoyageEvent.fromJson(oversizedPayload), throwsFormatException);
  });
}
