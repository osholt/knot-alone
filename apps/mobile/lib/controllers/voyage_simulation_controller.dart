import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import '../domain/voyage_session.dart';
import '../domain/sailor_color.dart';
import '../domain/sailor_location.dart';
import '../features/map/vessel_icon.dart';
import '../services/geo_calculations.dart';
import '../services/situation_event_factory.dart';
import 'situational_awareness_controller.dart';

enum VoyageSimulationState { ready, running, paused, completed }

/// The automatic second-bike-drop sequence shown by the Voyage Lab.
enum SimulationMarkerPhase {
  riding,
  waitingForSailors,
  sweeperApproaching,
  readyToGetUnderWay,
}

class SimulatedSailorSnapshot {
  const SimulatedSailorSnapshot({
    required this.id,
    required this.displayName,
    required this.role,
    required this.progress,
    required this.speedMetersPerSecond,
    required this.isLocal,
    required this.isOffRoute,
    required this.position,
    required this.headingDegrees,
    required this.offRouteTrail,
    required this.travelTrail,
    required this.vesselStyle,
    required this.sailorColor,
    this.sailorSymbol = sailorSymbolDefault,
  });

  final String id;
  final String displayName;
  final VoyageRole role;
  final double progress;
  final double speedMetersPerSecond;
  final bool isLocal;
  final bool isOffRoute;
  final GeoPoint position;
  final double headingDegrees;
  final VesselIconStyle vesselStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;

  /// Ephemeral visual trace for the current simulation run. Keeping this out
  /// of the durable awareness history prevents an older demo route from being
  /// connected to the current one after the bundled route changes.
  final List<GeoPoint> offRouteTrail;

  /// Recent on-road positions, used to show the actual path ridden by the
  /// current skipper without altering the planned route geometry.
  final List<GeoPoint> travelTrail;
}

/// Drives the production awareness pipeline with synthetic, authenticated GPS
/// fixes. The owning shell deliberately disables internet, nearby and device
/// location services for simulation sessions.
class VoyageSimulationController extends ChangeNotifier {
  VoyageSimulationController(
    this._awarenessController, {
    required VoyageSession session,
    required List<GeoPoint> route,
    List<GeoPoint> markerJunctions = const [],
    List<GeoPoint> fallbackJunctions = const [],
    this.tickInterval = const Duration(milliseconds: 100),
    this.eventInterval = const Duration(seconds: 2),
    this.sailorCount = VoyageSession.defaultSimulationSailorCount,
    bool voyageStarted = true,
  }) : assert(session.isSimulation),
       assert(route.length >= 2),
       assert(
         sailorCount >= VoyageSession.minimumSimulationSailorCount &&
             sailorCount <= VoyageSession.maximumSimulationSailorCount,
       ),
       _session = session,
       // Keep the public constructor argument usable outside this library.
       // ignore: prefer_initializing_formals
       _voyageStarted = voyageStarted,
       _routeSampler = _RouteSampler(route),
       _selectedLocalRole = session.role == VoyageRole.marker
           ? VoyageRole.sailor
           : session.role {
    final leadStart = _routeSampler.totalDistanceMeters * 0.06;
    _agents = _buildAgents(leadStart);
    List<double> usableJunctions(List<GeoPoint> points) => _routeSampler
        .progressesFor(points)
        .where(
          (progress) =>
              progress > leadStart + 140 &&
              progress < _routeSampler.totalDistanceMeters - 240,
        )
        .toList(growable: false);
    final requestedJunctions = usableJunctions(markerJunctions);
    final derivedJunctions = requestedJunctions.isEmpty
        ? usableJunctions(fallbackJunctions)
        : const <double>[];
    final selectedJunctions = requestedJunctions.isNotEmpty
        ? requestedJunctions
        : derivedJunctions;
    _markerJunctionProgresses = selectedJunctions.isEmpty
        ? [
            math.min(
              _routeSampler.totalDistanceMeters - 240,
              _routeSampler.totalDistanceMeters * 0.22,
            ),
          ]
        : selectedJunctions;
  }

  static const offRouteSailorId = 'voyage-lab-alex';
  static const sweeperSailorId = 'voyage-lab-charlie';

