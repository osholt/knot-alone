import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/controllers/pre_start_presence_controller.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

/// Two simulated devices whose clocks do **not** agree, sharing one relay, over
/// the real presence client so the response decoder is in the loop.
///
/// Issue #132 requires freshness to be judged on a clock both devices agree on.
/// The relay stamps every position's arrival and reports its own current time,
/// so a peer's position is aged on that one clock. Judging it against this
/// phone's clock minus the *peer's* timestamp measured the difference between two
/// clocks and aged out a sailor who was reporting every few seconds.
void main() {
  late _Relay relay;

  setUp(() => relay = _Relay());

  _Device device(
    String sailorId,
    String name, {
    VoyageRole role = VoyageRole.sailor,
    Duration clockOffset = Duration.zero,
  }) {
    final device = _Device(sailorId, name, role, clockOffset, relay);
    addTearDown(device.controller.close);
    return device;
  }

  test(
    "a peer whose clock is behind stays live, and is named rather than aged out",
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: -4),
      );
      relay.join('skipper', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'sailor');
      relay.startVoyage();
      await skipper.start();
      await follower.start();

      await follower.publish(51.3);
      relay.serverNow = relay.serverNow.add(const Duration(seconds: 4));
      await skipper.synchronize();

      final seen = skipper.presenceFor('follower')!;
      // Four minutes of clock difference is not four minutes of age.
      expect(seen.freshness, PresenceFreshness.live);
      expect(seen.clockBasis, PresenceClockBasis.sharedRelayClock);
      expect(seen.age, lessThan(const Duration(seconds: 30)));
      expect(seen.location, isNotNull);

      // The disagreement is stated in words, with the sailor named.
      final limitation = skipper.controller.limitations.singleWhere(
        (entry) => entry.kind == PresenceLimitationKind.sailorClockUntrusted,
      );
      expect(limitation.sailorId, 'follower');
      expect(limitation.message, contains('Alex'));
      expect(limitation.message, contains('behind'));

      // And the sailor is active in the roster, not "inactive · location stale".
      final participant = skipper.participantFor('follower');
      expect(participant.state, VoyageMembershipState.active);
      expect(participant.positionFreshness, PresenceFreshness.live);
    },
  );

  test(
    'a peer whose clock is ahead is judged on the relay clock too',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: 3),
      );
      relay.join('skipper', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'sailor');
      relay.startVoyage();
      await skipper.start();
      await follower.start();

      await follower.publish(51.3);
      await skipper.synchronize();

      final seen = skipper.presenceFor('follower')!;
      expect(seen.freshness, PresenceFreshness.live);
      expect(
        skipper.controller.limitations
            .where(
              (entry) =>
                  entry.kind == PresenceLimitationKind.sailorClockUntrusted,
            )
            .map((entry) => entry.message)
            .single,
        contains('ahead of'),
      );
    },
  );

  test(
    'a device whose own clock runs ahead of the relay still sees everyone',
    () async {
      // The failure this reproduces: every position the relay returned looked
      // expired against this phone's clock, so the whole reply — positions and
      // roster alike — was discarded on every poll, and the channel reported
      // "the voyage service cannot be reached" while it was answering perfectly.
      final skipper = device(
        'skipper',
        'Lead',
        role: VoyageRole.lead,
        clockOffset: const Duration(seconds: 90),
      );
      final follower = device('follower', 'Alex');
      relay.join('skipper', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'sailor');
      relay.startVoyage();
      await follower.start();
      await follower.publish(51.3);
      await skipper.start();

      expect(skipper.controller.availability, PresenceAvailability.live);
      expect(skipper.controller.unavailableReason, isNull);
      expect(skipper.rosterIds, containsAll(['skipper', 'follower']));
      expect(skipper.presenceFor('follower')!.location, isNotNull);
      expect(
        skipper.presenceFor('follower')!.freshness,
        PresenceFreshness.live,
      );
    },
  );

  test('one unreadable position does not hide the others', () async {
    final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('follower', 'Alex', 'sailor');
    await follower.start();
    await follower.publish(51.3);
    relay.injectUnreadablePosition = true;

    await skipper.start();

    expect(skipper.controller.availability, PresenceAvailability.live);
    expect(skipper.presenceFor('follower')!.location, isNotNull);
    final limitation = skipper.controller.limitations.singleWhere(
      (entry) => entry.kind == PresenceLimitationKind.positionsUnreadable,
    );
    expect(limitation.message, contains('could not be read'));
  });

  test('the relay clock offset is measured and reported', () async {
    final skipper = device(
      'skipper',
      'Lead',
      role: VoyageRole.lead,
      clockOffset: const Duration(seconds: -45),
    );
    await skipper.start();

    // The relay is 45 seconds ahead of this phone.
    expect(skipper.controller.relayClockOffset.inSeconds, 45);
  });

  test(
    'a position stops being retained on the relay clock, not the peer\'s',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: -10),
      );
      relay.join('follower', 'Alex', 'sailor');
      await follower.start();
      await follower.publish(51.3);
      await skipper.start();

      // Ten minutes of clock error is well past the five-minute retention window,
      // yet the position arrived seconds ago on the relay's clock.
      expect(skipper.presenceFor('follower')!.location, isNotNull);
      expect(skipper.controller.internetLocations, isNotEmpty);
    },
  );
}

