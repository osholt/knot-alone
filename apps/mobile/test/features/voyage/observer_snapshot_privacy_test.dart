import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/imported_route.dart' as route_domain;
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';
import 'package:tide_and_seek/services/sailor_contact_share.dart';

void main() {
  test('observer snapshot uses only the local device GPS sample', () {
    final now = DateTime.utc(2026, 7, 24, 12);
    final session = VoyageSession(
      voyageId: 'private-voyage-id',
      voyageCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localSailorId: 'local-sailor',
      displayName: 'Local sailor',
      role: VoyageRole.sailor,
      joinedAt: now,
    );
    final local = LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -0.1),
      recordedAt: now,
      accuracyMeters: 5,
    );

    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      voyageStatus: 'waiting',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      localLocation: local,
      assistance: null,
    );
    final encoded = snapshot.toJson().toString();

    expect(snapshot.subjectName, 'Local sailor');
    expect(snapshot.position?.latitude, 51.5);
    expect(encoded, isNot(contains('private-voyage-id')));
    expect(encoded, isNot(contains('private-invite-secret')));
    expect(encoded, isNot(contains('local-sailor')));
  });

  test(
    'a forged relay status for the local sailor is never observer input',
    () {
      final now = DateTime.utc(2026, 7, 24, 12);
      final forgedRemoteEvent = VoyageEvent(
        id: 'remote-forgery',
        voyageId: 'voyage-a',
        deviceId: 'local-sailor',
        type: VoyageEventType.statusMessage,
        priority: EventPriority.critical,
        createdAt: now,
        payload: const {'message': 'emergencyStop'},
        signature: 'a' * 64,
      );
      final session = VoyageSession(
        voyageId: 'voyage-a',
        voyageCode: '123456',
        inviteSecret: 'private-invite-secret-012345',
        joinToken: 'private-join-token',
        localSailorId: 'local-sailor',
        displayName: 'Local sailor',
        role: VoyageRole.sailor,
        joinedAt: now,
      );

      expect(forgedRemoteEvent.payload['message'], 'emergencyStop');
      final snapshot = buildLocalObserverSnapshot(
        session: session,
        snapshotGeneratedAt: now,
        voyageStatus: 'active',
        statusUpdatedAt: now,
        assistanceUpdatedAt: session.joinedAt,
        localLocation: null,
        // Only installation-local send/resolve actions may populate this value;
        // shared journal events are deliberately not an input.
        assistance: null,
      );

      expect(snapshot.assistance, isNull);
    },
  );

  test('a phone number shared inside the voyage never reaches an observer', () {
    // Issue #188 lets a sailor give their own number to the voyage's coordination
    // roles. An observer link is a separate authorisation decision (#36), so it
    // gets nothing of the sort - the same rule ICE has always had.
    final now = DateTime.utc(2026, 7, 27, 12);
    final session = VoyageSession(
      voyageId: 'private-voyage-id',
      voyageCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localSailorId: 'local-sailor',
      displayName: 'Local sailor',
      role: VoyageRole.lead,
      joinedAt: now,
    );
    const sharedNumber = '+44 7700 900321';
    final contact = SailorContactShare(
      eventId: 'contact-share',
      sailorId: 'bill',
      displayName: 'Bill',
      phoneNumber: sharedNumber,
      sharedAt: now,
      sharedByRole: VoyageRole.sailor,
      toVoyageGroup: false,
    );

    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      voyageStatus: 'active',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      localLocation: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: now,
        accuracyMeters: 5,
      ),
      assistance: null,
    );
    final encoded = snapshot.toJson().toString();

    expect(encoded, isNot(contains(sharedNumber)));
    expect(encoded, isNot(contains('900321')));
    expect(encoded, isNot(contains('phone')));
    expect(encoded, isNot(contains('contact')));
    // The share itself does carry the number - to the recipients it names.
    expect(contact.toJson()['phone'], sharedNumber);
    // And there is no snapshot field for a later change to populate.
    expect(snapshot.toJson().keys, isNot(contains('phoneNumber')));
    expect(snapshot.toJson().keys, isNot(contains('sailorContact')));
  });

  test('group watcher contains only bounded live roster and route data', () {
    final now = DateTime.utc(2026, 7, 30, 12);
    final session = VoyageSession(
      voyageId: 'private-voyage-id',
      voyageCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localSailorId: 'skipper-private-id',
      displayName: 'Oliver',
      role: VoyageRole.lead,
      joinedAt: now,
      voyageName: 'Sunday voyage',
    );
    final participants = [
      VoyageParticipant(
        sailorId: 'skipper-private-id',
        displayName: 'Oliver',
        role: VoyageRole.lead,
        joinedAt: now,
        lastSeenAt: now,
        state: VoyageMembershipState.active,
        motorcycleStyle: motorcycleIconStyleDefault,
        sailorColor: SailorColor.orange,
        transportEvidence: const {VoyageTransportEvidence.localDevice},
        isLocal: true,
      ),
      VoyageParticipant(
        sailorId: 'follower-private-id',
        displayName: 'Alex',
        role: VoyageRole.sweeper,
        joinedAt: now,
        lastSeenAt: now,
        state: VoyageMembershipState.active,
        motorcycleStyle: motorcycleIconStyleDefault,
        sailorColor: SailorColor.cyan,
        transportEvidence: const {VoyageTransportEvidence.internetRelay},
        isLocal: false,
      ),
    ];
    final remoteLocation = SailorLocation(
      sailorId: 'follower-private-id',
      displayName: 'Alex',
      role: VoyageRole.sweeper,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.6, longitude: -0.2),
        recordedAt: now,
        accuracyMeters: 9,
      ),
      receivedAt: now,
    );
    final route = route_domain.ImportedRoute(
      id: 'private-route-id',
      name: 'Public route label',
      description: 'Private route notes',
      importedAt: now,
      sourceFileName: 'private-source.gpx',
      paths: [
        route_domain.RoutePath(
          kind: route_domain.RoutePathKind.route,
          points: [
            for (var index = 0; index < 800; index += 1)
              route_domain.GeoPoint(
                latitude: 51 + index / 10000,
                longitude: -2 + index / 10000,
              ),
          ],
        ),
      ],
      waypoints: const [],
    );

    final snapshot = buildGroupObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      voyageStatus: 'active',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      liveParticipants: participants,
      renderedPositions: [remoteLocation],
      localLocation: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: now,
        accuracyMeters: 5,
      ),
      route: route,
    );
    final encoded = snapshot.toJson().toString();

    expect(snapshot.participants, hasLength(2));
    expect(snapshot.participants.first.position?.latitude, 51.5);
    expect(snapshot.participants.last.position?.latitude, 51.6);
    expect(snapshot.route?.points, hasLength(500));
    expect(snapshot.route?.points.first.latitude, 51);
    expect(snapshot.route?.points.last.latitude, closeTo(51.0799, 0.00001));
    expect(encoded, isNot(contains('private-voyage-id')));
    expect(encoded, isNot(contains('private-invite-secret')));
    expect(encoded, isNot(contains('private-id')));
    expect(encoded, isNot(contains('Private route notes')));
    expect(encoded, isNot(contains('private-source.gpx')));
    expect(encoded, isNot(contains('phone')));
    expect(encoded, isNot(contains('trail')));
  });
}
