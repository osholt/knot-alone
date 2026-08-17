import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/voyage_join_payload.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';

/// The offline claim in #279, proven against a relay that genuinely cannot be
/// reached.
///
/// The unit test elsewhere uses a fake directory that throws, which shows the code
/// path does not *call* the relay. This one goes further and uses the **real**
/// `HttpVoyageCodeDirectory` pointed at a refusing endpoint, so what is being
/// asserted is the behaviour a sailor in a car park with no signal actually gets:
/// the ordinary join fails, and scanning still works.
///
/// Port 1 on loopback refuses immediately. That matters for a test - an
/// unroutable address like TEST-NET-3 would prove the same thing but would sit
/// there until a connect timeout, and a slow test is a test people stop running.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const joinToken = 'resolve-token-0123456789';

  late VoyageController controller;
  late http.Client client;
  late VoyageCodeDirectory unreachableRelay;

  setUp(() {
    client = http.Client();
    unreachableRelay = HttpVoyageCodeDirectory(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('http://127.0.0.1:1/api'),
      ),
      client: client,
    );
    var id = 0;
    controller = VoyageController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 1, 9),
      idFactory: () => 'offline-${id++}',
      random: Random(11),
      voyageCodeDirectory: unreachableRelay,
      completedVoyageStore: InMemoryCompletedVoyageStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    client.close();
  });

  test('the ordinary join cannot work with the relay unreachable', () async {
    // Establishes that the endpoint really is dead, so the next test is proving
    // something rather than passing by accident.
    await controller.joinVoyage('934893', 'Sailor');

    expect(controller.hasActiveVoyage, isFalse);
    expect(
      controller.errorMessage,
      isNotNull,
      reason: 'joining by code needs the relay, and it is not there',
    );
  });

  test('a scanned invitation joins anyway', () async {
    const invitation = VoyageJoinPayload(
      voyageId: 'voyage-from-a-car-park',
      voyageCode: '135627',
      inviteSecret: secret,
      joinToken: joinToken,
    );

    await controller.joinVoyageFromInvitation(invitation, 'Scanned sailor');

    expect(controller.errorMessage, isNull);
    expect(controller.hasActiveVoyage, isTrue);

    final session = controller.session!;
    expect(session.voyageId, 'voyage-from-a-car-park');
    expect(session.voyageCode, '135627');
    expect(session.role, VoyageRole.sailor);
    // The credentials that make authenticated transport possible have to survive
    // intact. Without them the sailor holds a session that looks joined and can
    // reach nobody once signal returns.
    expect(session.inviteSecret, secret);
    expect(session.joinToken, joinToken);

    // A real join, not just a stored session: the roster shows this sailor, which
    // means the sailorJoined event was recorded.
    expect(
      controller.participants.map((participant) => participant.displayName),
      contains('Scanned sailor'),
    );
  });

  test('it is fast, because nothing waits on a network', () async {
    const invitation = VoyageJoinPayload(
      voyageId: 'voyage-from-a-car-park',
      voyageCode: '135627',
      inviteSecret: secret,
      joinToken: joinToken,
    );

    final started = DateTime.now();
    await controller.joinVoyageFromInvitation(invitation, 'Scanned sailor');
    final elapsed = DateTime.now().difference(started);

    expect(controller.hasActiveVoyage, isTrue);
    // Generous, because a loaded CI machine is not a benchmark. The point is that
    // it cannot have waited on a connect attempt, which is what any accidental
    // reintroduction of a relay call would cost.
    expect(
      elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'an offline join must not be waiting on anything',
    );
  });
}

class _FakeNearbyBridge implements NearbyBridge {
  const _FakeNearbyBridge();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
