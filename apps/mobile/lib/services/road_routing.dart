import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'measurement_formatter.dart';
import 'route_origin_bearing.dart';
import 'route_twistiness.dart';

class RoutingConfiguration {
  const RoutingConfiguration({
    required this.routingBaseUrl,
    required this.geocodingBaseUrl,
  });

  /// `motorcycleRoutingUrl` and its `TIDE_AND_SEEK_MOTORCYCLE_ROUTING_URL`
  /// override are gone with the Valhalla service (#31). Nothing pointed at a
  /// public motorcycle-costing endpoint any more, and a build flag naming one is
  /// an invitation to wire it back up.
  factory RoutingConfiguration.fromEnvironment() => RoutingConfiguration(
    routingBaseUrl: Uri.parse(
      const String.fromEnvironment(
        'TIDE_AND_SEEK_ROUTING_URL',
        defaultValue: 'https://router.project-osrm.org',
      ),
    ),
    geocodingBaseUrl: Uri.parse(
      const String.fromEnvironment(
        'TIDE_AND_SEEK_GEOCODING_URL',
        defaultValue: 'https://nominatim.openstreetmap.org',
      ),
    ),
  );

  /// Still OSRM, and still only read by `OsrmRoadRoutingService`, which survives
  /// as the manoeuvre parser the guidance tests need (#63). No passage is
  /// planned through it.
  final Uri routingBaseUrl;

  final Uri geocodingBaseUrl;
}

class RoadRouteResult {
  const RoadRouteResult({
    required this.points,
    required this.distanceMeters,
    required this.duration,
    this.maneuvers = const [],
    this.twistinessScore,
    this.preferences,
    this.warnings = const [],
  });

  final List<GeoPoint> points;
  final double distanceMeters;
  final Duration duration;
  final List<RoadRouteManeuver> maneuvers;

  /// Degrees of useful heading change per kilometre, as scored by
  /// [RouteTwistiness]. Null when the caller asked for no score.
  final double? twistinessScore;

  /// What the route was actually planned for. Null when the caller asked for
  /// nothing in particular.
  final RoutePreferences? preferences;

  /// What the planner wants the sailor told about this result, in its own words.
  ///
  /// Exists because a marine planner has limits a road one does not: direct
  /// courses are not checked against land, and a duration built on an assumed
  /// speed is not an ETA. Those are properties of *how the route was made*, so
  /// they belong with the result rather than being restated by every caller.
  final List<String> warnings;
}

/// A decision reported by the routing engine or restored from reviewed mapped
/// junction data rather than inferred from a bend in recorded GPS geometry.
/// These are the points where a second sailor may need to mark a junction.
class RoadRouteManeuver extends RouteManeuver {
  const RoadRouteManeuver({
    required super.position,
    required super.type,
    super.modifier,
    super.name,
    super.ref,
    super.exitNumber,
    super.drivingSide,
    super.bearingBeforeDegrees,
    super.bearingAfterDegrees,
    super.lanes,
  });

  /// OSRM does not expose UK give-way signage, but these manoeuvres are the
  /// routing decisions where the group leaves its current road or must
  /// negotiate a junction. A traffic-sign data source can add further points.
  bool get requiresSecondBikeDrop => const {
    'turn',
    'fork',
    'end of road',
    'roundabout',
    'rotary',
    'roundabout turn',
    'merge',
    'on ramp',
    'off ramp',
  }.contains(type);

  factory RoadRouteManeuver.fromJson(Map<String, Object?> json) {
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final type = json['type'];
    if (latitude is! num || longitude is! num || type is! String) {
      throw const FormatException('Route manoeuvre is invalid.');
    }
    return RoadRouteManeuver(
      position: GeoPoint(
        latitude: latitude.toDouble(),
        longitude: longitude.toDouble(),
      ),
      type: type,
      modifier: json['modifier'] as String?,
      name: json['name'] as String?,
      ref: json['ref'] as String?,
      exitNumber: (json['exitNumber'] as num?)?.toInt(),
      drivingSide: json['drivingSide'] as String?,
      bearingBeforeDegrees: (json['bearingBeforeDegrees'] as num?)?.toDouble(),
      bearingAfterDegrees: (json['bearingAfterDegrees'] as num?)?.toDouble(),
      lanes:
          (json['lanes'] as List?)
              ?.whereType<Map>()
              .map(
                (lane) => RouteLane.fromJson(Map<String, Object?>.from(lane)),
              )
              .toList(growable: false) ??
          const [],
    );
  }
}

