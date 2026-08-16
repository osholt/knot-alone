import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/imported_route.dart';
import '../domain/rider_location.dart';
import '../services/device_location_source.dart';
import '../services/geo_calculations.dart';

enum RouteRecorderState { idle, recording, paused }

/// Records a GPS track independent of any active ride, so a leader can
/// scout and save a route ahead of time and attach it to a ride later
/// (see [RecordedRouteStore]).
class RouteRecorderController extends ChangeNotifier {
  RouteRecorderController([DeviceLocationSource? source])
    : _source = source ?? DeviceLocationSource();

  final DeviceLocationSource _source;
  StreamSubscription<DeviceLocationStatus>? _statusSubscription;
  RouteRecorderState _state = RouteRecorderState.idle;
  final List<LocationSample> _samples = [];
  DateTime? _lastRecordedAt;
  String? _error;

  RouteRecorderState get state => _state;
  List<LocationSample> get samples => List.unmodifiable(_samples);
  int get pointCount => _samples.length;
  String? get error => _error;

  Duration get elapsed => _samples.isEmpty
      ? Duration.zero
      : _samples.last.recordedAt.difference(_samples.first.recordedAt);

  double get distanceMeters {
    var total = 0.0;
    for (var index = 1; index < _samples.length; index += 1) {
      total += GeoCalculations.distanceMeters(
        _samples[index - 1].position,
        _samples[index].position,
      );
    }
    return total;
  }

  /// Must be invoked by an explicit user action - it may prompt for location
  /// permission.
  Future<void> start() async {
    if (_state == RouteRecorderState.recording) return;
    _statusSubscription ??= _source.statuses.listen(_handleStatus);
    final access = await _source.requestAccess();
    if (!access.canSample) {
      _error = access.message;
      notifyListeners();
      return;
    }
    _error = null;
    _state = RouteRecorderState.recording;
    notifyListeners();
    await _source.start();
  }

  Future<void> pause() async {
    if (_state != RouteRecorderState.recording) return;
    await _source.stop();
    _state = RouteRecorderState.paused;
    notifyListeners();
  }

  Future<void> discard() async {
    await _source.stop();
    _samples.clear();
    _lastRecordedAt = null;
    _state = RouteRecorderState.idle;
    _error = null;
    notifyListeners();
  }

  /// Drops the point at [index] - e.g. a stray fix or an unwanted detour -
  /// keeping the rest of the trail intact and in order.
  void removePoint(int index) {
    if (index < 0 || index >= _samples.length) return;
    _samples.removeAt(index);
    notifyListeners();
  }

  /// Builds the finished recording as a GPX-exportable route, or null if
  /// [start]..[end] (inclusive; the full recording by default) selects
  /// fewer than two fixes to plot a meaningful track.
  ///
  /// The range is applied read-only, rather than by mutating [samples] -
  /// unlike [removePoint], an in-progress trim selection should stay purely
  /// a preview until the recording is actually saved.
  ImportedRoute? build({
    required String name,
    required String id,
    int? start,
    int? end,
  }) {
    final from = start ?? 0;
    final to = end ?? _samples.length - 1;
    if (from < 0 || to >= _samples.length || from > to) return null;
    final selected = _samples.sublist(from, to + 1);
    if (selected.length < 2) return null;
    final trimmedName = name.trim();
    final routeName = trimmedName.isEmpty ? 'Recorded route' : trimmedName;
    return ImportedRoute(
      id: id,
      name: routeName,
      importedAt: DateTime.now(),
      sourceFileName: 'recorded.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: routeName,
          points: [
            for (final sample in selected)
              GeoPoint(
                latitude: sample.position.latitude,
                longitude: sample.position.longitude,
                recordedAt: sample.recordedAt,
              ),
          ],
        ),
      ],
      waypoints: const [],
    );
  }

  void _handleStatus(DeviceLocationStatus status) {
    final sample = status.lastSample;
    if (status.state != DeviceLocationState.sampling ||
        sample == null ||
        sample.recordedAt == _lastRecordedAt) {
      return;
    }
    _lastRecordedAt = sample.recordedAt;
    _samples.add(sample);
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(disposeAsync());
    super.dispose();
  }

  /// Awaitable cleanup for callers (tests, in particular) that need to know
  /// the underlying subscription/location source have actually finished
  /// closing, not just that [dispose] has returned - [dispose] itself must
  /// stay synchronous to satisfy [ChangeNotifier], so it can't be awaited.
  Future<void> disposeAsync() async {
    await _statusSubscription?.cancel();
    await _source.dispose();
  }
}
