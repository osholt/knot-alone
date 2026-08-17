import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../domain/event_store.dart';
import '../domain/geo_point.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import '../domain/voyage_session.dart';
import '../domain/sailor_location.dart';
import '../domain/route_alert.dart';
import '../relay/live_presence.dart';
import '../services/route_deviation_detector.dart';
import '../services/skipper_track_exemption.dart';
import '../services/situation_event_factory.dart';

class SituationalAwarenessController extends ChangeNotifier {
  SituationalAwarenessController(
    this._eventStore,
    this._session, {
    required List<GeoPoint> route,
    List<List<GeoPoint>>? routeSegments,
    SituationClock? clock,
    SituationIdFactory? idFactory,
    this.voyageStarted = true,
    this.voyageStartedAt,
    this.routeConfig = const RouteDeviationConfig(),
    this.freshnessPolicy = const PresenceFreshnessPolicy(),
    this.onEventStored,
  }) : _route = List.unmodifiable(route),
       _routeSegments = List.unmodifiable(
         (routeSegments ?? [route]).map(
           (segment) => List<GeoPoint>.unmodifiable(segment),
         ),
       ),
       _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? const Uuid().v7 {
    _eventFactory = SituationEventFactory(
      session: _session,
      clock: _clock,
      idFactory: _idFactory,
    );
  }

  final EventStore _eventStore;
  VoyageSession _session;
  final List<GeoPoint> _route;
  final List<List<GeoPoint>> _routeSegments;
  final SituationClock _clock;
  final SituationIdFactory _idFactory;
  final bool voyageStarted;
  final DateTime? voyageStartedAt;
  final RouteDeviationConfig routeConfig;

  /// Documented age thresholds shared with the ephemeral presence channels, so
  /// the journal side and the presence side cannot disagree about whether a
  /// position is live, ageing or stale.
  final PresenceFreshnessPolicy freshnessPolicy;

  /// Receives an event after this controller has durably stored and applied it.
  ///
  /// The voyage shell uses this to update the shared in-memory journal one event
  /// at a time instead of re-reading the complete SQLite voyage after every
  /// position fix (#165).
  final ValueChanged<VoyageEvent>? onEventStored;
  late SituationEventFactory _eventFactory;

  final Map<String, SailorLocation> _locations = {};
  final Map<String, SailorLocationEvidence> _locationEvidence = {};
  final Map<String, SailorRouteAlert> _alerts = {};
  final Map<String, RouteDeviationDetector> _detectors = {};
  final Map<String, bool> _followingSkipperTrack = {};
  final List<({DateTime recordedAt, GeoPoint position})> _skipperTrail = [];
  bool _busy = false;
  bool _refreshingStaleness = false;
  String? _errorMessage;

  bool get busy => _busy;
  String? get errorMessage => _errorMessage;
  List<GeoPoint> get route => _route;

  /// The current voyage skipper's own recorded path so far - the group's live
  /// ground truth. Sailors are judged against this (as well as the planned
  /// route, if any) so a skipper's deliberate on-route deviation, such as a
  /// road-closure detour, doesn't read as the group having gone off course.
  List<GeoPoint> get skipperTrail => _skipperTrailPoints;

  /// The same durable skipper trail with its fix times retained, so map
  /// rendering can break an unknown interval instead of inventing a straight
  /// line across it (#205).
  List<({DateTime recordedAt, GeoPoint position})> get skipperTrailSamples =>
      _skipperTrailSamplesCache ??= List.unmodifiable(_skipperTrail);

  List<SailorLocation> get sailorLocations {
    final values = _locations.values.toList(growable: false);
    values.sort(
      (first, second) => first.displayName.compareTo(second.displayName),
    );
    return List.unmodifiable(values);
  }

  /// The journal's contribution to the reconciled live-position model.
  ///
  /// This controller owns the durable side only. Callers merge it with the
  /// ephemeral presence channels through [LivePresenceReconciler] so one model
  /// spans both voyage phases and both transports; doing the merge here would
  /// make an ephemeral snapshot look like voyage history.
  List<LiveSailorPresence> livePresenceAt(DateTime now) =>
      LivePresenceReconciler(policy: freshnessPolicy).reconcile(
        now: now,
        localSailorId: _session.localSailorId,
        journal: _locations.values,
      );

