import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tide_and_seek/domain/imported_route.dart';
import 'package:tide_and_seek/services/destination_planning.dart';
import 'package:tide_and_seek/services/passage_planning_service.dart';
import 'package:tide_and_seek/services/route_geometry_enricher.dart';

void main() {
  test('destination search stays disabled until a provider is selected', () {
    final configuration = DestinationSearchConfiguration.fromEnvironment();
    expect(configuration.geocodingBaseUrl.host, 'geocoding.invalid');
    expect(
      NominatimDestinationSearchService(
        client: MockClient((_) async => fail('must not make a request')),
        baseUrl: configuration.geocodingBaseUrl,
      ).search('Cowes'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Destination search is not configured.',
        ),
      ),
    );
  });

  test(
    'destination search supports coordinates and one-shot place search',
    () async {
      var requests = 0;
      final service = NominatimDestinationSearchService(
        client: MockClient((request) async {
          requests += 1;
          expect(request.url.queryParameters['q'], 'Cowes');
          expect(request.url.queryParameters['limit'], '5');
          return http.Response(
            jsonEncode([
              {
                'lat': '50.762',
                'lon': '-1.300',
                'display_name': 'Cowes, Isle of Wight, United Kingdom',
              },
            ]),
            200,
          );
        }),
        baseUrl: Uri.parse('https://geocoding.example.test'),
      );

      final coordinateMatch = await service.search('50.76, -1.30');
      final placeMatch = await service.search('Cowes');
      final cached = await service.search('cowes');

      expect(coordinateMatch.single.point.latitude, 50.76);
      expect(placeMatch.single.label, startsWith('Cowes'));
      expect(cached, same(placeMatch));
      expect(requests, 1);
    },
  );

  test('sparse GPX route points are replaced with passage geometry', () async {
    final planner = _FakePassagePlanner();
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
            GeoPoint(latitude: 50.7, longitude: -1.2),
            GeoPoint(latitude: 50.71, longitude: -1.21),
          ],
        ),
        RoutePath(
          kind: RoutePathKind.route,
          name: 'Planned section',
          points: [
            GeoPoint(latitude: 50.72, longitude: -1.22),
            GeoPoint(latitude: 50.73, longitude: -1.23),
          ],
        ),
      ],
      waypoints: const [],
    );

    final result = await RouteGeometryEnricher(
      passagePlanner: planner,
    ).enrich(route);

    expect(result.changed, isTrue);
    expect(result.snappedPathCount, 1);
    expect(result.route.paths.first.kind, RoutePathKind.track);
    expect(result.route.paths.last.kind, RoutePathKind.track);
    expect(result.route.paths.last.points, hasLength(3));
    expect(planner.requests.single, hasLength(2));
  });

  test('destination plan uses an explicit start location', () async {
    final search = NominatimDestinationSearchService(
      client: MockClient((request) async {
        final query = request.url.queryParameters['q'];
        final point = query == 'Cowes'
            ? {'lat': '50.762', 'lon': '-1.300'}
            : {'lat': '50.700', 'lon': '-1.500'};
        return http.Response(
          jsonEncode([
            {...point, 'display_name': '$query, United Kingdom'},
          ]),
          200,
        );
      }),
      baseUrl: Uri.parse('https://geocoding.example.test'),
    );
    final passagePlanner = _FakePassagePlanner();
    final planner = DestinationRoutePlanner(
      searchService: search,
      passagePlanner: passagePlanner,
    );

    final route = await planner.plan(originQuery: 'Yarmouth', query: 'Cowes');

    expect(route.waypoints.first.point.latitude, 50.7);
    expect(passagePlanner.requests.single.first.latitude, 50.7);
  });

  test('destination plan requires a current position or start query', () async {
    final planner = DestinationRoutePlanner(
      searchService: NominatimDestinationSearchService(
        client: MockClient((_) async => http.Response('[]', 200)),
        baseUrl: Uri.parse('https://geocoding.example.test'),
      ),
      passagePlanner: _FakePassagePlanner(),
    );

    await expectLater(
      planner.plan(query: 'Cowes'),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'destination review preserves ordered marks and reports ambiguity',
    () async {
      final search = _FakeDestinationSearchService({
        'Start': const [
          DestinationMatch(
            label: 'Start one',
            point: GeoPoint(latitude: 50.7, longitude: -1.5),
          ),
        ],
        'Mark': const [
          DestinationMatch(
            label: 'Mark one',
            point: GeoPoint(latitude: 50.72, longitude: -1.4),
          ),
          DestinationMatch(
            label: 'Mark two',
            point: GeoPoint(latitude: 50.8, longitude: -1.2),
          ),
        ],
        'Finish': const [
          DestinationMatch(
            label: 'Finish one',
            point: GeoPoint(latitude: 50.76, longitude: -1.3),
          ),
        ],
      });
      final passagePlanner = _FakePassagePlanner();
      final planner = DestinationRoutePlanner(
        searchService: search,
        passagePlanner: passagePlanner,
      );

      final plan = await planner.planForReview(
        originQuery: 'Start',
        stopQueries: const ['Mark'],
        query: 'Finish',
      );

      expect(plan.route.waypoints, hasLength(3));
      expect(plan.route.waypoints[1].name, 'Mark one');
      expect(passagePlanner.requests.single[1].latitude, 50.72);
      expect(plan.warnings.single, contains('Stop 1 had 2 possible matches'));
    },
  );

  test('destination review keeps the exact submitted search result', () async {
    const selected = DestinationMatch(
      label: 'Cowes, Isle of Wight',
      point: GeoPoint(latitude: 50.762, longitude: -1.300),
    );
    final passagePlanner = _FakePassagePlanner();
    final planner = DestinationRoutePlanner(
      searchService: const _FakeDestinationSearchService({
        'Cowes, Isle of Wight': [
          DestinationMatch(
            label: 'Cowes, Australia',
            point: GeoPoint(latitude: -38.45, longitude: 145.24),
          ),
        ],
      }),
      passagePlanner: passagePlanner,
    );

    final plan = await planner.planForReview(
      origin: const GeoPoint(latitude: 50.75, longitude: -1.31),
      query: selected.label,
      selectedDestination: selected,
    );

    expect(passagePlanner.requests.single.last.latitude, 50.762);
    expect(plan.route.name, 'To Cowes');
    expect(plan.warnings, isEmpty);
  });

  test('planning failure preserves the original sparse GPX route', () async {
    final route = ImportedRoute(
      id: 'route',
      name: 'Offline route',
      importedAt: DateTime.utc(2026),
      sourceFileName: 'offline.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 50.7, longitude: -1.5),
            GeoPoint(latitude: 50.76, longitude: -1.3),
          ],
        ),
      ],
      waypoints: const [],
    );

    final result = await RouteGeometryEnricher(
      passagePlanner: _FailingPassagePlanner(),
    ).enrich(route);

    expect(result.changed, isFalse);
    expect(result.route, same(route));
    expect(result.warning, contains('Could not lay'));
  });
}

class _FakePassagePlanner implements PassagePlanningService {
  final List<List<GeoPoint>> requests = [];

  @override
  Future<PassagePlanResult> planThrough(List<GeoPoint> waypoints) async {
    requests.add(waypoints);
    return const PassagePlanResult(
      points: [
        GeoPoint(latitude: 50.7, longitude: -1.5),
        GeoPoint(latitude: 50.72, longitude: -1.4),
        GeoPoint(latitude: 50.76, longitude: -1.3),
      ],
      distanceMeters: 10000,
      duration: Duration(hours: 1),
    );
  }
}

class _FailingPassagePlanner implements PassagePlanningService {
  @override
  Future<PassagePlanResult> planThrough(List<GeoPoint> waypoints) {
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