  final SituationalAwarenessController _awarenessController;
  final VoyageSession _session;
  final _RouteSampler _routeSampler;
  final Duration tickInterval;
  final Duration eventInterval;
  final int sailorCount;
  late final List<_SimulatedAgent> _agents;
  late final List<double> _markerJunctionProgresses;
  VoyageRole _selectedLocalRole;
  Timer? _timer;
  VoyageSimulationState _state = VoyageSimulationState.ready;
  Duration _simulatedElapsed = Duration.zero;
  double _timeScale = 8;
  double _baseSpeedMetersPerSecond = 13.4;
  bool _sweeperDelayed = false;
  bool _emitting = false;
  bool _markerMode = false;
  bool _voyageStarted;
  Duration _eventElapsed = Duration.zero;
  int _eventSequence = 0;
  DateTime? _lastRecordedAt;
  int _nextMarkerJunctionIndex = 0;
  double? _activeMarkerProgressMeters;
  String? _activeMarkerSailorId;
  Set<String> _sailorsExpectedToPass = const {};
  SimulationMarkerPhase _markerPhase = SimulationMarkerPhase.riding;
  Duration _sweeperApproachElapsed = Duration.zero;
  int _automaticMarkerActivation = 0;
  int _automaticMarkerGetUnderWayActivation = 0;
  bool _lastAutomaticMarkerGetUnderWayWasLocal = false;

  VoyageSimulationState get state => _state;
  Duration get simulatedElapsed => _simulatedElapsed;
  double get timeScale => _timeScale;
  double get baseSpeedMetersPerSecond => _baseSpeedMetersPerSecond;
  bool get sweeperDelayed => _sweeperDelayed;
  bool get voyageStarted => _voyageStarted;
  VoyageRole get localRole => _selectedLocalRole;
  bool get markerMode => _markerMode;
  SimulationMarkerPhase get markerPhase => _markerPhase;
  bool get automaticMarkerActive => _activeMarkerProgressMeters != null;
  bool get automaticMarkerIsLocal =>
      _activeMarkerSailorId == _session.localSailorId;
  String? get automaticMarkerSailorName => switch (_activeMarkerSailorId) {
    final String sailorId => _agent(sailorId).displayName,
    null => null,
  };
  bool get canGetUnderWay =>
      _markerMode && _markerPhase == SimulationMarkerPhase.readyToGetUnderWay;
  int get automaticMarkerActivation => _automaticMarkerActivation;
  int get automaticMarkerGetUnderWayActivation =>
      _automaticMarkerGetUnderWayActivation;
  bool get lastAutomaticMarkerGetUnderWayWasLocal =>
      _lastAutomaticMarkerGetUnderWayWasLocal;
  int get sailorsExpectedToPass => _sailorsExpectedToPass.length;
  int get sailorsPassedMarker {
    final markerProgress = _activeMarkerProgressMeters;
    if (markerProgress == null) return 0;
    return _sailorsExpectedToPass
        .where(
          (id) =>
              _agent(id).progressMeters >= markerProgress + _markerPassMeters,
        )
        .length;
  }

  double? get sweeperDistanceToMarkerMeters {
    final markerProgress = _activeMarkerProgressMeters;
    if (markerProgress == null) return null;
    return math.max(0, markerProgress - _agent(sweeperSailorId).progressMeters);
  }

  String get markerInstruction => switch (_markerPhase) {
    SimulationMarkerPhase.riding =>
      'The simulated second bike will stop at the next route decision.',
    SimulationMarkerPhase.waitingForSailors =>
      sailorsPassedMarker < sailorsExpectedToPass
          ? '${_markerSailorSubject()} $_markerSailorPresentVerb holding the junction while sailors pass '
                '($sailorsPassedMarker/$sailorsExpectedToPass).'
          : 'Sailors are through. ${_markerSailorSubject()} $_markerSailorPresentVerb waiting for '
                'Sweeper.',
    SimulationMarkerPhase.sweeperApproaching =>
      '${sailorsPassedMarker < sailorsExpectedToPass ? 'Traffic is still clearing. ' : 'All sailors are through. '}TEC is approaching — '
          '${_markerSailorSubject().toLowerCase()} should get ready to get under way.',
    SimulationMarkerPhase.readyToGetUnderWay =>
      'TEC has passed. ${_markerSailorSubject()} can get under way and return to '
          'navigation.',
  };
  bool get alexOffRoute => _agent(offRouteSailorId).isOffRoute;
  bool get isRunning => _state == VoyageSimulationState.running;
  double get routeDistanceMeters => _routeSampler.totalDistanceMeters;
  double get progress =>
      (_agents.first.progressMeters / routeDistanceMeters).clamp(0, 1);

