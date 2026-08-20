import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/quick_message.dart';
import 'package:tide_and_seek/domain/completed_voyage_store.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/imported_route.dart' as route_domain;
import 'package:tide_and_seek/domain/mob_state.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_coordination_mode.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_join_payload.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/received_quick_message.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/voyage_lifecycle.dart';
import 'package:tide_and_seek/services/sailor_contact_share.dart';
import 'package:tide_and_seek/services/situation_event_factory.dart';

void main() {
  late InMemoryEventStore eventStore;
  late InMemorySessionStore sessionStore;
  late VoyageController controller;
  late _InMemoryVoyageCodeDirectory voyageCodes;
  late InMemoryCompletedVoyageStore completedVoyageStore;
  late int id;

  setUp(() async {
    eventStore = InMemoryEventStore();
    sessionStore = InMemorySessionStore();
    voyageCodes = _InMemoryVoyageCodeDirectory();
    completedVoyageStore = InMemoryCompletedVoyageStore();
    id = 0;
    controller = VoyageController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(42),
      voyageCodeDirectory: voyageCodes,
      completedVoyageStore: completedVoyageStore,
    );
    await controller.initialize();
  });

  tearDown(() => controller.dispose());

  test('new voyage is persisted with lead role and a signed event', () async {
    await controller.createVoyage('Oliver');

    expect(controller.session?.role, VoyageRole.skipper);
    expect(controller.session?.displayName, 'Oliver');
    expect(controller.session?.voyageCode, matches(RegExp(r'^\d{6}$')));
    expect(controller.events, hasLength(1));
    expect(controller.events.single.type, VoyageEventType.voyageCreated);
    expect(controller.events.single.signature, hasLength(64));
    expect(controller.voyageStarted, isFalse);

    final restored = await sessionStore.load();
    expect(restored?.voyageId, controller.session?.voyageId);
  });

  test(
    'MOB is saved offline and cleared only by an explicit resolution',
    () async {
      await controller.createVoyage('Oliver');

      expect(
        await controller.activateMob(
          MobFix(
            latitude: 50.8,
            longitude: -1.1,
            recordedAt: DateTime.utc(2026, 7, 16, 11, 59, 58),
            accuracyMeters: 6,
            source: 'gnss',
            stale: false,
          ),
        ),
        isTrue,
      );

      final activation = controller.events.last;
      expect(activation.type, VoyageEventType.mobActivated);
      expect(activation.priority, EventPriority.critical);
      expect(activation.signature, hasLength(64));
      expect(controller.mobState.activeIncident!.fix.latitude, 50.8);
      expect(
        (await eventStore.eventsForVoyage(
          controller.session!.voyageId,
        )).last.id,
        activation.id,
      );

      expect(await controller.resolveMob(MobResolution.recovered), isTrue);
      expect(controller.events.last.type, VoyageEventType.mobResolved);
      expect(
        controller.events.last.payload['activationEventId'],
        activation.id,
      );
      expect(controller.mobState.active, isFalse);
    },
  );

  test('voyage coordination mode is persisted and published', () async {
    await controller.createVoyage(
      'Oliver',
      coordinationMode: VoyageCoordinationMode.crew,
    );

    expect(controller.session?.coordinationMode, VoyageCoordinationMode.crew);
    expect(controller.coordinationMode, VoyageCoordinationMode.crew);
    expect(
      controller.events.single.payload['coordinationMode'],
      VoyageCoordinationMode.crew.name,
    );
  });

  test(
    'a long voyage does not re-project membership for coordinate-only updates',
    () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      final session = controller.session!;
      final startedAt = controller.voyageStartedAt!;

      // A realistic two-hour journal. Before the cache, every foreground GPS
      // fix made VoyageMembershipReducer authenticate, sort and walk all 12,000
      // positions again.
      for (var index = 0; index < 12000; index += 1) {
        final recordedAt = startedAt.add(Duration(milliseconds: index * 600));
        final location = SailorLocation(
          sailorId: session.localSailorId,
          displayName: session.displayName,
          role: session.role,
          sample: LocationSample(
            position: GeoPoint(
              latitude: 51.46 + index * 0.00001,
              longitude: -2.5,
            ),
            recordedAt: recordedAt,
            accuracyMeters: 5,
          ),
          receivedAt: recordedAt,
        );
        final event = _signedEvent(
          session: session,
          id: 'long-location-$index',
          type: VoyageEventType.sailorLocationUpdated,
          createdAt: recordedAt,
          payload: {'location': location.toJson()},
        );
        expect(controller.ingestStoredEvent(event), isTrue);
      }

      LiveSailorPresence presenceAt(int index) {
        final recordedAt = startedAt.add(Duration(seconds: index));
        return LiveSailorPresence(
          sailorId: session.localSailorId,
          displayName: session.displayName,
          role: session.role,
          freshness: PresenceFreshness.live,
          sources: const {LivePresenceSource.localDevice},
          isLocal: true,
          knownSince: session.joinedAt,
          location: SailorLocation(
            sailorId: session.localSailorId,
            displayName: session.displayName,
            role: session.role,
            sample: LocationSample(
              position: GeoPoint(
                latitude: 51.5 + index * 0.00001,
                longitude: -2.5,
              ),
              recordedAt: recordedAt,
              accuracyMeters: 5,
            ),
            receivedAt: recordedAt,
          ),
          age: Duration.zero,
          contactAt: recordedAt,
        );
      }

      controller.observeLivePresence([presenceAt(0)]);
      expect(controller.liveView.renderedPositions, hasLength(1));
      final projections = controller.debugMembershipProjectionCount;

      for (var index = 1; index <= 1000; index += 1) {
        controller.observeLivePresence([presenceAt(index)]);
        expect(
          controller.liveView.renderedPositions.single.sample.position.latitude,
          closeTo(51.5 + index * 0.00001, 1e-9),
        );
      }

      expect(controller.debugMembershipProjectionCount, projections);
      controller.refreshMembershipFreshness();
      controller.liveView;
      expect(controller.debugMembershipProjectionCount, projections + 1);
    },
  );

  test('skipper start is signed, durable, idempotent and restored', () async {
    await controller.createVoyage('Oliver');

    await controller.startVoyage();
    await controller.startVoyage();

    final startEvents = controller.events
        .where((event) => event.type == VoyageEventType.voyageStarted)
        .toList();
    expect(startEvents, hasLength(1));
    expect(
      startEvents.single.payload['skipperSailorId'],
      controller.session!.localSailorId,
    );
    expect(startEvents.single.signature, hasLength(64));
    expect(controller.voyageStartedAt, DateTime.utc(2026, 7, 16, 12));

    final restored = VoyageController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 13),
      idFactory: () => 'restored-start-id',
      random: Random(9),
      voyageCodeDirectory: voyageCodes,
    );
    await restored.initialize();
    expect(restored.voyageStarted, isTrue);
    expect(restored.voyageStartedAt, controller.voyageStartedAt);
    restored.dispose();
  });

  test(
    'skipper route publish and clear are signed durable revisions',
    () async {
      await controller.createVoyage('Oliver');
      final route = route_domain.ImportedRoute(
        id: 'route-a',
        name: 'Coast route',
        importedAt: DateTime.utc(2026, 7, 16),
        sourceFileName: 'coast.gpx',
        paths: const [
          route_domain.RoutePath(
            kind: route_domain.RoutePathKind.track,
            points: [
              route_domain.GeoPoint(latitude: 51.4, longitude: -2.6),
              route_domain.GeoPoint(latitude: 51.5, longitude: -2.5),
            ],
          ),
        ],
        waypoints: const [],
      );

      await controller.publishRoute(route);

      expect(controller.authoritativeRoute?.name, 'Coast route');
      expect(controller.authoritativeRouteState.revisionNumber, 1);
      expect(
        controller.events.last.type,
        VoyageEventType.routeRevisionPublished,
      );
      expect(controller.events.last.signature, hasLength(64));

      await controller.clearRoute();

      expect(controller.authoritativeRouteState.hasDecision, isTrue);
      expect(controller.authoritativeRoute, isNull);
      expect(controller.authoritativeRouteState.revisionNumber, 2);
      expect(controller.events.last.type, VoyageEventType.routeCleared);
    },
  );

  test('a non-skipper cannot publish or clear the group route', () async {
    await controller.createVoyage('Oliver');
    await controller.setRole(VoyageRole.sailor);
    final route = route_domain.ImportedRoute(
      id: 'route-a',
      name: 'Wrong route',
      importedAt: DateTime.utc(2026, 7, 16),
      sourceFileName: 'wrong.gpx',
      paths: const [
        route_domain.RoutePath(
          kind: route_domain.RoutePathKind.track,
          points: [route_domain.GeoPoint(latitude: 51.4, longitude: -2.6)],
        ),
      ],
      waypoints: const [],
    );

    await controller.publishRoute(route);
    expect(controller.authoritativeRoute, isNull);
    expect(controller.errorMessage, contains('Only the voyage skipper'));

    controller.clearError();
    await controller.clearRoute();
    expect(controller.authoritativeRouteState.hasDecision, isFalse);
    expect(controller.errorMessage, contains('Only the voyage skipper'));
  });

  test('a non-skipper cannot start the voyage', () async {
    await controller.createVoyage('Oliver');
    await controller.setRole(VoyageRole.sailor);

    await controller.startVoyage();

    expect(controller.voyageStarted, isFalse);
    expect(controller.errorMessage, contains('Only the voyage skipper'));
    expect(
      controller.events.where(
        (event) => event.type == VoyageEventType.voyageStarted,
      ),
      isEmpty,
    );
  });

  test(
    'offline skipper handover and duplicate starts converge deterministically',
    () async {
      await controller.createVoyage('Oliver');
      final session = controller.session!;
      final followerSession = VoyageSession(
        voyageId: session.voyageId,
        voyageCode: session.voyageCode,
        inviteSecret: session.inviteSecret,
        joinToken: session.joinToken,
        localSailorId: 'follower',
        displayName: 'Alex',
        role: VoyageRole.sailor,
        joinedAt: DateTime.utc(2026, 7, 16, 12, 1),
      );
      await eventStore.append(
        _signedEvent(
          session: followerSession,
          id: 'join-follower',
          type: VoyageEventType.sailorJoined,
          createdAt: DateTime.utc(2026, 7, 16, 12, 1),
          payload: const {'displayName': 'Alex', 'role': 'sailor'},
        ),
      );
      await eventStore.append(
        _signedEvent(
          session: followerSession,
          id: 'promote-follower',
          type: VoyageEventType.roleChanged,
          createdAt: DateTime.utc(2026, 7, 16, 12, 2),
          payload: const {'role': 'lead'},
        ),
      );
      for (final id in ['start-z', 'start-a']) {
        await eventStore.append(
          _signedEvent(
            session: followerSession,
            id: id,
            type: VoyageEventType.voyageStarted,
            createdAt: DateTime.utc(2026, 7, 16, 12, 3),
            payload: const {
              'skipperSailorId': 'follower',
              'skipperDisplayName': 'Alex',
            },
          ),
        );
      }

      await controller.reloadEvents();

      expect(controller.voyageStarted, isTrue);
      expect(controller.voyageStartedAt, DateTime.utc(2026, 7, 16, 12, 3));
      expect(controller.participants, hasLength(2));
      expect(
        controller.participants
            .singleWhere((participant) => participant.sailorId == 'follower')
            .role,
        VoyageRole.skipper,
      );
    },
  );

  test('simulation voyage is explicitly tagged and restartable', () async {
    await controller.createSimulationVoyage(sailorCount: 30);

    final firstVoyageId = controller.session!.voyageId;
    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.simulationSailorCount, 30);
    expect(controller.session?.displayName, 'Demo Skipper');
    expect(controller.events.first.payload['simulation'], isTrue);
    expect(controller.events, hasLength(1));
    expect(controller.voyageStarted, isFalse);

    await controller.startVoyage();

    expect(controller.events.last.type, VoyageEventType.voyageStarted);
    expect(controller.voyageStarted, isTrue);

    await controller.restartSimulationVoyage(sailorCount: 12);

    expect(controller.session?.isSimulation, isTrue);
    expect(controller.session?.simulationSailorCount, 12);
    expect(controller.session?.voyageId, isNot(firstVoyageId));
    expect(await eventStore.eventsForVoyage(firstVoyageId), isEmpty);
    expect(controller.voyageStarted, isFalse);
  });

  test('invalid join code is rejected without creating a session', () async {
    await controller.joinVoyage('123', 'Oliver');

    expect(controller.hasActiveVoyage, isFalse);
    expect(controller.errorMessage, contains('six-digit'));
  });

  test(
    'six-digit voyage code resolves the skipper voyage credentials',
    () async {
      await controller.createVoyage('Lead');
      final skipperSession = controller.session!;
      await controller.publishVoyageCode();

      final follower = VoyageController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 7, 16, 12),
        idFactory: () => 'follower-id',
        random: Random(7),
        voyageCodeDirectory: voyageCodes,
      );
      await follower.initialize();
      await follower.joinVoyage(skipperSession.voyageCode, 'Follower');

      expect(follower.session?.voyageId, skipperSession.voyageId);
      expect(follower.session?.inviteSecret, skipperSession.inviteSecret);
      follower.dispose();
    },
  );

  test('voyage code joins the skipper voyage with its relay secret', () async {
    await controller.createVoyage('Lead');
    final skipperSession = controller.session!;
    await controller.publishVoyageCode();

    final follower = VoyageController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 7, 16, 12),
      idFactory: () => 'follower-id',
      random: Random(7),
      voyageCodeDirectory: voyageCodes,
    );
    await follower.initialize();
    await follower.joinVoyage(skipperSession.voyageCode, 'Follower');

    expect(follower.session?.voyageId, skipperSession.voyageId);
    expect(follower.session?.voyageCode, skipperSession.voyageCode);
    expect(follower.session?.inviteSecret, skipperSession.inviteSecret);
    expect(follower.session?.role, VoyageRole.sailor);
    expect(
      SituationEventFactory.verify(
        follower.events.single,
        skipperSession.inviteSecret,
      ),
      isTrue,
    );
    follower.dispose();
  });

  test(
    'joining sailor receives the voyage join token for future re-sharing',
    () async {
      await controller.createVoyage('Lead');
      final skipperSession = controller.session!;
      await controller.publishVoyageCode();

      final follower = VoyageController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 7, 16, 12),
        idFactory: () => 'follower-id',
        random: Random(7),
        voyageCodeDirectory: voyageCodes,
      );
      await follower.initialize();
      await follower.joinVoyage(skipperSession.voyageCode, 'Follower');

      expect(follower.session?.joinToken, skipperSession.joinToken);
      follower.dispose();
    },
  );

  test(
    'voyage code share text carries the six digits and a paired invite',
    () async {
      await controller.createVoyage('Lead');
      final skipperSession = controller.session!;

      expect(
        controller.voyageCodeShareText,
        contains('Voyage code: ${skipperSession.voyageCode}'),
      );
      expect(
        controller.voyageCodeShareText,
        contains('${skipperSession.voyageCode}#${skipperSession.joinToken}'),
      );
    },
  );

  // #51. The message used to open with an `https://tideandseek.invalid/...`
  // address: a reserved TLD that cannot resolve, on a build with no Associated
  // Domain and no custom URL scheme. Every invitation therefore led with the
  // one thing in it that failed when tapped.
  test(
    'voyage code share text contains nothing that fails when tapped',
    () async {
      await controller.createVoyage('Lead');

      expect(controller.voyageCodeShareText, isNot(contains('http')));
      expect(controller.voyageCodeShareText, isNot(contains('.invalid')));
    },
  );

  test(
    'the voyage code is the first actionable thing in the share text',
    () async {
      await controller.createVoyage('Lead');
      final text = controller.voyageCodeShareText;
      final activeSession = controller.session!;

      expect(
        text.indexOf('Voyage code: ${activeSession.voyageCode}'),
        lessThan(text.indexOf(activeSession.joinToken)),
        reason: 'the six digits are what a recipient will actually type',
      );
    },
  );

  test('non-numeric voyage code is rejected before lookup', () async {
    await controller.joinVoyage('ABC234', 'Oliver');

    expect(controller.hasActiveVoyage, isFalse);
    expect(controller.errorMessage, contains('six-digit'));
  });

  test('quick messages are durable, prioritised directed events', () async {
    await controller.createVoyage('Oliver');
    await controller.sendQuickMessage(
      QuickMessage.emergencyStop,
      recipientSailorIds: const ['lead', 'sweeper', 'lead'],
    );

    final pending = await eventStore.pendingEvents(
      controller.session!.voyageId,
    );
    final message = pending.last;
    expect(message.type, VoyageEventType.statusMessage);
    expect(message.priority, EventPriority.critical);
    expect(message.payload['message'], 'emergencyStop');
    expect(message.payload['recipientSailorIds'], const ['lead', 'sweeper']);
  });

  test('a quick message carries who raised it and where they were', () async {
    // #151: "Bill needs fuel" is not actionable without "1.2 miles back", and a
    // recipient may not have the sender in their roster yet.
    await controller.createVoyage('Bill');
    await controller.sendQuickMessage(
      QuickMessage.fuel,
      position: const GeoPoint(latitude: 53.1, longitude: -1.02),
    );

    final raised = controller.events.last;
    expect(raised.payload['senderDisplayName'], 'Bill');
    expect(raised.payload['position'], const {
      'latitude': 53.1,
      'longitude': -1.02,
    });
    // Group-visible: the dashboard grid addresses nobody in particular.
    expect(raised.payload.containsKey('recipientSailorIds'), isFalse);
  });

  test(
    'acknowledging a quick message is recorded once, for its sender',
    () async {
      await controller.createVoyage('Ana');
      final session = controller.session!;
      // A message from another sailor, signed with the voyage's own invite secret,
      // exactly as one arrives over either transport.
      final unsigned = VoyageEvent(
        id: 'bill-fuel',
        voyageId: session.voyageId,
        deviceId: 'bill',
        type: VoyageEventType.statusMessage,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16, 11, 59),
        expiresAt: DateTime.utc(2026, 7, 16, 13),
        payload: const {
          'message': 'fuel',
          'label': 'Need fuel',
          'senderDisplayName': 'Bill',
        },
        signature: '',
      );
      await eventStore.append(
        VoyageEvent(
          id: unsigned.id,
          voyageId: unsigned.voyageId,
          deviceId: unsigned.deviceId,
          type: unsigned.type,
          priority: unsigned.priority,
          createdAt: unsigned.createdAt,
          expiresAt: unsigned.expiresAt,
          payload: unsigned.payload,
          signature: VoyageEventAuthenticator.sign(
            unsigned,
            session.inviteSecret,
          ),
        ),
      );
      await controller.reloadEvents();

      final received = controller.quickMessages.single;
      expect(received.headline, 'Bill needs fuel');
      expect(received.isAcknowledged, isFalse);

      await controller.acknowledgeQuickMessage(received);
      final acknowledgement = controller.events.last;
      expect(
        ReceivedQuickMessageReducer.isAcknowledgement(acknowledgement),
        isTrue,
      );
      expect(acknowledgement.payload['recipientSailorIds'], const ['bill']);
      expect(acknowledgement.payload['label'], 'Seen: Need fuel');

      // Folded onto the message, and never recorded twice.
      final folded = controller.quickMessages.single;
      expect(folded.isAcknowledged, isTrue);
      expect(folded.acknowledgedBy(session.localSailorId), isTrue);
      expect(folded.firstAcknowledgement?.displayName, 'Ana');
      final before = controller.events.length;
      await controller.acknowledgeQuickMessage(folded);
      expect(controller.events.length, before);
    },
  );

  test(
    'skipper can pause and resume the shared voyage without stopping GPS',
    () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();

      await controller.pauseVoyage();
      expect(controller.voyagePaused, isTrue);
      expect(controller.events.last.type, VoyageEventType.voyagePaused);

      await controller.resumeVoyage();
      expect(controller.voyagePaused, isFalse);
      expect(controller.events.last.type, VoyageEventType.voyageResumed);
    },
  );

  test('ending a real voyage creates a secret-free local archive', () async {
    await controller.createVoyage('Oliver', voyageName: 'Peak District');
    final inviteSecret = controller.session!.inviteSecret;
    final joinToken = controller.session!.joinToken;
    await controller.startVoyage();

    await controller.endVoyage();

    final archived = (await completedVoyageStore.list()).single;
    expect(archived.title, 'Peak District');
    expect(archived.localRole, VoyageRole.skipper);
    expect(archived.endedAt, DateTime.utc(2026, 7, 16, 12));
    expect(archived.toJson().toString(), isNot(contains(inviteSecret)));
    expect(archived.toJson().toString(), isNot(contains(joinToken)));
  });

  test('ended voyage is removed only after explicit clearing', () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;
    await controller.endVoyage();

    await controller.clearEndedVoyage();

    expect(controller.hasActiveVoyage, isFalse);
    expect(await sessionStore.load(), isNull);
    expect(await eventStore.eventsForVoyage(voyageId), isEmpty);
  });

  test('stepping away from an ended voyage keeps all of its data', () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;
    await controller.endVoyage();

    controller.setEndedVoyageAside();

    // The voyage stops owning the screen without giving anything up (#207).
    expect(controller.endedVoyageSetAside, isTrue);
    expect(controller.hasActiveVoyage, isTrue);
    expect(controller.voyageEnded, isTrue);
    expect(await sessionStore.load(), isNotNull);
    expect(await eventStore.eventsForVoyage(voyageId), isNotEmpty);

    controller.reopenEndedVoyage();

    expect(controller.endedVoyageSetAside, isFalse);
    expect(controller.session?.voyageId, voyageId);
  });

  test(
    'creating after a set-aside ended voyage starts with clean state',
    () async {
      await controller.createVoyage('Oliver', voyageName: 'First voyage');
      final endedVoyageId = controller.session!.voyageId;
      await controller.endVoyage();
      controller.setEndedVoyageAside();

      await controller.createVoyage('Oliver', voyageName: 'Second voyage');

      expect(controller.session?.voyageId, isNot(endedVoyageId));
      expect(controller.session?.voyageName, 'Second voyage');
      expect(controller.voyageEnded, isFalse);
      expect(controller.endedVoyageSetAside, isFalse);
      expect(
        controller.events.map((event) => event.voyageId),
        everyElement(controller.session!.voyageId),
      );
      expect(await eventStore.eventsForVoyage(endedVoyageId), isEmpty);
      expect((await completedVoyageStore.list()).single.title, 'First voyage');
    },
  );

  test('creating cannot replace a voyage which has not ended', () async {
    await controller.createVoyage('Oliver', voyageName: 'Current voyage');
    final voyageId = controller.session!.voyageId;

    await controller.createVoyage('Oliver', voyageName: 'Replacement');

    expect(controller.session?.voyageId, voyageId);
    expect(controller.session?.voyageName, 'Current voyage');
    expect(
      controller.errorMessage,
      'Finish or leave your current voyage before creating another.',
    );
  });

  test('joining cannot replace a voyage which has not ended', () async {
    await controller.createVoyage('Oliver', voyageName: 'Current voyage');
    final current = controller.session!;

    await controller.joinVoyageFromInvitation(
      const VoyageJoinPayload(
        voyageId: 'another-voyage',
        voyageCode: '654321',
        inviteSecret: 'another-voyage-secret-0123456789',
        joinToken: 'another-join-token-0123456789',
      ),
      'Oliver',
    );

    expect(controller.session?.voyageId, current.voyageId);
    expect(
      controller.errorMessage,
      'Finish or leave your current voyage before joining another.',
    );
  });

  test('a set-aside voyage cannot outlive the voyage it refers to', () async {
    await controller.createVoyage('Oliver');
    await controller.endVoyage();
    controller.setEndedVoyageAside();

    await controller.clearEndedVoyage();

    expect(controller.endedVoyageSetAside, isFalse);
    expect(controller.hasActiveVoyage, isFalse);
  });

  test('a running voyage cannot be set aside', () async {
    await controller.createVoyage('Oliver');
    await controller.startVoyage();

    controller.setEndedVoyageAside();

    expect(controller.endedVoyageSetAside, isFalse);
  });

  // #206/#207. The journal is append-only, so un-ending a voyage is a later event
  // and not a deletion. The later of the pair decides, exactly as voyagePaused and
  // voyageResumed already decide whether the group is stopped.
  group('a skipper can un-end a voyage', () {
    test('reopening puts the voyage back to running', () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      await controller.endVoyage();
      expect(controller.voyageEnded, isTrue);

      expect(await controller.reopenVoyage(), VoyageReopenOutcome.reopened);

      expect(controller.voyageEnded, isFalse);
      expect(controller.voyageStarted, isTrue);
      expect(controller.voyagePhase, VoyagePhase.started);
      // Nothing was removed: both events are still in the journal.
      expect(
        controller.events.map((event) => event.type),
        containsAll([
          VoyageEventType.voyageEnded,
          VoyageEventType.voyageReopened,
        ]),
      );
      expect(controller.events.last.signature, hasLength(64));
    });

    test('ending again after a reopen ends the voyage again', () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();
      await controller.endVoyage();
      await controller.reopenVoyage();

      await controller.endVoyage();

      expect(controller.voyageEnded, isTrue);
    });

    test('a sailor who is not the skipper cannot reopen', () async {
      await controller.createVoyage('Oliver');
      await controller.endVoyage();
      await controller.setRole(VoyageRole.sailor);

      expect(await controller.reopenVoyage(), VoyageReopenOutcome.notSkipper);
      expect(controller.voyageEnded, isTrue);
    });

    test('a running voyage has nothing to reopen', () async {
      await controller.createVoyage('Oliver');
      await controller.startVoyage();

      expect(await controller.reopenVoyage(), VoyageReopenOutcome.notEnded);
    });

    test('a relay that cannot carry the reopen records nothing', () async {
      await controller.createVoyage('Oliver');
      await controller.endVoyage();
      final eventCount = controller.events.length;

      expect(
        await controller.reopenVoyage(relayCanCarryReopen: false),
        VoyageReopenOutcome.relayUnsupported,
      );

      // Not recorded locally either: a skipper back on the map while the group
      // still sees a finished voyage is worse than being told it is unavailable.
      expect(controller.events, hasLength(eventCount));
      expect(controller.voyageEnded, isTrue);
    });

    test('past the recovery window there is nothing left to reopen', () async {
      var now = DateTime.utc(2026, 7, 28, 8);
      var seedId = 0;
      final aged = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
        clock: () => now,
        idFactory: () => 'aged-${seedId++}',
        random: Random(3),
        voyageCodeDirectory: voyageCodes,
        completedVoyageStore: completedVoyageStore,
      );
      await aged.initialize();
      await aged.createVoyage('Oliver');
      await aged.endVoyage();

      now = now
          .add(VoyageController.endedVoyageRecoveryWindow)
          .add(const Duration(minutes: 1));

      expect(await aged.reopenVoyage(), VoyageReopenOutcome.windowExpired);
      aged.dispose();
    });

    test('a reopened voyage is no longer scheduled for deletion', () async {
      var now = DateTime.utc(2026, 7, 28, 8);
      var seedId = 0;
      final controllerWithClock = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
        clock: () => now,
        idFactory: () => 'reopen-${seedId++}',
        random: Random(4),
        voyageCodeDirectory: voyageCodes,
        completedVoyageStore: completedVoyageStore,
      );
      await controllerWithClock.initialize();
      await controllerWithClock.createVoyage('Oliver');
      final voyageId = controllerWithClock.session!.voyageId;
      await controllerWithClock.endVoyage();
      await controllerWithClock.reopenVoyage();
      controllerWithClock.dispose();

      // The retention timer keys off the end; reopening has to call it off, or a
      // running voyage deletes itself out from under the group.
      now = now
          .add(VoyageController.endedVoyageRecoveryWindow)
          .add(const Duration(minutes: 1));
      final restored = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
        clock: () => now,
        idFactory: () => 'restored-${seedId++}',
        random: Random(5),
        voyageCodeDirectory: voyageCodes,
        completedVoyageStore: completedVoyageStore,
      );
      await restored.initialize();

      expect(restored.hasActiveVoyage, isTrue);
      expect(restored.voyageEnded, isFalse);
      expect(await eventStore.eventsForVoyage(voyageId), isNotEmpty);
      restored.dispose();
    });
  });

  test(
    'expired ended voyage data is deleted when the app is reopened',
    () async {
      var now = DateTime.utc(2026, 7, 16, 12);
      var seedId = 0;
      final seed = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
        clock: () => now,
        idFactory: () => 'retention-${seedId++}',
        random: Random(1),
        voyageCodeDirectory: voyageCodes,
      );
      await seed.initialize();
      await seed.createVoyage('Oliver');
      final voyageId = seed.session!.voyageId;
      await seed.endVoyage();
      seed.dispose();

      now = now
          .add(VoyageController.endedVoyageRecoveryWindow)
          .add(const Duration(seconds: 1));
      final reopened = VoyageController(
        eventStore,
        sessionStore,
        const _FakeNearbyBridge(),
        clock: () => now,
        idFactory: () => 'reopened-${seedId++}',
        random: Random(2),
        voyageCodeDirectory: voyageCodes,
      );
      await reopened.initialize();

      expect(reopened.hasActiveVoyage, isFalse);
      expect(await sessionStore.load(), isNull);
      expect(await eventStore.eventsForVoyage(voyageId), isEmpty);
      reopened.dispose();
    },
  );

  test(
    'leaving records a signed departure before clearing the session',
    () async {
      await controller.createVoyage('Oliver');
      final voyageId = controller.session!.voyageId;
      VoyageEvent? published;

      await controller.leaveVoyage(
        publishDeparture: (departure) async => published = departure,
      );

      expect(controller.hasActiveVoyage, isFalse);
      expect(await sessionStore.load(), isNull);
      final retained = await eventStore.eventsForVoyage(voyageId);
      expect(retained.last.type, VoyageEventType.sailorLeft);
      expect(retained.last.payload['sailorId'], retained.last.deviceId);
      expect(published?.id, retained.last.id);
      expect(published?.signature, hasLength(64));
    },
  );

  test('explicit ICE share carries no recipient filter', () async {
    await controller.createVoyage('Oliver');
    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: 'Type 1 diabetic',
      recipientSailorIds: const [],
    );

    final shared = controller.events.singleWhere(
      (event) => event.type == VoyageEventType.iceInfoShared,
    );
    expect(shared.payload.containsKey('recipientSailorIds'), isFalse);
    expect(controller.sentIceShares.single.toWholeGroup, isTrue);
    expect(controller.sentIceShares.single.viewedAt, isNull);
  });

  test('default-share-with-skipper carries a recipient filter', () async {
    await controller.createVoyage('Oliver');
    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: '',
      recipientSailorIds: const ['skipper-device'],
    );

    final shared = controller.events.singleWhere(
      (event) => event.type == VoyageEventType.iceInfoShared,
    );
    expect(shared.payload['recipientSailorIds'], ['skipper-device']);
    expect(controller.sentIceShares.single.toWholeGroup, isFalse);
  });

  test('a scanned invitation joins with the relay unreachable', () async {
    // #279: every other join path ends in VoyageCodeDirectory.resolve, an HTTPS
    // call, so a group with no signal cannot form a voyage at all - which is the
    // situation this product is for. The directory here throws on any call, so
    // this asserts the absence of a network round trip rather than assuming it.
    final offline = VoyageController(
      eventStore,
      sessionStore,
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 1, 9),
      idFactory: () => 'offline-${id++}',
      random: Random(7),
      voyageCodeDirectory: _UnreachableVoyageCodeDirectory(),
      completedVoyageStore: completedVoyageStore,
    );
    addTearDown(offline.dispose);

    const invitation = VoyageJoinPayload(
      voyageId: 'voyage-from-qr',
      voyageCode: '135627',
      inviteSecret: '0123456789abcdef0123456789abcdef',
      joinToken: 'resolve-token-0123456789',
    );

    await offline.joinVoyageFromInvitation(invitation, 'Scanned sailor');

    expect(offline.errorMessage, isNull, reason: 'the join must succeed');
    final session = offline.session;
    expect(session, isNotNull);
    expect(session!.voyageId, 'voyage-from-qr');
    expect(session.voyageCode, '135627');
    // The credentials that make authenticated transport possible have to arrive
    // intact, or the sailor is in a session that looks joined and can talk to
    // nobody.
    expect(session.inviteSecret, invitation.inviteSecret);
    expect(session.joinToken, invitation.joinToken);
    expect(session.role, VoyageRole.sailor);
    expect(session.displayName, 'Scanned sailor');

    // And it is a real join, not just a stored session: the roster has to show
    // this sailor, which means the sailorJoined event was recorded.
    expect(
      offline.participants.map((participant) => participant.displayName),
      contains('Scanned sailor'),
    );
  });

  test('the voyage names who ended it', () async {
    // #283: a tester whose voyage the skipper ended read it as a crash. Naming the
    // person is the difference between "something broke" and "the skipper stopped
    // the voyage", and it comes from the journal so a phone that was offline or has
    // restarted since can still say it.
    await controller.createVoyage('Skipper');
    await controller.startVoyage();

    expect(
      controller.voyageEndedBy,
      isNull,
      reason: 'a running voyage has nobody who ended it',
    );

    await controller.endVoyage();

    final endedBy = controller.voyageEndedBy;
    expect(endedBy, isNotNull);
    expect(endedBy!.isLocalSailor, isTrue);
    expect(endedBy.displayName, 'Skipper');
  });

  test('received ICE shares include broadcasts and shares addressed to me, '
      'not shares addressed elsewhere', () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;
    final myId = controller.session!.localSailorId;

    await eventStore.append(
      VoyageEvent(
        id: 'broadcast-share',
        voyageId: voyageId,
        deviceId: 'remote-device-a',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote A',
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      VoyageEvent(
        id: 'addressed-to-me',
        voyageId: voyageId,
        deviceId: 'remote-device-b',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: {
          'contactName': 'Jo',
          'contactPhone': '+44 7700 900333',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote B',
          'recipientSailorIds': [myId],
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      VoyageEvent(
        id: 'addressed-elsewhere',
        voyageId: voyageId,
        deviceId: 'remote-device-c',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Chris',
          'contactPhone': '+44 7700 900444',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote C',
          'recipientSailorIds': ['someone-else'],
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    final receivedIds = controller.receivedIceShares
        .map((share) => share.eventId)
        .toSet();
    expect(receivedIds, {'broadcast-share', 'addressed-to-me'});
  });

  test('viewing a share records exactly one view event, however many times '
      "it's opened", () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;
    final myId = controller.session!.localSailorId;

    await eventStore.append(
      VoyageEvent(
        id: 'their-share',
        voyageId: voyageId,
        deviceId: 'remote-device',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote',
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    await controller.markIceInfoViewed('their-share');
    await controller.markIceInfoViewed('their-share');

    final views = controller.events.where(
      (event) => event.type == VoyageEventType.iceInfoViewed,
    );
    expect(views, hasLength(1));
    expect(views.single.deviceId, myId);
  });

  test("a received view event updates the sharer's own share with who saw it "
      'and when', () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;

    await controller.shareEmergencyInfo(
      contactName: 'Sam',
      contactPhone: '+44 7700 900111',
      medicalNotes: '',
      recipientSailorIds: const [],
    );
    final sharedEventId = controller.events
        .singleWhere((event) => event.type == VoyageEventType.iceInfoShared)
        .id;
    expect(controller.sentIceShares.single.viewedAt, isNull);

    await eventStore.append(
      VoyageEvent(
        id: 'their-view',
        voyageId: voyageId,
        deviceId: 'remote-device',
        type: VoyageEventType.iceInfoViewed,
        priority: EventPriority.routine,
        createdAt: DateTime.utc(2026, 7, 16, 13),
        payload: {'sharedEventId': sharedEventId},
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();

    final sent = controller.sentIceShares.single;
    expect(sent.viewedAt, DateTime.utc(2026, 7, 16, 13));
    expect(sent.viewedBySailorId, 'remote-device');
  });

  test('ending the voyage purges unused received ICE shares, keeps used and '
      'self-sent ones', () async {
    await controller.createVoyage('Oliver');
    final voyageId = controller.session!.voyageId;
    final myId = controller.session!.localSailorId;

    await eventStore.append(
      VoyageEvent(
        id: 'unused-share',
        voyageId: voyageId,
        deviceId: 'remote-device-a',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: const {
          'contactName': 'Alex',
          'contactPhone': '+44 7700 900222',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote A',
        },
        signature: 'relay-test',
      ),
    );
    await eventStore.append(
      VoyageEvent(
        id: 'used-share',
        voyageId: voyageId,
        deviceId: 'remote-device-b',
        type: VoyageEventType.iceInfoShared,
        priority: EventPriority.critical,
        createdAt: DateTime.utc(2026, 7, 16, 12),
        payload: {
          'contactName': 'Jo',
          'contactPhone': '+44 7700 900333',
          'medicalNotes': '',
          'sharedByDisplayName': 'Remote B',
          'recipientSailorIds': [myId],
        },
        signature: 'relay-test',
      ),
    );
    await controller.reloadEvents();
    controller.markIceShareUsed('used-share');

    await controller.shareEmergencyInfo(
      contactName: 'Own contact',
      contactPhone: '+44 7700 900555',
      medicalNotes: '',
      recipientSailorIds: const [],
    );
    final ownShareId = controller.events
        .singleWhere(
          (event) =>
              event.type == VoyageEventType.iceInfoShared &&
              event.deviceId == myId,
        )
        .id;

    await controller.endVoyage();

    final remainingIds = (await eventStore.eventsForVoyage(voyageId))
        .where((event) => event.type == VoyageEventType.iceInfoShared)
        .map((event) => event.id)
        .toSet();
    expect(remainingIds, {'used-share', ownShareId});
  });

  group("sharing a sailor's own number (#188)", () {
    /// Signs a peer's share with the live voyage secret, because the reducer
    /// verifies: an unauthenticated event must never be able to plant a number.
    Future<void> appendPeerShare({
      required String eventId,
      required String sailorId,
      required String phone,
      List<String>? recipientSailorIds,
      DateTime? createdAt,
    }) async {
      final session = controller.session!;
      final unsigned = VoyageEvent(
        id: eventId,
        voyageId: session.voyageId,
        deviceId: sailorId,
        type: VoyageEventType.sailorContactShared,
        priority: EventPriority.important,
        createdAt: createdAt ?? DateTime.utc(2026, 7, 16, 11, 55),
        payload: {
          'contact': {
            'sailorId': sailorId,
            'displayName': sailorId,
            'phone': phone,
            'sharedByRole': VoyageRole.skipper.name,
          },
          'recipientSailorIds': ?recipientSailorIds,
        },
        signature: '',
      );
      await eventStore.append(
        VoyageEvent(
          id: unsigned.id,
          voyageId: unsigned.voyageId,
          deviceId: unsigned.deviceId,
          type: unsigned.type,
          priority: unsigned.priority,
          createdAt: unsigned.createdAt,
          payload: unsigned.payload,
          signature: VoyageEventAuthenticator.sign(
            unsigned,
            session.inviteSecret,
          ),
        ),
      );
      await controller.reloadEvents();
    }

    test('an ordinary sailor addresses it to the skipper and TEC and to nobody '
        'else, and it is a separate event from ICE', () async {
      await controller.createVoyage('Oliver');

      final shared = await controller.shareOwnContactNumber(
        phoneNumber: '+44 7700 900321',
        recipients: const SailorContactRecipients.addressed([
          'skipper',
          'sweeper',
        ]),
      );

      expect(shared, isTrue);
      final event = controller.events.singleWhere(
        (event) => event.type == VoyageEventType.sailorContactShared,
      );
      expect(event.payload['recipientSailorIds'], ['skipper', 'sweeper']);
      expect((event.payload['contact'] as Map)['phone'], '+44 7700 900321');
      // The number never travels as an ICE share, which carries next of kin.
      expect(
        controller.events.where(
          (event) => event.type == VoyageEventType.iceInfoShared,
        ),
        isEmpty,
      );
      expect(controller.hasSharedOwnContactNumber, isTrue);
    });

    test('records nothing when there is nobody to address, or the number is '
        'not dialable', () async {
      await controller.createVoyage('Oliver');

      expect(
        await controller.shareOwnContactNumber(
          phoneNumber: '+44 7700 900321',
          recipients: const SailorContactRecipients.addressed([]),
        ),
        isFalse,
      );
      expect(
        await controller.shareOwnContactNumber(
          phoneNumber: 'tel:+447700900321',
          recipients: const SailorContactRecipients.addressed(['skipper']),
        ),
        isFalse,
      );
      expect(
        controller.events.where(
          (event) => event.type == VoyageEventType.sailorContactShared,
        ),
        isEmpty,
      );
      expect(controller.hasSharedOwnContactNumber, isFalse);
    });

    test("a share addressed elsewhere never reaches this sailor's contact "
        'list', () async {
      await controller.createVoyage('Oliver');
      final myId = controller.session!.localSailorId;

      await appendPeerShare(
        eventId: 'addressed-to-me',
        sailorId: 'skipper-device',
        phone: '+44 7700 900111',
        recipientSailorIds: [myId],
      );
      await appendPeerShare(
        eventId: 'addressed-elsewhere',
        sailorId: 'other-device',
        phone: '+44 7700 900222',
        recipientSailorIds: const ['somebody-else'],
      );
      await appendPeerShare(
        eventId: 'voyage-wide',
        sailorId: 'sweeper-device',
        phone: '+44 7700 900333',
        recipientSailorIds: null,
      );

      final contacts = controller.receivedSailorContacts;
      expect(contacts.keys.toSet(), {'skipper-device', 'sweeper-device'});
      expect(contacts['skipper-device']!.phoneNumber, '+44 7700 900111');
      // The number of a sailor who addressed somebody else is not merely
      // hidden - it is not in the model any surface reads.
      expect(
        contacts.values.map((contact) => contact.phoneNumber),
        isNot(contains('+44 7700 900222')),
      );
    });

    test('ending the voyage purges an unused shared number and keeps a dialled '
        'one, exactly as ICE is treated', () async {
      await controller.createVoyage('Oliver');
      final voyageId = controller.session!.voyageId;
      final myId = controller.session!.localSailorId;

      await appendPeerShare(
        eventId: 'unused-number',
        sailorId: 'skipper-device',
        phone: '+44 7700 900111',
        recipientSailorIds: [myId],
      );
      await appendPeerShare(
        eventId: 'dialled-number',
        sailorId: 'sweeper-device',
        phone: '+44 7700 900222',
        recipientSailorIds: [myId],
      );
      controller.markSailorContactUsed('dialled-number');
      await controller.shareOwnContactNumber(
        phoneNumber: '+44 7700 900999',
        recipients: const SailorContactRecipients.addressed(['skipper-device']),
      );

      await controller.endVoyage();

      final remaining = await eventStore.eventsForVoyage(voyageId);
      final remainingContactIds = remaining
          .where((event) => event.type == VoyageEventType.sailorContactShared)
          .map((event) => event.id)
          .toSet();
      // The dialled one and this sailor's own outbound share survive; the unused
      // one is gone from storage, not merely filtered out of a getter.
      expect(remainingContactIds, contains('dialled-number'));
      expect(remainingContactIds, isNot(contains('unused-number')));
      expect(
        remaining
            .where((event) => event.type == VoyageEventType.sailorContactShared)
            .any((event) => event.deviceId == myId),
        isTrue,
      );
      // And nothing is offered to dial once the voyage has ended, whatever
      // survives in the journal.
      expect(controller.receivedSailorContacts, isEmpty);
    });

    test('an unsigned share can never plant a number', () async {
      await controller.createVoyage('Oliver');
      final session = controller.session!;

      await eventStore.append(
        VoyageEvent(
          id: 'forged',
          voyageId: session.voyageId,
          deviceId: 'mallory',
          type: VoyageEventType.sailorContactShared,
          priority: EventPriority.important,
          createdAt: DateTime.utc(2026, 7, 16, 11, 55),
          payload: {
            'contact': const {
              'sailorId': 'mallory',
              'displayName': 'Mallory',
              'phone': '+44 7700 900444',
            },
            'recipientSailorIds': [session.localSailorId],
          },
          signature: 'f' * 64,
        ),
      );
      await controller.reloadEvents();

      expect(controller.receivedSailorContacts, isEmpty);
    });
  });
}

VoyageEvent _signedEvent({
  required VoyageSession session,
  required String id,
  required VoyageEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = VoyageEvent(
    id: id,
    voyageId: session.voyageId,
    deviceId: session.localSailorId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return VoyageEvent(
    id: unsigned.id,
    voyageId: unsigned.voyageId,
    deviceId: unsigned.deviceId,
    type: unsigned.type,
    priority: unsigned.priority,
    createdAt: unsigned.createdAt,
    payload: unsigned.payload,
    signature: SituationEventFactory.sign(unsigned, session.inviteSecret),
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}

/// Refuses every lookup, so a test that joins through it is proving the join made
/// no network call rather than merely not noticing one (#279).
class _UnreachableVoyageCodeDirectory implements VoyageCodeDirectory {
  @override
  Future<void> register(VoyageSession session) async =>
      throw StateError('the relay must not be reached');

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) => throw StateError('the relay must not be reached');

  @override
  void close() {}
}

class _InMemoryVoyageCodeDirectory implements VoyageCodeDirectory {
  final _credentials = <String, VoyageCodeCredentials>{};

  @override
  Future<void> register(VoyageSession session) async {
    final existing = _credentials[session.voyageCode];
    if (existing != null && existing.voyageId != session.voyageId) {
      throw const VoyageCodeDirectoryException(
        'Voyage code is already in use.',
        codeConflict: true,
      );
    }
    _credentials[session.voyageCode] = VoyageCodeCredentials(
      voyageId: session.voyageId,
      voyageCode: session.voyageCode,
      inviteSecret: session.inviteSecret,
      joinToken: session.joinToken,
    );
  }

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async {
    final credentials = _credentials[voyageCode];
    if (credentials == null) {
      throw const VoyageCodeDirectoryException(
        'That voyage code is not active.',
      );
    }
    return credentials;
  }

  @override
  void close() {}
}