  List<SailorRouteAlert> get routeAlerts {
    final values = _alerts.values
        .map(_exemptIfFollowingSkipperTrack)
        .where((alert) => alert.assessment.alertLevel != RouteAlertLevel.none)
        .toList();
    values.sort(
      (first, second) => second.assessment.alertLevel.index.compareTo(
        first.assessment.alertLevel.index,
      ),
    );
    return List.unmodifiable(values);
  }

  SailorLocation? get localLocation => _locations[_session.localSailorId];

  List<SailorLocationEvidence> get authenticatedLocationEvidence =>
      List.unmodifiable(
        _locationEvidence.values.where((evidence) => evidence.authenticated),
      );

  SailorLocationEvidence? locationEvidenceFor(String sailorId) =>
      _locationEvidence[sailorId];

  SailorRouteAlert? alertFor(String sailorId) {
    final alert = _alerts[sailorId];
    return alert == null ? null : _exemptIfFollowingSkipperTrack(alert);
  }

  /// Whether [sailorId]'s most recent fix was inside the voyage skipper's live
  /// track corridor. Such a sailor is on route by definition.
  bool isFollowingSkipperTrack(String sailorId) =>
      _followingSkipperTrack[sailorId] ?? false;

  void updateLocalSession(VoyageSession session) {
    if (session.voyageId != _session.voyageId ||
        session.localSailorId != _session.localSailorId) {
      throw ArgumentError(
        'Cannot replace awareness with another voyage session',
      );
    }
    _session = session;
    _eventFactory = SituationEventFactory(
      session: session,
      clock: _clock,
      idFactory: _idFactory,
    );
  }

