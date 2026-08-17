import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';

void main() {
  test('canonically signs the complete envelope and rejects tampering', () {
    final unsigned = _event(
      signature: '',
      expiresAt: DateTime.utc(2026, 7, 16, 12),
      payload: const {
        'z': 'last',
        'nested': {'z': true, 'a': false},
      },
    );
    final signed = _event(
      signature: VoyageEventAuthenticator.sign(unsigned, _secret),
      expiresAt: unsigned.expiresAt,
      payload: unsigned.payload,
    );

    expect(VoyageEventAuthenticator.verify(signed, _secret), isTrue);
    expect(
      VoyageEventAuthenticator.verify(
        _event(signature: signed.signature, payload: const {'message': 'No'}),
        _secret,
      ),
      isFalse,
    );
    expect(
      VoyageEventAuthenticator.verify(
        _event(
          signature: signed.signature,
          expiresAt: DateTime.utc(2026, 7, 16, 13),
          payload: signed.payload,
        ),
        _secret,
      ),
      isFalse,
    );
    expect(
      VoyageEventAuthenticator.verify(
        _event(
          signature: signed.signature,
          expiresAt: signed.expiresAt,
          payload: const {
            'nested': {'a': false, 'z': true},
            'z': 'last',
          },
        ),
        _secret,
      ),
      isTrue,
    );
  });

  test('keeps legacy event signatures readable', () {
    final unsigned = _event(signature: '');
    final legacyBody = jsonEncode({
      'id': unsigned.id,
      'voyageId': unsigned.voyageId,
      'deviceId': unsigned.deviceId,
      'type': unsigned.type.name,
      'priority': unsigned.priority.name,
      'createdAt': unsigned.createdAt.toUtc().toIso8601String(),
      'payload': unsigned.payload,
    });
    final legacySignature = Hmac(
      sha256,
      utf8.encode(_secret),
    ).convert(utf8.encode(legacyBody)).toString();

    expect(
      VoyageEventAuthenticator.verify(
        _event(signature: legacySignature),
        _secret,
      ),
      isTrue,
    );
  });
}

const _secret = '0123456789abcdef0123456789abcdef';

VoyageEvent _event({
  required String signature,
  Map<String, Object?> payload = const {'message': 'OK'},
  DateTime? expiresAt,
}) => VoyageEvent(
  id: 'event-1',
  voyageId: 'voyage-alpha',
  deviceId: 'device-1',
  type: VoyageEventType.statusMessage,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10),
  expiresAt: expiresAt,
  payload: payload,
  signature: signature,
);
