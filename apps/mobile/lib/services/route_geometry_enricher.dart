import '../domain/imported_route.dart';
import 'passage_planning_service.dart';

class RouteGeometryEnrichment {
  const RouteGeometryEnrichment({
    required this.route,
    required this.attempted,
    required this.snappedPathCount,
    this.warning,
  });

  final ImportedRoute route;
  final bool attempted;
  final int snappedPathCount;
  final String? warning;

  bool get changed => snappedPathCount > 0;
}

class RouteGeometryEnricher {
  const RouteGeometryEnricher({
    required this.passagePlanner,
    this.maximumViaPoints = 50,
  });

  final PassagePlanningService passagePlanner;
  final int maximumViaPoints;

  Future<RouteGeometryEnrichment> enrich(ImportedRoute route) async {
    final paths = <RoutePath>[];
    var attempted = false;
    var snapped = 0;
    String? warning;

    for (final path in route.paths) {
      if (path.kind != RoutePathKind.route || path.points.length < 2) {
        paths.add(path);
        continue;
      }
      attempted = true;
      try {
        final result = await passagePlanner.planThrough(
          _sample(path.points, maximumViaPoints),
        );
        paths.add(
          RoutePath(
            kind: RoutePathKind.track,
            name: path.name,
            points: result.points,
          ),
        );
        snapped += 1;
      } on Object catch (error) {
        paths.add(path);
        warning ??= 'Could not lay every GPX passage leg: $error';
      }
    }

    if (route.paths.isEmpty && route.waypoints.length >= 2) {
      attempted = true;
      try {
        final result = await passagePlanner.planThrough(
          _sample(
            route.waypoints.map((waypoint) => waypoint.point).toList(),
            maximumViaPoints,
          ),
        );
        paths.add(
          RoutePath(
            kind: RoutePathKind.track,
            name: route.name,
            points: result.points,
          ),
        );
        snapped += 1;
      } on Object catch (error) {
        warning = 'Could not lay the GPX waypoint passage: $error';
      }
    }

    if (snapped == 0) {
      return RouteGeometryEnrichment(
        route: route,
        attempted: attempted,
        snappedPathCount: 0,
        warning: warning,
      );
    }
    return RouteGeometryEnrichment(
      route: ImportedRoute(
        id: route.id,
        name: route.name,
        description: route.description,
        importedAt: route.importedAt,
        sourceFileName: route.sourceFileName,
        paths: List.unmodifiable(paths),
        waypoints: route.waypoints,
        // Recalculating geometry must not silently un-reject a marking
        // position a person already rejected for this route (#179).
        markerReview: route.markerReview,
        plannedDuration: route.plannedDuration,
      ),
      attempted: attempted,
      snappedPathCount: snapped,
      warning: warning,
    );
  }
}

List<GeoPoint> _sample(List<GeoPoint> points, int maximum) {
  if (maximum < 2) {
    throw ArgumentError.value(maximum, 'maximum', 'Must be at least two.');
  }
  if (points.length <= maximum) return List.unmodifiable(points);
  return List.generate(maximum, (index) {
    final sourceIndex = (index * (points.length - 1) / (maximum - 1)).round();
    return points[sourceIndex];
  }, growable: false);
}