  List<SimulatedSailorSnapshot> get sailors => List.unmodifiable(
    _agents.map((agent) {
      final sampled = _sampleAgent(agent);
      return SimulatedSailorSnapshot(
        id: agent.id,
        displayName: agent.isLocal ? _localPerspectiveName : agent.displayName,
        role: agent.role,
        progress: (agent.progressMeters / routeDistanceMeters).clamp(0, 1),
        speedMetersPerSecond: _speedFor(agent),
        isLocal: agent.isLocal,
        isOffRoute: agent.isOffRoute,
        position: sampled.position,
        headingDegrees: sampled.headingDegrees,
        offRouteTrail: List.unmodifiable(agent.offRouteTrail),
        travelTrail: List.unmodifiable(_displayTrailFor(agent)),
        vesselStyle: agent.vesselStyle,
        sailorSymbol: agent.sailorSymbol,
        sailorColor: agent.sailorColor,
      );
    }),
  );

  List<_SimulatedAgent> _buildAgents(double leadStart) {
    final trailingSpan = math.min(860, math.max(160, leadStart * 0.82));
    double initialProgress(int index) =>
        math.max(0, leadStart - trailingSpan * index / (sailorCount - 1));
    // Cycles through the catalogues so a full Voyage Lab group shows a variety
    // of silhouettes and colours without repeating the local sailor's own
    // choices. Lead/TEC roles still override to their reserved colour when
    // rendered, so this only ever shows for plain sailors.
    VesselIconStyle demoStyleFor(int index) =>
        VesselIconStyle.values[(index + 1) % VesselIconStyle.values.length];
    SailorColor demoColorFor(int index) =>
        SailorColor.values[(index + 1) % SailorColor.values.length];
    _SimulatedAgent sailor({
      required String id,
      required String displayName,
      required int index,
      required VoyageRole role,
      bool isLocal = false,
    }) => _SimulatedAgent(
      id: id,
      displayName: displayName,
      role: role,
      progressMeters: initialProgress(index),
      speedFactor: 1 - (0.2 * index / (sailorCount - 1)),
      trafficPhaseSeconds: (3 + index * 12) % 58,
      isLocal: isLocal,
      vesselStyle: isLocal ? _session.vesselStyle : demoStyleFor(index),
      sailorSymbol: isLocal ? _session.sailorSymbol : sailorSymbolDefault,
      sailorColor: isLocal ? _session.sailorColor : demoColorFor(index),
    );

    final agents = <_SimulatedAgent>[
      sailor(
        id: _session.localSailorId,
        displayName: _session.displayName,
        index: 0,
        role: _selectedLocalRole,
        isLocal: true,
      ),
      sailor(
        id: 'voyage-lab-maya',
        displayName: 'Maya',
        index: 1,
        role: _selectedLocalRole == VoyageRole.lead
            ? VoyageRole.sailor
            : VoyageRole.lead,
      ),
      sailor(
        id: offRouteSailorId,
        displayName: 'Alex',
        index: 2,
        role: VoyageRole.sailor,
      ),
    ];
    var nextIndex = 3;
    if (sailorCount >= 5) {
      agents.add(
        sailor(
          id: 'voyage-lab-jordan',
          displayName: 'Jordan',
          index: nextIndex++,
          role: VoyageRole.sailor,
        ),
      );
    }
    var sailorNumber = 1;
    while (agents.length < sailorCount - 1) {
      agents.add(
        sailor(
          id: 'voyage-lab-sailor-$sailorNumber',
          displayName: 'Sailor $sailorNumber',
          index: nextIndex++,
          role: VoyageRole.sailor,
        ),
      );
      sailorNumber += 1;
    }
    agents.add(
      sailor(
        id: sweeperSailorId,
        displayName: 'Charlie',
        index: sailorCount - 1,
        role: _selectedLocalRole == VoyageRole.sweeper
            ? VoyageRole.sailor
            : VoyageRole.sweeper,
      ),
    );
    return agents;
  }

  List<GeoPoint> _displayTrailFor(_SimulatedAgent agent) {
    if (agent.role != VoyageRole.lead) return agent.travelTrail;
    final sweeper = _agent(sweeperSailorId);
    final routeTrail = _routeSampler.pointsBetween(
      math.min(sweeper.progressMeters, agent.progressMeters),
      agent.progressMeters,
    );
    if (!agent.isOffRoute || agent.offRouteTrail.length < 2) {
      return routeTrail;
    }
    // Keep the planned path back to TEC, then show the actual deviation beyond
    // it so the skipper trail remains useful during a prolonged off-course run.
    return [...routeTrail, ...agent.offRouteTrail];
  }

