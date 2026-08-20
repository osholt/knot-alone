import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/mob_state.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';

void main() {
  test('activation survives reduction with its last-known fix', () {
    final state = MobReducer.reduce([
      _event(
        id: 'mob-1',
        type: VoyageEventType.mobActivated,
        payload: {
          'latitude': 50.8,
          'longitude': -1.1,
          'positionRecordedAt': '2026-08-20T12:00:00.000Z',
          'accuracyMeters': 7.0,
          'positionSource': 'gnss',
          'fixStale': false,
        },
      ),
    ]);

    expect(state.active, isTrue);
    expect(state.activeIncident!.activationEventId, 'mob-1');
    expect(state.activeIncident!.fix.latitude, 50.8);
    expect(state.activeIncident!.fix.source, 'gnss');
    expect(state.activeIncident!.fix.stale, isFalse);
  });

  test('only a matching explicit resolution clears the incident', () {
    final activation = _event(
      id: 'mob-1',
      type: VoyageEventType.mobActivated,
      payload: const {'positionSource': 'none', 'fixStale': true},
    );
    final wrong = _event(
      id: 'resolved-wrong',
      type: VoyageEventType.mobResolved,
      at: DateTime.utc(2026, 8, 20, 12, 1),
      payload: const {
        'activationEventId': 'another',
        'resolution': 'recovered',
      },
    );
    final matching = _event(
      id: 'resolved',
      type: VoyageEventType.mobResolved,
      at: DateTime.utc(2026, 8, 20, 12, 2),
      payload: const {'activationEventId': 'mob-1', 'resolution': 'recovered'},
    );

    expect(MobReducer.reduce([activation, wrong]).active, isTrue);
    expect(MobReducer.reduce([activation, wrong, matching]).active, isFalse);
  });
}

VoyageEvent _event({
  required String id,
  required VoyageEventType type,
  required Map<String, Object?> payload,
  DateTime? at,
}) => VoyageEvent(
  id: id,
  voyageId: 'voyage',
  deviceId: 'device',
  type: type,
  priority: EventPriority.critical,
  createdAt: at ?? DateTime.utc(2026, 8, 20, 12),
  payload: payload,
  signature: 'a' * 64,
);
