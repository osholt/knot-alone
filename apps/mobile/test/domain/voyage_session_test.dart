import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_coordination_mode.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/features/map/motorcycle_icon.dart';

void main() {
  final session = VoyageSession(
    voyageId: 'voyage',
    voyageCode: 'SIM123',
    inviteSecret: 'secret',
    joinToken: 'aTokenWithPlentyOfEntropy',
    localSailorId: 'lead',
    displayName: 'Demo Lead',
    role: VoyageRole.lead,
    joinedAt: DateTime.utc(2026, 7, 17),
    isSimulation: true,
  );

  test('simulation marker survives session persistence', () {
    expect(VoyageSession.fromJson(session.toJson()).isSimulation, isTrue);
  });

  test(
    'simulation sailor count persists and legacy sessions use five sailors',
    () {
      final configured = VoyageSession(
        voyageId: 'voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'secret',
        joinToken: 'aTokenWithPlentyOfEntropy',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.lead,
        joinedAt: DateTime.utc(2026, 7, 17),
        isSimulation: true,
        simulationSailorCount: 30,
      );
      expect(
        VoyageSession.fromJson(configured.toJson()).simulationSailorCount,
        30,
      );

      final legacy = session.toJson()..remove('simulationSailorCount');
      expect(
        VoyageSession.fromJson(legacy).simulationSailorCount,
        VoyageSession.defaultSimulationSailorCount,
      );
    },
  );

  test('legacy sessions default to live voyages', () {
    final json = session.toJson()..remove('isSimulation');
    expect(VoyageSession.fromJson(json).isSimulation, isFalse);
  });

  test(
    'coordination mode persists and old voyages keep drop-off behaviour',
    () {
      final solo = VoyageSession(
        voyageId: 'voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'secret',
        joinToken: 'aTokenWithPlentyOfEntropy',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.lead,
        joinedAt: DateTime.utc(2026, 7, 17),
        coordinationMode: VoyageCoordinationMode.solo,
      );
      expect(
        VoyageSession.fromJson(solo.toJson()).coordinationMode,
        VoyageCoordinationMode.solo,
      );

      final legacy = solo.toJson()..remove('coordinationMode');
      expect(
        VoyageSession.fromJson(legacy).coordinationMode,
        VoyageCoordinationMode.crew,
      );
    },
  );

  test(
    'sailor symbol survives session persistence and old sessions use a bike',
    () {
      final custom = VoyageSession(
        voyageId: 'voyage',
        voyageCode: 'SIM123',
        inviteSecret: 'secret',
        joinToken: 'aTokenWithPlentyOfEntropy',
        localSailorId: 'lead',
        displayName: 'Demo Lead',
        role: VoyageRole.lead,
        joinedAt: DateTime.utc(2026, 7, 17),
        sailorSymbol: const SailorSymbol.initials(),
      );
      expect(
        VoyageSession.fromJson(custom.toJson()).sailorSymbol,
        const SailorSymbol.initials(),
      );

      final legacy = custom.toJson()..remove('sailorSymbol');
      expect(VoyageSession.fromJson(legacy).sailorSymbol, sailorSymbolDefault);
    },
  );

  test(
    'a session persisted before join tokens existed gets a fresh one instead of crashing',
    () {
      final json = session.toJson()..remove('joinToken');
      final restored = VoyageSession.fromJson(json);
      expect(restored.joinToken.length, greaterThanOrEqualTo(16));
    },
  );
}
