import '../domain/voyage_role.dart';
import '../domain/sailor_color.dart';
import '../domain/sailor_location.dart';
import '../features/map/motorcycle_icon.dart';

/// How old a sailor's newest position is, in states a sailor can act on.
///
/// Thresholds are deliberately explicit and shared by every surface so a map
/// marker, the roster and a vehicle head unit cannot disagree about whether a
/// position is trustworthy. A [stale] position is still retained so it can be
/// visibly demoted rather than silently disappearing, which is the difference
/// between "I can see he has stopped reporting" and "he vanished".
enum PresenceFreshness {
  /// Reported within [PresenceFreshnessPolicy.liveWithin].
  live,

  /// Older than [PresenceFreshnessPolicy.liveWithin] but still within
  /// [PresenceFreshnessPolicy.ageingWithin].
  ageing,

  /// Older than [PresenceFreshnessPolicy.ageingWithin].
  ///
  /// Still drawn: where a sailor stopped is exactly what the group needs in
  /// order to go back for them. It is demoted in wording and colour so it can
  /// never be mistaken for a current position.
  stale,

  /// No position at all — the sailor is in the voyage but nothing has arrived.
  none,
}

extension PresenceFreshnessLabels on PresenceFreshness {
  /// Wording that never relies on colour alone.
  String get label => switch (this) {
    PresenceFreshness.live => 'Live',
    PresenceFreshness.ageing => 'Ageing',
    PresenceFreshness.stale => 'Stale',
    PresenceFreshness.none => 'No position',
  };

  bool get isTrustworthy => this == PresenceFreshness.live;

  /// True when the position is recent enough to count as current proof that the
  /// sailor is reachable. A stale position is evidence of a past fix only.
  bool get isTrackedAsContact =>
      this == PresenceFreshness.live || this == PresenceFreshness.ageing;
}

/// Which clock a position's age was measured on.
///
/// Two phones do not share a clock, so ageing a peer's position by this
/// device's clock minus the *peer's* own timestamp measures the difference
/// between two clocks as well as the age. A relay-stamped arrival time and the
/// relay's own current time are one clock, so they can be subtracted honestly.
enum PresenceClockBasis {
  /// Aged on the relay's clock: its arrival stamp against its current time.
  sharedRelayClock,

  /// Aged on this device's clock against the publisher's own timestamp. Correct
  /// for this phone's own fixes; for a peer it is only as good as their clock.
  publisherClock,
}

extension PresenceClockBasisLabels on PresenceClockBasis {
  String get label => switch (this) {
    PresenceClockBasis.sharedRelayClock => 'Timed by the voyage service',
    PresenceClockBasis.publisherClock => "Timed by the sailor's own phone",
  };
}

/// The documented age thresholds for [PresenceFreshness].
class PresenceFreshnessPolicy {
  const PresenceFreshnessPolicy({
    this.liveWithin = const Duration(seconds: 20),
    this.ageingWithin = const Duration(seconds: 60),
    this.retainFor = const Duration(minutes: 5),
    this.publisherClockTolerance = const Duration(seconds: 30),
  });

  /// A position at most this old is [PresenceFreshness.live].
  final Duration liveWithin;

  /// A position at most this old is [PresenceFreshness.ageing]; anything older
  /// is [PresenceFreshness.stale].
  final Duration ageingWithin;

  /// How long the *ephemeral* presence channels keep reporting a snapshot after
  /// it stops being refreshed.
  ///
  /// This bounds an in-memory cache; it is not a rule for hiding positions. A
  /// stale position is demoted, never deleted — deleting it would turn "he
  /// stopped moving here" into "he was never here", which is the failure this
  /// whole model exists to remove.
  final Duration retainFor;

  /// How far a publisher's own timestamp may sit from the relay's arrival stamp
  /// before that phone's clock is treated as untrustworthy rather than its
  /// position as old. Beyond this the disagreement is stated in words; it never
  /// ages a reporting sailor out silently.
  final Duration publisherClockTolerance;

