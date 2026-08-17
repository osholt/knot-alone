import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/pre_start_presence_controller.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/relay/relay_presence.dart';

/// Two simulated devices sharing one relay, exercising the sequences from the
/// field report in issue #99: a joiner who could see the route but never the
/// skipper's advancing position, and a skipper who never saw the joiner join.
void main() {
  late _FakeRelay relay;
  late DateTime now;

  DateTime clock() => now;

  setUp(() {
    now = DateTime.utc(2026, 7, 25, 9);
    relay = _FakeRelay(clock);
  });

  _Device device(
    String sailorId,
    String name, {
    VoyageRole role = VoyageRole.sailor,
  }) {
    final session = _session(sailorId, name, role);
    final controller = PreStartPresenceController(
      relay.apiFor(sailorId),
      pollInterval: const Duration(days: 1),
      clock: clock,
    );
    addTearDown(controller.close);
    return _Device(session, controller, clock);
  }

  test('a sailor visible before the start stays visible across it', () async {
    final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('skipper', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'sailor');
    await skipper.start();
    await follower.start();

    await skipper.publish(51.0);
    await follower.publish(51.3);
    expect(follower.visibleSailorIds, containsAll(['skipper', 'follower']));
    expect(follower.controller.phase, VoyagePresencePhase.open);

    relay.startVoyage();
    now = now.add(const Duration(seconds: 4));
    await skipper.publish(51.001);
    await follower.synchronize();

    // No gap and no duplicate identity across `voyageStarted`.
    expect(follower.controller.phase, VoyagePresencePhase.started);
    expect(follower.visibleSailorIds, containsAll(['skipper', 'follower']));
    expect(follower.positionFor('skipper')!.sample.position.latitude, 51.001);
    expect(
      follower.presence.where((entry) => entry.sailorId == 'skipper').length,
      1,
    );
  });

  test(
    'the skipper sees a sailor who joins an already-started voyage',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      relay.join('skipper', 'Lead', 'lead');
      await skipper.start();
      relay.startVoyage();
      await skipper.publish(51.0);

      // The joiner arrives after the start and publishes one fix.
      final joiner = device('joiner', 'Bill');
      relay.join('joiner', 'Bill', 'sailor');
      await joiner.start();
      await joiner.publish(51.4);

      // The skipper polls presence only: no journal batch is involved.
      now = now.add(const Duration(seconds: 4));
      await skipper.synchronize();

      expect(skipper.rosterIds, containsAll(['skipper', 'joiner']));
      expect(skipper.visibleSailorIds, contains('joiner'));
      expect(skipper.positionFor('joiner')!.displayName, 'Bill');
      expect(skipper.freshnessFor('joiner'), PresenceFreshness.live);
    },
  );

  test(
    'the joiner sees the skipper advancing, not one frozen position',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      relay.join('skipper', 'Lead', 'lead');
      await skipper.start();
      relay.startVoyage();
      final joiner = device('joiner', 'Bill');
      relay.join('joiner', 'Bill', 'sailor');
      await joiner.start();

      final observed = <double>[];
      for (var step = 0; step < 4; step += 1) {
        now = now.add(const Duration(seconds: 4));
        await skipper.publish(51.0 + step * 0.001);
        await joiner.synchronize();
        observed.add(joiner.positionFor('skipper')!.sample.position.latitude);
        expect(joiner.freshnessFor('skipper'), PresenceFreshness.live);
      }

      expect(observed, [51.0, 51.001, 51.002, 51.003]);
    },
  );

  test('a sailor who restarts the app rejoins without re-opting in', () async {
    final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
    relay.join('skipper', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'sailor');
    await skipper.start();
    relay.startVoyage();

    final first = device('follower', 'Alex');
    await first.start();
    await first.publish(51.2);
    now = now.add(const Duration(seconds: 2));
    await skipper.synchronize();
    expect(skipper.visibleSailorIds, contains('follower'));

    // A process restart drops every in-memory snapshot on that device.
    await first.controller.stop(clearRemote: false);
    final second = device('follower', 'Alex');
    await second.start();

    expect(second.rosterIds, containsAll(['skipper', 'follower']));
    await second.publish(51.21);
    now = now.add(const Duration(seconds: 2));
    await skipper.synchronize();
    expect(skipper.positionFor('follower')!.sample.position.latitude, 51.21);
  });

  test('presence resumes by itself after a network loss', () async {
    final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('skipper', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'sailor');
    await skipper.start();
    await follower.start();
    relay.startVoyage();
    await skipper.publish(51.0);
    await follower.synchronize();
    expect(follower.visibleSailorIds, contains('skipper'));

    relay.offline = true;
    now = now.add(const Duration(seconds: 4));
    await follower.synchronize();
    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnreachable,
    );
    expect(
      follower.controller.unavailableReason,
      contains('cannot be reached'),
    );
    // A dropped connection must not blank the last known positions.
    expect(follower.visibleSailorIds, contains('skipper'));

    relay.offline = false;
    now = now.add(const Duration(seconds: 4));
    await skipper.publish(51.005);
    await follower.synchronize();

    expect(follower.controller.availability, PresenceAvailability.live);
    expect(follower.positionFor('skipper')!.sample.position.latitude, 51.005);
    expect(follower.controller.unavailableReason, isNull);
    expect(follower.controller.limitations, isEmpty);
  });

  test(
    'a position that stops updating ages, goes stale, then disappears',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      final follower = device('follower', 'Alex');
      relay.join('skipper', 'Lead', 'lead');
      await skipper.start();
      await follower.start();
      await skipper.publish(51.0);
      await follower.synchronize();
      expect(follower.freshnessFor('skipper'), PresenceFreshness.live);

      // The skipper stops reporting. The relay's own TTL removes the row, but the
      // follower keeps demoting what it last saw rather than blinking it out.
      now = now.add(const Duration(seconds: 30));
      await follower.synchronize();
      expect(follower.freshnessFor('skipper'), PresenceFreshness.ageing);

      now = now.add(const Duration(seconds: 45));
      await follower.synchronize();
      expect(follower.freshnessFor('skipper'), PresenceFreshness.stale);
      expect(follower.positionFor('skipper'), isNotNull);

      // Past the ephemeral channel's retention window the cached snapshot is
      // released. The sailor is still named by the roster, now with an explicit
      // "no position" rather than a marker frozen at an old coordinate.
      now = now.add(const Duration(minutes: 6));
      await follower.synchronize();
      expect(follower.freshnessFor('skipper'), PresenceFreshness.none);
      expect(follower.positionFor('skipper'), isNull);
      expect(follower.rosterIds, contains('skipper'));
    },
  );

  test(
    'nearby presence covers a sailor the internet relay cannot see',
    () async {
      final follower = device('follower', 'Alex');
      final nearby = _FakeNearbyGateway();
      addTearDown(nearby.close);
      await follower.start();
      await follower.controller.attachNearby(nearby);

      nearby.emit(
        RelayPresenceUpdate(
          sailorId: 'peer',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: _location('peer', 'Sam', 51.9, now),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(follower.visibleSailorIds, contains('peer'));
      expect(
        follower.presence
            .firstWhere((entry) => entry.sailorId == 'peer')
            .sources,
        {LivePresenceSource.nearbyPresence},
      );
      expect(follower.controller.nearbyLocations.single.sailorId, 'peer');
      expect(follower.controller.internetLocations, isEmpty);
    },
  );

  test('an out-of-order relay reply cannot rewind a sailor', () async {
    final follower = device('follower', 'Alex');
    await follower.start();
    relay.publish('skipper', 'Lead', 52.0, now);
    await follower.synchronize();
    expect(follower.positionFor('skipper')!.sample.position.latitude, 52.0);

    // A delayed reply carrying an older sample for the same sailor.
    relay.publish(
      'skipper',
      'Lead',
      51.0,
      now.subtract(const Duration(seconds: 30)),
    );
    await follower.synchronize();

    expect(follower.positionFor('skipper')!.sample.position.latitude, 52.0);
  });

  test('a service without the capability produces a named state', () async {
    relay.capabilities = const {'voyage-start-v1'};
    final follower = device('follower', 'Alex');

    await follower.start();

    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnsupported,
    );
    expect(follower.controller.supported, isFalse);
    expect(
      follower.controller.limitations.single.kind,
      PresenceLimitationKind.serviceCapabilityMissing,
    );
    expect(follower.controller.unavailableReason, contains('does not support'));
  });

  test(
    'nearby presence still works when the relay lacks the capability',
    () async {
      relay.capabilities = const {'voyage-start-v1'};
      final follower = device('follower', 'Alex');
      final nearby = _FakeNearbyGateway();
      addTearDown(nearby.close);
      await follower.start();
      await follower.controller.attachNearby(nearby);

      expect(follower.controller.supported, isTrue);
      nearby.emit(
        RelayPresenceUpdate(
          sailorId: 'peer',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: _location('peer', 'Sam', 51.9, now),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(follower.visibleSailorIds, contains('peer'));
    },
  );

  test('a legacy peer is named rather than silently missing', () async {
    final follower = device('follower', 'Alex');
    relay.join('bill', 'Bill', 'sailor');
    relay.publish('bill', 'Bill', 51.7, now, livePresence: false);

    await follower.start();

    final limitation = follower.controller.limitations.single;
    expect(limitation.kind, PresenceLimitationKind.peerAppOlder);
    expect(limitation.sailorId, 'bill');
    expect(limitation.message, contains('Bill'));
    // The peer is still shown while their build can publish.
    expect(follower.visibleSailorIds, contains('bill'));
  });

  test(
    'an older relay without a phase field still carries positions',
    () async {
      relay.capabilities = const {'pre-start-presence-v1'};
      relay.reportPhase = false;
      relay.reportMembers = false;
      final follower = device('follower', 'Alex');
      relay.publish('skipper', 'Lead', 51.0, now);

      await follower.start();

      expect(follower.controller.availability, PresenceAvailability.live);
      expect(follower.controller.phase, VoyagePresencePhase.unknown);
      expect(follower.controller.roster, isEmpty);
      expect(follower.visibleSailorIds, contains('skipper'));
    },
  );

  test('a rejected voyage credential is reported as unauthorized', () async {
    relay.unauthorized = true;
    final follower = device('follower', 'Alex');

    await follower.start();

    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnauthorized,
    );
    expect(follower.controller.unavailableReason, contains('rejected'));
  });

  test(
    'stopping clears this device from the relay and its peer demotes it',
    () async {
      final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
      final follower = device('follower', 'Alex');
      await skipper.start();
      await follower.start();
      await skipper.publish(51.0);
      await follower.synchronize();
      expect(follower.visibleSailorIds, contains('skipper'));

      await skipper.controller.stop();
      expect(skipper.controller.availability, PresenceAvailability.stopped);
      expect(skipper.controller.locations, isEmpty);

      // The peer keeps the last position and demotes it. A marker that silently
      // vanishes is indistinguishable from one that was never there.
      now = now.add(const Duration(seconds: 90));
      await follower.synchronize();
      expect(follower.freshnessFor('skipper'), PresenceFreshness.stale);

      now = now.add(const Duration(minutes: 6));
      await follower.synchronize();
      expect(follower.visibleSailorIds, isNot(contains('skipper')));
    },
  );

  test('an explicit departure removes a sailor immediately', () async {
    final skipper = device('skipper', 'Lead', role: VoyageRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('skipper', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'sailor');
    await skipper.start();
    await follower.start();
    await skipper.publish(51.0);
    await follower.synchronize();
    expect(follower.visibleSailorIds, contains('skipper'));

    relay.leave('skipper');
    now = now.add(const Duration(seconds: 4));
    await follower.synchronize();

    expect(follower.visibleSailorIds, isNot(contains('skipper')));
    expect(
      follower.presence.map((entry) => entry.sailorId),
      isNot(contains('skipper')),
    );
  });
}

class _Device {
  _Device(this.session, this.controller, this._clock);

  final VoyageSession session;
  final PreStartPresenceController controller;
  final DateTime Function() _clock;

  Future<void> start() => controller.start(session);

  Future<void> synchronize() => controller.synchronizeNow();

  Future<void> publish(double latitude) async {
    controller.updateLocalPosition(
      _location(
        session.localSailorId,
        session.displayName,
        latitude,
        _clock(),
        role: session.role,
      ),
    );
    await controller.synchronizeNow();
  }

  List<LiveSailorPresence> get presence => controller.presenceAt(_clock());

  Iterable<String> get visibleSailorIds =>
      controller.locations.map((location) => location.sailorId);

  Iterable<String> get rosterIds =>
      controller.roster.map((member) => member.sailorId);

  SailorLocation? positionFor(String sailorId) => controller.locations
      .where((location) => location.sailorId == sailorId)
      .firstOrNull;

  PresenceFreshness? freshnessFor(String sailorId) => presence
      .where((entry) => entry.sailorId == sailorId)
      .firstOrNull
      ?.freshness;
}

/// A shared relay both devices talk to, implementing the same rules as the
/// FastAPI service: replace-only positions, a TTL, a phase, and a roster derived
/// from membership rather than from any caller's cursor.
class _FakeRelay {
  _FakeRelay(this._clock);

  final DateTime Function() _clock;
  final Map<String, _StoredPosition> _positions = {};
  final List<PresenceRosterEntry> _members = [];
  Set<String> capabilities = RelayProtocolCapabilities.current;
  Duration ttl = const Duration(seconds: 45);
  VoyagePresencePhase phase = VoyagePresencePhase.open;
  bool reportPhase = true;
  bool reportMembers = true;
  bool offline = false;
  bool unauthorized = false;

  PreStartPresenceApi apiFor(String sailorId) => _FakeRelayApi(this, sailorId);

  void startVoyage() => phase = VoyagePresencePhase.started;

  void join(String sailorId, String displayName, String role) {
    _members
      ..removeWhere((member) => member.sailorId == sailorId)
      ..add(
        PresenceRosterEntry(
          sailorId: sailorId,
          displayName: displayName,
          role: role,
          joinedAt: _clock(),
        ),
      );
  }

  void leave(String sailorId) {
    for (var index = 0; index < _members.length; index += 1) {
      final member = _members[index];
      if (member.sailorId != sailorId) continue;
      _members[index] = PresenceRosterEntry(
        sailorId: member.sailorId,
        displayName: member.displayName,
        role: member.role,
        joinedAt: member.joinedAt,
        left: true,
      );
    }
  }

  void publish(
    String sailorId,
    String displayName,
    double latitude,
    DateTime recordedAt, {
    bool livePresence = true,
  }) {
    _positions[sailorId] = _StoredPosition(
      location: _location(sailorId, displayName, latitude, recordedAt),
      expiresAt: _clock().add(ttl),
      livePresence: livePresence,
    );
  }

  PreStartPresenceResult handle({
    required String sailorId,
    required SailorLocation? position,
    required bool clear,
  }) {
    if (offline) {
      throw const InternetRelayException(
        'Live positions are temporarily unavailable.',
        retryable: true,
      );
    }
    if (unauthorized) {
      throw const InternetRelayException(
        'The voyage service rejected this voyage credential.',
        unauthorized: true,
      );
    }
    final servesLive = capabilities.contains(
      RelayProtocolCapabilities.livePresence,
    );
    if (!servesLive &&
        !capabilities.contains(RelayProtocolCapabilities.preStartPresence)) {
      throw const InternetRelayException(
        'This voyage service does not support live sailor positions yet.',
        code: 'feature_unsupported',
      );
    }
    final now = _clock();
    _positions.removeWhere((_, stored) => !stored.expiresAt.isAfter(now));
    if (phase == VoyagePresencePhase.ended) {
      _positions.clear();
    } else if (clear) {
      _positions.remove(sailorId);
    } else if (position != null) {
      _positions[sailorId] = _StoredPosition(
        location: position,
        expiresAt: now.add(ttl),
        livePresence: servesLive,
      );
    }
    final visible = phase == VoyagePresencePhase.started && !servesLive
        ? const <_StoredPosition>[]
        : _positions.values.toList(growable: false);
    return PreStartPresenceResult(
      locations: [for (final stored in visible) stored.location],
      ttl: ttl,
      phase: reportPhase ? phase : VoyagePresencePhase.unknown,
      roster: reportMembers && servesLive
          ? List.of(_members)
          : const <PresenceRosterEntry>[],
      legacyPeerSailorIds: {
        for (final stored in visible)
          if (!stored.livePresence) stored.location.sailorId,
      },
      livePresenceServed: servesLive,
    );
  }
}

class _StoredPosition {
  const _StoredPosition({
    required this.location,
    required this.expiresAt,
    required this.livePresence,
  });

  final SailorLocation location;
  final DateTime expiresAt;
  final bool livePresence;
}

class _FakeRelayApi implements PreStartPresenceApi {
  _FakeRelayApi(this._relay, this._sailorId);

  final _FakeRelay _relay;
  final String _sailorId;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required VoyageSession session,
    required SailorLocation? position,
    required bool clear,
  }) async =>
      _relay.handle(sailorId: _sailorId, position: position, clear: clear);

  @override
  void close() {}
}

