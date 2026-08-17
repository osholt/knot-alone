import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/imported_route.dart';
import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import 'voyage_event_authenticator.dart';
import 'voyage_lifecycle.dart';

class VoyageRouteState {
  const VoyageRouteState({
    this.route,
    this.revisionId,
    this.revisionNumber = 0,
    this.changedAt,
    this.changedBySailorId,
    this.hasDecision = false,
  });

  final ImportedRoute? route;
  final String? revisionId;
  final int revisionNumber;
  final DateTime? changedAt;
  final String? changedBySailorId;
  final bool hasDecision;
}

class VoyageRouteEncoder {
  const VoyageRouteEncoder({this.maximumChunkCharacters = 3500});

  final int maximumChunkCharacters;

  EncodedVoyageRoute encode(ImportedRoute route) {
    final compressed = gzip.encode(utf8.encode(route.toJsonString()));
    final encoded = base64Url.encode(compressed);
    final chunks = <String>[];
    for (
      var offset = 0;
      offset < encoded.length;
      offset += maximumChunkCharacters
    ) {
      chunks.add(
        encoded.substring(
          offset,
          (offset + maximumChunkCharacters).clamp(0, encoded.length),
        ),
      );
    }
    return EncodedVoyageRoute(
      chunks: List.unmodifiable(chunks),
      sha256Digest: sha256.convert(compressed).toString(),
      compressedBytes: compressed.length,
    );
  }
}

class EncodedVoyageRoute {
  const EncodedVoyageRoute({
    required this.chunks,
    required this.sha256Digest,
    required this.compressedBytes,
  });

  final List<String> chunks;
  final String sha256Digest;
  final int compressedBytes;
}

class VoyageRouteReducer {
  const VoyageRouteReducer();

  VoyageRouteState fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.voyageId == voyageId &&
                  VoyageEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(VoyageLifecycleReducer.compareEvents);
    final roles = <String, VoyageRole>{};
    final chunksByRevision = <String, Map<int, String>>{};
    final chunkAuthors = <String, String>{};
    final actions = <_RouteAction>[];

    for (final event in ordered) {
      switch (event.type) {
        case VoyageEventType.voyageCreated:
        case VoyageEventType.sailorJoined:
        case VoyageEventType.roleChanged:
          final role = _role(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
          break;
        case VoyageEventType.routeRevisionChunk:
          if (!_isCurrentSkipperEvent(event, roles)) continue;
          final revisionId = _string(event.payload['revisionId']);
          final index = event.payload['index'];
          final data = _string(event.payload['data']);
          if (revisionId == null ||
              index is! int ||
              index < 0 ||
              data == null ||
              data.length > 4096) {
            continue;
          }
          final previousAuthor = chunkAuthors[revisionId];
          if (previousAuthor != null && previousAuthor != event.deviceId) {
            continue;
          }
          chunkAuthors[revisionId] = event.deviceId;
          chunksByRevision.putIfAbsent(revisionId, () => {})[index] = data;
          break;
        case VoyageEventType.routeRevisionPublished:
          if (!_isCurrentSkipperEvent(event, roles)) continue;
          final action = _RouteAction.published(event);
          if (action != null) actions.add(action);
          break;
        case VoyageEventType.routeCleared:
          if (!_isCurrentSkipperEvent(event, roles)) continue;
          final revisionId = _string(event.payload['revisionId']);
          final revisionNumber = event.payload['revisionNumber'];
          if (revisionId == null ||
              revisionNumber is! int ||
              revisionNumber < 1) {
            continue;
          }
          actions.add(
            _RouteAction(
              event: event,
              revisionId: revisionId,
              revisionNumber: revisionNumber,
              cleared: true,
            ),
          );
          break;
        case VoyageEventType.sailorLeft:
        case VoyageEventType.voyageStarted:
        case VoyageEventType.markerStarted:
        case VoyageEventType.markerPass:
        case VoyageEventType.markerEnded:
        case VoyageEventType.statusMessage:
        case VoyageEventType.sailorLocationUpdated:
        case VoyageEventType.hazardReported:
        case VoyageEventType.hazardCleared:
        case VoyageEventType.routeDeviationChanged:
        case VoyageEventType.routeAlertAcknowledged:
        case VoyageEventType.voyagePaused:
        case VoyageEventType.voyageResumed:
        case VoyageEventType.voyageEnded:
        case VoyageEventType.voyageReopened:
        case VoyageEventType.iceInfoShared:
        case VoyageEventType.iceInfoViewed:
        case VoyageEventType.sweeperRoleRequested:
        case VoyageEventType.sweeperRoleResponded:
        case VoyageEventType.rejoinRouteShared:
        case VoyageEventType.sailorContactShared:
          break;
      }
    }

    var state = const VoyageRouteState();
    for (final action in actions) {
      if (action.revisionNumber < state.revisionNumber) continue;
      if (action.cleared) {
        state = VoyageRouteState(
          revisionId: action.revisionId,
          revisionNumber: action.revisionNumber,
          changedAt: action.event.createdAt,
          changedBySailorId: action.event.deviceId,
          hasDecision: true,
        );
        continue;
      }
      final route = _decodeRoute(
        action,
        chunksByRevision[action.revisionId],
        chunkAuthors[action.revisionId],
      );
      if (route == null) continue;
      state = VoyageRouteState(
        route: route,
        revisionId: action.revisionId,
        revisionNumber: action.revisionNumber,
        changedAt: action.event.createdAt,
        changedBySailorId: action.event.deviceId,
        hasDecision: true,
      );
    }
    return state;
  }

