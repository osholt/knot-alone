import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'measurement_formatter.dart';
import 'passage_planning_service.dart';

class DestinationSearchConfiguration {
  const DestinationSearchConfiguration({required this.geocodingBaseUrl});

  factory DestinationSearchConfiguration.fromEnvironment() =>
      DestinationSearchConfiguration(
        geocodingBaseUrl: Uri.parse(
          const String.fromEnvironment(
            'TIDE_AND_SEEK_GEOCODING_URL',
            defaultValue: 'https://geocoding.invalid',
          ),
        ),
      );

  final Uri geocodingBaseUrl;
}

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
    required this.passagePlanner,
    String Function()? idFactory,
    DateTime Function()? clock,
  }) : _idFactory = idFactory ?? const Uuid().v4,
       _clock = clock ?? DateTime.now;

  final DestinationSearchService searchService;
  final PassagePlanningService passagePlanner;
  final String Function() _idFactory;
  final DateTime Function() _clock;

  Future<DestinationRoutePlan> planForReview({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DestinationMatch? selectedDestination,
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
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
    final passage = await passagePlanner.planThrough([
      resolvedOrigin,
      ...resolvedStops.map((stop) => stop.point),
      destination.point,
    ]);
    warnings.addAll(passage.warnings);
    final id = _idFactory();
    final route = ImportedRoute(
      id: id,
      name: 'To ${_shortLabel(destination.label)}',
      description:
          'Passage generated by Tide and Seek. '
          '${MeasurementFormatter(distanceUnit).distance(passage.distanceMeters)}, '
          '${_durationLabel(passage.duration)}.',
      importedAt: _clock().toUtc(),
      sourceFileName: 'tide-and-seek-destination-$id.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: 'Passage to ${_shortLabel(destination.label)}',
          points: passage.points,
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
      plannedDuration: passage.duration,
    );
    return DestinationRoutePlan(
      route: route,
      distanceMeters: passage.distanceMeters,
      duration: passage.duration,
      warnings: List.unmodifiable(warnings),
    );
  }

  Future<ImportedRoute> plan({
    GeoPoint? origin,
    String? originQuery,
    List<String> stopQueries = const [],
    required String query,
    DistanceUnit distanceUnit = DistanceUnit.nauticalMiles,
  }) async => (await planForReview(
    origin: origin,
    originQuery: originQuery,
    stopQueries: stopQueries,
    query: query,
    distanceUnit: distanceUnit,
  )).route;
}

class DestinationRoutePlan {
  const DestinationRoutePlan({
    required this.route,
    required this.distanceMeters,
    required this.duration,
    this.warnings = const [],
  });

  final ImportedRoute route;
  final double distanceMeters;
  final Duration duration;
  final List<String> warnings;
}

const _requestHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'Tide and Seek/1.0 (https://github.com/osholt/knot-alone)',
};

String _basePath(Uri base) {
  final path = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return path == '/' ? '' : path;
}

void _requireHttps(Uri uri, String service) {
  if (uri.host.endsWith('.invalid')) {
    throw FormatException('$service is not configured.');
  }
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
