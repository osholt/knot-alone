import '../domain/imported_route.dart';

/// How a route or trail line is presented on the voyage map.
///
/// The kind only affects styling and never whether a trail exists: a sailor who
/// has left the planned route still has a trail, it simply reads as an
/// off-route excursion.
enum SailorTrailKind {
  /// Any sailor's travelled path, including the local sailor's own.
  sailor,

  /// The current skipper's travelled path - the group's ground truth when the
  /// plan stops matching the road, so it is styled as the most prominent trail
  /// and is rendered on every participant's map.
  skipper,

  /// A sailor whose route alert says they are suspected off route, confirmed off
  /// route, or recovering.
  offRoute,

  /// The advisory rejoin route computed for an off-course sailor (#102). The one
  /// kind that is not recorded history: it is where the routing engine says to
  /// go next, which is why it is never produced by [SailorTrailRecorder] and is
  /// published alongside the recorded trails instead.
  rejoin,
}

/// One sailor's travelled path, ready to be rendered.
class SailorTrail {
  const SailorTrail({
    required this.sailorId,
    required this.displayName,
    required this.kind,
    required this.points,
  });

  final String sailorId;
  final String displayName;
  final SailorTrailKind kind;
  final List<GeoPoint> points;

  bool get isRenderable => points.length >= 2;
}

/// One sailor's current state, as far as trail recording is concerned.
///
/// Note what is absent: whether a route is loaded, and how far this sailor is
/// from it. Neither may decide whether a trail exists.
class SailorTrailUpdate {
  const SailorTrailUpdate({
    required this.sailorId,
    required this.displayName,
    this.position,
    this.isSkipper = false,
    this.isOffRoute = false,
    this.isEligible = true,
    this.journalTrail,
  });

  final String sailorId;
  final String displayName;

  /// The newest known fix, or null when this refresh brought nothing new.
  final GeoPoint? position;

  final bool isSkipper;

  /// Whether the sailor's route alert says they are off route. Styling only.
  final bool isOffRoute;

  /// Whether the sailor is eligible for live position sharing. An ineligible
  /// sailor's history is dropped rather than retained unseen.
  final bool isEligible;

  /// History recovered from the durable voyage journal, which is what lets a
  /// trail survive an app restart mid-voyage. Preferred over this device's live
  /// recording when it is longer.
  final List<GeoPoint>? journalTrail;
}

/// Records where every sailor has actually been, from position history alone.
///
/// Route matching is deliberately not an input. The travelled trail used to be
/// derived from the planned route's progress split plus an off-route trace that
/// only existed while a sailor was flagged, so a skipper who rode off the
/// imported GPX - a state the skipper can never be flagged for, because their
/// own trail is treated as a valid route - lost their trail entirely (#100).
/// Recording is therefore unconditional, and route matching is left to drive
/// route progress and alerts only.
///
/// Samples are inserted in recorded order rather than arrival order, because
/// relayed and journal-replayed fixes are not guaranteed to arrive in the order
/// they were recorded. Each sailor's history is bounded by
/// [maximumPointsPerSailor]; the oldest points are dropped first so the visible
/// trail stays continuous up to the current position.
class SailorTrailRecorder {
  SailorTrailRecorder({
    this.maximumPointsPerSailor = defaultMaximumPointsPerSailor,
    this.minimumSeparationDegrees = 1e-7,
    this.maximumContinuousGap = defaultMaximumContinuousGap,
  }) : assert(maximumPointsPerSailor >= 2),
       assert(minimumSeparationDegrees >= 0);

  /// A runaway guard, not a display policy — and the second place that
  /// distinction had to be made.
  ///
  /// This was 120 points. Positions become durable reports at roughly one per
  /// 20 m of travel (`PositionReportPolicy`: 18 m of travel, met at the first
  /// 10 m platform fix at or beyond it), so 120 points was **about 2.4 km of
  /// riding, whatever the length of the voyage**. Past that the oldest points
  /// were deleted and the drawn trail slid along behind the sailor like a tail,
  /// which is exactly the report in #299: "it forgets your track after a
  /// while". A solo sailor reaches it in two or three minutes.
  ///
  /// It also silently undid #280. That issue raised the skipper trail's bound in
  /// `SituationalAwarenessController` from 600 to 100,000 after a 112 mile voyage
  /// lost its tail — but that trail is handed to this recorder as
  /// [SailorTrailUpdate.journalTrail] and cut back down to 120 here by
  /// [boundedTrail], so the fix never reached the map. A bound below its own
  /// source is not a bound, it is a deletion.
  ///
  /// Nothing needed it. The renderer already bounds what it draws:
  /// `TrailDisplaySimplifier` reduces every trace to at most 2,000 points with
  /// adaptive tolerance, once per change, before either map implementation sees
  /// it. This constant was only ever protecting memory, so it is now sized as a
  /// memory backstop and matched to the journal trail it must not contradict:
  /// 100,000 points is 2,000 km of riding at the report rate above, or over a
  /// fortnight at the stationary keep-alive rate of four a minute. No voyage
  /// reaches either.
  ///
  /// It is per sailor, so a large group's live history now scales with how far
  /// the voyage has gone rather than with a constant — around 20,000 points each
  /// for a six-hour voyage. That is the intended trade: a sailor's own track is
  /// not something to economise on.
  static const defaultMaximumPointsPerSailor = 100000;

