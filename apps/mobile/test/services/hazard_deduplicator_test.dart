import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/services/hazard_deduplicator.dart';

void main() {
  test('nearby same-type reports merge and preserve stable identity', () {
    final now = DateTime.utc(2026, 7, 16, 12);
    final original = _hazard(
      id: 'first',
      position: const GeoPoint(latitude: 51, longitude: -1),
      at: now,
    );
    final incoming = _hazard(
      id: 'second',
      position: const GeoPoint(latitude: 51.0002, longitude: -1),
      at: now.add(const Duration(minutes: 2)),
      severity: HazardSeverity.serious,
    );

    final merged = const HazardDeduplicator().mergeOrAdd(incoming, [original]);

    expect(merged.id, 'first');
    expect(merged.confirmations, 2);
    expect(merged.severity, HazardSeverity.serious);
  });

  test('different, distant, and expired reports stay independent', () {
    final now = DateTime.utc(2026, 7, 16, 12);
    final existing = _hazard(
      id: 'first',
      position: const GeoPoint(latitude: 51, longitude: -1),
      at: now.subtract(const Duration(hours: 2)),
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );
    final incoming = _hazard(
      id: 'second',
      position: const GeoPoint(latitude: 51, longitude: -1),
      at: now,
    );

    expect(
      const HazardDeduplicator().mergeOrAdd(incoming, [existing]).id,
      'second',
    );
  });

  test('hazard JSON preserves source and expiry metadata', () {
    final report = _hazard(
      id: 'hazard',
      position: const GeoPoint(latitude: 51, longitude: -1),
      at: DateTime.utc(2026, 7, 16, 12),
    );

    final restored = HazardReport.fromJson(report.toJson());

    expect(restored.id, report.id);
    expect(restored.position, report.position);
    expect(restored.expiresAt.isAtSameMomentAs(report.expiresAt), isTrue);
    expect(restored.source, HazardSource.rider);
  });
}

HazardReport _hazard({
  required String id,
  required GeoPoint position,
  required DateTime at,
  DateTime? expiresAt,
  HazardSeverity severity = HazardSeverity.caution,
}) => HazardReport(
  id: id,
  rideId: 'ride',
  type: HazardType.debris,
  severity: severity,
  position: position,
  reportedAt: at,
  updatedAt: at,
  expiresAt: expiresAt ?? at.add(const Duration(hours: 2)),
  reporterId: 'rider',
  source: HazardSource.rider,
);