class _Device {
  _Device(
    this.sailorId,
    this.displayName,
    this.role,
    this.clockOffset,
    this.relay,
  ) : controller = PreStartPresenceController(
        HttpPreStartPresenceClient(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example/api'),
          ),
          client: MockClient(relay.handle),
          clock: () => relay.serverNow.add(clockOffset),
        ),
        pollInterval: const Duration(days: 1),
        clock: () => relay.serverNow.add(clockOffset),
      );

  final String sailorId;
  final String displayName;
  final VoyageRole role;

  /// This phone's clock minus the relay's.
  final Duration clockOffset;
  final _Relay relay;
  final PreStartPresenceController controller;

  DateTime get now => relay.serverNow.add(clockOffset);

  VoyageSession get session => VoyageSession(
    voyageId: 'voyage-clock-skew',
    voyageCode: '123456',
    inviteSecret: '0123456789abcdef0123456789abcdef',
    joinToken: 'test-join-token-0123456789',
    localSailorId: sailorId,
    displayName: displayName,
    role: role,
    joinedAt: now,
  );

  late final VoyageSession _session = session;

  Future<void> start() => controller.start(_session);

  Future<void> synchronize() => controller.synchronizeNow();

  Future<void> publish(double latitude) async {
    controller.updateLocalPosition(
      SailorLocation(
        sailorId: sailorId,
        displayName: displayName,
        role: role,
        sample: LocationSample(
          position: GeoPoint(latitude: latitude, longitude: -2.4),
          recordedAt: now,
          accuracyMeters: 5,
        ),
        receivedAt: now,
      ),
    );
    await controller.synchronizeNow();
  }

  LiveSailorPresence? presenceFor(String sailorId) => controller
      .presenceAt(now)
      .where((entry) => entry.sailorId == sailorId)
      .firstOrNull;

  Iterable<String> get rosterIds =>
      controller.roster.map((member) => member.sailorId);

  /// The roster row this device would show, from the one reconciled model.
  VoyageParticipant participantFor(String sailorId) =>
      const VoyageMembershipReducer()
          .fromEvents(
            voyageId: _session.voyageId,
            inviteSecret: _session.inviteSecret,
            events: const [],
            now: now,
            localSailorId: _session.localSailorId,
            localDisplayName: _session.displayName,
            localRole: _session.role,
            localJoinedAt: _session.joinedAt,
            localVesselStyle: _session.vesselStyle,
            localSailorColor: _session.sailorColor,
            voyageStartedAt: now.subtract(const Duration(minutes: 30)),
            livePresence: controller.presenceAt(now),
          )
          .firstWhere((participant) => participant.sailorId == sailorId);
}

/// A fake relay that stamps arrivals and reports its own clock, exactly as
/// `apps/server` does.
class _Relay {
  DateTime serverNow = DateTime.utc(2026, 7, 26, 12);
  Duration ttl = const Duration(seconds: 45);
  bool started = false;
  bool injectUnreadablePosition = false;
  final Map<String, Map<String, Object?>> _positions = {};
  final List<Map<String, Object?>> _members = [];

  void startVoyage() => started = true;

  void join(String sailorId, String displayName, String role) => _members.add({
    'sailorId': sailorId,
    'displayName': displayName,
    'role': role,
    'joinedAt': serverNow.toIso8601String(),
    'left': false,
  });

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/v1/compatibility')) {
      return http.Response(
        jsonEncode({
          'serverProtocol': 1,
          'minimumClientProtocol': 1,
          'maximumClientProtocol': 1,
          'capabilities': RelayProtocolCapabilities.current.toList(),
          'requiredCapabilities': <String>[],
          'cacheSeconds': 300,
          'updateUrls': {'default': 'https://tideandseek.invalid'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final sailorId = body['deviceId']! as String;
    final position = body['position'];
    _positions.removeWhere(
      (_, row) =>
          !DateTime.parse(row['expiresAt']! as String).isAfter(serverNow),
    );
    if (body['clear'] == true) {
      _positions.remove(sailorId);
    } else if (position is Map) {
      _positions[sailorId] = {
        ...Map<String, Object?>.from(position),
        'sailorId': sailorId,
        // The relay's own stamps, on the relay's own clock.
        'receivedAt': serverNow.toIso8601String(),
        'expiresAt': serverNow.add(ttl).toIso8601String(),
        'livePresence': true,
        'clientProtocol': 1,
      };
    }
    return http.Response(
      jsonEncode({
        'protocolVersion': 1,
        'ttlSeconds': ttl.inSeconds,
        'phase': started ? 'started' : 'open',
        'members': _members,
        'serverTime': serverNow.toIso8601String(),
        'positions': [
          ..._positions.values,
          if (injectUnreadablePosition) {'sailorId': 'broken'},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
