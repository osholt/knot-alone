import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

/// Issue #132: the sailor count and the drawn markers were two separate
/// judgements of the same sailor, so a skipper could count a follower ("2 sailors")
/// and simultaneously show them inactive with no position and no explanation.
///
/// These tests assert the agreement itself: for one sailor set, the live count is
/// exactly the sailors with a rendered position plus the sailors with a stated
/// reason for having none. Nothing may fall between the two.
void main() {
  final now = DateTime.utc(2026, 7, 26, 12);

  test('every counted sailor is either rendered or stated, never neither', () {
    final view = VoyageLiveView.reconcile(
      participants: [
        _participant('skipper', 'Lead', role: VoyageRole.lead),
        _participant('follower', 'Alex'),
        _participant('sam', 'Sam'),
      ],
      presence: [
        _presence(
          'skipper',
          'Lead',
          location: _location('skipper', 'Lead', now),
        ),
        _presence(
          'follower',
          'Alex',
          location: _location('follower', 'Alex', now),
        ),
        // Named by the roster, no position yet.
        _presence('sam', 'Sam'),
      ],
    );

    expect(view.liveSailorCount, 3);
    expect(view.renderedPositions.map((position) => position.sailorId), [
      'skipper',
      'follower',
    ]);
    expect(view.countedWithoutPosition.map((entry) => entry.sailorId), ['sam']);
    expect(view.isReconciled, isTrue);
    for (final entry in view.countedWithoutPosition) {
      expect(entry.positionAbsence.label, isNotNull);
      expect(entry.hasStatedPositionState, isTrue);
    }
  });

  test('the field failure: counted, no marker, and a reason on the row', () {
    // The skipper counts two sailors and has no position for the follower. That
    // is allowed only while the reason is on the roster row.
    final view = VoyageLiveView.reconcile(
      participants: [
        _participant('skipper', 'Lead', role: VoyageRole.lead),
        _participant('follower', 'Alex', state: VoyageMembershipState.inactive),
      ],
      presence: [
        _presence(
          'skipper',
          'Lead',
          location: _location('skipper', 'Lead', now),
        ),
      ],
    );

    expect(view.liveSailorCount, 2);
    expect(view.renderedPositions.length, 1);
    final follower = view.countedWithoutPosition.single;
    expect(follower.sailorId, 'follower');
    expect(follower.positionAbsence, VoyagePositionAbsence.noPositionReported);
    expect(follower.stateLabel, contains('no position reported yet'));
    expect(view.isReconciled, isTrue);
  });

  test(
    'a transport that cannot deliver positions is blamed, not the sailor',
    () {
      final view = VoyageLiveView.reconcile(
        participants: [
          _participant('skipper', 'Lead', role: VoyageRole.lead),
          _participant('follower', 'Alex'),
        ],
        presence: const [],
        positionChannelUnavailable: true,
      );

      expect(view.liveSailorCount, 2);
      expect(view.renderedPositions, isEmpty);
      expect(
        view.countedWithoutPosition.map((entry) => entry.positionAbsence),
        everyElement(VoyagePositionAbsence.positionChannelUnavailable),
      );
      expect(
        view.countedWithoutPosition.first.stateLabel,
        contains('live positions paused on this phone'),
      );
    },
  );

  test('a sailor who has left is neither counted nor rendered', () {
    final view = VoyageLiveView.reconcile(
      participants: [
        _participant('skipper', 'Lead', role: VoyageRole.lead),
        _participant('gone', 'Gone', state: VoyageMembershipState.left),
      ],
      presence: [
        _presence(
          'skipper',
          'Lead',
          location: _location('skipper', 'Lead', now),
        ),
        // A lingering ephemeral position for a sailor who has left.
        _presence('gone', 'Gone', location: _location('gone', 'Gone', now)),
      ],
    );

    expect(view.liveSailorCount, 1);
    expect(view.renderedPositions.single.sailorId, 'skipper');
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
  });

  test('the record a departed sailor keeps is never drawn as a marker', () {
    // Issue #144 keeps the roster row and its last known position. That record
    // is readable and it is not a marker: the sailor is not there.
    final view = VoyageLiveView.reconcile(
      participants: [
        _participant('skipper', 'Lead', role: VoyageRole.lead),
        _participant(
          'gone',
          'Gone',
          state: VoyageMembershipState.left,
          lastKnownLocation: _location(
            'gone',
            'Gone',
            now.subtract(const Duration(minutes: 8)),
          ),
        ),
      ],
      presence: [
        _presence(
          'skipper',
          'Lead',
          location: _location('skipper', 'Lead', now),
        ),
      ],
    );

    expect(view.liveSailorCount, 1);
    expect(view.renderedPositions.map((position) => position.sailorId), [
      'skipper',
    ]);
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
    final gone = view.participants.singleWhere(
      (participant) => participant.sailorId == 'gone',
    );
    expect(gone.lastKnownPositionLabel, contains('51.20000, -2.40000'));
    expect(gone.isEligibleForLivePosition, isFalse);
    expect(gone.hasStatedPositionState, isTrue);
  });

  test('a stale position is still rendered, and still counted', () {
    final view = VoyageLiveView.reconcile(
      participants: [
        _participant('skipper', 'Lead', role: VoyageRole.lead),
        _participant('follower', 'Alex', state: VoyageMembershipState.inactive),
      ],
      presence: [
        _presence(
          'skipper',
          'Lead',
          location: _location('skipper', 'Lead', now),
        ),
        _presence(
          'follower',
          'Alex',
          freshness: PresenceFreshness.stale,
          location: _location(
            'follower',
            'Alex',
            now.subtract(const Duration(minutes: 3)),
          ),
        ),
      ],
    );

    expect(view.liveSailorCount, 2);
    expect(view.renderedPositions.length, 2);
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
  });
}

VoyageParticipant _participant(
  String sailorId,
  String displayName, {
  VoyageRole role = VoyageRole.sailor,
  VoyageMembershipState state = VoyageMembershipState.active,
  SailorLocation? lastKnownLocation,
}) => VoyageParticipant(
  lastKnownLocation: lastKnownLocation,
  sailorId: sailorId,
  displayName: displayName,
  role: role,
  joinedAt: DateTime.utc(2026, 7, 26, 11),
  lastSeenAt: DateTime.utc(2026, 7, 26, 12),
  state: state,
  motorcycleStyle: motorcycleIconStyleDefault,
  sailorColor: sailorColorDefault,
  transportEvidence: const {VoyageTransportEvidence.internetRelay},
  isLocal: false,
);

LiveSailorPresence _presence(
  String sailorId,
  String displayName, {
  SailorLocation? location,
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveSailorPresence(
  sailorId: sailorId,
  displayName: displayName,
  role: VoyageRole.sailor,
  freshness: location == null ? PresenceFreshness.none : freshness,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: DateTime.utc(2026, 7, 26, 11),
  location: location,
);

SailorLocation _location(String sailorId, String displayName, DateTime at) =>
    SailorLocation(
      sailorId: sailorId,
      displayName: displayName,
      role: VoyageRole.sailor,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.2, longitude: -2.4),
        recordedAt: at,
        accuracyMeters: 5,
      ),
      receivedAt: at,
    );
