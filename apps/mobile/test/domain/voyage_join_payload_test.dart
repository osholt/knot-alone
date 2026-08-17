import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_join_payload.dart';

/// A QR code is arbitrary input from a camera - anyone can print one - so every
/// bound here is checked rather than trusted (#279).
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const joinToken = 'resolve-token-0123456789';

  const payload = VoyageJoinPayload(
    voyageId: '019fb78c-4045-7213-b053-9197b4c2669f',
    voyageCode: '934893',
    inviteSecret: secret,
    joinToken: joinToken,
  );

  test('round-trips', () {
    final decoded = VoyageJoinPayload.decode(payload.encode());

    expect(decoded.voyageId, payload.voyageId);
    expect(decoded.voyageCode, payload.voyageCode);
    expect(decoded.inviteSecret, payload.inviteSecret);
    expect(decoded.joinToken, payload.joinToken);
  });

  test('tolerates surrounding whitespace from a scan', () {
    expect(
      VoyageJoinPayload.decode('  ${payload.encode()}\n').voyageCode,
      '934893',
    );
  });

  test('never puts the secret in toString', () {
    // toString reaches logs and error reports, and a voyage secret has no business
    // in either.
    expect(payload.toString(), isNot(contains(secret)));
    expect(payload.toString(), isNot(contains(joinToken)));
    expect(payload.toString(), contains('934893'));
  });

  group('refuses', () {
    void expectRejected(String raw, {String? because}) {
      expect(
        () => VoyageJoinPayload.decode(raw),
        throwsA(isA<FormatException>()),
        reason: because,
      );
    }

    test('anything that is not one of ours', () {
      expectRejected('https://example.com/join');
      expectRejected('just some text');
      expectRejected('');
    });

    test('a future format rather than half-understanding it', () {
      // A wrong join is worse than a refused one: a sailor who silently ends up in
      // a degraded session has no way to tell.
      expectRejected('sweeper2:934893:voyage:$secret:$joinToken');
    });

    test('a malformed voyage code', () {
      expectRejected('sweeper1:93489:voyage-1:$secret:$joinToken');
      expectRejected('sweeper1:abcdef:voyage-1:$secret:$joinToken');
      expectRejected('sweeper1:9348931:voyage-1:$secret:$joinToken');
    });

    test('a missing voyage', () {
      expectRejected('sweeper1:934893::$secret:$joinToken');
    });

    test('a secret too short to drive authenticated transport', () {
      // The relay, push registration and the event authenticator all check the
      // same 16-character floor. Accepting less would produce a session that looks
      // joined and silently cannot talk to anybody.
      expectRejected(
        'sweeper1:934893:voyage-1:tooshort:$joinToken',
        because:
            'a short secret cannot authenticate, so joining would be a lie',
      );
    });

    test('a join token too short', () {
      expectRejected('sweeper1:934893:voyage-1:$secret:short');
    });

    test('too few or too many fields', () {
      expectRejected('sweeper1:934893:voyage-1:$secret');
      expectRejected('sweeper1:934893:voyage-1:$secret:$joinToken:extra');
    });
  });
}