/// Which way traffic goes round, where OpenStreetMap says so.
enum MiniRoundaboutRotation { clockwise, anticlockwise }

/// One `highway=mini_roundabout` node from OpenStreetMap.
///
/// Position and, where the map states it, rotation. Nothing else: this used to
/// be a hand-reviewed catalogue carrying hand-measured arm bearings for two
/// named junctions, which only ever helped those two and could not be checked
/// against anything.
class MappedMiniRoundabout {
  const MappedMiniRoundabout({
    required this.position,
    this.osmId,
    this.rotation,
  });

  final GeoPoint position;
  final String? osmId;

  /// Null where the map does not say. The app's own default then applies,
  /// rather than this layer asserting a rotation the extract did not carry.
  final MiniRoundaboutRotation? rotation;
}

/// The bundled mini-roundabout layer, generated from OpenStreetMap.
///
/// OSRM and Valhalla both route through `highway=mini_roundabout` nodes without
/// necessarily emitting a manoeuvre, so a sailor gets no instruction at a
/// junction they have to give way at. This restores one.
///
/// It states the direction through the junction and **does not claim an exit
/// number**. Counting exits needs the bearing of every arm, which this layer
/// does not carry; the catalogue this replaced carried them for two junctions
/// by hand. Saying "mini roundabout, turn right" from data that supports it
/// beats saying "third exit" from data that does not.
class MappedMiniRoundaboutCatalogue {
  const MappedMiniRoundaboutCatalogue(this.roundabouts);

  static const assetKey = 'assets/mini_roundabouts.geojson';

  static const empty = MappedMiniRoundaboutCatalogue([]);

  static const routeMatchToleranceMeters = 12.0;
  static const duplicateManeuverToleranceMeters = 20.0;
  static const bearingSampleDistanceMeters = 12.0;

  final List<MappedMiniRoundabout> roundabouts;

  static Future<MappedMiniRoundaboutCatalogue> load({
    AssetBundle? bundle,
  }) async => parse(await (bundle ?? rootBundle).loadString(assetKey));

