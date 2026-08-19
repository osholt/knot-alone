import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/route_preferences.dart';

/// These fixtures are the web planner's own numbers, copied from
/// `apps/website/planner-core.mjs`. If either side changes, one of the two test
/// suites fails, which is what stops the app and the planner disagreeing about
/// what a preference means (#182).
void main() {
  group('route styles match the web planner contract', () {
    test('api values and detour limits are the planner values', () {
      expect(RouteStyle.values.map((style) => style.apiValue), [
        'quickest',
        'balanced',
        'twisty',
        'very-twisty',
      ]);
      expect(RouteStyle.quickest.detourLimit, 1);
      expect(RouteStyle.flowing.detourLimit, 1.25);
      expect(RouteStyle.twisty.detourLimit, 1.5);
      expect(RouteStyle.veryTwisty.detourLimit, 1.75);
    });

    test('only the quickest style declines alternatives', () {
      expect(RouteStyle.quickest.prefersBends, isFalse);
      expect(RouteStyle.flowing.prefersBends, isTrue);
      expect(RouteStyle.twisty.prefersBends, isTrue);
      expect(RouteStyle.veryTwisty.prefersBends, isTrue);
    });

    test('an unknown stored style falls back to quickest', () {
      expect(RouteStyle.fromApiValue('flowing'), isNull);
      expect(
        RoutePreferences.fromJson(const {'style': 'flowing'}).style,
        RouteStyle.quickest,
      );
    });
  });

  group('byway default', () {
    test('unsurfaced byways are avoided unless a sailor says otherwise', () {
      expect(
        RoutePreferences.defaults.bywaySurface,
        BywaySurfacePreference.avoidUnsurfaced,
      );
      expect(RoutePreferences.defaults.bywaySurface.avoidsUnsurfaced, isTrue);
    });

    test(
      'a route with no recorded preference gets the road-biased default',
      () {
        expect(
          RoutePreferences.fromJson(const {}).bywaySurface,
          BywaySurfacePreference.avoidUnsurfaced,
        );
        expect(
          RoutePreferences.fromJson(const {
            'bywaySurface': 'nonsense',
          }).bywaySurface,
          BywaySurfacePreference.avoidUnsurfaced,
        );
      },
    );

    test('the summary always states which way round the byways are', () {
      expect(RoutePreferences.defaults.summary, 'Unsurfaced byways avoided.');
      expect(
        const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ).summary,
        'Unsurfaced byways allowed.',
      );
    });
  });

  group('engine choice matches requestRoadRoute in the web planner', () {
    test('defaults stay on OSRM', () {
      expect(RoutePreferences.defaults.requiresMotorcycleCosting, isFalse);
    });

    test('a bendier style alone stays on OSRM', () {
      for (final style in RouteStyle.values) {
        expect(
          RoutePreferences(style: style).requiresMotorcycleCosting,
          isFalse,
          reason: '${style.apiValue} needs only OSRM alternatives',
        );
      }
    });

    test('each avoidance moves to the motorcycle service', () {
      expect(
        const RoutePreferences(avoidMotorways: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidMajorRoads: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidTolls: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidFerries: true).requiresMotorcycleCosting,
        isTrue,
      );
    });

    test('seeking byways moves to the motorcycle service', () {
      // OSRM's car profile does not route highway=track at all, so this is the
      // byway case OSRM cannot serve.
      expect(
        const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ).requiresMotorcycleCosting,
        isTrue,
      );
    });
  });

  // The Valhalla costing-options group was here: six tests pinning this
  // class's translation into Valhalla's motorcycle costing model against the
  // web planner's numbers. Both the method and the service that consumed it
  // are gone (#31).
  //
  // The serialisation tests below stay, and matter more now: these fields no
  // longer reach a planner but are still written into saved routes and GPX,
  // so they have to keep round-tripping until #31 migrates them out.

  test('preferences round-trip through JSON', () {
    const preferences = RoutePreferences(
      style: RouteStyle.veryTwisty,
      avoidMotorways: true,
      avoidMajorRoads: true,
      avoidTolls: true,
      avoidFerries: true,
      bywaySurface: BywaySurfacePreference.allowUnsurfaced,
    );

    expect(RoutePreferences.fromJson(preferences.toJson()), preferences);
    expect(preferences.toJson()['style'], 'very-twisty');
    expect(preferences.toJson()['bywaySurface'], 'allow-unsurfaced');
  });

  test('the applied notes read in the planner order', () {
    expect(
      const RoutePreferences(
        style: RouteStyle.flowing,
        avoidMotorways: true,
        avoidMajorRoads: true,
        avoidTolls: true,
        avoidFerries: true,
      ).appliedNotes,
      [
        'Flowing-road bias',
        'motorways excluded',
        'major roads avoided',
        'tolls excluded',
        'ferries excluded',
        'unsurfaced byways avoided',
      ],
    );
  });
}
