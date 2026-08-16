import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import '../domain/marker_assistance.dart';
import '../domain/ride_role.dart';
import '../domain/rider_location.dart';
import '../controllers/ride_controller.dart';
import '../controllers/situational_awareness_controller.dart';
import '../services/marker_pass_detector.dart';
import '../services/marker_suggestion_detector.dart';

typedef MarkerClock = DateTime Function();

class MarkerAssistanceController extends ChangeNotifier {
  MarkerAssistanceController(
    this._rideController,
    this._awarenessController, {
    required List<GeoPoint> route,
    required List<RouteDecisionPoint> decisionPoints,
    MarkerClock? clock,
    MarkerSuggestionConfig suggestionConfig = const MarkerSuggestionConfig(),
    MarkerPassConfig passConfig = const MarkerPassConfig(),
  }) : _clock = clock ?? DateTime.now,
       _suggestionDetector = MarkerSuggestionDetector(
         route: route,
         decisionPoints: decisionPoints,
         config: suggestionConfig,
       ),
       _passDetector = MarkerPassDetector(config: passConfig);

  final RideController _rideController;
  final SituationalAwarenessController _awarenessController;
  final MarkerClock _clock;
  final MarkerSuggestionDetector _suggestionDetector;
  final MarkerPassDetector _passDetector;

  MarkerSuggestionEvaluation _evaluation = const MarkerSuggestionEvaluation(
    state: MarkerSuggestionState.monitoring,
    message: 'Marker assistance is starting.',
  );
  Future<void> _evaluationQueue = Future.value();
  String? _passDetectorSessionId;
  bool _disposed = false;

  MarkerSuggestionEvaluation get evaluation => _evaluation;
  MarkerSuggestion? get suggestion => _evaluation.suggestion;
  bool get hasSuggestion => suggestion != null;
  bool get tecPassed => _rideController.tecPassedCurrentMarker;

  void initialize() {
    _rideController.addListener(_scheduleEvaluation);
    _awarenessController.addListener(_scheduleEvaluation);
    _scheduleEvaluation();
  }

  Future<void> evaluateNow() => _evaluate();

  Future<void> confirmSuggestion() async {
    final current = suggestion;
    if (current == null || _rideController.markerActive) return;
    await _rideController.startMarker(
      mode: 'assisted-confirmed',
      decisionPointId: current.decisionPoint.id,
    );
    if (_rideController.markerActive) {
      _suggestionDetector.accept(_clock());
    }
    await _evaluate();
  }

  void dismissSuggestion() {
    if (suggestion == null) return;
    _suggestionDetector.dismiss(_clock());
    _scheduleEvaluation();
  }

  void _scheduleEvaluation() {
    final previous = _evaluationQueue;
    _evaluationQueue = () async {
      try {
        await previous;
      } on Object {
        // A later location fix must still be evaluated.
      }
      await _evaluate();
    }();
  }

  Future<void> _evaluate() async {
    if (_disposed) return;
    final now = _clock();
    final local = _awarenessController.localLocation;
    final markerActive = _rideController.markerActive;
    final sessionId = _rideController.currentMarkerSessionId;

    if (markerActive &&
        sessionId != null &&
        sessionId != _passDetectorSessionId &&
        local != null) {
      _passDetectorSessionId = sessionId;
      _passDetector.start(local.sample.position, _remoteEvidence, now);
    } else if (!markerActive && _passDetectorSessionId != null) {
      _passDetector.stop();
      _passDetectorSessionId = null;
    }

    _evaluation = _suggestionDetector.evaluate(
      MarkerDetectorObservation(
        localLocation: local,
        groupLocations: _awarenessController.riderLocations,
        now: now,
        markerActive: markerActive,
      ),
    );

    if (markerActive && _passDetectorSessionId != null) {
      final passes = _passDetector.evaluate(_remoteEvidence, now);
      if (passes.isNotEmpty) {
        await _rideController.reloadEvents();
      }
      for (final pass in passes) {
        final role = RideRole.values.byName(pass.roleName);
        await _rideController.recordMarkerPass(
          pass.riderId,
          evidenceEventId: pass.locationEventId,
          riderRole: role,
          observedAt: pass.observedAt,
        );
      }
    }
    if (!_disposed) notifyListeners();
  }

  Iterable<RiderLocationEvidence> get _remoteEvidence =>
      _awarenessController.authenticatedLocationEvidence.where(
        (evidence) =>
            evidence.location.riderId != _rideController.session?.localRiderId,
      );

  @override
  void dispose() {
    _disposed = true;
    _rideController.removeListener(_scheduleEvaluation);
    _awarenessController.removeListener(_scheduleEvaluation);
    _passDetector.stop();
    super.dispose();
  }
}