  static MappedMiniRoundaboutCatalogue parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Mini-roundabout layer is not a GeoJSON object.',
      );
    }
    final features = decoded['features'];
    final roundabouts = <MappedMiniRoundabout>[];
    if (features is List) {
      for (final feature in features) {
        final roundabout = _roundabout(feature);
        if (roundabout != null) roundabouts.add(roundabout);
      }
    }
    return MappedMiniRoundaboutCatalogue(List.unmodifiable(roundabouts));
  }

  static MappedMiniRoundabout? _roundabout(Object? feature) {
    if (feature is! Map<String, dynamic>) return null;
    final geometry = feature['geometry'];
    if (geometry is! Map<String, dynamic>) return null;
    if (geometry['type'] != 'Point') return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final longitude = (coordinates[0] as num?)?.toDouble();
    final latitude = (coordinates[1] as num?)?.toDouble();
    if (longitude == null || latitude == null) return null;
    final properties = feature['properties'];
    final tags = properties is Map<String, dynamic>
        ? properties
        : const <String, dynamic>{};
    return MappedMiniRoundabout(
      position: GeoPoint(latitude: latitude, longitude: longitude),
      osmId: tags['osmId'] as String?,
      rotation: switch (tags['rotation']) {
        'clockwise' => MiniRoundaboutRotation.clockwise,
        'anticlockwise' => MiniRoundaboutRotation.anticlockwise,
        _ => null,
      },
    );
  }

  /// Nodes near enough to the route to be worth projecting onto it.
  ///
  /// A whole-country layer is tens of thousands of nodes and projecting every
  /// one onto every route would be felt on the way into a voyage. The bounding
  /// box is a cheap comparison that discards almost all of them.
  List<MappedMiniRoundabout> _candidates(List<GeoPoint> route) {
    var minLatitude = route.first.latitude;
    var maxLatitude = route.first.latitude;
    var minLongitude = route.first.longitude;
    var maxLongitude = route.first.longitude;
    for (final point in route) {
      if (point.latitude < minLatitude) minLatitude = point.latitude;
      if (point.latitude > maxLatitude) maxLatitude = point.latitude;
      if (point.longitude < minLongitude) minLongitude = point.longitude;
      if (point.longitude > maxLongitude) maxLongitude = point.longitude;
    }
    const metersPerDegreeLatitude = 111320.0;
    final latitudePad = routeMatchToleranceMeters / metersPerDegreeLatitude;
    final widest = maxLatitude.abs() > minLatitude.abs()
        ? maxLatitude
        : minLatitude;
    final longitudeScale =
        metersPerDegreeLatitude * math.cos(widest * math.pi / 180);
    final longitudePad = longitudeScale <= 1
        ? 180.0
        : routeMatchToleranceMeters / longitudeScale;
    return [
      for (final roundabout in roundabouts)
        if (roundabout.position.latitude >= minLatitude - latitudePad &&
            roundabout.position.latitude <= maxLatitude + latitudePad &&
            roundabout.position.longitude >= minLongitude - longitudePad &&
            roundabout.position.longitude <= maxLongitude + longitudePad)
          roundabout,
    ];
  }

  List<RoadRouteManeuver> enrich({
    required List<GeoPoint> route,
    required List<RoadRouteManeuver> maneuvers,
  }) {
    if (route.length < 2 || roundabouts.isEmpty) return maneuvers;
    final additions =
        <({double progressMeters, List<RoadRouteManeuver> maneuvers})>[];
    for (final roundabout in _candidates(route)) {
      final projection = _projectOntoRoute(roundabout.position, route);
      if (projection.distanceMeters > routeMatchToleranceMeters ||
          maneuvers.any(
            (maneuver) =>
                _isRoundaboutManeuver(maneuver.type) &&
                _distanceMeters(maneuver.position, roundabout.position) <=
                    duplicateManeuverToleranceMeters,
          )) {
        continue;
      }
      final before = _pointAtRouteProgress(
        route,
        projection.progressMeters - bearingSampleDistanceMeters,
      );
      final after = _pointAtRouteProgress(
        route,
        projection.progressMeters + bearingSampleDistanceMeters,
      );
      final approachBearing = _bearingDegrees(before, projection.point);
      final departureBearing = _bearingDegrees(projection.point, after);
      // Stated only where the map states it. Left null otherwise, so the
      // renderer's own default decides rather than this layer asserting a
      // rotation the extract did not carry.
      final drivingSide = switch (roundabout.rotation) {
        MiniRoundaboutRotation.clockwise => 'left',
        MiniRoundaboutRotation.anticlockwise => 'right',
        null => null,
      };
      additions.add((
        progressMeters: projection.progressMeters,
        maneuvers: [
          RoadRouteManeuver(
            position: roundabout.position,
            type: 'roundabout',
            drivingSide: drivingSide,
            bearingBeforeDegrees: approachBearing,
          ),
          RoadRouteManeuver(
            position: roundabout.position,
            type: 'exit roundabout',
            drivingSide: drivingSide,
            bearingAfterDegrees: departureBearing,
          ),
        ],
      ));
    }
    if (additions.isEmpty) return maneuvers;
    additions.sort(
      (first, second) => first.progressMeters.compareTo(second.progressMeters),
    );
    final enriched = maneuvers.toList();
    for (final addition in additions) {
      final insertAt = enriched.indexWhere(
        (maneuver) =>
            _projectOntoRoute(maneuver.position, route).progressMeters >
            addition.progressMeters,
      );
      enriched.insertAll(
        insertAt < 0 ? enriched.length : insertAt,
        addition.maneuvers,
      );
    }
    return List.unmodifiable(enriched);
  }
}

/// The bundled layer, read once per process.
///
/// Memoised because every route and every road match wants the same 16,000-odd
/// nodes, and because a failed read must not retry on every route: an
/// unreadable asset degrades guidance at mini-roundabouts, which is not a
/// reason to fail the voyage.
Future<MappedMiniRoundaboutCatalogue>? _bundledMiniRoundabouts;

Future<MappedMiniRoundaboutCatalogue> bundledMiniRoundabouts() =>
    _bundledMiniRoundabouts ??= MappedMiniRoundaboutCatalogue.load().catchError(
      (Object error) => MappedMiniRoundaboutCatalogue.empty,
    );