  Future<void> initialize({Iterable<VoyageEvent>? restoredEvents}) async {
    final events =
        restoredEvents ?? await _eventStore.eventsForVoyage(_session.voyageId);
    var replayed = 0;
    for (final event in events) {
      _applyEvent(event, replaying: true);
      replayed += 1;
      // A restored group voyage can contain tens of thousands of positions. The
      // reducer remains ordered, but yields between bounded batches so Android
      // can draw and respond while the journal is projected into map state
      // (#209).
      if (replayed % 250 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    notifyListeners();
  }

  Future<void> recordLocalLocation(LocationSample sample) async {
    if (!voyageStarted ||
        (voyageStartedAt != null &&
            sample.recordedAt.isBefore(voyageStartedAt!))) {
      return;
    }
    final location = SailorLocation(
      sailorId: _session.localSailorId,
      displayName: _session.displayName,
      role: _session.role,
      sample: sample,
      receivedAt: _clock(),
      vesselStyle: _session.vesselStyle,
      sailorSymbol: _session.sailorSymbol,
      sailorColor: _session.sailorColor,
    );
    await _run(() async {
      final previousAlert = _alerts[location.sailorId]?.assessment;
      final event = _eventFactory.create(
        type: VoyageEventType.sailorLocationUpdated,
        payload: {'location': location.toJson()},
        expiresAt: _clock().add(const Duration(minutes: 30)),
      );
      await _appendAndApply(event);
      final currentAlert = _alerts[location.sailorId]?.assessment;
      if (previousAlert?.state != currentAlert?.state ||
          previousAlert?.alertLevel != currentAlert?.alertLevel ||
          previousAlert?.audience != currentAlert?.audience) {
        await _persistAlertTransition(location.sailorId);
      }
    });
  }

  Future<void> acknowledgeAlert(String sailorId) async {
    final alert = _alerts[sailorId];
    if (alert == null || alert.acknowledged) {
      return;
    }
    await _run(() async {
      final acknowledgedAt = _clock();
      final updated = alert.copyWithAcknowledgement(
        acknowledgedBy: _session.localSailorId,
        acknowledgedAt: acknowledgedAt,
      );
      final event = _eventFactory.create(
        type: VoyageEventType.routeAlertAcknowledged,
        payload: {'alert': updated.toJson()},
        priority: EventPriority.important,
      );
      await _appendAndApply(event);
    });
  }

  Future<void> ingestRemoteEvent(VoyageEvent event) async {
    if (event.voyageId != _session.voyageId ||
        !_supportedSituationalEventTypes.contains(event.type)) {
      throw const FormatException('Event is not valid for this voyage.');
    }
    if (!SituationEventFactory.verify(event, _session.inviteSecret)) {
      throw const FormatException('Event signature is invalid.');
    }
    await _eventStore.append(event);
    _applyEvent(event);
    onEventStored?.call(event);
    notifyListeners();
  }

  Future<void> refreshStaleness() async {
    if (_refreshingStaleness) return;
    _refreshingStaleness = true;
    try {
      final locations = List<SailorLocation>.of(_locations.values);
      for (final location in locations) {
        final previous = _alerts[location.sailorId]?.assessment;
        _evaluateLocation(location);
        final current = _alerts[location.sailorId]?.assessment;
        if (previous?.state != current?.state ||
            previous?.alertLevel != current?.alertLevel ||
            previous?.audience != current?.audience) {
          await _persistAlertTransition(location.sailorId);
        }
      }
      notifyListeners();
    } finally {
      _refreshingStaleness = false;
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  Future<void> _persistAlertTransition(String sailorId) async {
    final alert = _alerts[sailorId];
    if (alert == null) {
      return;
    }
    final event = _eventFactory.create(
      type: VoyageEventType.routeDeviationChanged,
      payload: {'alert': alert.toJson()},
      priority: _priorityForAlert(alert.assessment.alertLevel),
      expiresAt: _clock().add(const Duration(hours: 2)),
    );
    await _eventStore.append(event);
    onEventStored?.call(event);
  }

  Future<void> _appendAndApply(VoyageEvent event) async {
    await _eventStore.append(event);
    _applyEvent(event);
    onEventStored?.call(event);
  }

  void _applyEvent(VoyageEvent event, {bool replaying = false}) {
    if (event.voyageId != _session.voyageId) {
      return;
    }
    if (_isVoyageActivityEvent(event.type) && !_isWithinVoyageActivity(event)) {
      return;
    }
    switch (event.type) {
      case VoyageEventType.sailorLocationUpdated:
        final location = SailorLocation.fromJson(
          _mapPayload(event.payload['location']),
        );
        if (voyageStartedAt != null &&
            location.sample.recordedAt.isBefore(voyageStartedAt!)) {
          break;
        }
        final previous = _locations[location.sailorId];
        if (previous == null ||
            !location.sample.recordedAt.isBefore(previous.sample.recordedAt)) {
          _locations[location.sailorId] = location;
          _locationEvidence[location.sailorId] = SailorLocationEvidence(
            location: location,
            eventId: event.id,
            eventCreatedAt: event.createdAt,
            authenticated:
                event.deviceId == location.sailorId &&
                SituationEventFactory.verify(event, _session.inviteSecret),
          );
          _evaluateLocation(location);
        }
        break;
      case VoyageEventType.routeDeviationChanged:
      case VoyageEventType.routeAlertAcknowledged:
        final alert = SailorRouteAlert.fromJson(
          _mapPayload(event.payload['alert']),
        );
        final current = _alerts[alert.sailorId];
        if (current == null ||
            !alert.assessment.evaluatedAt.isBefore(
              current.assessment.evaluatedAt,
            )) {
          _alerts[alert.sailorId] = alert;
        }
        break;
      case VoyageEventType.routeRevisionChunk:
      case VoyageEventType.routeRevisionPublished:
      case VoyageEventType.routeCleared:
      case VoyageEventType.voyageCreated:
      case VoyageEventType.sailorJoined:
      case VoyageEventType.sailorLeft:
      case VoyageEventType.roleChanged:
      case VoyageEventType.voyageStarted:
      case VoyageEventType.markerStarted:
      case VoyageEventType.markerPass:
      case VoyageEventType.markerEnded:
      case VoyageEventType.statusMessage:
      case VoyageEventType.voyagePaused:
      case VoyageEventType.voyageResumed:
      case VoyageEventType.voyageEnded:
      case VoyageEventType.voyageReopened:
      case VoyageEventType.iceInfoShared:
      case VoyageEventType.iceInfoViewed:
      // Skipper-issued TEC requests and relayed rejoin routes (#128) are
      // reconciled by their own reducers from the durable journal, not by this
      // controller. They are listed rather than defaulted so a future event
      // type still has to be considered here.
      case VoyageEventType.sweeperRoleRequested:
      case VoyageEventType.sweeperRoleResponded:
      case VoyageEventType.rejoinRouteShared:
      // Recorded by builds that still had the road hazard surfaces. Kept in the
      // journal so an archived voyage still decodes; nothing projects them now.
      case VoyageEventType.hazardReported:
      case VoyageEventType.hazardCleared:
      case VoyageEventType.sailorContactShared:
        break;
    }
    if (!replaying) {}
  }

  bool _isWithinVoyageActivity(VoyageEvent event) {
    if (!voyageStarted) return false;
    final startedAt = voyageStartedAt;
    return startedAt == null || !event.createdAt.isBefore(startedAt);
  }

  static bool _isVoyageActivityEvent(VoyageEventType type) => switch (type) {
    VoyageEventType.sailorLocationUpdated ||
    VoyageEventType.routeDeviationChanged ||
    VoyageEventType.routeAlertAcknowledged => true,
    _ => false,
  };

  void _evaluateLocation(SailorLocation location) {
    if (location.role == VoyageRole.lead) {
      _recordSkipperTrailPoint(location.sample);
    }
    // Per-role, and re-applied on every fix so a hand-over mid-voyage moves both
    // sailors onto the right comparison without resetting their hysteresis.
    final segments = _routeSegmentsFor();
    final detector = _detectors.putIfAbsent(
      location.sailorId,
      () => RouteDeviationDetector(
        _route,
        config: routeConfig,
        routeSegments: segments,
      ),
    );
    detector.updateRouteSegments(segments);
    final assessment = _applySkipperFollowExemption(
      location,
      detector,
      detector.evaluate(location.sample, _clock()),
    );
    // Always replaced, not only when the state changes. The stored assessment is
    // what the sailor is told - "you are off route by X" - and what the rejoin
    // planner reads, so keeping the one from the last state *transition* froze
    // the distance and the timestamp for as long as a sailor stayed off route
    // (#162). Callers that need to know whether anything meaningful changed
    // compare state, level and audience themselves.
    _alerts[location.sailorId] = SailorRouteAlert(
      sailorId: location.sailorId,
      displayName: location.displayName,
      assessment: assessment,
    );
  }

  /// Inserts in chronological order (by [LocationSample.recordedAt], not
  /// arrival order) since relayed and replayed events are not guaranteed to
  /// arrive in the order they were recorded. Duplicate/older-or-equal
  /// timestamps are dropped rather than reordering an already-recorded point.
  void _recordSkipperTrailPoint(LocationSample sample) {
    var index = _skipperTrail.length;
    while (index > 0 &&
        _skipperTrail[index - 1].recordedAt.isAfter(sample.recordedAt)) {
      index -= 1;
    }
    if (index > 0 &&
        !_skipperTrail[index - 1].recordedAt.isBefore(sample.recordedAt)) {
      return;
    }
    _skipperTrail.insert(index, (
      recordedAt: sample.recordedAt,
      position: sample.position,
    ));
    _skipperTrailPointsCache = null;
    _skipperTrailSamplesCache = null;
    // A runaway guard, not a display policy. The trail used to be truncated to
    // SkipperTrackExemption.defaultRecentPointLimit (600) here, which cost a
    // tester the tail of a 6 h 4 m, 112 mile voyage: 600 points is roughly the
    // last 40 minutes, so everything before that was deleted and could never be
    // drawn, exported or recapped again. This bound exists only so a pathological
    // session cannot grow without limit - at one fix per second it is over 27
    // hours, which no voyage reaches.
    if (_skipperTrail.length > maximumRetainedTrailPoints) {
      _skipperTrail.removeRange(
        0,
        _skipperTrail.length - maximumRetainedTrailPoints,
      );
    }
  }

  /// Memory backstop for the retained skipper trail. Deliberately far above any
  /// real voyage; see [_recordSkipperTrailPoint].
  static const maximumRetainedTrailPoints = 100000;

  List<GeoPoint>? _skipperTrailPointsCache;
  List<({DateTime recordedAt, GeoPoint position})>? _skipperTrailSamplesCache;

  /// Built once per change rather than per read.
  ///
  /// This is what makes retaining the whole trail affordable. The 600-point
  /// truncation was guarding a real cost, but the wrong one: it was not the
  /// renderer, which already simplifies once per change through
  /// `TrailDisplaySimplifier` (#165). It was this projection, which rebuilt the
  /// entire list on every call - and [_applySkipperFollowExemption] calls it on
  /// every follower position update. Caching it removes the per-update cost
  /// without deleting any history.
  List<GeoPoint> get _skipperTrailPoints => _skipperTrailPointsCache ??=
      List.unmodifiable([for (final point in _skipperTrail) point.position]);

  /// The most recent points only, for the "is this sailor following the skipper"
  /// corridor check.
  ///
  /// [SkipperTrackExemption.isFollowingSkipperTrack] slices to its own limit
  /// anyway, so passing the whole trail would be correct - but it would copy the
  /// whole thing to throw most of it away. Slicing here keeps that call bounded
  /// by the exemption's own rule regardless of how long the voyage has run, which
  /// is the performance property #165 actually needed.
  List<GeoPoint> get _recentSkipperTrailPoints {
    const limit = SkipperTrackExemption.defaultRecentPointLimit;
    final from = _skipperTrail.length > limit
        ? _skipperTrail.length - limit
        : 0;
    return [
      for (var i = from; i < _skipperTrail.length; i += 1)
        _skipperTrail[i].position,
    ];
  }

  /// What each sailor is compared against before exemptions.
  ///
  /// Every sailor is compared against the planned route here. Followers get the
  /// separate skipper-track exemption in [_applySkipperFollowExemption].
  ///
  /// Keeping the two questions separate avoids scanning the skipper trail twice
  /// per follower update, and avoids an older part of that growing trail
  /// silently overriding [SkipperTrackExemption]'s deliberate "recent track"
  /// rule (#165). The skipper must also stay on this path: comparing them with
  /// their own current endpoint would make them on-route anywhere (#162).
  List<List<GeoPoint>> _routeSegmentsFor() => _routeSegments;

  // ---------------------------------------------------------------------------
  // Issue #102 - skipper-follow exemption. Deliberately the only place this rule
  // is decided, so the alert state, the relayed deviation event, the roster, the
  // map and the skipper's off-course count cannot disagree.
  //
  // A sailor inside the corridor of the skipper's ACTUAL recorded track is on
  // route whatever the planned GPX says - including when the skipper has
  // abandoned the GPX themselves. Applied at both ends: when this device
  // evaluates a fix, and when a deviation alert arrives from another device that
  // had not yet seen the skipper's trail.
  // ---------------------------------------------------------------------------

  RouteDeviationAssessment _applySkipperFollowExemption(
    SailorLocation location,
    RouteDeviationDetector detector,
    RouteDeviationAssessment assessment,
  ) {
    // The skipper is always the end of their own trail, so exempting them says
    // nothing; leave their verdict to the geometry.
    final exempt =
        location.role != VoyageRole.lead &&
        SkipperTrackExemption.isFollowingSkipperTrack(
          position: location.sample.position,
          accuracyMeters: location.sample.accuracyMeters,
          skipperTrack: _recentSkipperTrailPoints,
          corridorMeters: routeConfig.skipperTrackCorridorMeters,
        );
    _followingSkipperTrack[location.sailorId] = exempt;
    // A stale or inaccurate fix is a GPS problem, not a route problem, and must
    // keep reporting as one.
    if (!exempt || assessment.state == RouteTrackingState.gpsStale) {
      return assessment;
    }
    detector.resetOffRouteHysteresis();
    return RouteDeviationDetector.followingSkipperTrackAssessment(
      evaluatedAt: assessment.evaluatedAt,
      distanceFromRouteMeters: assessment.distanceFromRouteMeters,
    );
  }

  SailorRouteAlert _exemptIfFollowingSkipperTrack(SailorRouteAlert alert) {
    if (!isFollowingSkipperTrack(alert.sailorId) ||
        alert.assessment.state == RouteTrackingState.gpsStale ||
        alert.assessment.alertLevel == RouteAlertLevel.none) {
      return alert;
    }
    return SailorRouteAlert(
      sailorId: alert.sailorId,
      displayName: alert.displayName,
      assessment: RouteDeviationDetector.followingSkipperTrackAssessment(
        evaluatedAt: alert.assessment.evaluatedAt,
        distanceFromRouteMeters: alert.assessment.distanceFromRouteMeters,
      ),
      acknowledged: alert.acknowledged,
      acknowledgedBy: alert.acknowledgedBy,
      acknowledgedAt: alert.acknowledgedAt,
    );
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) {
      return;
    }
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await operation();
    } on FormatException catch (error) {
      _errorMessage = error.message;
    } on Object catch (error, stackTrace) {
      _errorMessage = 'Situational awareness could not be updated.';
      if (kDebugMode) {
        debugPrint('Situational awareness failed: $error\n$stackTrace');
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static Map<String, Object?> _mapPayload(Object? value) =>
      Map<String, Object?>.from(value! as Map);

  static EventPriority _priorityForAlert(RouteAlertLevel level) =>
      switch (level) {
        RouteAlertLevel.none || RouteAlertLevel.watch => EventPriority.routine,
        RouteAlertLevel.urgent => EventPriority.important,
        RouteAlertLevel.critical => EventPriority.critical,
      };

  static const _supportedSituationalEventTypes = {
    VoyageEventType.sailorLocationUpdated,
    VoyageEventType.routeDeviationChanged,
    VoyageEventType.routeAlertAcknowledged,
  };
}