  /// A healthy voyage reports every few seconds. Beyond this interval the app
  /// does not know where the sailor went, so joining the fixes would invent a
  /// straight road across the missing section (#205).
  static const defaultMaximumContinuousGap = Duration(minutes: 2);

  final int maximumPointsPerSailor;
  final double minimumSeparationDegrees;
  final Duration maximumContinuousGap;

  final _trails = <String, List<GeoPoint>>{};

  /// The recorded trail for [sailorId], oldest point first.
  List<GeoPoint> trailFor(String sailorId) =>
      List.unmodifiable(_trails[sailorId] ?? const <GeoPoint>[]);

  /// Records this refresh's fixes and returns every sailor's trail.
  ///
  /// Unconditional: a sailor off the planned route, a sailor with no planned
  /// route at all, and the skipper - who is never flagged off route because
  /// their own trail counts as a valid route - all keep a trail. The off-route
  /// flag only chooses how the trail is styled.
  List<SailorTrail> update(Iterable<SailorTrailUpdate> sailors) {
    final trails = <SailorTrail>[];
    for (final sailor in sailors) {
      if (!sailor.isEligible) {
        forget(sailor.sailorId);
        continue;
      }
      final position = sailor.position;
      if (position != null) {
        record(sailorId: sailor.sailorId, point: position);
      }
      final recorded = trailFor(sailor.sailorId);
      final journal = sailor.journalTrail;
      trails.add(
        SailorTrail(
          sailorId: sailor.sailorId,
          displayName: sailor.displayName,
          kind: kindFor(
            isSkipper: sailor.isSkipper,
            isOffRoute: sailor.isOffRoute,
          ),
          points: journal != null && journal.length > recorded.length
              ? boundedTrail(journal)
              : recorded,
        ),
      );
    }
    return List.unmodifiable(trails);
  }

  /// The most recent [maximumPointsPerSailor] points of [trail], so history from
  /// any source obeys the same bound.
  List<GeoPoint> boundedTrail(List<GeoPoint> trail) => List.unmodifiable(
    trail.length > maximumPointsPerSailor
        ? trail.sublist(trail.length - maximumPointsPerSailor)
        : trail,
  );

  /// Splits recorded history anywhere the location stream was absent too long
  /// to draw an honest continuous trail.
  List<List<GeoPoint>> continuousSegments(List<GeoPoint> trail) {
    if (trail.isEmpty) return const [];
    final segments = <List<GeoPoint>>[
      <GeoPoint>[trail.first],
    ];
    for (final point in trail.skip(1)) {
      final previous = segments.last.last;
      final previousAt = previous.recordedAt;
      final recordedAt = point.recordedAt;
      if (previousAt != null &&
          recordedAt != null &&
          recordedAt.difference(previousAt) > maximumContinuousGap) {
        segments.add(<GeoPoint>[]);
      }
      segments.last.add(point);
    }
    return [
      for (final segment in segments) List<GeoPoint>.unmodifiable(segment),
    ];
  }

  /// The skipper kind always wins: a skipper cannot be off route by design, so
  /// their trail must never be restyled as an excursion.
  static SailorTrailKind kindFor({
    required bool isSkipper,
    required bool isOffRoute,
  }) => isSkipper
      ? SailorTrailKind.skipper
      : isOffRoute
      ? SailorTrailKind.offRoute
      : SailorTrailKind.sailor;

  /// Records [point] for [sailorId] and reports whether it extended the trail.
  ///
  /// Points that repeat the sailor's last recorded position, or that predate an
  /// already recorded position, are ignored rather than reordering history.
  bool record({required String sailorId, required GeoPoint point}) {
    final trail = _trails.putIfAbsent(sailorId, () => <GeoPoint>[]);
    final index = _insertionIndex(trail, point);
    if (index == null) return false;
    trail.insert(index, point);
    if (trail.length > maximumPointsPerSailor) {
      trail.removeRange(0, trail.length - maximumPointsPerSailor);
    }
    return true;
  }

  /// Drops [sailorId]'s history, used when a sailor stops being eligible for
  /// live position sharing.
  ///
  /// A sailor simply missing from a refresh keeps their history: they may be
  /// briefly stale rather than gone, and a returning sailor must not restart
  /// their trail.
  void forget(String sailorId) => _trails.remove(sailorId);

  void clear() => _trails.clear();

  int? _insertionIndex(List<GeoPoint> trail, GeoPoint point) {
    if (trail.isEmpty) return 0;
    final recordedAt = point.recordedAt;
    if (recordedAt == null) {
      return _isSamePlace(trail.last, point) ? null : trail.length;
    }
    var index = trail.length;
    while (index > 0) {
      final previous = trail[index - 1].recordedAt;
      if (previous == null || !previous.isAfter(recordedAt)) break;
      index -= 1;
    }
    if (index > 0) {
      final previous = trail[index - 1];
      if (previous.recordedAt != null &&
          !previous.recordedAt!.isBefore(recordedAt)) {
        return null;
      }
      if (_isSamePlace(previous, point)) return null;
    }
    return index;
  }

  bool _isSamePlace(GeoPoint first, GeoPoint second) =>
      (first.latitude - second.latitude).abs() <= minimumSeparationDegrees &&
      (first.longitude - second.longitude).abs() <= minimumSeparationDegrees;
}