abstract interface class RoadRoutingService {
  /// Routes through [waypoints].
  ///
  /// [preferences] is what the sailor asked the route to be like. Null means
  /// "whatever this service does by default", which is what an internal caller
  /// such as an off-route rejoin wants: a rejoin leg is not a planning decision
  /// and must not silently acquire the exclusions of the route it rejoins.
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,

    /// Which way the sailor is pointing at the first waypoint, in degrees (#444).
    ///
    /// A position on a two-way road is ambiguous, and an engine that guesses
    /// wrong returns a first instruction that only makes sense facing the other
    /// way. Null means "no usable heading" — see `route_origin_bearing.dart` for
    /// when that is the honest answer.
    double? originBearingDegrees,
  });
}

class OsrmRoadRoutingService implements RoadRoutingService {
  const OsrmRoadRoutingService({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 15),
    this.maximumResponseBytes = 5 * 1024 * 1024,
    this.readMiniRoundabouts = bundledMiniRoundabouts,
  });

  /// Alternatives asked of OSRM when a bendier style has to choose between
  /// them. The web planner asks for the same three.
  static const alternativeCount = 3;

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final int maximumResponseBytes;

  /// Reads the bundled mini-roundabout layer.
  ///
  /// A function rather than the catalogue itself so the asset is read lazily,
  /// off the path that builds a route, and only once per process.
  final Future<MappedMiniRoundaboutCatalogue> Function() readMiniRoundabouts;

  @override
  Future<RoadRouteResult> routeThrough(
    List<GeoPoint> waypoints, {
    RoutePreferences? preferences,
    double? originBearingDegrees,
  }) async {
    if (waypoints.length < 2) {
      throw const FormatException('At least two route points are required.');
    }
    if (waypoints.length > 100) {
      throw const FormatException(
        'A maximum of 100 route points is supported.',
      );
    }
    _requireHttps(baseUrl, 'Routing');
    final style = preferences?.style ?? RouteStyle.quickest;
    final coordinates = waypoints
        .map((point) => '${point.longitude},${point.latitude}')
        .join(';');
    final path = '${_basePath(baseUrl)}/route/v1/driving/$coordinates';
    final uri = baseUrl.replace(
      path: path,
      queryParameters: {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'true',
        // Only asked for when a style has to choose. The quickest route needs
        // no alternatives, and not asking keeps the default request identical
        // to the one this client has always sent.
        if (style.prefersBends) 'alternatives': '$alternativeCount',
        // Constrains only the origin, so the rejoin point and the target may be
        // approached however the engine likes (#444).
        'bearings': ?osrmBearings(
          originBearingDegrees: originBearingDegrees,
          waypointCount: waypoints.length,
        ),
      },
    );
    final response = await client
        .get(uri, headers: _requestHeaders)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('Road routing failed (${response.statusCode}).');
    }
    if (response.bodyBytes.length > maximumResponseBytes) {
      throw const FormatException('Road routing response is too large.');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map || decoded['code'] != 'Ok') {
      final message = decoded is Map ? decoded['message'] : null;
      throw FormatException(
        message is String && message.trim().isNotEmpty
            ? message
            : 'No road route was found.',
      );
    }
    final routes = decoded['routes'];
    if (routes is! List || routes.isEmpty || routes.first is! Map) {
      throw const FormatException('Road routing returned no route.');
    }
    final parsed = routes
        .whereType<Map>()
        .map((route) => parseRoute(Map<String, dynamic>.from(route)))
        .toList(growable: false);
    final chosen =
        RouteTwistiness.chooseWithinDetour(
          parsed,
          style: style,
          duration: (candidate) =>
              candidate.duration.inMilliseconds.toDouble() / 1000,
          twistiness: (candidate) => candidate.twistinessScore ?? 0,
        ) ??
        parsed.first;
    final miniRoundabouts = await readMiniRoundabouts();
    return RoadRouteResult(
      points: chosen.points,
      distanceMeters: chosen.distanceMeters,
      duration: chosen.duration,
      maneuvers: miniRoundabouts.enrich(
        route: chosen.points,
        maneuvers: chosen.maneuvers,
      ),
      twistinessScore: chosen.twistinessScore,
      preferences: preferences,
    );
  }

  /// Parses the standard OSRM Route object shared by the route and match
  /// services. Keeping one parser means imported-track matching cannot drift
  /// from ordinary destination routing in geometry or manoeuvre handling.
  static RoadRouteResult parseRoute(Map<String, dynamic> route) {
    final geometry = route['geometry'];
    if (geometry is! Map || geometry['coordinates'] is! List) {
      throw const FormatException('Road routing geometry is invalid.');
    }
    final points = (geometry['coordinates'] as List)
        .map((coordinate) {
          if (coordinate is! List || coordinate.length < 2) {
            throw const FormatException('Road routing coordinate is invalid.');
          }
          final longitude = coordinate[0];
          final latitude = coordinate[1];
          if (longitude is! num || latitude is! num) {
            throw const FormatException('Road routing coordinate is invalid.');
          }
          return GeoPoint(
            latitude: latitude.toDouble(),
            longitude: longitude.toDouble(),
          );
        })
        .toList(growable: false);
    if (points.length < 2) {
      throw const FormatException(
        'Road routing returned insufficient geometry.',
      );
    }
    final distance = route['distance'];
    final duration = route['duration'];
    if (distance is! num || duration is! num) {
      throw const FormatException('Road routing summary is invalid.');
    }
    return RoadRouteResult(
      points: points,
      distanceMeters: distance.toDouble(),
      duration: Duration(milliseconds: (duration.toDouble() * 1000).round()),
      maneuvers: parseManeuvers(route['legs']),
      twistinessScore: RouteTwistiness.score(
        points,
        distanceMeters: distance.toDouble(),
      ),
    );
  }

  static List<RoadRouteManeuver> parseManeuvers(Object? rawLegs) {
    if (rawLegs is! List) return const [];
    final maneuvers = <RoadRouteManeuver>[];
    for (final rawLeg in rawLegs) {
      if (rawLeg is! Map || rawLeg['steps'] is! List) continue;
      for (final rawStep in rawLeg['steps'] as List) {
        if (rawStep is! Map || rawStep['maneuver'] is! Map) continue;
        final step = Map<String, Object?>.from(rawStep);
        final rawManeuver = Map<String, Object?>.from(
          rawStep['maneuver'] as Map,
        );
        final location = rawManeuver['location'];
        final type = rawManeuver['type'];
        if (location is! List ||
            location.length < 2 ||
            location[0] is! num ||
            location[1] is! num ||
            type is! String) {
          continue;
        }
        maneuvers.add(
          RoadRouteManeuver(
            position: GeoPoint(
              latitude: (location[1] as num).toDouble(),
              longitude: (location[0] as num).toDouble(),
            ),
            type: type,
            modifier: rawManeuver['modifier'] as String?,
            name: step['name'] as String?,
            ref: step['ref'] as String?,
            // OSRM documents `exit` as the roundabout/rotary exit count only.
            exitNumber: (rawManeuver['exit'] as num?)?.toInt(),
            drivingSide: step['driving_side'] as String?,
            bearingBeforeDegrees: _bearing(rawManeuver['bearing_before']),
            bearingAfterDegrees: _bearing(rawManeuver['bearing_after']),
            lanes: _parseLanes(step['intersections']),
          ),
        );
      }
    }
    return List.unmodifiable(maneuvers);
  }

  /// OSRM reports `bearing_before`/`bearing_after` in whole degrees clockwise
  /// from true north. They are the manoeuvre's own geometry and are what the
  /// app uses to state a direction, rather than the driving side.
  static double? _bearing(Object? value) {
    if (value is! num || !value.isFinite) return null;
    return (value.toDouble() % 360 + 360) % 360;
  }

  static List<RouteLane> _parseLanes(Object? rawIntersections) {
    if (rawIntersections is! List) return const [];
    for (final rawIntersection in rawIntersections) {
      if (rawIntersection is! Map || rawIntersection['lanes'] is! List) {
        continue;
      }
      final lanes = <RouteLane>[];
      for (final rawLane in rawIntersection['lanes'] as List) {
        if (rawLane is! Map) continue;
        final indications =
            (rawLane['indications'] as List?)
                ?.whereType<String>()
                .map((value) => value.trim().toLowerCase())
                .where((value) => value.isNotEmpty)
                .toList(growable: false) ??
            const <String>[];
        lanes.add(
          RouteLane(indications: indications, valid: rawLane['valid'] == true),
        );
      }
      if (lanes.isNotEmpty) return List.unmodifiable(lanes);
    }
    return const [];
  }
}