  Future<void> initialize() async {
    for (final agent in _agents) {
      _recordTravelTrail(agent);
    }
    await _emitPositions();
  }

  void setVoyageStarted(bool value) {
    if (_voyageStarted == value) return;
    _voyageStarted = value;
    if (!value && _state != VoyageSimulationState.completed) {
      _state = VoyageSimulationState.ready;
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  void start() {
    if (!_voyageStarted ||
        _state == VoyageSimulationState.completed ||
        isRunning) {
      return;
    }
    _state = VoyageSimulationState.running;
    _timer ??= Timer.periodic(tickInterval, (_) {
      if (isRunning) unawaited(_tick(tickInterval));
    });
    notifyListeners();
  }

  void pause() {
    if (!isRunning) return;
    _state = VoyageSimulationState.paused;
    notifyListeners();
  }

  void setTimeScale(double value) {
    final next = value.clamp(1, 16).toDouble();
    if (next == _timeScale) return;
    _timeScale = next;
    notifyListeners();
  }

  void setBaseSpeedMetersPerSecond(double value) {
    final next = value.clamp(4, 25).toDouble();
    if (next == _baseSpeedMetersPerSecond) return;
    _baseSpeedMetersPerSecond = next;
    notifyListeners();
  }

  void setAlexOffRoute(bool value) {
    final alex = _agent(offRouteSailorId);
    if (alex.isOffRoute == value) return;
    alex.isOffRoute = value;
    alex.offRouteTrail.clear();
    if (value) _recordOffRouteTrail(alex);
    notifyListeners();
  }

  void setSweeperDelayed(bool value) {
    if (_sweeperDelayed == value) return;
    _sweeperDelayed = value;
    notifyListeners();
  }

  void setLocalRole(VoyageRole role) {
    if (role == VoyageRole.marker || role == _selectedLocalRole) return;
    // The virtual viewpoint can safely change while another sailor is holding a
    // junction. It remains locked only when this device is the marker.
    if (_markerMode &&
        (_activeMarkerSailorId == null || automaticMarkerIsLocal)) {
      return;
    }
    _selectedLocalRole = role;
    _assignPerspectiveRoles();
    if (_activeMarkerSailorId case final markerSailorId?) {
      _agent(markerSailorId).role = VoyageRole.marker;
    }
    _positionFleetForPerspective();
    _skipJunctionsBehindLocalSailor();
    for (final agent in _agents) {
      agent.travelTrail.clear();
      _recordTravelTrail(agent);
    }
    notifyListeners();
  }

  void setMarkerMode(bool value) {
    if (_markerMode == value) return;
    _markerMode = value;
    if (value) {
      _agents.first.role = VoyageRole.marker;
    } else {
      _finishMarkerMode();
      _assignPerspectiveRoles();
    }
    notifyListeners();
  }

  /// Leaves a completed automatic marker stop and resumes the navigation
  /// simulation. The owning shell records the matching marker-ended event.
  void getUnderWay() {
    if (!canGetUnderWay) return;
    setMarkerMode(false);
  }

  Future<void> _tick(Duration realElapsed) async {
    if (_state == VoyageSimulationState.completed) return;
    _advanceMotion(realElapsed);
    _eventElapsed += realElapsed;
    notifyListeners();
    if (_eventElapsed < eventInterval || _emitting) return;
    _eventElapsed = Duration.zero;
    await _emitPositions();
  }

  /// Advances virtual time and emits one GPS fix per sailor. Public so tests and
  /// scripted demos can progress deterministically without waiting for timers.
  Future<void> advance(Duration realElapsed) async {
    if (!_voyageStarted ||
        _state == VoyageSimulationState.completed ||
        _emitting) {
      return;
    }
    _advanceMotion(realElapsed);
    _eventElapsed = Duration.zero;
    await _emitPositions();
    notifyListeners();
  }

  void _advanceMotion(Duration realElapsed) {
    final simulatedMicroseconds = (realElapsed.inMicroseconds * _timeScale)
        .round();
    final simulatedDelta = Duration(microseconds: simulatedMicroseconds);
    _simulatedElapsed += simulatedDelta;
    final seconds =
        simulatedDelta.inMicroseconds / Duration.microsecondsPerSecond;
    final secondBike = _secondBikeFollowingLead();
    final lead = _leadAgent();
    final projectedLeadProgress = _isStoppedAtMarker(lead)
        ? lead.progressMeters
        : math.min(
            routeDistanceMeters,
            lead.progressMeters + _speedFor(lead) * seconds,
          );
    for (final agent in _agents) {
      if (_isStoppedAtMarker(agent)) continue;
      final nextProgress = math.min(
        routeDistanceMeters,
        agent.progressMeters + _speedFor(agent) * seconds,
      );
      if (agent.id == secondBike?.id &&
          _shouldStartAutomaticMarker(
            agent,
            nextProgress,
            projectedLeadProgress,
          )) {
        agent.progressMeters =
            _markerJunctionProgresses[_nextMarkerJunctionIndex];
        _startAutomaticMarker(agent);
        continue;
      }
      agent.progressMeters = nextProgress;
    }
    _keepFollowerBehindSkipper();
    for (final agent in _agents) {
      _recordTravelTrail(agent);
      if (agent.isOffRoute) _recordOffRouteTrail(agent);
    }
    _updateAutomaticMarkerPhase(realElapsed);
    final completed = _agents.every(
      (agent) => agent.progressMeters >= routeDistanceMeters,
    );
    if (completed) _state = VoyageSimulationState.completed;
    if (completed) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _emitPositions() async {
    if (_emitting) return;
    _emitting = true;
    try {
      final recordedAt = _nextRecordedAt();
      final samples = [
        for (final agent in _agents)
          (agent: agent, sampled: _sampleAgent(agent)),
      ];
      for (final entry in samples) {
        final agent = entry.agent;
        final sampled = entry.sampled;
        final sample = LocationSample(
          position: sampled.position,
          recordedAt: recordedAt,
          accuracyMeters: 4,
          speedMetersPerSecond: _speedFor(agent),
          headingDegrees: sampled.headingDegrees,
        );
        if (agent.isLocal) {
          await _awarenessController.recordLocalLocation(sample);
        } else {
          await _emitRemoteLocation(agent, sample, recordedAt);
        }
      }
    } finally {
      _emitting = false;
    }
  }

  Future<void> _emitRemoteLocation(
    _SimulatedAgent agent,
    LocationSample sample,
    DateTime recordedAt,
  ) async {
    final remoteSession = VoyageSession(
      voyageId: _session.voyageId,
      voyageCode: _session.voyageCode,
      inviteSecret: _session.inviteSecret,
      joinToken: _session.joinToken,
      localSailorId: agent.id,
      displayName: agent.displayName,
      role: agent.role,
      joinedAt: _session.joinedAt,
      isSimulation: true,
      vesselStyle: agent.vesselStyle,
      sailorSymbol: agent.sailorSymbol,
      sailorColor: agent.sailorColor,
    );
    final location = SailorLocation(
      sailorId: agent.id,
      displayName: agent.displayName,
      role: agent.role,
      sample: sample,
      receivedAt: recordedAt,
      vesselStyle: agent.vesselStyle,
      sailorSymbol: agent.sailorSymbol,
      sailorColor: agent.sailorColor,
    );
    final event =
        SituationEventFactory(
          session: remoteSession,
          clock: () => recordedAt,
          idFactory: () =>
              'voyage-lab-${agent.id}-${recordedAt.microsecondsSinceEpoch}-${_eventSequence++}',
        ).create(
          type: VoyageEventType.sailorLocationUpdated,
          payload: {'location': location.toJson()},
          expiresAt: recordedAt.add(const Duration(minutes: 30)),
        );
    await _awarenessController.ingestRemoteEvent(event);
  }

  double _speedFor(_SimulatedAgent agent) {
    if (!_voyageStarted) return 0;
    if (_state == VoyageSimulationState.completed) return 0;
    if (_isStoppedAtMarker(agent)) return 0;
    if (agent.id == sweeperSailorId && _sweeperDelayed) {
      return _baseSpeedMetersPerSecond * 0.45;
    }
    final elapsedSeconds =
        _simulatedElapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final trafficCycle = (elapsedSeconds + agent.trafficPhaseSeconds) % 58;
    // Staggered traffic-light waits let the virtual group spread naturally
    // rather than moving as a rigid five-bike line.
    final trafficFactor = trafficCycle < 4
        ? 0.08
        : 0.74 +
              0.22 *
                  ((math.sin(elapsedSeconds / 8 + agent.trafficPhaseSeconds) +
                          1) /
                      2);
    return _baseSpeedMetersPerSecond * agent.speedFactor * trafficFactor;
  }

  _SimulatedAgent _agent(String id) =>
      _agents.firstWhere((agent) => agent.id == id);

  void _recordOffRouteTrail(_SimulatedAgent agent) {
    final point = _sampleAgent(agent).position;
    final trail = agent.offRouteTrail;
    if (trail.isEmpty ||
        GeoCalculations.distanceMeters(trail.last, point) >= 2) {
      trail.add(point);
      if (trail.length > 600) trail.removeRange(0, trail.length - 600);
    }
  }

  void _recordTravelTrail(_SimulatedAgent agent) {
    final point = _sampleAgent(agent).position;
    final trail = agent.travelTrail;
    if (trail.isEmpty ||
        GeoCalculations.distanceMeters(trail.last, point) >= 2) {
      trail.add(point);
      if (trail.length > 180) trail.removeRange(0, trail.length - 180);
    }
  }

  bool _shouldStartAutomaticMarker(
    _SimulatedAgent candidate,
    double nextProgress,
    double projectedLeadProgress,
  ) {
    if (_markerMode ||
        _nextMarkerJunctionIndex >= _markerJunctionProgresses.length) {
      return false;
    }
    final markerProgress = _markerJunctionProgresses[_nextMarkerJunctionIndex];
    return candidate.id != _leadAgent().id &&
        projectedLeadProgress >= markerProgress + _skipperClearanceMeters &&
        nextProgress >= markerProgress;
  }

  void _startAutomaticMarker(_SimulatedAgent marker) {
    final markerProgress = _markerJunctionProgresses[_nextMarkerJunctionIndex];
    final lead = _leadAgent();
    _markerMode = true;
    _activeMarkerProgressMeters = markerProgress;
    _activeMarkerSailorId = marker.id;
    _markerPhase = SimulationMarkerPhase.waitingForSailors;
    marker.role = VoyageRole.marker;
    _sailorsExpectedToPass = {
      for (final agent in _agents)
        if (agent.id != marker.id &&
            agent.id != lead.id &&
            agent.id != sweeperSailorId &&
            agent.progressMeters <= markerProgress + _markerPassMeters)
          agent.id,
    };
    _lastAutomaticMarkerGetUnderWayWasLocal = false;
    _automaticMarkerActivation += 1;
  }

  void _updateAutomaticMarkerPhase(Duration realElapsed) {
    final markerProgress = _activeMarkerProgressMeters;
    if (!_markerMode || markerProgress == null) return;
    final sweeper = _agent(sweeperSailorId);
    final distance = markerProgress - sweeper.progressMeters;
    if (distance <= _sweeperVoyageOffMeters) {
      _lastAutomaticMarkerGetUnderWayWasLocal = automaticMarkerIsLocal;
      _automaticMarkerGetUnderWayActivation += 1;
      setMarkerMode(false);
      return;
    }
    if (distance <= _sweeperApproachMeters) {
      _markerPhase = SimulationMarkerPhase.sweeperApproaching;
      return;
    }
    final sailorsAreThrough = sailorsPassedMarker >= sailorsExpectedToPass;
    if (!sailorsAreThrough) {
      _markerPhase = SimulationMarkerPhase.waitingForSailors;
      _sweeperApproachElapsed = Duration.zero;
      return;
    }
    if (sweeper.progressMeters >= markerProgress + _markerPassMeters) {
      _markerPhase = SimulationMarkerPhase.sweeperApproaching;
      _sweeperApproachElapsed += realElapsed;
      if (_sweeperApproachElapsed >= const Duration(seconds: 2)) {
        _markerPhase = SimulationMarkerPhase.readyToGetUnderWay;
      }
      return;
    }
    _markerPhase = SimulationMarkerPhase.waitingForSailors;
    _sweeperApproachElapsed = Duration.zero;
  }

  void _finishMarkerMode() {
    if (_activeMarkerProgressMeters != null &&
        _nextMarkerJunctionIndex < _markerJunctionProgresses.length) {
      _nextMarkerJunctionIndex += 1;
    }
    _activeMarkerProgressMeters = null;
    _activeMarkerSailorId = null;
    _sailorsExpectedToPass = const {};
    _markerPhase = SimulationMarkerPhase.riding;
    _sweeperApproachElapsed = Duration.zero;
  }

  void _positionFleetForPerspective() {
    final local = _agents.first;
    if (_selectedLocalRole == VoyageRole.sweeper) {
      final lastRemoteProgress = _agents
          .where((agent) => !agent.isLocal)
          .map((agent) => agent.progressMeters)
          .reduce(math.min);
      local.progressMeters = math.max(0, lastRemoteProgress - 160);
      return;
    }
    if (_selectedLocalRole != VoyageRole.sailor) return;
    final maya = _agent('voyage-lab-maya');
    maya.progressMeters = math.min(
      routeDistanceMeters,
      math.max(maya.progressMeters, local.progressMeters + _followerGapMeters),
    );
  }

  void _keepFollowerBehindSkipper() {
    if (_selectedLocalRole != VoyageRole.sailor) return;
    final local = _agents.first;
    final lead = _leadAgent();
    if (lead.id == local.id) return;
    local.progressMeters = math.min(
      local.progressMeters,
      math.max(0, lead.progressMeters - _followerGapMeters),
    );
  }

  void _skipJunctionsBehindLocalSailor() {
    while (_nextMarkerJunctionIndex < _markerJunctionProgresses.length &&
        _markerJunctionProgresses[_nextMarkerJunctionIndex] <=
            _agents.first.progressMeters + 20) {
      _nextMarkerJunctionIndex += 1;
    }
  }

  _SimulatedPosition _sampleAgent(_SimulatedAgent agent) {
    final sampled = _routeSampler.sampleAt(agent.progressMeters);
    // The synthetic off-route scenario must recover at the destination so the
    // same completion rule used by a live voyage can end the demo naturally.
    final recoveredAtDestination =
        agent.progressMeters >= routeDistanceMeters - 45;
    return _SimulatedPosition(
      position: agent.isOffRoute && !recoveredAtDestination
          ? _offsetPoint(sampled.point, sampled.headingDegrees, 220)
          : sampled.point,
      headingDegrees: sampled.headingDegrees,
    );
  }

  void _assignPerspectiveRoles() {
    for (final agent in _agents) {
      agent.role = VoyageRole.sailor;
    }
    _agents.first.role = _selectedLocalRole;
    if (_selectedLocalRole != VoyageRole.lead) {
      _agent('voyage-lab-maya').role = VoyageRole.lead;
    }
    if (_selectedLocalRole != VoyageRole.sweeper) {
      _agent(sweeperSailorId).role = VoyageRole.sweeper;
    }
  }

  static const _markerPassMeters = 35.0;
  static const _sweeperApproachMeters = 260.0;
  static const _sweeperVoyageOffMeters = 55.0;
  static const _followerGapMeters = 180.0;
  static const _skipperClearanceMeters = 18.0;

  bool _isStoppedAtMarker(_SimulatedAgent agent) =>
      _markerMode &&
      (_activeMarkerSailorId == agent.id ||
          (_activeMarkerSailorId == null && agent.isLocal));

  _SimulatedAgent _leadAgent() => _agents.firstWhere(
    (agent) => agent.role == VoyageRole.lead,
    orElse: () => _agents.first,
  );

  _SimulatedAgent? _secondBikeFollowingLead() {
    final lead = _leadAgent();
    final following =
        _agents
            .where(
              (agent) =>
                  agent.id != lead.id &&
                  agent.progressMeters <= lead.progressMeters,
            )
            .toList(growable: false)
          ..sort(
            (first, second) =>
                second.progressMeters.compareTo(first.progressMeters),
          );
    return following.isEmpty ? null : following.first;
  }

  String _markerSailorSubject() => automaticMarkerIsLocal
      ? 'You'
      : (automaticMarkerSailorName ?? 'The sailor');

  String get _markerSailorPresentVerb => automaticMarkerIsLocal ? 'are' : 'is';

  String get _localPerspectiveName => switch (_selectedLocalRole) {
    VoyageRole.lead => _session.displayName,
    VoyageRole.sailor => 'You · Follower',
    VoyageRole.sweeper => 'You · TEC',
    VoyageRole.marker => 'You · Marker',
  };

  DateTime _nextRecordedAt() {
    final now = DateTime.now();
    final previous = _lastRecordedAt;
    final result = previous == null || now.isAfter(previous)
        ? now
        : previous.add(const Duration(milliseconds: 1));
    _lastRecordedAt = result;
    return result;
  }

  static GeoPoint _offsetPoint(
    GeoPoint point,
    double headingDegrees,
    double offsetMeters,
  ) {
    final direction = (headingDegrees + 90) * math.pi / 180;
    final northMeters = math.cos(direction) * offsetMeters;
    final eastMeters = math.sin(direction) * offsetMeters;
    final latitude = point.latitude + northMeters / 111320;
    final longitude =
        point.longitude +
        eastMeters / (111320 * math.cos(point.latitude * math.pi / 180).abs());
    return GeoPoint(latitude: latitude, longitude: longitude);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class _SimulatedAgent {
  _SimulatedAgent({
    required this.id,
    required this.displayName,
    required this.role,
    required this.progressMeters,
    required this.speedFactor,
    required this.trafficPhaseSeconds,
    required this.vesselStyle,
    required this.sailorColor,
    this.isLocal = false,
    this.sailorSymbol = sailorSymbolDefault,
  });

  final String id;
  final String displayName;
  VoyageRole role;
  double progressMeters;
  final double speedFactor;
  final double trafficPhaseSeconds;
  final VesselIconStyle vesselStyle;
  final SailorSymbol sailorSymbol;
  final SailorColor sailorColor;
  final bool isLocal;
  bool isOffRoute = false;
  final List<GeoPoint> offRouteTrail = [];
  final List<GeoPoint> travelTrail = [];
}

class _SimulatedPosition {
  const _SimulatedPosition({
    required this.position,
    required this.headingDegrees,
  });

  final GeoPoint position;
  final double headingDegrees;
}

class _RouteSampler {
  _RouteSampler(List<GeoPoint> route) : _route = List.unmodifiable(route) {
    _cumulativeDistances = [0];
    for (var index = 1; index < _route.length; index += 1) {
      _cumulativeDistances.add(
        _cumulativeDistances.last +
            GeoCalculations.distanceMeters(_route[index - 1], _route[index]),
      );
    }
    totalDistanceMeters = _cumulativeDistances.last;
    if (totalDistanceMeters <= 0) {
      throw ArgumentError('Simulation route must contain distinct points.');
    }
  }

  final List<GeoPoint> _route;
  late final List<double> _cumulativeDistances;
  late final double totalDistanceMeters;

  List<double> progressesFor(List<GeoPoint> points) {
    final values =
        points
            .map((point) => GeoCalculations.projectOntoPolyline(point, _route))
            .where((projection) => projection.distanceFromRouteMeters <= 120)
            .map((projection) => projection.distanceAlongRouteMeters)
            .toList()
          ..sort();
    final unique = <double>[];
    for (final value in values) {
      if (unique.isEmpty || value - unique.last >= 120) unique.add(value);
    }
    return List.unmodifiable(unique);
  }

  List<GeoPoint> pointsBetween(double fromMeters, double toMeters) {
    final start = fromMeters.clamp(0, totalDistanceMeters).toDouble();
    final end = toMeters.clamp(0, totalDistanceMeters).toDouble();
    if (end <= start) return [sampleAt(start).point];
    // Keep the skipper trace continuous enough to read on the map without
    // sending every GPS tick through the overlay source.
    final stepMeters = math.max(20, (end - start) / 750);
    final segmentCount = ((end - start) / stepMeters).ceil();
    return List.unmodifiable([
      for (var index = 0; index <= segmentCount; index += 1)
        sampleAt(start + (end - start) * index / segmentCount).point,
    ]);
  }

  _SampledRoutePoint sampleAt(double distanceMeters) {
    final target = distanceMeters.clamp(0, totalDistanceMeters).toDouble();
    var index = 0;
    while (index < _route.length - 2 &&
        _cumulativeDistances[index + 1] < target) {
      index += 1;
    }
    final start = _route[index];
    final end = _route[index + 1];
    final segmentLength =
        _cumulativeDistances[index + 1] - _cumulativeDistances[index];
    final fraction = segmentLength == 0
        ? 0.0
        : ((target - _cumulativeDistances[index]) / segmentLength).clamp(
            0.0,
            1.0,
          );
    return _SampledRoutePoint(
      point: GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      ),
      headingDegrees: _bearingDegrees(start, end),
    );
  }

  static double _bearingDegrees(GeoPoint start, GeoPoint end) {
    final latitude1 = start.latitude * math.pi / 180;
    final latitude2 = end.latitude * math.pi / 180;
    final longitudeDelta = (end.longitude - start.longitude) * math.pi / 180;
    final y = math.sin(longitudeDelta) * math.cos(latitude2);
    final x =
        math.cos(latitude1) * math.sin(latitude2) -
        math.sin(latitude1) * math.cos(latitude2) * math.cos(longitudeDelta);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
}

class _SampledRoutePoint {
  const _SampledRoutePoint({required this.point, required this.headingDegrees});

  final GeoPoint point;
  final double headingDegrees;
}
