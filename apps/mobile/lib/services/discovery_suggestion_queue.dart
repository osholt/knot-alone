import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart';
import 'motorcycle_discovery.dart';

class DiscoverySuggestionDraft {
  const DiscoverySuggestionDraft({
    required this.clientSubmissionId,
    required this.category,
    required this.action,
    required this.name,
    required this.reason,
    required this.points,
    required this.createdAt,
    this.targetFeatureId,
    this.evidenceUrl,
  });

  final String clientSubmissionId;
  final MotorcycleDiscoveryCategory category;
  final String action;
  final String? targetFeatureId;
  final String name;
  final String reason;
  final String? evidenceUrl;
  final List<GeoPoint> points;
  final DateTime createdAt;

  GeoPoint get point => points[points.length ~/ 2];

  Map<String, Object?> toJson() => {
    'clientSubmissionId': clientSubmissionId,
    'category': category.apiValue,
    'action': action,
    'targetFeatureId': targetFeatureId,
    'name': name,
    'reason': reason,
    'evidenceUrl': evidenceUrl,
    'geometry': points.length == 1
        ? {
            'type': 'Point',
            'coordinates': [point.longitude, point.latitude],
          }
        : {
            'type': 'LineString',
            'coordinates': [
              for (final point in points) [point.longitude, point.latitude],
            ],
          },
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory DiscoverySuggestionDraft.fromJson(Map<String, Object?> json) {
    final category = MotorcycleDiscoveryCategory.values.where(
      (item) => item.apiValue == json['category'],
    );
    final geometry = json['geometry'];
    final coordinates = geometry is Map ? geometry['coordinates'] : null;
    final pointCoordinates = geometry is Map && geometry['type'] == 'Point'
        ? [coordinates]
        : coordinates;
    if (category.isEmpty ||
        pointCoordinates is! List ||
        pointCoordinates.isEmpty ||
        pointCoordinates.length > 200) {
      throw const FormatException('Queued discovery suggestion is invalid.');
    }
    return DiscoverySuggestionDraft(
      clientSubmissionId: json['clientSubmissionId'] as String,
      category: category.single,
      action: json['action'] as String,
      targetFeatureId: json['targetFeatureId'] as String?,
      name: json['name'] as String,
      reason: json['reason'] as String,
      evidenceUrl: json['evidenceUrl'] as String?,
      points: pointCoordinates
          .map((rawPoint) {
            if (rawPoint is! List ||
                rawPoint.length != 2 ||
                rawPoint[0] is! num ||
                rawPoint[1] is! num) {
              throw const FormatException(
                'Queued discovery coordinate is invalid.',
              );
            }
            return GeoPoint(
              longitude: (rawPoint[0] as num).toDouble(),
              latitude: (rawPoint[1] as num).toDouble(),
            );
          })
          .toList(growable: false),
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
    );
  }
}

class DiscoverySuggestionQueue {
  DiscoverySuggestionQueue._(this._preferences, this._drafts);

  static const _key = 'ride-relay-discovery-suggestions-v1';
  static const _maximumDrafts = 25;
  static const _uuid = Uuid();

  final SharedPreferences _preferences;
  final List<DiscoverySuggestionDraft> _drafts;

  List<DiscoverySuggestionDraft> get drafts => List.unmodifiable(_drafts);

  static Future<DiscoverySuggestionQueue> openDefault() async {
    final preferences = await SharedPreferences.getInstance();
    final drafts = <DiscoverySuggestionDraft>[];
    try {
      final raw = jsonDecode(preferences.getString(_key) ?? '[]');
      if (raw is List) {
        drafts.addAll(
          raw
              .whereType<Map>()
              .map(
                (item) => DiscoverySuggestionDraft.fromJson(
                  Map<String, Object?>.from(item),
                ),
              )
              .take(_maximumDrafts),
        );
      }
    } on Object {
      await preferences.remove(_key);
    }
    return DiscoverySuggestionQueue._(preferences, drafts);
  }

  Future<DiscoverySuggestionDraft> enqueue({
    required MotorcycleDiscoveryCategory category,
    required String action,
    required String name,
    required String reason,
    required GeoPoint point,
    List<GeoPoint>? geometryPoints,
    String? targetFeatureId,
    String? evidenceUrl,
  }) async {
    final draft = DiscoverySuggestionDraft(
      clientSubmissionId: _uuid.v4(),
      category: category,
      action: action,
      targetFeatureId: targetFeatureId,
      name: _truncate(name, 120),
      reason: _truncate(reason, 500),
      evidenceUrl: (evidenceUrl?.trim().isEmpty ?? true)
          ? null
          : evidenceUrl!.trim(),
      points: List.unmodifiable(
        _sampleGeometry(
          geometryPoints?.isNotEmpty ?? false ? geometryPoints! : [point],
        ),
      ),
      createdAt: DateTime.now().toUtc(),
    );
    _drafts.add(draft);
    if (_drafts.length > _maximumDrafts) _drafts.removeAt(0);
    await _save();
    return draft;
  }

  Future<int> sendAfterConfirmation({
    required http.Client client,
    required Uri apiOrigin,
  }) async {
    var sent = 0;
    for (final draft in List<DiscoverySuggestionDraft>.from(_drafts)) {
      final response = await client.post(
        apiOrigin.resolve('/api/v1/discovery/suggestions'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(draft.toJson()),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) break;
      _drafts.remove(draft);
      sent += 1;
    }
    await _save();
    return sent;
  }

  Future<void> _save() => _preferences.setString(
    _key,
    jsonEncode(_drafts.map((draft) => draft.toJson()).toList()),
  );

  static String _truncate(String value, int maximumLength) {
    final trimmed = value.trim();
    return trimmed.length <= maximumLength
        ? trimmed
        : trimmed.substring(0, maximumLength);
  }

  static List<GeoPoint> _sampleGeometry(List<GeoPoint> points) {
    if (points.length <= 200) return points;
    return [
      for (var index = 0; index < 200; index += 1)
        points[((index * (points.length - 1)) / 199).round()],
    ];
  }
}

class DiscoverySuggestionConfiguration {
  const DiscoverySuggestionConfiguration(this.apiOrigin);

  factory DiscoverySuggestionConfiguration.fromEnvironment() {
    const value = String.fromEnvironment('RIDE_RELAY_DISCOVERY_API_URL');
    return DiscoverySuggestionConfiguration(
      value.trim().isEmpty ? null : Uri.parse(value),
    );
  }

  final Uri? apiOrigin;
}
