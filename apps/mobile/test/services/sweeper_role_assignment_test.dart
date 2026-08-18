import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/services/skipper_voyage_status.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/sweeper_role_assignment.dart';

/// Issue #128 part 1. A skipper can ask a named sailor to be the Sweeper;
/// only the skipper can ask, only the named sailor can answer, and the skipper can
/// tell "asked" from "covered".
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final start = DateTime.utc(2026, 7, 26, 9);
  const reducer = SweeperRoleAssignmentReducer();

  SweeperRoleAssignmentState reduce(
    List<VoyageEvent> events, {
    DateTime? now,
    SweeperRoleAssignmentReducer? using,
  }) => (using ?? reducer).fromEvents(
    voyageId: 'voyage-a',
    inviteSecret: secret,
    events: events,
    now: now ?? start.add(const Duration(minutes: 1)),
  );

  List<VoyageEvent> roster() => [
    _event(
      id: 'a-created',
      deviceId: 'skipper',
      type: VoyageEventType.voyageCreated,
      createdAt: start,
      payload: const {'displayName': 'Lead', 'role': 'lead'},
    ),
    _event(
      id: 'b-join-bill',
      deviceId: 'bill',
      type: VoyageEventType.sailorJoined,
      createdAt: start.add(const Duration(seconds: 10)),
      payload: const {'displayName': 'Bill', 'role': 'sailor'},
    ),
    _event(
      id: 'c-join-dave',
      deviceId: 'dave',
      type: VoyageEventType.sailorJoined,
      createdAt: start.add(const Duration(seconds: 20)),
      payload: const {'displayName': 'Dave', 'role': 'sailor'},
    ),
  ];

  VoyageEvent request({
    required String id,
    required String requestId,
    required String target,
    String skipper = 'skipper',
    String? claimedSkipper,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: skipper,
    type: VoyageEventType.sweeperRoleRequested,
    createdAt: start.add(after),
    payload: SweeperRoleAssignmentReducer.requestPayload(
      requestId: requestId,
      skipperSailorId: claimedSkipper ?? skipper,
      targetSailorId: target,
      targetDisplayName: target == 'bill' ? 'Bill' : 'Dave',
    ),
  );

  VoyageEvent response({
    required String id,
    required String requestId,
    required String responder,
    required bool accepted,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: responder,
    type: VoyageEventType.sweeperRoleResponded,
    createdAt: start.add(after),
    payload: SweeperRoleAssignmentReducer.responsePayload(
      requestId: requestId,
      targetSailorId: responder,
      accepted: accepted,
    ),
  );

  VoyageEvent roleChanged({
    required String id,
    required String deviceId,
    required VoyageRole role,
    required Duration after,
  }) => _event(
    id: id,
    deviceId: deviceId,
    type: VoyageEventType.roleChanged,
    createdAt: start.add(after),
    payload: {'role': role.name},
  );

  group('a skipper-initiated request', () {
    test('is pending until the target answers, then accepted', () {
      final asked = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
      ];

      final pending = reduce(asked);
      expect(pending.latest?.status, SweeperRoleAssignmentStatus.pending);
      expect(pending.hasPendingRequest, isTrue);
      // Until Bill says yes the back is not covered, and the label says so.
      expect(pending.acceptedSweeperSailorId, isNull);
      expect(
        pending.latest?.statusLabel,
        contains('waiting for them to accept'),
      );
      expect(pending.pendingFor('bill')?.requestId, 'req-1');
      expect(pending.pendingFor('dave'), isNull);

      final accepted = reduce([
        ...asked,
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 45),
        ),
      ]);
      expect(accepted.latest?.status, SweeperRoleAssignmentStatus.accepted);
      expect(accepted.acceptedSweeperSailorId, 'bill');
      expect(accepted.hasPendingRequest, isFalse);
      expect(accepted.pendingFor('bill'), isNull);
    });

    test('records a decline as a decline, not as silence', () {
      final declined = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-decline',
          requestId: 'req-1',
          responder: 'bill',
          accepted: false,
          after: const Duration(seconds: 40),
        ),
      ]);

      expect(declined.latest?.status, SweeperRoleAssignmentStatus.declined);
      expect(declined.acceptedSweeperSailorId, isNull);
      expect(declined.latest?.statusLabel, 'Bill declined');
    });

    test('expires when nobody answers, rather than waiting for ever', () {
      final events = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
      ];

      expect(
        reduce(
          events,
          now: start.add(const Duration(minutes: 9)),
        ).latest?.status,
        SweeperRoleAssignmentStatus.pending,
      );
      final expired = reduce(
        events,
        now: start.add(const Duration(minutes: 11)),
      );
      expect(expired.latest?.status, SweeperRoleAssignmentStatus.expired);
      expect(expired.latest?.statusLabel, contains('never answered'));
      // An expired request must not raise the prompt again on the target.
      expect(expired.pendingFor('bill'), isNull);
    });
  });

  group('forged and replayed requests', () {
    test('a request from a sailor who is not the skipper is rejected', () {
      final forged = reduce([
        ...roster(),
        request(
          id: 'd-forged',
          requestId: 'req-forged',
          target: 'dave',
          skipper: 'bill',
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(forged.assignments, isEmpty);
      expect(forged.pendingFor('dave'), isNull);
    });

    test('a request naming somebody else as its author is rejected', () {
      final forged = reduce([
        ...roster(),
        // Bill's device, claiming the skipper issued it.
        request(
          id: 'd-forged',
          requestId: 'req-forged',
          target: 'dave',
          skipper: 'bill',
          claimedSkipper: 'skipper',
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(forged.assignments, isEmpty);
    });

    test('a response from a device other than the target is rejected', () {
      final events = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        // Dave accepting on Bill's behalf.
        _event(
          id: 'e-forged-accept',
          deviceId: 'dave',
          type: VoyageEventType.sweeperRoleResponded,
          createdAt: start.add(const Duration(seconds: 40)),
          payload: SweeperRoleAssignmentReducer.responsePayload(
            requestId: 'req-1',
            targetSailorId: 'bill',
            accepted: true,
          ),
        ),
      ];

      final state = reduce(events);
      expect(state.latest?.status, SweeperRoleAssignmentStatus.pending);
      expect(state.acceptedSweeperSailorId, isNull);

      // And Bill's own later answer still counts: the forgery did not consume it.
      final answered = reduce([
        ...events,
        response(
          id: 'f-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 50),
        ),
      ]);
      expect(answered.acceptedSweeperSailorId, 'bill');
    });

    test('an unsigned request is rejected', () {
      final unsigned = VoyageEvent(
        id: 'd-unsigned',
        voyageId: 'voyage-a',
        deviceId: 'skipper',
        type: VoyageEventType.sweeperRoleRequested,
        priority: EventPriority.important,
        createdAt: start.add(const Duration(seconds: 30)),
        payload: SweeperRoleAssignmentReducer.requestPayload(
          requestId: 'req-1',
          skipperSailorId: 'skipper',
          targetSailorId: 'bill',
          targetDisplayName: 'Bill',
        ),
        signature: 'f' * 64,
      );

      expect(reduce([...roster(), unsigned]).assignments, isEmpty);
    });
  });

  group('convergence', () {
    test('duplicate and out-of-order delivery reach the same state', () {
      final inOrder = [
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 45),
        ),
      ];
      final shuffled = [
        inOrder[4],
        inOrder[2],
        inOrder[3],
        inOrder[0],
        inOrder[1],
        // Duplicates of both halves, as a replayed frame would deliver.
        inOrder[3],
        inOrder[4],
      ];

      final ordered = reduce(inOrder);
      final jumbled = reduce(shuffled);
      expect(jumbled.assignments, hasLength(ordered.assignments.length));
      expect(jumbled.acceptedSweeperSailorId, ordered.acceptedSweeperSailorId);
      expect(jumbled.latest?.status, ordered.latest?.status);
      expect(jumbled.latest?.respondedAt, ordered.latest?.respondedAt);
    });

    test('an answer timestamped before its own question still counts', () {
      // Two phones, two clocks. The answer must not be matched to the question
      // by its position in the journal.
      final state = reduce([
        ...roster(),
        request(
          id: 'e-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 40),
        ),
        response(
          id: 'd-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 30),
        ),
      ]);

      expect(state.acceptedSweeperSailorId, 'bill');
      expect(state.latest?.status, SweeperRoleAssignmentStatus.accepted);
    });

    test('a second request supersedes an unanswered first', () {
      final state = reduce([
        ...roster(),
        request(
          id: 'd-ask-bill',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        request(
          id: 'e-ask-dave',
          requestId: 'req-2',
          target: 'dave',
          after: const Duration(seconds: 40),
        ),
      ]);

      expect(
        state.assignments.first.status,
        SweeperRoleAssignmentStatus.superseded,
      );
      expect(state.latest?.targetSailorId, 'dave');
      expect(state.latest?.status, SweeperRoleAssignmentStatus.pending);
      // The superseded target must not still be prompted.
      expect(state.pendingFor('bill'), isNull);
      expect(state.pendingFor('dave'), isNotNull);
    });

    test('a sailor who leaves while holding the role stops being the TEC', () {
      final state = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        response(
          id: 'e-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 40),
        ),
        _event(
          id: 'f-left',
          deviceId: 'bill',
          type: VoyageEventType.sailorLeft,
          createdAt: start.add(const Duration(minutes: 5)),
          payload: const {'sailorId': 'bill', 'reason': 'left'},
        ),
      ], now: start.add(const Duration(minutes: 6)));

      expect(state.latest?.status, SweeperRoleAssignmentStatus.targetLeft);
      expect(state.acceptedSweeperSailorId, isNull);
      expect(state.latest?.statusLabel, contains('has left the voyage'));
    });

    test('a request survives a later skipper handover', () {
      // The skipper asks Bill, then hands the lead to Dave. The request was
      // legitimate when issued, so it stays legitimate; only new requests are
      // judged against who is skipper now.
      final state = reduce([
        ...roster(),
        request(
          id: 'd-request',
          requestId: 'req-1',
          target: 'bill',
          after: const Duration(seconds: 30),
        ),
        roleChanged(
          id: 'e-handover-away',
          deviceId: 'skipper',
          role: VoyageRole.sailor,
          after: const Duration(seconds: 40),
        ),
        roleChanged(
          id: 'f-handover-to',
          deviceId: 'dave',
          role: VoyageRole.skipper,
          after: const Duration(seconds: 41),
        ),
        response(
          id: 'g-accept',
          requestId: 'req-1',
          responder: 'bill',
          accepted: true,
          after: const Duration(seconds: 50),
        ),
      ]);

      expect(state.acceptedSweeperSailorId, 'bill');

      // And the former skipper can no longer issue one.
      final afterHandover = reduce([
        ...roster(),
        roleChanged(
          id: 'd-handover-away',
          deviceId: 'skipper',
          role: VoyageRole.sailor,
          after: const Duration(seconds: 30),
        ),
        roleChanged(
          id: 'e-handover-to',
          deviceId: 'dave',
          role: VoyageRole.skipper,
          after: const Duration(seconds: 31),
        ),
        request(
          id: 'f-stale-request',
          requestId: 'req-stale',
          target: 'bill',
          after: const Duration(seconds: 40),
        ),
      ]);
      expect(afterHandover.assignments, isEmpty);
    });
  });

  group('the four SweeperAvailability states through an assignment', () {
    const calculator = SkipperVoyageStatusCalculator();
    final askedAndAccepted = [
      ...roster(),
      request(
        id: 'd-request',
        requestId: 'req-1',
        target: 'bill',
        after: const Duration(seconds: 30),
      ),
      response(
        id: 'e-accept',
        requestId: 'req-1',
        responder: 'bill',
        accepted: true,
        after: const Duration(seconds: 40),
      ),
      roleChanged(
        id: 'f-role',
        deviceId: 'bill',
        role: VoyageRole.sweeper,
        after: const Duration(seconds: 41),
      ),
    ];

    SailorLocation billAt(DateTime recordedAt) => SailorLocation(
      sailorId: 'bill',
      displayName: 'Bill',
      role: VoyageRole.sweeper,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: recordedAt,
        accuracyMeters: 5,
      ),
      receivedAt: recordedAt,
    );

    test('none before the request, then awaitingLocation once accepted', () {
      final now = start.add(const Duration(minutes: 1));
      expect(
        calculator
            .resolveSweeperTarget(
              localSailorId: 'skipper',
              sailorLocations: const [],
              now: now,
            )
            .availability,
        SweeperAvailability.none,
      );

      final assignment = reduce(askedAndAccepted, now: now);
      final awaiting = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: const [],
        // Membership supplies the registered id; the assignment supplies the
        // tie-break. Neither invents a position.
        registeredSweeperSailorIds: const ['bill'],
        assignedSweeperSailorId: assignment.acceptedSweeperSailorId,
        now: now,
      );
      expect(awaiting.availability, SweeperAvailability.awaitingLocation);
      expect(awaiting.sailorId, 'bill');
      expect(awaiting.navigableLocation, isNull);
    });

    test('tracking with a fresh fix, stale once it ages out', () {
      final now = start.add(const Duration(minutes: 2));
      final assignment = reduce(askedAndAccepted, now: now);

      final tracking = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: [billAt(now.subtract(const Duration(seconds: 20)))],
        registeredSweeperSailorIds: const ['bill'],
        assignedSweeperSailorId: assignment.acceptedSweeperSailorId,
        now: now,
      );
      expect(tracking.availability, SweeperAvailability.tracking);
      expect(tracking.navigableLocation, isNotNull);

      final stale = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: [billAt(now.subtract(const Duration(minutes: 5)))],
        registeredSweeperSailorIds: const ['bill'],
        assignedSweeperSailorId: assignment.acceptedSweeperSailorId,
        now: now,
      );
      expect(stale.availability, SweeperAvailability.stale);
      // A stale fix is still withheld from anything that would navigate to it.
      expect(stale.navigableLocation, isNull);
    });

    test('two sailors holding the role resolve to the accepted one', () {
      final now = start.add(const Duration(minutes: 2));
      final assignment = reduce(askedAndAccepted, now: now);
      final selfSelected = SailorLocation(
        sailorId: 'dave',
        displayName: 'Dave',
        role: VoyageRole.sweeper,
        sample: LocationSample(
          position: const GeoPoint(latitude: 51.4, longitude: -0.2),
          // Fresher than Bill's, so without the tie-break Dave would win.
          recordedAt: now,
          accuracyMeters: 5,
        ),
        receivedAt: now,
      );

      final withoutAssignment = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: [
          billAt(now.subtract(const Duration(seconds: 30))),
          selfSelected,
        ],
        now: now,
      );
      expect(withoutAssignment.sailorId, 'dave');

      final resolved = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: [
          billAt(now.subtract(const Duration(seconds: 30))),
          selfSelected,
        ],
        registeredSweeperSailorIds: const ['bill', 'dave'],
        assignedSweeperSailorId: assignment.acceptedSweeperSailorId,
        now: now,
      );
      expect(resolved.sailorId, 'bill');
      expect(resolved.availability, SweeperAvailability.tracking);
    });

    test('an assignment never invents a TEC who is not registered', () {
      final now = start.add(const Duration(minutes: 2));
      final resolved = calculator.resolveSweeperTarget(
        localSailorId: 'skipper',
        sailorLocations: const [],
        assignedSweeperSailorId: 'bill',
        now: now,
      );

      expect(resolved.availability, SweeperAvailability.none);
      expect(resolved.sailorId, isNull);
    });
  });
}

VoyageEvent _event({
  required String id,
  required String deviceId,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  const secret = '0123456789abcdef0123456789abcdef';
  final unsigned = VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: id,
    voyageId: 'voyage-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: VoyageEventAuthenticator.sign(unsigned, secret),
  );
}
