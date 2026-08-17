import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/sailor_color.dart';
import 'package:tide_and_seek/domain/sailor_location.dart';
import 'package:tide_and_seek/features/map/vessel_icon.dart';
import 'package:tide_and_seek/relay/live_presence.dart';
import 'package:tide_and_seek/services/voyage_membership.dart';

/// **From what moment is a sailor's position visible to the rest of the group?**
///
/// Decided for #300: **from the moment they join.** Before setting off is
/// exactly when a group is working out who has arrived and where they are, so
/// a map with no people on it is the map being useless when it is most looked
/// at.
///
/// The rule has two halves and they are deliberately carried by different
/// channels:
///
///  - **Presence makes a sailor visible.** Ephemeral, current position only, and
///    it runs across the `voyageStarted` transition, so a sailor gathering at the
///    meet point appears and stays visible when the voyage begins.
///  - **The journal records history, and history starts at Start voyage.** No
///    track point is written or transmitted before then; a sailor who joins an
///    hour early and voyages elsewhere first leaves no trace of it.
///    `situational_awareness_controller_test.dart` holds that half.
///
/// This existed as behaviour before it existed as a rule, which is why the
/// original report read as a bug. Written down here so a future change has to
/// disagree with it on purpose.
void main() {
  final now = DateTime.utc(2026, 8, 2, 9);

  SailorLocation locationFor(String sailorId, {DateTime? at}) => SailorLocation(
    sailorId: sailorId,
    displayName: sailorId,
    role: VoyageRole.sailor,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.4676, longitude: -2.5015),
      recordedAt: at ?? now,
      accuracyMeters: 5,
    ),
    receivedAt: at ?? now,
  );

  PresenceRosterMember rosterMember(String sailorId) => PresenceRosterMember(
    sailorId: sailorId,
    displayName: sailorId,
    role: VoyageRole.sailor,
    joinedAt: now,
  );

  VoyageParticipant participant(
    String sailorId, {
    VoyageMembershipState state = VoyageMembershipState.joined,
  }) => VoyageParticipant(
    sailorId: sailorId,
    displayName: sailorId,
    role: VoyageRole.sailor,
    joinedAt: now,
    lastSeenAt: now,
    state: state,
    vesselStyle: VesselIconStyle.sloop,
    sailorSymbol: sailorSymbolDefault,
    sailorColor: SailorColor.green,
    transportEvidence: const {VoyageTransportEvidence.internetRelay},
    isLocal: false,
  );

  /// The production render path for a real (non-simulated) voyage: presence is
  /// reconciled across its sources, then the live view decides who is drawn.
  /// `active_voyage_shell.dart` hands the result straight to the map.
  VoyageLiveView render({
    required List<SailorLocation> presencePositions,
    required List<VoyageParticipant> participants,
  }) => VoyageLiveView.reconcile(
    participants: participants,
    presence: const LivePresenceReconciler().reconcile(
      now: now,
      localSailorId: 'me',
      // Deliberately empty: before the voyage starts the journal has nothing in
      // it, and that is the point. Everything drawn here comes from presence.
      journal: const [],
      internetPresence: presencePositions,
      roster: [
        for (final sailor in participants) rosterMember(sailor.sailorId),
      ],
    ),
  );

  test('a sailor who has joined is drawn before the voyage starts', () {
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam')],
    );

    expect(view.renderedPositions.map((location) => location.sailorId), [
      'sam',
    ]);
  });

  test('every sailor in the pre-start count either has a position or a '
      'stated reason for not having one', () {
    // The invariant `VoyageLiveView` was built for (#132), which has to hold
    // before the start too or the pre-start map can count someone it refuses
    // to draw, with nothing said.
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam'), participant('alex')],
    );

    expect(view.participants, hasLength(2));
    expect(
      view.participants.every((sailor) => sailor.hasStatedPositionState),
      isTrue,
    );
    final alex = view.participants.firstWhere(
      (sailor) => sailor.sailorId == 'alex',
    );
    expect(alex.positionAbsence, VoyagePositionAbsence.noPositionReported);
  });

  test('a sailor who has left is not drawn, whenever they left', () {
    // A departure is authoritative in both phases. A lingering ephemeral
    // position must not resurrect someone who has gone home.
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam', state: VoyageMembershipState.left)],
    );

    expect(view.renderedPositions, isEmpty);
  });

  test('visibility does not wait for a route', () {
    // The original report was made with no GPX set. Nothing in this path reads
    // a route, and that is what the test is here to keep true (#124).
    final view = render(
      presencePositions: [locationFor('sam'), locationFor('alex')],
      participants: [participant('sam'), participant('alex')],
    );

    expect(view.renderedPositions, hasLength(2));
  });

  test('the same sailors stay drawn once the voyage starts', () {
    // Presence runs across the transition on purpose. Nobody may blink out at
    // the moment the skipper presses Start.
    final before = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam')],
    );
    final after = render(
      presencePositions: [
        locationFor('sam', at: now.add(const Duration(seconds: 30))),
      ],
      participants: [participant('sam', state: VoyageMembershipState.active)],
    );

    expect(
      after.renderedPositions.map((location) => location.sailorId),
      before.renderedPositions.map((location) => location.sailorId),
    );
  });
}