  PresenceFreshness classify(Duration age) {
    final bounded = age.isNegative ? Duration.zero : age;
    if (bounded <= liveWithin) return PresenceFreshness.live;
    if (bounded <= ageingWithin) return PresenceFreshness.ageing;
    return PresenceFreshness.stale;
  }
}

/// Which channel produced a position. A sailor can be corroborated by more than
/// one at a time; that is evidence of reachability, not a conflict.
enum LivePresenceSource {
  /// This phone's own GPS.
  localDevice,

  /// The ephemeral, non-journalled presence channel over the internet relay.
  internetPresence,

  /// The ephemeral, non-journalled presence channel over the nearby relay.
  nearbyPresence,

  /// A durable `sailorLocationUpdated` event from the offline-first journal.
  journal,
}

extension LivePresenceSourceLabels on LivePresenceSource {
  String get label => switch (this) {
    LivePresenceSource.localDevice => 'This phone',
    LivePresenceSource.internetPresence => 'Internet presence',
    LivePresenceSource.nearbyPresence => 'Nearby presence',
    LivePresenceSource.journal => 'Voyage journal',
  };
}

/// A sailor the transport says is in the voyage, learned without waiting for the
/// bulk event batch.
///
/// This is advisory: the durable journal stays authoritative for identity and
/// role. A roster member exists so a wedged or backed-off batch sync cannot
/// hide a participant who is demonstrably reachable.
class PresenceRosterMember {
  const PresenceRosterMember({
    required this.sailorId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.left = false,
    this.leftAt,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.sailorSymbol = sailorSymbolDefault,
    this.sailorColor = sailorColorDefault,
  });

  final String sailorId;
  final String displayName;
  final VoyageRole role;
  final DateTime joinedAt;
  final bool left;

  /// When the relay recorded this sailor's departure, when it reports it.
  ///
  /// Null from a relay that does not, in which case the departure is still
  /// authoritative but cannot be ordered against a later rejoin, so the roster
  /// may only add a departed row it alone knows about (#144).
  final DateTime? leftAt;
  final MotorcycleIconStyle motorcycleStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;
}

/// One sailor's reconciled live state, spanning both voyage phases and every
/// transport.
class LiveSailorPresence {
  const LiveSailorPresence({
    required this.sailorId,
    required this.displayName,
    required this.role,
    required this.freshness,
    required this.sources,
    required this.isLocal,
    required this.knownSince,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.sailorSymbol = sailorSymbolDefault,
    this.sailorColor = sailorColorDefault,
    this.location,
    this.age,
    this.contactAt,
    this.clockBasis = PresenceClockBasis.publisherClock,
    this.publisherClockOffset,
  });

  final String sailorId;
  final String displayName;
  final VoyageRole role;
  final PresenceFreshness freshness;
  final Set<LivePresenceSource> sources;
  final bool isLocal;

  /// The earliest moment this sailor is known to have been in the voyage, from the
  /// roster when the transport supplies it and otherwise from their oldest
  /// observed sample. Deterministic so a recomputed roster does not reorder.
  final DateTime knownSince;
  final MotorcycleIconStyle motorcycleStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;

  /// The newest position for this sailor, or null when there is none worth
  /// drawing. Never a position older than
  /// [PresenceFreshnessPolicy.retainFor].
  final SailorLocation? location;

  /// Age of [location] at the moment of reconciliation.
  final Duration? age;

  /// When this sailor was last demonstrably in contact, expressed on **this**
  /// device's clock. Null when nothing has been heard from them at all.
  ///
  /// Deliberately not interchangeable with the age of [location], even though
  /// today both are derived from the newest position that arrived. Position
  /// reports are driven by distance travelled with a keep-alive on a timer
  /// (#166), so a sailor stopped at a set of lights keeps proving they are there
  /// while their position correctly stops changing. Anything judging *whether a
  /// sailor is present* must read this; anything judging *how current their
  /// position is* must read [age].
  final DateTime? contactAt;