// `ValhallaMotorcycleRoutingService` and `PreferenceAwareRoadRoutingService`
// were here (#31).
//
// The first drove Valhalla's **motorcycle** costing model, complete with a
// twistiness preference; the second chose between it and OSRM's car profile.
// #19 replaced both with `RhumbLinePassagePlanner`, because asked to plan
// from Cowes to Cherbourg neither failed - they confidently returned a road
// route around the coast and through Dover.
//
// `OsrmRoadRoutingService` above is **not** deleted with them, and the
// reason is worth stating rather than rediscovering: it is the only thing
// that can produce a manoeuvre list, and the turn-by-turn guidance stack -
// 2,350 lines across navigation_guidance, maneuver_symbol, the manoeuvre
// list and the diagnostics - is still here and tested through it. Removing
// it therefore means removing that stack, which is #63, and is a design
// decision rather than hygiene: a passage may still want "in 2 cables,
// alter to 072" at a mark, which is not a turn instruction.

class DestinationMatch {
  const DestinationMatch({required this.label, required this.point});

  final String label;
  final GeoPoint point;
}

abstract interface class DestinationSearchService {
  Future<List<DestinationMatch>> search(String query);
}

class NominatimDestinationSearchService implements DestinationSearchService {
  NominatimDestinationSearchService({
    required this.client,
    required this.baseUrl,
    this.timeout = const Duration(seconds: 10),
  });

