import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';

void main() {
  group('the active voyage names its destinations once (#404)', () {
    // The navigation bar, the landscape rail and the voyage menu all read this
    // list. The menu is the only way to reach these while the sailor is moving,
    // so a copy that drifted would send a sailor to the wrong tab at exactly the
    // moment they cannot look at the screen.

    test('an ordinary voyage is Map, Voyage, Settings', () {
      final destinations = voyageDestinations(simulation: false);

      expect(destinations.map((destination) => destination.label), [
        'Map',
        'Voyage',
        'Settings',
      ]);
      expect(destinations.map((destination) => destination.index), [0, 1, 2]);
    });

    test('a simulation inserts Voyage Lab and shifts what follows it', () {
      // The shell's `switch` puts Voyage Lab at 1 in a simulation, so Voyage and
      // Settings is one further along than in an ordinary voyage. Carrying the
      // index rather than letting a caller count is what keeps the menu
      // agreeing with the bar.
      final destinations = voyageDestinations(simulation: true);

      expect(destinations.map((destination) => destination.label), [
        'Map',
        'Voyage Lab',
        'Voyage',
        'Settings',
      ]);
      expect(destinations.map((destination) => destination.index), [
        0,
        1,
        2,
        3,
      ]);
      expect(
        destinations.firstWhere((d) => d.label == 'Voyage').index,
        2,
        reason: 'Voyage Lab occupies 1 in a simulation',
      );
    });

    test('the map is always the first destination', () {
      // `hideWhileMoving` is written against index 0 being the map. If that
      // ever stopped being true the bar would hide on the wrong tab.
      for (final simulation in [false, true]) {
        expect(
          voyageDestinations(simulation: simulation).first.index,
          0,
          reason: 'simulation: $simulation',
        );
        expect(
          voyageDestinations(simulation: simulation).first.label,
          'Map',
          reason: 'simulation: $simulation',
        );
      }
    });
  });
}