  /// Which clock [age] and [contactAt] were measured on.
  final PresenceClockBasis clockBasis;

  /// How far the publisher's own timestamp sits behind the relay's arrival stamp
  /// for [location], when the relay stamped it. Positive means the publisher's
  /// phone clock is behind the relay's.
  ///
  /// This is the difference between two clocks, not an age. It exists so a
  /// sailor whose clock is wrong is *told* that, instead of being aged out as if
  /// they had stopped reporting.
  final Duration? publisherClockOffset;

  /// True when the publisher's clock disagrees with the relay's by more than the
  /// policy tolerates, so their own timestamps cannot be used to judge freshness.
  bool get publisherClockUntrusted => publisherClockOffset != null;

  bool get hasPosition => location != null;

  /// Plain wording for a roster row or marker label. Never colour-only.
  String get freshnessLabel {
    final currentAge = age;
    if (freshness == PresenceFreshness.none || currentAge == null) {
      return PresenceFreshness.none.label;
    }
    if (freshness == PresenceFreshness.live) {
      return PresenceFreshness.live.label;
    }
    return '${freshness.label} ${formatPresenceAge(currentAge)}';
  }
}

/// Compact, human age used in marker labels and roster rows.
String formatPresenceAge(Duration age) {
  final seconds = age.isNegative ? 0 : age.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = age.inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${age.inHours}h';
}

/// Every reason live sailor state can be incomplete, as a named state rather
/// than an empty map.
enum PresenceLimitationKind {
  /// The configured voyage service does not advertise the presence capability.
  serviceCapabilityMissing,

  /// The voyage service is reachable but presence requests are failing.
  serviceUnreachable,

  /// The voyage credential was rejected for presence.
  serviceUnauthorized,

  /// This app is older than the voyage service requires.
  clientUpdateRequired,

  /// The voyage service is older than this app.
  serviceUpgradeRequired,

  /// A peer's app is too old to publish continuous live positions.
  peerAppOlder,

  /// A peer's phone clock disagrees with the voyage service, so their own
  /// timestamps cannot be used to judge how fresh their position is.
  sailorClockUntrusted,

  /// Live positions arrived but could not be read, so they were skipped rather
  /// than discarding the whole reply.
  positionsUnreadable,

  /// Events this app does not understand arrived and were ignored.
  unsupportedEventsIgnored,

  /// Events could not be uploaded because the service lacks the capability.
  uploadCapabilityMissing,

  /// An event the service refuses was set aside so the rest of the voyage keeps
  /// flowing.
  uploadQuarantined,

  /// The voyage service cannot carry a skipper-issued Sweeper request, so
  /// the role has to be taken by the sailor themselves.
  sweeperAssignmentUnsupportedByService,

  /// A named sailor's app cannot read a skipper-issued Sweeper request.
  sweeperAssignmentUnsupportedByPeer,

  /// The voyage service cannot carry a sailor's rejoin route to the skipper.
  rejoinSharingUnsupportedByService,

  /// The voyage service cannot carry a sailor's own phone number to the voyage's
  /// coordination roles, so nothing was shared.
  sailorContactSharingUnsupportedByService,
}

/// A single named, user-readable limitation.
///
/// [message] is composed from a fixed vocabulary. It never carries a hostname,
/// URL, credential or raw error text.
class PresenceLimitation {
  const PresenceLimitation({
    required this.kind,
    required this.message,
    this.sailorId,
    this.sailorDisplayName,
  });

  final PresenceLimitationKind kind;
  final String message;
  final String? sailorId;
  final String? sailorDisplayName;

