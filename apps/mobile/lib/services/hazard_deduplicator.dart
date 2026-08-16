import '../domain/hazard.dart';
import 'geo_calculations.dart';

class HazardDeduplicator {
  const HazardDeduplicator({
    this.distanceThresholdMeters = 75,
    this.timeThreshold = const Duration(minutes: 30),
  });

  final double distanceThresholdMeters;
  final Duration timeThreshold;

  HazardReport mergeOrAdd(
    HazardReport incoming,
    Iterable<HazardReport> existing,
  ) {
    HazardReport? match;
    var nearestDistance = double.infinity;
    for (final candidate in existing) {
      if (candidate.type != incoming.type ||
          !candidate.isActiveAt(incoming.reportedAt) ||
          incoming.reportedAt.difference(candidate.updatedAt).abs() >
              timeThreshold) {
        continue;
      }
      final distance = GeoCalculations.distanceMeters(
        candidate.position,
        incoming.position,
      );
      if (distance <= distanceThresholdMeters && distance < nearestDistance) {
        match = candidate;
        nearestDistance = distance;
      }
    }
    if (match == null) {
      return incoming;
    }
    final severity = incoming.severity.index > match.severity.index
        ? incoming.severity
        : match.severity;
    final expiresAt = incoming.expiresAt.isAfter(match.expiresAt)
        ? incoming.expiresAt
        : match.expiresAt;
    return match.copyWith(
      severity: severity,
      updatedAt: incoming.updatedAt,
      expiresAt: expiresAt,
      details: incoming.details,
      confirmations: match.confirmations + 1,
    );
  }
}
