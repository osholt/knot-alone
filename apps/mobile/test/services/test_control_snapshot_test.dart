import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';
import 'package:tide_and_seek/services/test_control_snapshot.dart';

/// `voyage_live_view_test.dart` asserts the app's own roster/marker agreement for
/// issue #132. These tests assert that the **driven** surface reports that same
/// disagreement instead of hiding it.
///
/// This matters because the whole value of automating step 8b is that the machine
/// notices what a tired person at a bench would not. A snapshot that merged the
/// roster and the presence channel into one tidy list would have reported a
/// healthy voyage throughout the #132 field failure, and the automation would have
/// been worse than useless - it would have manufactured false evidence.
void main() {
  final now = DateTime.utc(2026, 7, 31, 12);

  test(
    'a sailor with a position is reported as placed, and the gate holds',
    () {
      final result = TestControlSnapshot.reconcile(
        [_participant('r1'), _participant('r2')],
        [
          _presence('r1', location: _location('r1', now)),
          _presence('r2', location: _location('r2', now)),
        ],
      );

      expect(result['rosterCount'], 2);
      expect(result['withPosition'], ['r1', 'r2']);
      expect(result['countedWithoutPositionOrReason'], isEmpty);
      expect(result['gateSatisfied'], isTrue);
    },
  );

  test('a sailor with no position but a presence row still satisfies the '
      'gate', () {
    // A stale or not-yet-fixed sailor is fine: their row can say why. The pass
    // gate is about sailors with neither a position nor a reason.
    final result = TestControlSnapshot.reconcile(
      [_participant('r1'), _participant('r2')],
      [
        _presence('r1', location: _location('r1', now)),
        _presence('r2', freshness: PresenceFreshness.stale),
      ],
    );

    expect(result['withPosition'], ['r1']);
    expect(result['withoutPositionButExplained'], ['r2']);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(result['gateSatisfied'], isTrue);
  });

  test('the #132 signature is reported, not smoothed away', () {
    // The exact field failure: the roster counts two sailors, the presence
    // channel knows about one. The second sailor is counted with no position and
    // no row to explain it.
    final result = TestControlSnapshot.reconcile(
      [
        _participant('r1'),
        // Has reported a position before, so its absence from the presence
        // channel is a loss rather than a startup state.
        _participant(
          'r2',
          state: VoyageMembershipState.inactive,
          lastKnownLocation: _location('r2', now),
        ),
      ],
      [_presence('r1', location: _location('r1', now))],
    );

    expect(result['rosterCount'], 2);
    expect(result['presenceCount'], 1);
    expect(
      result['countedWithoutPositionOrReason'],
      ['r2'],
      reason: 'the counted-but-unplaced sailor must be named',
    );
    expect(
      result['gateSatisfied'],
      isFalse,
      reason: 'a driven test must fail here, not report a healthy voyage',
    );
  });

  test('the mirror-image fault is reported too', () {
    // A marker drawn for somebody the roster does not admit to. Less commonly
    // seen than #132 but the same class of divergence, and a driven run should
    // not have to notice it by eye.
    final result = TestControlSnapshot.reconcile(
      [_participant('r1')],
      [
        _presence('r1', location: _location('r1', now)),
        _presence('ghost', location: _location('ghost', now)),
      ],
    );

    expect(result['placedButNotInRoster'], ['ghost']);
    expect(result['gateSatisfied'], isFalse);
  });

  test('a departed sailor is excluded from the count rather than counted '
      'without a position', () {
    // #144: a sailor who has left stays in the roster until the voyage ends, but
    // must not be counted as a live sailor with no position - that would look
    // exactly like the #132 fault and send a driven test hunting a bug that is
    // not there.
    final result = TestControlSnapshot.reconcile(
      [
        _participant('r1'),
        _participant(
          'r2',
          leftAt: now,
          lastKnownLocation: _location('r2', now),
        ),
      ],
      [_presence('r1', location: _location('r1', now))],
    );

    expect(result['rosterCount'], 1);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(result['gateSatisfied'], isTrue);
  });

  test('a sailor who has never had a fix is starting up, not a fault', () {
    // Found by driving a real voyage: at /v1/voyage/start the skipper is in the
    // roster, the presence channel is empty and nobody has reported a position
    // yet. An earlier version failed the gate here, which would have reported a
    // #132 recurrence on a completely healthy voyage.
    final result = TestControlSnapshot.reconcile([
      _participant('r1'),
    ], const []);

    expect(result['rosterCount'], 1);
    expect(result['awaitingFirstFix'], ['r1']);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(
      result['gateSatisfied'],
      isTrue,
      reason: 'voyage start must not read as a bug',
    );
  });
}

VoyageParticipant _participant(
  String sailorId, {
  VoyageMembershipState state = VoyageMembershipState.active,
  DateTime? leftAt,
  SailorLocation? lastKnownLocation,
}) => VoyageParticipant(
  lastKnownLocation: lastKnownLocation,
  sailorId: sailorId,
  displayName: sailorId.toUpperCase(),
  role: VoyageRole.sailor,
  joinedAt: DateTime.utc(2026, 7, 31, 11),
  lastSeenAt: DateTime.utc(2026, 7, 31, 11, 59),
  leftAt: leftAt,
  state: state,
  motorcycleStyle: motorcycleIconStyleDefault,
  sailorColor: sailorColorDefault,
  transportEvidence: const {VoyageTransportEvidence.internetRelay},
  isLocal: false,
);

LiveSailorPresence _presence(
  String sailorId, {
  SailorLocation? location,
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveSailorPresence(
  sailorId: sailorId,
  displayName: sailorId.toUpperCase(),
  role: VoyageRole.sailor,
  freshness: location == null ? freshness : PresenceFreshness.live,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: DateTime.utc(2026, 7, 31, 11),
  location: location,
);

SailorLocation _location(String sailorId, DateTime at) => SailorLocation(
  sailorId: sailorId,
  displayName: sailorId.toUpperCase(),
  role: VoyageRole.sailor,
  sample: LocationSample(
    position: const GeoPoint(latitude: 51.2, longitude: -2.4),
    recordedAt: at,
    accuracyMeters: 5,
  ),
  receivedAt: at,
);
