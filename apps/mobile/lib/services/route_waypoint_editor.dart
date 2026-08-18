import '../domain/imported_route.dart';
import 'route_primary_path.dart';
import 'route_reshape_planner.dart';

/// Inserts a deliberate stop on the leg nearest [waypoint].
///
/// Shaping controls are re-indexed around the new stop so adding a café or
/// meeting point does not discard route adjustments the sailor already made.
ImportedRoute insertRouteWaypoint(ImportedRoute route, RouteWaypoint waypoint) {
  final waypoints = _editableWaypoints(route);
  if (waypoints.length < 2) {
    throw const FormatException(
      'A route needs a start and destination before a waypoint can be added.',
    );
  }
  final legIndex = routeLegIndexForPoint(route, waypoint.point);
  final insertionIndex = (legIndex + 1).clamp(1, waypoints.length - 1);
  final waypointProgress = routeProgressForPoint(route, waypoint.point);
  final shapingPoints = [
    for (final shapingPoint in route.shapingPoints)
      RouteShapingPoint(
        id: shapingPoint.id,
        point: shapingPoint.point,
        legIndex: shapingPoint.legIndex < legIndex
            ? shapingPoint.legIndex
            : shapingPoint.legIndex > legIndex
            ? shapingPoint.legIndex + 1
            : routeProgressForPoint(route, shapingPoint.point) <=
                  waypointProgress
            ? legIndex
            : legIndex + 1,
      ),
  ];
  final updatedWaypoints = [...waypoints]..insert(insertionIndex, waypoint);
  return _withWaypoints(route, updatedWaypoints, shapingPoints);
}

/// Removes an intermediate stop and merges the two surrounding route legs.
ImportedRoute removeRouteWaypoint(ImportedRoute route, int index) {
  if (index <= 0 || index >= route.waypoints.length - 1) {
    throw const FormatException(
      'The route start and destination cannot be removed.',
    );
  }
  final removedLeg = index - 1;
  final waypoints = [...route.waypoints]..removeAt(index);
  final shapingPoints = [
    for (final shapingPoint in route.shapingPoints)
      RouteShapingPoint(
        id: shapingPoint.id,
        point: shapingPoint.point,
        legIndex: shapingPoint.legIndex <= removedLeg
            ? shapingPoint.legIndex
            : shapingPoint.legIndex - 1,
      ),
  ];
  return _withWaypoints(route, waypoints, shapingPoints);
}

ImportedRoute _withWaypoints(
  ImportedRoute route,
  List<RouteWaypoint> waypoints,
  List<RouteShapingPoint> shapingPoints,
) => ImportedRoute(
  id: route.id,
  name: route.name,
  description: route.description,
  importedAt: route.importedAt,
  sourceFileName: route.sourceFileName,
  paths: route.paths,
  waypoints: List.unmodifiable(waypoints),
  shapingPoints: List.unmodifiable(shapingPoints),
  // These describe the old route. The live recalculation replaces them before
  // the candidate can be confirmed.
  maneuvers: const [],
  markerReview: route.markerReview,
  preferences: route.preferences,
);

List<RouteWaypoint> _editableWaypoints(ImportedRoute route) {
  if (route.waypoints.length >= 2) return route.waypoints;
  final geometry = routePrimaryPath(route);
  if (geometry.length < 2) return route.waypoints;
  return [
    RouteWaypoint(point: geometry.first, name: 'Start', symbol: 'Flag, Blue'),
    RouteWaypoint(
      point: geometry.last,
      name: 'Destination',
      symbol: 'Flag, Red',
    ),
  ];
}

/// Progress along the primary ridden geometry, used to keep edits ordered.
double routeProgressForPoint(ImportedRoute route, GeoPoint point) {
  final geometry = routePrimaryPath(route);
  if (geometry.length < 2) return 0;
  var nearestProgress = 0.0;
  var nearestDistance = double.infinity;
  for (var index = 1; index < geometry.length; index += 1) {
    final start = geometry[index - 1];
    final end = geometry[index];
    final latitudeDelta = end.latitude - start.latitude;
    final longitudeDelta = end.longitude - start.longitude;
    final lengthSquared =
        latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta;
    final position = lengthSquared == 0
        ? 0.0
        : (((point.latitude - start.latitude) * latitudeDelta +
                      (point.longitude - start.longitude) * longitudeDelta) /
                  lengthSquared)
              .clamp(0.0, 1.0);
    final projectedLatitude = start.latitude + position * latitudeDelta;
    final projectedLongitude = start.longitude + position * longitudeDelta;
    final latitudeError = point.latitude - projectedLatitude;
    final longitudeError = point.longitude - projectedLongitude;
    final distance =
        latitudeError * latitudeError + longitudeError * longitudeError;
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestProgress = index - 1 + position;
    }
  }
  return nearestProgress;
}

/// Renames a mark, leaving the passage itself untouched.
///
/// Deliberately does **not** go through [_withWaypoints]. Insert and remove
/// change the geometry, so they clear the manoeuvres and the planned duration
/// and force a re-plan. A name change does none of that: the courses, the
/// distances and the times are all exactly what they were. Routing it through
/// the re-planner would throw away a correct plan and make the sailor watch a
/// progress bar for typing a word.
///
/// A blank name clears it rather than storing an empty string, so a cleared
/// name reads the same as a mark that never had one - which is what GPX
/// round-trips and what the review list's fallback labelling already handles.
ImportedRoute renameRouteWaypoint(
  ImportedRoute route,
  int index,
  String? name,
) {
  if (index < 0 || index >= route.waypoints.length) {
    throw const FormatException('That mark is not on this passage.');
  }
  final trimmed = name?.trim();
  final existing = route.waypoints[index];
  final waypoints = [...route.waypoints];
  waypoints[index] = RouteWaypoint(
    point: existing.point,
    name: trimmed == null || trimmed.isEmpty ? null : trimmed,
    description: existing.description,
    symbol: existing.symbol,
  );
  return ImportedRoute(
    id: route.id,
    name: route.name,
    description: route.description,
    importedAt: route.importedAt,
    sourceFileName: route.sourceFileName,
    paths: route.paths,
    waypoints: List.unmodifiable(waypoints),
    shapingPoints: route.shapingPoints,
    maneuvers: route.maneuvers,
    markerReview: route.markerReview,
    preferences: route.preferences,
    plannedDuration: route.plannedDuration,
  );
}

/// A default name for a newly placed mark that no existing mark is using.
///
/// Naming from the waypoint count collides: place a mark on a five-mark passage
/// and it becomes "Mark 5"; remove a different mark and place another, and the
/// count is five again, so two marks on the same passage answer to the same
/// name. Two identically named marks in a passage brief is a real hazard rather
/// than an untidiness - "steer for Mark 5" stops being an instruction.
String nextMarkName(ImportedRoute route) {
  final taken = {
    for (final waypoint in route.waypoints)
      if (waypoint.name case final name?) name.trim().toLowerCase(),
  };
  for (var number = 1; ; number += 1) {
    final candidate = 'Mark $number';
    if (!taken.contains(candidate.toLowerCase())) return candidate;
  }
}