  static PresenceLimitation peerAppOlder({
    required String sailorId,
    required String displayName,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.peerAppOlder,
    sailorId: sailorId,
    sailorDisplayName: displayName,
    message:
        "$displayName's app is older — their live position will not appear "
        'once the voyage starts until they update.',
  );

  /// Names a peer whose phone clock disagrees with the voyage service.
  ///
  /// Their position is still shown and still counts as contact: it is timed by
  /// the voyage service instead of by their phone. Saying so is the alternative to
  /// silently ageing out a sailor who is reporting perfectly well.
  static PresenceLimitation sailorClockUntrusted({
    required String sailorId,
    required String displayName,
    required Duration offset,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.sailorClockUntrusted,
    sailorId: sailorId,
    sailorDisplayName: displayName,
    message:
        "$displayName's phone clock is ${formatPresenceAge(offset.abs())} "
        '${offset.isNegative ? 'ahead of' : 'behind'} the voyage service, so '
        'their position is timed by the voyage service instead. Their location '
        'is still live.',
  );

  static PresenceLimitation positionsUnreadable(
    int count,
  ) => PresenceLimitation(
    kind: PresenceLimitationKind.positionsUnreadable,
    message:
        '$count live position${count == 1 ? '' : 's'} could not be read and '
        'were skipped. Every other sailor is unaffected.',
  );

  static const serviceCapabilityMissing = PresenceLimitation(
    kind: PresenceLimitationKind.serviceCapabilityMissing,
    message:
        'The voyage service does not support live sailor positions yet, so only '
        'saved voyage history is shared.',
  );

  static const serviceUnreachable = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUnreachable,
    message:
        'Live sailor positions are paused because the voyage service cannot be '
        'reached. They resume automatically.',
  );

  static const serviceUnauthorized = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUnauthorized,
    message:
        'The voyage service rejected this voyage invitation, so live sailor '
        'positions are unavailable. Re-join with a fresh invite.',
  );

  static const clientUpdateRequired = PresenceLimitation(
    kind: PresenceLimitationKind.clientUpdateRequired,
    message:
        'Update Tide and Seek: this build is older than the voyage service '
        'supports, so live sailor positions are unavailable.',
  );

  static const serviceUpgradeRequired = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUpgradeRequired,
    message:
        'This app is newer than the voyage service, so live sailor positions are '
        'unavailable until the service is updated.',
  );

  static PresenceLimitation unsupportedEventsIgnored(int count) =>
      PresenceLimitation(
        kind: PresenceLimitationKind.unsupportedEventsIgnored,
        message:
            '$count voyage update${count == 1 ? '' : 's'} from a newer app '
            'version could not be read and were skipped. Everything else in '
            'the voyage is unaffected.',
      );

  static PresenceLimitation uploadCapabilityMissing(int count) =>
      PresenceLimitation(
        kind: PresenceLimitationKind.uploadCapabilityMissing,
        message:
            '$count voyage update${count == 1 ? '' : 's'} stayed on this phone '
            'because the voyage service does not support them yet.',
      );

  static PresenceLimitation uploadQuarantined(int count) => PresenceLimitation(
    kind: PresenceLimitationKind.uploadQuarantined,
    message:
        '$count voyage update${count == 1 ? '' : 's'} were set aside because the '
        'voyage service refused them. Joining, positions and alerts keep working.',
  );

  /// The outgoing direction for #128 part 1: this build can ask, the relay
  /// cannot carry the question. Names the fallback rather than letting the
  /// skipper believe a sailor was asked.
  static const sweeperAssignmentUnsupportedByService = PresenceLimitation(
    kind: PresenceLimitationKind.sweeperAssignmentUnsupportedByService,
    message:
        'The voyage service is too old to pass on a Sweeper request, so '
        'nobody has been asked. The sailor has to set the role themselves on '
        'their own Voyage tab.',
  );

  /// The incoming direction for #128 part 1: the request will reach that
  /// sailor's phone and their build will skip it, so the skipper must be told
  /// which sailor, by name, rather than watching a request sit at "waiting".
  static PresenceLimitation sweeperAssignmentUnsupportedByPeer({
    required String sailorId,
    required String displayName,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.sweeperAssignmentUnsupportedByPeer,
    sailorId: sailorId,
    sailorDisplayName: displayName,
    message:
        "$displayName's app is older — they will not see a Sweeper "
        'request until they update. Ask them to set the role themselves.',
  );

  /// #128 part 2. The sailor keeps their own rejoin guidance either way; only the
  /// skipper's copy is lost, and the skipper is told so.
  static const rejoinSharingUnsupportedByService = PresenceLimitation(
    kind: PresenceLimitationKind.rejoinSharingUnsupportedByService,
    message:
        'The voyage service is too old to send your rejoin route to the voyage '
        'skipper. You still have it on this phone; the skipper will not see it.',
  );

  /// #188. A new event type is rejected outright by an older *build*, and
  /// withheld by an older *relay*, so the one thing a sailor must never be left
  /// with is the belief that their number went out. Names what is lost and what
  /// still works: the in-app alert never needed a phone number.
  static const sailorContactSharingUnsupportedByService = PresenceLimitation(
    kind: PresenceLimitationKind.sailorContactSharingUnsupportedByService,
    message:
        'The voyage service is too old to pass on your phone number, so nobody '
        'has been given it. Your emergency alert still reaches the skipper and '
        'TEC in the app.',
  );
}

