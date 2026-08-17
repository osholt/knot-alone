import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/relay/relay_protocol.dart';
import 'package:tide_and_seek/relay/relay_queue.dart';
import 'package:tide_and_seek/relay/relay_presence.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final now = DateTime.utc(2026, 7, 16, 12);
  const protocol = RelayProtocol();

  test('round trips a bounded authenticated event batch', () {
    final frame = _eventFrame(now);
    final bytes = protocol.encode(frame, secret: secret);
    final decoded = protocol.decode(
      bytes,
      secret: secret,
      expectedVoyageId: 'voyage-1',
      now: now.add(const Duration(seconds: 1)),
    );

    expect(bytes.length, lessThanOrEqualTo(RelayProtocol.maxFrameBytes));
    expect(decoded.kind, RelayFrameKind.events);
    expect(decoded.events.single.event.id, 'event-1');
    expect(decoded.events.single.hopCount, 2);
  });

  test('rejects a frame authenticated with another voyage secret', () {
    final bytes = protocol.encode(_eventFrame(now), secret: secret);

    expect(
      () => protocol.decode(
        bytes,
        secret: 'fedcba9876543210fedcba9876543210',
        expectedVoyageId: 'voyage-1',
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });

  test('rejects tampering and oversized input before accepting events', () {
    final bytes = protocol.encode(_eventFrame(now), secret: secret);
    bytes[bytes.length ~/ 2] ^= 1;
    expect(
      () => protocol.decode(
        bytes,
        secret: secret,
        expectedVoyageId: 'voyage-1',
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );

    expect(
      () => protocol.decode(
        Uint8List(RelayProtocol.maxFrameBytes + 1),
        secret: secret,
        expectedVoyageId: 'voyage-1',
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });

  test('rejects stale frames and drops expired queued events', () {
    final bytes = protocol.encode(_eventFrame(now), secret: secret);
    expect(
      () => protocol.decode(
        bytes,
        secret: secret,
        expectedVoyageId: 'voyage-1',
        now: now.add(const Duration(minutes: 6)),
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });

  test('round trips one authenticated replace-only presence snapshot', () {
    final location = SailorLocation(
      sailorId: 'device-a',
      displayName: 'Alex',
      role: VoyageRole.sailor,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.1, longitude: -2.4),
        recordedAt: now,
        accuracyMeters: 4,
      ),
      receivedAt: now,
    );
    final bytes = protocol.encode(
      RelayFrame(
        kind: RelayFrameKind.presence,
        voyageId: 'voyage-1',
        senderId: 'device-a',
        frameId: 'presence-1',
        sentAt: now,
        presence: RelayPresenceUpdate(
          sailorId: 'device-a',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: location,
        ),
      ),
      secret: secret,
    );

    final decoded = protocol.decode(
      bytes,
      secret: secret,
      expectedVoyageId: 'voyage-1',
      now: now.add(const Duration(seconds: 1)),
    );

    expect(decoded.kind, RelayFrameKind.presence);
    expect(decoded.presence?.sailorId, 'device-a');
    expect(decoded.presence?.position?.sample.position.latitude, 51.1);
    expect(decoded.events, isEmpty);
  });
}

RelayFrame _eventFrame(DateTime now) => RelayFrame(
  kind: RelayFrameKind.events,
  voyageId: 'voyage-1',
  senderId: 'device-a',
  frameId: 'frame-1',
  sentAt: now,
  events: [
    QueuedRelayEvent(
      event: VoyageEvent(
        id: 'event-1',
        voyageId: 'voyage-1',
        deviceId: 'device-a',
        type: VoyageEventType.statusMessage,
        priority: EventPriority.critical,
        createdAt: now,
        expiresAt: now.add(const Duration(hours: 1)),
        payload: const {'message': 'emergencyStop'},
        signature: 'a' * 64,
      ),
      firstSeenAt: now,
      expiresAt: now.add(const Duration(hours: 1)),
      hopCount: 2,
    ),
  ],
);