  final http.Client client;
  final Uri baseUrl;
  final Duration timeout;
  final Map<String, List<DestinationMatch>> _cache = {};

  @override
  Future<List<DestinationMatch>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter a destination.');
    }
    final coordinates = _parseCoordinates(trimmed);
    if (coordinates != null) {
      return [DestinationMatch(label: trimmed, point: coordinates)];
    }
    final cacheKey = trimmed.toLowerCase();
    final cached = _cache[cacheKey];
    if (cached != null) return cached;
    _requireHttps(baseUrl, 'Destination search');
    final uri = baseUrl.replace(
      path: '${_basePath(baseUrl)}/search',
      queryParameters: {
        'q': trimmed,
        'format': 'jsonv2',
        'limit': '5',
        'addressdetails': '0',
      },
    );
    final response = await client
        .get(uri, headers: _requestHeaders)
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        'Destination search failed (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('Destination search response is invalid.');
    }
    final matches = <DestinationMatch>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final latitude = double.tryParse('${item['lat'] ?? ''}');
      final longitude = double.tryParse('${item['lon'] ?? ''}');
      final label = item['display_name'];
      if (latitude == null ||
          longitude == null ||
          label is! String ||
          label.trim().isEmpty) {
        continue;
      }
      matches.add(
        DestinationMatch(
          label: label.trim(),
          point: GeoPoint(latitude: latitude, longitude: longitude),
        ),
      );
    }
    if (matches.isEmpty) {
      throw FormatException('No destination matched "$trimmed".');
    }
    final result = List<DestinationMatch>.unmodifiable(matches);
    _cache[cacheKey] = result;
    return result;
  }
}