  static ImportedRoute? _decodeRoute(
    _RouteAction action,
    Map<int, String>? chunks,
    String? chunkAuthor,
  ) {
    if (chunks == null ||
        chunkAuthor != action.event.deviceId ||
        chunks.length != action.chunkCount) {
      return null;
    }
    final buffer = StringBuffer();
    for (var index = 0; index < action.chunkCount; index += 1) {
      final value = chunks[index];
      if (value == null) return null;
      buffer.write(value);
    }
    try {
      final compressed = base64Url.decode(buffer.toString());
      if (compressed.length != action.compressedBytes ||
          sha256.convert(compressed).toString() != action.sha256Digest) {
        return null;
      }
      return ImportedRoute.fromJsonString(
        utf8.decode(gzip.decode(compressed), allowMalformed: false),
      );
    } on Object {
      return null;
    }
  }

  static bool _isCurrentSkipperEvent(
    VoyageEvent event,
    Map<String, VoyageRole> roles,
  ) =>
      roles[event.deviceId] == VoyageRole.lead &&
      event.payload['skipperSailorId'] == event.deviceId;

  static VoyageRole? _role(Object? value) {
    if (value is! String) return null;
    try {
      return VoyageRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

class _RouteAction {
  const _RouteAction({
    required this.event,
    required this.revisionId,
    required this.revisionNumber,
    required this.cleared,
    this.chunkCount = 0,
    this.compressedBytes = 0,
    this.sha256Digest = '',
  });

  static _RouteAction? published(VoyageEvent event) {
    final revisionId = VoyageRouteReducer._string(event.payload['revisionId']);
    final revisionNumber = event.payload['revisionNumber'];
    final chunkCount = event.payload['chunkCount'];
    final compressedBytes = event.payload['compressedBytes'];
    final digest = VoyageRouteReducer._string(event.payload['sha256']);
    if (revisionId == null ||
        revisionNumber is! int ||
        revisionNumber < 1 ||
        chunkCount is! int ||
        chunkCount < 1 ||
        chunkCount > 5000 ||
        compressedBytes is! int ||
        compressedBytes < 1 ||
        digest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return null;
    }
    return _RouteAction(
      event: event,
      revisionId: revisionId,
      revisionNumber: revisionNumber,
      cleared: false,
      chunkCount: chunkCount,
      compressedBytes: compressedBytes,
      sha256Digest: digest,
    );
  }

  final VoyageEvent event;
  final String revisionId;
  final int revisionNumber;
  final bool cleared;
  final int chunkCount;
  final int compressedBytes;
  final String sha256Digest;
}
