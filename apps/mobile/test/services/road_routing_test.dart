import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/road_routing.dart';
import 'package:tide_and_seek/services/route_geometry_enricher.dart';

import 'osrm_maneuver_fixtures.dart';

void main() {
  // The mini-roundabout layer is a bundled asset.
  TestWidgetsFlutterBinding.ensureInitialized();
  test('OSRM client requests and parses full road geometry', () async {
    final client = MockClient((request) async {
      expect(request.url.path, contains('/route/v1/driving/'));
      expect(request.url.queryParameters['geometries'], 'geojson');
      expect(request.url.queryParameters['overview'], 'full');
      expect(request.url.queryParameters['steps'], 'true');
      expect(request.url.queryParameters['bearings'], isNull);
      expect(request.headers['User-Agent'], contains('Sweeper'));
      return http.Response(
        jsonEncode({
          'code': 'Ok',
          'routes': [
            {
              'distance': 1250.5,
              'duration': 92.4,
              'geometry': {
                'coordinates': [
                  [-1.0, 53.0],
                  [-1.005, 53.005],
                  [-1.01, 53.01],
                ],
              },
              'legs': [
                {
                  'steps': [
                    {
                      'name': 'Gorse Lane',
                      'driving_side': 'left',
                      'maneuver': {
                        'type': 'roundabout',
                        'modifier': 'right',
                        'exit': 3,
                        'location': [-2.386091, 51.452344],
                      },
                      'intersections': [
                        {
                          'lanes': [
                            {
                              'indications': ['left'],
                              'valid': false,
                            },
                            {
                              'indications': ['straight', 'right'],
                              'valid': true,
                            },
                          ],
                        },
                      ],
                    },
                    {
                      'name': 'London Road',
                      'maneuver': {
                        'type': 'new name',
                        'location': [-2.35, 51.5],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final service = OsrmRoadRoutingService(
      client: client,
      baseUrl: Uri.parse('https://routing.example.test'),
    );

    final result = await service.routeThrough(const [
      GeoPoint(latitude: 53, longitude: -1),
      GeoPoint(latitude: 53.01, longitude: -1.01),
    ]);

    expect(result.points, hasLength(3));
    expect(result.distanceMeters, 1250.5);
    expect(result.duration, const Duration(milliseconds: 92400));
    expect(result.maneuvers, hasLength(2));
    expect(result.maneuvers.first.requiresSecondBikeDrop, isTrue);
    expect(result.maneuvers.first.name, 'Gorse Lane');
    expect(result.maneuvers.first.exitNumber, 3);
    expect(result.maneuvers.first.drivingSide, 'left');
    expect(result.maneuvers.first.lanes, hasLength(2));
    expect(result.maneuvers.first.lanes.first.valid, isFalse);
    expect(result.maneuvers.first.lanes.last.indications, [
      'straight',
      'right',
    ]);
    expect(result.maneuvers.last.requiresSecondBikeDrop, isFalse);
  });

  test('OSRM constrains only the moving reroute origin bearing', () async {
    final client = MockClient((request) async {
      // OSRM requires one bearings element per coordinate; empty elements keep
      // the normal snap at later rejoin waypoints.
      expect(request.url.queryParameters['bearings'], '91,60;;');
      return http.Response(_osrmResponse(), 200);
    });
    final service = OsrmRoadRoutingService(
      client: client,
      baseUrl: Uri.parse('https://routing.example.test'),
    );

    await service.routeThrough(const [
      GeoPoint(latitude: 53, longitude: -1),
      GeoPoint(latitude: 53.01, longitude: -1.01),
      GeoPoint(latitude: 53.02, longitude: -1.02),
    ], originBearingDegrees: 90.6);
  });

  test('roundabout steps keep their bearings, exit count and lanes', () async {
    final route = await routeFromOsrmResponse(ukRoundaboutStraightOnResponse());

    final entry = route.maneuvers[1];
    final exit = route.maneuvers[2];

    expect(entry.type, 'roundabout');
    expect(entry.exitNumber, 2);
    expect(entry.modifier, 'slight left');
    expect(entry.bearingBeforeDegrees, 1);
    expect(entry.bearingAfterDegrees, 315);
    expect(entry.drivingSide, 'left');
    expect(entry.lanes.map((lane) => lane.valid), [false, true, false]);
    expect(exit.type, 'exit roundabout');
    expect(exit.bearingAfterDegrees, 2);
  });

  test(
    'a junction the engine omits is restored from the bundled layer',
    () async {
      // The captured response is a real OSRM answer that genuinely omits two
      // mapped mini-roundabouts (#163). It used to be fixed by a hand-reviewed
      // catalogue holding those two junctions and their hand-measured arms;
      // this asserts the general OpenStreetMap layer covers them instead.
      final catalogue = await MappedMiniRoundaboutCatalogue.load();
      final response = newCheltenhamRoadOmittedRoundaboutsResponse();
      final rawLocations =
          (((response['routes'] as List).single as Map)['legs'] as List)
              .expand((leg) => ((leg as Map)['steps'] as List).whereType<Map>())
              .map((step) => (step['maneuver'] as Map)['location'])
              .toList(growable: false);
      expect(
        rawLocations,
        isNot(contains(equals([-2.5010632, 51.4672133]))),
        reason: 'the captured engine response genuinely omits the west node',
      );
      expect(
        rawLocations,
        isNot(contains(equals([-2.5005026, 51.4670501]))),
        reason: 'the captured engine response genuinely omits the east node',
      );

      final route = await routeFromOsrmResponse(
        response,
        id: 'issue-163',
        readMiniRoundabouts: () async => catalogue,
      );
      final restored = route.maneuvers
          .where(
            (maneuver) =>
                maneuver.type == 'roundabout' &&
                (maneuver.position.longitude - -2.5010632).abs() < 0.0005,
          )
          .toList(growable: false);

      expect(restored, hasLength(1));
      // No exit number is claimed. Counting exits needs every arm's bearing,
      // which this layer does not carry - the catalogue it replaced carried
      // them for two junctions by hand and for nowhere else.
      expect(restored.single.exitNumber, isNull);
      // Stated because OpenStreetMap states it for this node, not assumed.
      expect(restored.single.drivingSide, 'left');
      expect(restored.single.bearingBeforeDegrees, isNotNull);
    },
  );

  test(
    'the bundled layer is general, not a list of reported junctions',
    () async {
      final catalogue = await MappedMiniRoundaboutCatalogue.load();

      // The point of the change: coverage is whatever OpenStreetMap maps, so a
      // junction nobody has reported is served exactly as well as one that has.
      expect(catalogue.roundabouts.length, greaterThan(10000));
      expect(
        catalogue.roundabouts.where(
          (roundabout) =>
              roundabout.rotation == MiniRoundaboutRotation.clockwise,
        ),
        isNotEmpty,
      );
    },
  );

  test('restoration is bounded and never duplicates an engine step', () {
    // Arbitrary coordinates: the rule is what is under test, not a place.
    const node = GeoPoint(latitude: 53.1000, longitude: -1.5000);
    const catalogue = MappedMiniRoundaboutCatalogue([
      MappedMiniRoundabout(
        position: node,
        rotation: MiniRoundaboutRotation.clockwise,
      ),
    ]);

    const wellAway = [
      GeoPoint(latitude: 53.2000, longitude: -1.6000),
      GeoPoint(latitude: 53.2000, longitude: -1.5000),
    ];
    expect(
      catalogue.enrich(route: wellAway, maneuvers: const []),
      isEmpty,
      reason: 'ordinary route geometry is not inferred to be a roundabout',
    );

    const throughNode = [
      GeoPoint(latitude: 53.1010, longitude: -1.5010),
      node,
      GeoPoint(latitude: 53.0990, longitude: -1.4990),
    ];
    const engineManeuvers = [
      RoadRouteManeuver(position: node, type: 'roundabout', exitNumber: 2),
      RoadRouteManeuver(position: node, type: 'exit roundabout'),
    ];
    expect(
      catalogue.enrich(route: throughNode, maneuvers: engineManeuvers),
      same(engineManeuvers),
      reason: 'a future provider fix must not create duplicate instructions',
    );

    final restored = catalogue.enrich(route: throughNode, maneuvers: const []);
    expect(restored.map((maneuver) => maneuver.type), [
      'roundabout',
      'exit roundabout',
    ]);
    expect(restored.first.exitNumber, isNull);
  });

  test('a small roundabout reported as a turn still needs a marker', () {
    expect(
      const RoadRouteManeuver(
        position: GeoPoint(latitude: 51.46, longitude: -2.59),
        type: 'roundabout turn',
        modifier: 'left',
      ).requiresSecondBikeDrop,
      isTrue,
    );
  });

  test(
    'destination search supports coordinates and one-shot place search',
    () async {
      var requests = 0;
      final service = NominatimDestinationSearchService(
        client: MockClient((request) async {
          requests += 1;
          expect(request.url.queryParameters['q'], 'Matlock Bath');
          expect(request.url.queryParameters['limit'], '5');
          return http.Response(
            jsonEncode([
              {
                'lat': '53.121',
                'lon': '-1.562',
                'display_name': 'Matlock Bath, Derbyshire, United Kingdom',
              },
            ]),
            200,
          );
        }),
        baseUrl: Uri.parse('https://geocoding.example.test'),
      );

      final coordinateMatch = await service.search('53.12, -1.56');
      final placeMatch = await service.search('Matlock Bath');

      expect(coordinateMatch.single.point.latitude, 53.12);
      expect(placeMatch.single.label, startsWith('Matlock Bath'));
      expect(requests, 1);
    },
  );

  test(
    'sparse GPX route points are replaced with road track geometry',
    () async {
      final routing = _FakeRoadRoutingService();
      final route = ImportedRoute(
        id: 'route',
        name: 'Sparse route',
        importedAt: DateTime.utc(2026),
        sourceFileName: 'sparse.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            name: 'Recorded section',
            points: [
              GeoPoint(latitude: 52.9, longitude: -1),
              GeoPoint(latitude: 52.91, longitude: -1.01),
            ],
          ),
          RoutePath(
            kind: RoutePathKind.route,
            name: 'Planned section',
            points: [
              GeoPoint(latitude: 53, longitude: -1),
              GeoPoint(latitude: 53.1, longitude: -1.1),
            ],
          ),
        ],
        waypoints: const [],
      );

      final result = await RouteGeometryEnricher(
        routingService: routing,
      ).enrich(route);

      expect(result.changed, isTrue);
      expect(result.snappedPathCount, 1);
      expect(result.route.paths.first.kind, RoutePathKind.track);
      expect(result.route.paths.last.kind, RoutePathKind.track);
      expect(result.route.paths.last.points, hasLength(3));
      expect(result.route.maneuvers.single.name, 'High Street');
      expect(routing.requests.single, hasLength(2));
    },
  );

  test('destination plan geocodes an explicit start location instead of '
      'requiring the current position', () async {
    final search = NominatimDestinationSearchService(
      client: MockClient((request) async {
        final query = request.url.queryParameters['q'];
        final point = query == 'Matlock Bath'
            ? {'lat': '53.121', 'lon': '-1.562'}
            : {'lat': '52.0', 'lon': '-1.9'};
        return http.Response(
          jsonEncode([
            {...point, 'display_name': '$query, United Kingdom'},
          ]),
          200,
        );
      }),
      baseUrl: Uri.parse('https://geocoding.example.test'),
    );
    final routing = _FakeRoadRoutingService();
    final planner = DestinationRoutePlanner(
      searchService: search,
      routingService: routing,
    );

    final route = await planner.plan(
      originQuery: 'Bakewell',
      query: 'Matlock Bath',
    );

    expect(route.waypoints.first.point.latitude, 52.0);
    expect(routing.requests.single.first.latitude, 52.0);
    expect(route.maneuvers.single.name, 'High Street');
  });

  test(
    'destination plan requires either a current position or a start query',
    () async {
      final planner = DestinationRoutePlanner(
        searchService: NominatimDestinationSearchService(
          client: MockClient((_) async => http.Response('[]', 200)),
          baseUrl: Uri.parse('https://geocoding.example.test'),
        ),
        routingService: _FakeRoadRoutingService(),
      );

      await expectLater(
        planner.plan(query: 'Matlock Bath'),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'destination review preserves ordered stops and reports ambiguity',
    () async {
      final search = _FakeDestinationSearchService({
        'Start': const [
          DestinationMatch(
            label: 'Start one',
            point: GeoPoint(latitude: 53, longitude: -1),
          ),
        ],
        'Stop': const [
          DestinationMatch(
            label: 'Stop one',
            point: GeoPoint(latitude: 53.1, longitude: -1.1),
          ),
          DestinationMatch(
            label: 'Stop two',
            point: GeoPoint(latitude: 54, longitude: -2),
          ),
        ],
        'Finish': const [
          DestinationMatch(
            label: 'Finish one',
            point: GeoPoint(latitude: 53.2, longitude: -1.2),
          ),
        ],
      });
      final routing = _FakeRoadRoutingService();
      final planner = DestinationRoutePlanner(
        searchService: search,
        routingService: routing,
      );

      final plan = await planner.planForReview(
        originQuery: 'Start',
        stopQueries: const ['Stop'],
        query: 'Finish',
      );

      expect(plan.route.waypoints, hasLength(3));
      expect(plan.route.waypoints[1].name, 'Stop one');
      expect(routing.requests.single[1].latitude, 53.1);
      expect(plan.warnings.single, contains('Stop 1 had 2 possible matches'));
    },
  );

  test('destination review keeps the exact submitted search result', () async {
    const selected = DestinationMatch(
      label: 'Chippenham, Wiltshire',
      point: GeoPoint(latitude: 51.46, longitude: -2.12),
    );
    final routing = _FakeRoadRoutingService();
    final planner = DestinationRoutePlanner(
      // A repeated text search would pick the wrong same-named place. The
      // Each row carries its coordinates so selection remains exact.
      searchService: const _FakeDestinationSearchService({
        'Chippenham, Wiltshire': [
          DestinationMatch(
            label: 'Chippenham, Cambridgeshire',
            point: GeoPoint(latitude: 52.2, longitude: 0.1),
          ),
        ],
      }),
      routingService: routing,
    );

    final plan = await planner.planForReview(
      origin: const GeoPoint(latitude: 51.45, longitude: -2.58),
      query: selected.label,
      selectedDestination: selected,
    );

    expect(routing.requests.single.last.latitude, 51.46);
    expect(routing.requests.single.last.longitude, -2.12);
    expect(plan.route.name, 'To Chippenham');
    expect(plan.warnings, isEmpty);
  });

  test('routing failure preserves the original sparse GPX route', () async {
    final route = ImportedRoute(
      id: 'route',
      name: 'Offline route',
      importedAt: DateTime.utc(2026),
      sourceFileName: 'offline.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 53, longitude: -1),
            GeoPoint(latitude: 53.1, longitude: -1.1),
          ],
        ),
      ],
      waypoints: const [],
    );

    final result = await RouteGeometryEnricher(
      routingService: _FailingRoadRoutingService(),
    ).enrich(route);

    expect(result.changed, isFalse);
    expect(result.route, same(route));
    expect(result.warning, contains('Could not match'));
  });

  group('route preferences reach the provider (#182)', () {
    test('the quickest style asks for no alternatives', () async {
      Uri? requested;
      final service = OsrmRoadRoutingService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(_osrmResponse(), 200);
        }),
        baseUrl: Uri.parse('https://routing.example.test'),
      );

      final result = await service.routeThrough(
        _twoPoints,
        preferences: RoutePreferences.defaults,
      );

      expect(requested!.queryParameters.containsKey('alternatives'), isFalse);
      expect(result.preferences, RoutePreferences.defaults);
      expect(result.twistinessScore, isNotNull);
    });

    test('a bendier style asks OSRM for three alternatives and picks the '
        'bendiest inside the allowance', () async {
      Uri? requested;
      final service = OsrmRoadRoutingService(
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(_osrmAlternativesResponse(), 200);
        }),
        baseUrl: Uri.parse('https://routing.example.test'),
      );

      final flowing = await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(style: RouteStyle.flowing),
      );
      final veryTwisty = await service.routeThrough(
        _twoPoints,
        preferences: const RoutePreferences(style: RouteStyle.veryTwisty),
      );

      expect(requested!.queryParameters['alternatives'], '3');
      // Quickest is 1000 s. Flowing allows 1250 s, so only the 1200 s
      // alternative qualifies; very twisty allows 1750 s and reaches the
      // bendiest 1700 s one.
      expect(flowing.duration, const Duration(seconds: 1200));
      expect(veryTwisty.duration, const Duration(seconds: 1700));
      expect(veryTwisty.twistinessScore, greaterThan(flowing.twistinessScore!));
    });

    // Six tests that drove the Valhalla motorcycle service and the
    // preference-aware dispatcher were here, covering motorcycle costing,
    // unsurfaced-byway levers, engine selection and the turn-instruction
    // warning. All three classes are gone (#31), and there is nothing left
    // to select between - `RhumbLinePassagePlanner` is the only planner, and
    // it ignores preferences entirely, which is what #61 removed the
    // preferences UI for.
    test('re-snapping a shared route reuses its own preferences', () async {
      final routing = _FakeRoadRoutingService();
      final route = ImportedRoute(
        id: 'shared',
        name: 'Shared twisty route',
        importedAt: DateTime.utc(2026),
        sourceFileName: 'shared.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.route,
            points: [
              GeoPoint(latitude: 53, longitude: -1),
              GeoPoint(latitude: 53.1, longitude: -1.1),
            ],
          ),
        ],
        waypoints: const [],
        preferences: const RoutePreferences(
          style: RouteStyle.twisty,
          avoidMotorways: true,
        ),
      );

      final result = await RouteGeometryEnricher(
        routingService: routing,
      ).enrich(route);

      expect(routing.requestedPreferences.single, route.preferences);
      expect(result.route.preferences, route.preferences);
    });
  });
}

const _twoPoints = [
  GeoPoint(latitude: 53, longitude: -1),
  GeoPoint(latitude: 53.01, longitude: -1.01),
];

String _osrmResponse() => jsonEncode({
  'code': 'Ok',
  'routes': [
    {
      'distance': 1250.5,
      'duration': 92.4,
      'geometry': {
        'coordinates': [
          [-1.0, 53.0],
          [-1.005, 53.005],
          [-1.01, 53.01],
        ],
      },
    },
  ],
});

/// Three alternatives: straight and quickest first, then a bendier one inside
/// the flowing allowance, then the bendiest and slowest.
String _osrmAlternativesResponse() {
  List<List<double>> sinusoid(double amplitude) => [
    for (var index = 0; index < 40; index += 1)
      [-1.0 + index * 0.004, 53.0 + math.sin(index / 2.5) * amplitude],
  ];
  return jsonEncode({
    'code': 'Ok',
    'routes': [
      {
        'distance': 20000,
        'duration': 1000,
        'geometry': {'coordinates': sinusoid(0)},
      },
      {
        'distance': 22000,
        'duration': 1200,
        'geometry': {'coordinates': sinusoid(0.006)},
      },
      {
        'distance': 26000,
        'duration': 1700,
        'geometry': {'coordinates': sinusoid(0.012)},
      },
    ],
  });
}

class _FakeRoadRoutingService implements RoadRoutingService {
  final List<List<GeoPoint>> requests = [];
  final List<RoutePreferences?> requestedPreferences = [];

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    requests.add(waypoints);
    requestedPreferences.add(preferences);
    return const RoadRouteResult(
      points: [
        GeoPoint(latitude: 53, longitude: -1),
        GeoPoint(latitude: 53.05, longitude: -1.05),
        GeoPoint(latitude: 53.1, longitude: -1.1),
      ],
      distanceMeters: 10000,
      duration: Duration(minutes: 12),
      maneuvers: [
        RoadRouteManeuver(
          position: GeoPoint(latitude: 53.05, longitude: -1.05),
          type: 'turn',
          modifier: 'left',
          name: 'High Street',
        ),
      ],
    );
  }
}

class _FailingRoadRoutingService implements RoadRoutingService {
  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) {
    throw const FormatException('offline');
  }
}

class _FakeDestinationSearchService implements DestinationSearchService {
  const _FakeDestinationSearchService(this.results);

  final Map<String, List<DestinationMatch>> results;

  @override
  Future<List<DestinationMatch>> search(String query) async =>
      results[query] ?? const [];
}