class DestinationRoutePlanner {
  DestinationRoutePlanner({
    required this.searchService,
    required this.routingService,
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final DestinationSearchService searchService;
  final RoadRoutingService routingService;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  Future<DestinationRoutePlan> planForReview({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DestinationMatch? selectedDestination,
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
    RoutePreferences preferences = RoutePreferences.defaults,
  }) async {
    final warnings = <String>[];
    final GeoPoint resolvedOrigin;
    String originLabel;
    if (originQuery != null && originQuery.trim().isNotEmpty) {
      final originMatches = await searchService.search(originQuery);
      if (originMatches.length > 1) {
        warnings.add(
          'The start location had ${originMatches.length} possible matches. '
          'Check the selected pin before confirming.',
        );
      }
      resolvedOrigin = originMatches.first.point;
      originLabel = originMatches.first.label;
    } else if (origin != null) {
      resolvedOrigin = origin;
      originLabel = 'Current location';
    } else {
      throw const FormatException(
        'A start location or current position is required.',
      );
    }

    final resolvedStops = <DestinationMatch>[];
    for (var index = 0; index < stopQueries.length; index += 1) {
      final value = stopQueries[index].trim();
      if (value.isEmpty) continue;
      final matches = await searchService.search(value);
      if (matches.length > 1) {
        warnings.add(
          'Stop ${index + 1} had ${matches.length} possible matches. '
          'Check the selected pin before confirming.',
        );
      }
      resolvedStops.add(matches.first);
    }

    final destinationMatches = selectedDestination == null
        ? await searchService.search(query)
        : [selectedDestination];
    if (selectedDestination == null && destinationMatches.length > 1) {
      warnings.add(
        'The destination had ${destinationMatches.length} possible matches. '
        'Check the selected pin before confirming.',
      );
    }
    final destination = destinationMatches.first;
    final roadRoute = await routingService.routeThrough([
      resolvedOrigin,
      ...resolvedStops.map((stop) => stop.point),
      destination.point,
    ], preferences: preferences);
    // The planner speaks for itself about how the route was made - a marine
    // planner's limits (direct courses, assumed speed) are not something every
    // caller should have to restate, and the old motorcycle-specific notice
    // here would have fired on every passage (#19).
    warnings.addAll(roadRoute.warnings);
    final id = _idFactory();
    final route = ImportedRoute(
      id: id,
      name: 'To ${_shortLabel(destination.label)}',
      description:
          'Passage generated by Tide and Seek. '
          '${MeasurementFormatter(distanceUnit).distance(roadRoute.distanceMeters)}, '
          '${_durationLabel(roadRoute.duration)}.',
      importedAt: _clock().toUtc(),
      sourceFileName: 'tide-and-seek-destination-$id.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: 'Passage to ${_shortLabel(destination.label)}',
          points: roadRoute.points,
        ),
      ],
      waypoints: [
        RouteWaypoint(
          point: resolvedOrigin,
          name: originLabel == 'Current location'
              ? 'Start'
              : _shortLabel(originLabel),
          description: originLabel,
          symbol: 'Flag, Blue',
        ),
        for (var index = 0; index < resolvedStops.length; index += 1)
          RouteWaypoint(
            point: resolvedStops[index].point,
            name: _shortLabel(resolvedStops[index].label),
            description: resolvedStops[index].label,
            symbol: 'Flag, Green',
          ),
        RouteWaypoint(
          point: destination.point,
          name: _shortLabel(destination.label),
          description: destination.label,
          symbol: 'Flag, Red',
        ),
      ],
      maneuvers: roadRoute.maneuvers,
      preferences: preferences,
      plannedDuration: roadRoute.duration,
    );
    return DestinationRoutePlan(
      route: route,
      distanceMeters: roadRoute.distanceMeters,
      duration: roadRoute.duration,
      twistinessScore: roadRoute.twistinessScore,
      warnings: List.unmodifiable(warnings),
    );
  }

  /// [originQuery] is geocoded the same way [query] (the destination)
  /// already is, and takes priority when given - the route need not start
  /// from the sailor's current location. [origin] is the fallback used only
  /// when there is no [originQuery]; at least one of the two is required.
  Future<ImportedRoute> plan({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
    RoutePreferences preferences = RoutePreferences.defaults,
  }) async {
    return (await planForReview(
      origin: origin,
      originQuery: originQuery,
      stopQueries: stopQueries,
      query: query,
      distanceUnit: distanceUnit,
      preferences: preferences,
    )).route;
  }
}

class DestinationRoutePlan {
  const DestinationRoutePlan({
    required this.route,
    required this.distanceMeters,
    required this.duration,
    this.twistinessScore,
    this.warnings = const [],
  });

  final ImportedRoute route;
  final double distanceMeters;
  final Duration duration;

  /// The route's own twistiness, so the app can show the same number the web
  /// planner shows for the same geometry.
  final double? twistinessScore;
  final List<String> warnings;
}