class _FakeNearbyGateway implements RelayPresenceGateway {
  final _updates = StreamController<RelayPresenceUpdate>.broadcast();
  final List<({SailorLocation? position, bool clear, Duration ttl})> published =
      [];

  @override
  Stream<RelayPresenceUpdate> get presenceUpdates => _updates.stream;

  void emit(RelayPresenceUpdate update) => _updates.add(update);

  @override
  Future<void> publishPresence(
    SailorLocation? position, {
    bool clear = false,
    Duration ttl = const Duration(seconds: 45),
  }) async {
    published.add((position: position, clear: clear, ttl: ttl));
  }

  Future<void> close() => _updates.close();
}

VoyageSession _session(String sailorId, String name, VoyageRole role) =>
    VoyageSession(
      voyageId: 'voyage-live-presence',
      voyageCode: '123456',
      inviteSecret: '0123456789abcdef0123456789abcdef',
      joinToken: 'test-join-token-0123456789',
      localSailorId: sailorId,
      displayName: name,
      role: role,
      joinedAt: DateTime.utc(2026, 7, 25, 9),
    );

SailorLocation _location(
  String sailorId,
  String displayName,
  double latitude,
  DateTime recordedAt, {
  VoyageRole role = VoyageRole.sailor,
}) => SailorLocation(
  sailorId: sailorId,
  displayName: displayName,
  role: role,
  sample: LocationSample(
    position: GeoPoint(latitude: latitude, longitude: -2.4),
    recordedAt: recordedAt,
    accuracyMeters: 5,
  ),
  receivedAt: recordedAt,
);