/// Merges every position channel into one per-sailor live state.
///
/// The reconciler is pure and phase-neutral on purpose. Pre-start presence,
/// post-start journal events and nearby presence all arrive here, so a sailor
/// visible before the start stays visible across `voyageStarted` without
/// re-opting-in and without a duplicate identity.
class LivePresenceReconciler {
  const LivePresenceReconciler({this.policy = const PresenceFreshnessPolicy()});

  final PresenceFreshnessPolicy policy;

  /// [journal] is the durable post-start location history, [internetPresence]
  /// and [nearbyPresence] are the ephemeral channels, and [roster] names sailors
  /// the transport has seen even when no position exists yet.
  ///
  /// [relayClockOffset] is the relay's clock minus this device's, measured on the
  /// last successful presence sync. A remote sailor's position that the relay
  /// stamped is aged on the relay's clock — the only clock both phones share —
  /// so a peer whose own clock is wrong is never aged out as if they had stopped
  /// reporting. This device's own fixes are always aged on its own clock.
  List<LiveSailorPresence> reconcile({
    required DateTime now,
    required String localSailorId,
    Iterable<SailorLocation> journal = const [],
    Iterable<SailorLocation> internetPresence = const [],
    Iterable<SailorLocation> nearbyPresence = const [],
    Iterable<PresenceRosterMember> roster = const [],
    Duration relayClockOffset = Duration.zero,
  }) {
    final best = <String, _Candidate>{};
    void offer(SailorLocation location, LivePresenceSource source) {
      final existing = best[location.sailorId];
      if (existing == null) {
        best[location.sailorId] = _Candidate(location, {source});
        return;
      }
      existing.sources.add(source);
      if (location.sample.recordedAt.isBefore(existing.oldestSampleAt)) {
        existing.oldestSampleAt = location.sample.recordedAt;
      }
      // Newest recorded sample wins, so a duplicate or out-of-order delivery
      // can never rewind a sailor to an older coordinate.
      if (location.sample.recordedAt.isAfter(
        existing.location.sample.recordedAt,
      )) {
        existing.location = location;
        existing.newestSource = source;
      }
    }

    for (final location in journal) {
      offer(location, LivePresenceSource.journal);
    }
    for (final location in internetPresence) {
      offer(location, LivePresenceSource.internetPresence);
    }
    for (final location in nearbyPresence) {
      offer(location, LivePresenceSource.nearbyPresence);
    }

    final rosterById = <String, PresenceRosterMember>{};
    final departed = <String>{};
    for (final member in roster) {
      if (member.left) {
        departed.add(member.sailorId);
        continue;
      }
      rosterById[member.sailorId] = member;
    }

    final result = <LiveSailorPresence>[];
    for (final sailorId in {...best.keys, ...rosterById.keys}) {
      // A departure is explicit and authoritative. A lingering ephemeral
      // position must not resurrect a sailor who has left the voyage.
      if (departed.contains(sailorId)) continue;
      final candidate = best[sailorId];
      final member = rosterById[sailorId];
      final isLocal = sailorId == localSailorId;
      if (candidate == null) {
        result.add(
          LiveSailorPresence(
            sailorId: sailorId,
            displayName: member!.displayName,
            role: member.role,
            freshness: PresenceFreshness.none,
            sources: const {},
            isLocal: isLocal,
            knownSince: member.joinedAt,
            motorcycleStyle: member.motorcycleStyle,
            sailorSymbol: member.sailorSymbol,
            sailorColor: member.sailorColor,
          ),
        );
        continue;
      }
      final location = candidate.location;
      // A remote position the relay stamped is aged on the relay's clock: its
      // arrival stamp against the relay's current time. Both come from one
      // clock, so the subtraction is an age and nothing else. This device's own
      // fixes never travel through the relay before being drawn, so they stay on
      // this device's clock.
      final relayStamped =
          !isLocal &&
          candidate.newestSource == LivePresenceSource.internetPresence;
      final publisherOffset = location.receivedAt.difference(
        location.sample.recordedAt,
      );
      final age = relayStamped
          ? _nonNegative(
              now.add(relayClockOffset).difference(location.receivedAt),
            )
          : location.sample.ageAt(now);
      final freshness = policy.classify(age);
      final sources = {
        ...candidate.sources,
        if (isLocal) LivePresenceSource.localDevice,
      };
      result.add(
        LiveSailorPresence(
          clockBasis: relayStamped
              ? PresenceClockBasis.sharedRelayClock
              : PresenceClockBasis.publisherClock,
          publisherClockOffset:
              relayStamped &&
                  publisherOffset.abs() > policy.publisherClockTolerance
              ? publisherOffset
              : null,
          sailorId: sailorId,
          // The roster is the transport's authoritative identity when it has
          // one; a position payload is only self-described.
          displayName: member?.displayName ?? location.displayName,
          role: member?.role ?? location.role,
          freshness: freshness,
          sources: Set.unmodifiable(sources),
          isLocal: isLocal,
          knownSince: member?.joinedAt ?? candidate.oldestSampleAt,
          motorcycleStyle: location.motorcycleStyle,
          sailorSymbol: location.sailorSymbol,
          sailorColor: location.sailorColor,
          location: location,
          age: age,
          // The newest evidence of this sailor, moved onto this device's clock.
          // For a relay-stamped position that is the relay's arrival stamp, the
          // only clock both phones share, so a stationary sailor republishing an
          // unchanged position still advances their contact.
          contactAt: now.subtract(age),
        ),
      );
    }
    result.sort((left, right) {
      final byName = left.displayName.compareTo(right.displayName);
      return byName != 0 ? byName : left.sailorId.compareTo(right.sailorId);
    });
    return List.unmodifiable(result);
  }

  /// The reconciled positions worth drawing, newest per sailor.
  List<SailorLocation> reconcileLocations({
    required DateTime now,
    required String localSailorId,
    Iterable<SailorLocation> journal = const [],
    Iterable<SailorLocation> internetPresence = const [],
    Iterable<SailorLocation> nearbyPresence = const [],
    Duration relayClockOffset = Duration.zero,
  }) => List.unmodifiable([
    for (final presence in reconcile(
      now: now,
      localSailorId: localSailorId,
      journal: journal,
      internetPresence: internetPresence,
      nearbyPresence: nearbyPresence,
      relayClockOffset: relayClockOffset,
    ))
      ?presence.location,
  ]);
}

Duration _nonNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;

class _Candidate {
  _Candidate(this.location, this.sources)
    : oldestSampleAt = location.sample.recordedAt,
      newestSource = sources.first;

  SailorLocation location;
  final Set<LivePresenceSource> sources;
  DateTime oldestSampleAt;

  /// Which channel supplied [location]. Only the internet presence channel
  /// carries a relay-stamped arrival time.
  LivePresenceSource newestSource;
}