({GeoPoint point, double progressMeters, double distanceMeters})
_projectOntoRoute(GeoPoint point, List<GeoPoint> route) {
  const earthRadius = 6371000.0;
  final referenceLatitude = point.latitude * math.pi / 180;
  var travelled = 0.0;
  var bestDistance = double.infinity;
  var bestProgress = 0.0;
  var bestPoint = route.first;
  for (var index = 0; index < route.length - 1; index += 1) {
    final start = route[index];
    final end = route[index + 1];
    final startX =
        (start.longitude - point.longitude) *
        math.pi /
        180 *
        math.cos(referenceLatitude) *
        earthRadius;
    final startY =
        (start.latitude - point.latitude) * math.pi / 180 * earthRadius;
    final endX =
        (end.longitude - point.longitude) *
        math.pi /
        180 *
        math.cos(referenceLatitude) *
        earthRadius;
    final endY = (end.latitude - point.latitude) * math.pi / 180 * earthRadius;
    final deltaX = endX - startX;
    final deltaY = endY - startY;
    final lengthSquared = deltaX * deltaX + deltaY * deltaY;
    final fraction = lengthSquared <= 0
        ? 0.0
        : (-(startX * deltaX + startY * deltaY) / lengthSquared).clamp(
            0.0,
            1.0,
          );
    final nearestX = startX + deltaX * fraction;
    final nearestY = startY + deltaY * fraction;
    final distance = math.sqrt(nearestX * nearestX + nearestY * nearestY);
    final segmentLength = _distanceMeters(start, end);
    if (distance < bestDistance) {
      bestDistance = distance;
      bestProgress = travelled + segmentLength * fraction;
      bestPoint = GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      );
    }
    travelled += segmentLength;
  }
  return (
    point: bestPoint,
    progressMeters: bestProgress,
    distanceMeters: bestDistance,
  );
}

GeoPoint _pointAtRouteProgress(List<GeoPoint> route, double progressMeters) {
  if (progressMeters <= 0) return route.first;
  var travelled = 0.0;
  for (var index = 0; index < route.length - 1; index += 1) {
    final start = route[index];
    final end = route[index + 1];
    final segmentLength = _distanceMeters(start, end);
    if (segmentLength > 0 && travelled + segmentLength >= progressMeters) {
      final fraction = (progressMeters - travelled) / segmentLength;
      return GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      );
    }
    travelled += segmentLength;
  }
  return route.last;
}

double _distanceMeters(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371000.0;
  final firstLatitude = first.latitude * math.pi / 180;
  final secondLatitude = second.latitude * math.pi / 180;
  final deltaLatitude = (second.latitude - first.latitude) * math.pi / 180;
  final deltaLongitude = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
      math.cos(firstLatitude) *
          math.cos(secondLatitude) *
          math.sin(deltaLongitude / 2) *
          math.sin(deltaLongitude / 2);
  return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _bearingDegrees(GeoPoint first, GeoPoint second) {
  final firstLatitude = first.latitude * math.pi / 180;
  final secondLatitude = second.latitude * math.pi / 180;
  final deltaLongitude = (second.longitude - first.longitude) * math.pi / 180;
  final y = math.sin(deltaLongitude) * math.cos(secondLatitude);
  final x =
      math.cos(firstLatitude) * math.sin(secondLatitude) -
      math.sin(firstLatitude) *
          math.cos(secondLatitude) *
          math.cos(deltaLongitude);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

bool _isRoundaboutManeuver(String type) => const {
  'roundabout',
  'rotary',
  'roundabout turn',
  'exit roundabout',
  'exit rotary',
}.contains(type.trim().toLowerCase());

const _requestHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'Sweeper/1.0 (https://github.com/osholt/tailendcharlie)',
};

String _basePath(Uri base) {
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return path == '/' ? '' : path;
}

void _requireHttps(Uri uri, String service) {
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('$service must use a configured HTTPS service.');
  }
}

GeoPoint? _parseCoordinates(String value) {
  final match = RegExp(
    r'^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$',
  ).firstMatch(value);
  if (match == null) return null;
  final latitude = double.tryParse(match.group(1)!);
  final longitude = double.tryParse(match.group(2)!);
  if (latitude == null ||
      longitude == null ||
      latitude < -90 ||
      latitude > 90 ||
      longitude < -180 ||
      longitude > 180) {
    throw const FormatException('Destination coordinates are invalid.');
  }
  return GeoPoint(latitude: latitude, longitude: longitude);
}

String _shortLabel(String label) => label.split(',').first.trim();

String _durationLabel(Duration duration) {
  final minutes = (duration.inSeconds / 60).round();
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final remainder = minutes % 60;
  return remainder == 0 ? '$hours hr' : '$hours hr $remainder min';
}
