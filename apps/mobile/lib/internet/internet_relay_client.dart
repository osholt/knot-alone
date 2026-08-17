import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/voyage_event.dart';
import '../domain/sailor_location.dart';
import '../domain/voyage_session.dart';
import '../relay/relay_event_compatibility.dart';

class InternetRelayConfiguration {
  const InternetRelayConfiguration({
    required this.baseUri,
    this.headerTimeout = const Duration(seconds: 8),
    this.bodyTimeout = const Duration(seconds: 15),
    this.maximumRequestBytes = 64 * 1024,
    this.maximumResponseBytes = 128 * 1024,
    this.maximumEventBytes = 8 * 1024,
    this.maximumUploadEvents = 20,
    this.maximumDownloadEvents = 100,
  });

  factory InternetRelayConfiguration.fromEnvironment() {
    const value = String.fromEnvironment('TIDE_AND_SEEK_API_BASE_URL');
    if (value.trim().isEmpty) {
      return const InternetRelayConfiguration(baseUri: null);
    }
    return InternetRelayConfiguration(baseUri: Uri.tryParse(value.trim()));
  }

  final Uri? baseUri;
  final Duration headerTimeout;
  final Duration bodyTimeout;
  final int maximumRequestBytes;
  final int maximumResponseBytes;
  final int maximumEventBytes;
  final int maximumUploadEvents;
  final int maximumDownloadEvents;

  bool get isConfigured => configurationError == null && baseUri != null;

  String? get configurationError {
    final uri = baseUri;
    if (uri == null) return 'No internet relay endpoint is configured.';
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      return 'Internet relay requires an absolute HTTPS endpoint.';
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      return 'Internet relay endpoint cannot contain credentials, a query, or a fragment.';
    }
    return null;
  }
}

abstract final class RelayProtocolCapabilities {
  static const voyageStart = 'voyage-start-v1';
  static const membership = 'membership-v1';
  static const preStartPresence = 'pre-start-presence-v1';

  /// Presence that spans the pre-start and started phases and reports a
  /// cursor-independent voyage roster. Supersedes [preStartPresence]; both are
  /// advertised so an older relay keeps working.
  static const livePresence = 'live-presence-v2';
  static const routeRevisions = 'route-revisions-v1';
  static const pushNotifications = 'push-notifications-v1';
  static const observerAccess = 'observer-access-v1';
  static const trafficIncidents = 'traffic-incidents-v1';
  static const trafficReroutes = 'traffic-reroutes-v1';

  /// The skipper asking a named sailor to take the Sweeper role, and
  /// that sailor's answer (issue #128 part 1).
  static const sweeperRoleAssignment = 'sweeper-role-assignment-v1';

  /// A separated sailor's advisory rejoin route, relayed to the voyage skipper only
  /// (issue #128 part 2).
  static const rejoinRouteSharing = 'rejoin-route-sharing-v1';

  /// A sailor's own phone number, addressed to the voyage's coordination roles
  /// (issue #188). Named so a client can say "the voyage service cannot carry
  /// this" instead of appearing to have shared a number that went nowhere.
  static const sailorContactSharing = 'sailor-contact-sharing-v1';

  /// The skipper un-ending a voyage that ended by mistake (#206, #207).
  ///
  /// Named so a client can refuse to offer the action rather than record a
  /// reopen that never leaves the phone: a skipper back on the map while every
  /// other sailor still sees a finished voyage is worse than being told it cannot
  /// be done.
  static const voyageReopen = 'voyage-reopen-v1';

  static const current = {
    voyageStart,
    membership,
    preStartPresence,
    livePresence,
    routeRevisions,
    pushNotifications,
    observerAccess,
    trafficIncidents,
    trafficReroutes,
    sweeperRoleAssignment,
    rejoinRouteSharing,
    sailorContactSharing,
    voyageReopen,
  };
}

class RelayClientDescriptor {
  const RelayClientDescriptor({
    required this.protocolVersion,
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    required this.capabilities,
    this.distributionTrack = unknownVersion,
  });

  /// The build's real identity.
  ///
  /// When a build channel does not inject `TIDE_AND_SEEK_APP_VERSION` /
  /// `TIDE_AND_SEEK_APP_BUILD` the descriptor reports [unknownVersion] instead of
  /// a plausible-looking constant. A wrong version is worse than an absent one:
  /// it makes every version-conditional diagnostic silently misleading.
  factory RelayClientDescriptor.current() => RelayClientDescriptor(
    protocolVersion: 1,
    platform: defaultTargetPlatform.name,
    appVersion: _declaredAppVersion,
    appBuild: _declaredAppBuild,
    capabilities: RelayProtocolCapabilities.current,
    distributionTrack: _declaredDistributionTrack,
  );

  static const unknownVersion = 'unknown';

  static const _rawAppVersion = String.fromEnvironment(
    'TIDE_AND_SEEK_APP_VERSION',
  );
  static const _rawAppBuild = String.fromEnvironment('TIDE_AND_SEEK_APP_BUILD');
  static const _rawDistributionTrack = String.fromEnvironment(
    'TIDE_AND_SEEK_DISTRIBUTION_TRACK',
  );

  static String get _declaredAppVersion =>
      _sanitiseDescriptorValue(_rawAppVersion);

  static String get _declaredAppBuild => _sanitiseDescriptorValue(_rawAppBuild);

  static String get _declaredDistributionTrack =>
      _sanitiseDescriptorValue(_rawDistributionTrack);

  /// Keeps a dart-define out of the header set unless it is a plain, bounded
  /// token, so a malformed injection can never smuggle header syntax.
  static String _sanitiseDescriptorValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return unknownVersion;
    if (!RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(trimmed)) return unknownVersion;
    return trimmed;
  }

  final int protocolVersion;
  final String platform;
  final String appVersion;
  final String appBuild;
  final Set<String> capabilities;

  /// The distribution track the build was destined for, as stamped in by the
  /// release workflow, or [unknownVersion] on an unstamped build.
  ///
  /// Sent to the relay so the reverse proxy's access log answers "which track
  /// is this tester on" without asking the tester, which is exactly the
  /// question the #101 delivery investigation could not answer. Parsed into
  /// [DistributionTrack] by `BuildIdentity.fromEnvironment`, so the About
  /// screen and this header can never disagree.
  final String distributionTrack;

  /// False when the build channel did not inject its version, so callers can
  /// say "this build does not report its version" instead of quoting a wrong
  /// one.
  bool get reportsAppVersion =>
      appVersion != unknownVersion && appBuild != unknownVersion;

  Map<String, String> get headers => {
    'x-tailendcharlie-protocol': '$protocolVersion',
    'x-tailendcharlie-platform': platform,
    'x-tailendcharlie-app-version': appVersion,
    'x-tailendcharlie-app-build': appBuild,
    'x-tailendcharlie-distribution-track': distributionTrack,
    'x-tailendcharlie-capabilities': (capabilities.toList()..sort()).join(','),
  };
}

enum RelayCompatibilityDisposition {
  compatible,
  legacyCompatible,
  updateRequired,
  serverUpgradeRequired,
  temporarilyUnavailable,
}

class RelayCompatibilityResult {
  const RelayCompatibilityResult({
    required this.disposition,
    required this.serverProtocol,
    required this.minimumClientProtocol,
    required this.capabilities,
    required this.checkedAt,
    required this.validUntil,
    this.message,
    this.updateUri,
  });

  final RelayCompatibilityDisposition disposition;
  final int serverProtocol;
  final int minimumClientProtocol;
  final Set<String> capabilities;
  final DateTime checkedAt;
  final DateTime validUntil;
  final String? message;
  final Uri? updateUri;

  bool get canSynchronize =>
      disposition == RelayCompatibilityDisposition.compatible ||
      disposition == RelayCompatibilityDisposition.legacyCompatible;

  bool supports(String capability) => capabilities.contains(capability);
}

abstract interface class RelayCompatibilityApi {
  Future<RelayCompatibilityResult> checkCompatibility();

  void close();
}

class InternetSyncResult {
  const InternetSyncResult({
    required this.cursor,
    required this.acceptedEventIds,
    required this.events,
    this.ignoredEventCount = 0,
    this.ignoredEventTypes = const {},
  });

  final String cursor;
  final Set<String> acceptedEventIds;
  final List<VoyageEvent> events;

  /// Events in the batch this build does not understand. They are skipped, the
  /// cursor still advances past them, and the rest of the batch is delivered:
  /// one future event type must never stall the whole voyage.
  final int ignoredEventCount;

  /// The sanitised type names that were skipped, for a named diagnostic. Only
  /// short, alphanumeric names survive sanitisation.
  final Set<String> ignoredEventTypes;
}

class InternetRelayException implements Exception {
  const InternetRelayException(
    this.message, {
    this.retryable = false,
    this.unauthorized = false,
    this.retryAfter,
    this.statusCode,
    this.code,
    this.actionUrl,
  });

  final String message;
  final bool retryable;
  final bool unauthorized;
  final Duration? retryAfter;
  final int? statusCode;
  final String? code;
  final Uri? actionUrl;

  @override
  String toString() => 'InternetRelayException: $message';
}

abstract interface class InternetRelayApi {
  InternetRelayConfiguration get configuration;

  Future<InternetSyncResult> synchronize({
    required VoyageSession session,
    required String? cursor,
    required List<VoyageEvent> events,
  });

  void close();
}

abstract interface class PreStartPresenceApi {
  InternetRelayConfiguration get configuration;

  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required VoyageSession session,
    required SailorLocation? position,
    required bool clear,
  });

  void close();
}

/// The voyage phase the presence channel reports, so the client never has to
/// infer continuity from its own journal cursor.
enum VoyagePresencePhase { open, started, ended, unknown }

/// One sailor the presence channel says is in the voyage.
///
/// Derived by the relay from durable membership events without consulting the
/// caller's cursor, so a wedged or backed-off batch sync cannot hide a
/// participant.
class PresenceRosterEntry {
  const PresenceRosterEntry({
    required this.sailorId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.left = false,
    this.leftAt,
  });

  final String sailorId;
  final String displayName;
  final String role;
  final DateTime joinedAt;
  final bool left;

  /// When the relay recorded the departure. Absent from an older relay, which
  /// reports [left] alone.
  final DateTime? leftAt;
}

class PreStartPresenceResult {
  const PreStartPresenceResult({
    required this.locations,
    required this.ttl,
    this.phase = VoyagePresencePhase.unknown,
    this.roster = const [],
    this.legacyPeerSailorIds = const {},
    this.livePresenceServed = false,
    this.serverTime,
    this.unreadablePositionCount = 0,
  });

  final List<SailorLocation> locations;
  final Duration ttl;

  /// The relay's own clock at the moment it built this reply, when it reports
  /// one. It is the only clock two phones share, so it is what a peer's
  /// relay-stamped position is aged against.
  final DateTime? serverTime;

  /// Positions in the reply this build could not decode. They are skipped
  /// individually: one unreadable position must never discard the whole reply,
  /// which is how a single bad row used to hide every sailor at once.
  final int unreadablePositionCount;

  /// The phase the relay reports for this voyage.
  final VoyagePresencePhase phase;

  /// Sailors the relay knows about, independent of the event batch.
  final List<PresenceRosterEntry> roster;

  /// Sailors whose presence was published by a build without live-presence
  /// support, so their position will stop once the voyage starts.
  final Set<String> legacyPeerSailorIds;

  /// True when the relay served positions under the live-presence contract
  /// rather than the legacy pre-start-only one.
  final bool livePresenceServed;
}

/// The short-lived server directory that turns a six-digit voyage code into the
/// voyage credentials needed by the authenticated relays.
abstract interface class VoyageCodeDirectory {
  Future<void> register(VoyageSession session);

  Future<VoyageCodeCredentials> resolve(String voyageCode, {String? joinToken});

  void close();
}

class VoyageCodeCredentials {
  const VoyageCodeCredentials({
    required this.voyageId,
    required this.voyageCode,
    required this.inviteSecret,
    required this.joinToken,
  });

  final String voyageId;
  final String voyageCode;
  final String inviteSecret;

  /// So a sailor who joins can also re-share a fully hardened invite later,
  /// not just the voyage creator.
  final String joinToken;
}

class VoyageCodeDirectoryException implements Exception {
  const VoyageCodeDirectoryException(
    this.message, {
    this.codeConflict = false,
    this.retryable = false,
  });

  final String message;
  final bool codeConflict;
  final bool retryable;

  @override
  String toString() => 'VoyageCodeDirectoryException: $message';
}

class HttpVoyageCodeDirectory implements VoyageCodeDirectory {
  factory HttpVoyageCodeDirectory.fromEnvironment() => HttpVoyageCodeDirectory(
    configuration: InternetRelayConfiguration.fromEnvironment(),
    client: http.Client(),
  );

  factory HttpVoyageCodeDirectory({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpVoyageCodeDirectory._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpVoyageCodeDirectory._(
    this.configuration,
    this._client,
    this._clientDescriptor,
    this._clock,
  );

  final InternetRelayConfiguration configuration;
  final http.Client _client;
  final RelayClientDescriptor _clientDescriptor;
  final DateTime Function() _clock;
  RelayCompatibilityResult? _cachedCompatibility;

  /// How hard to try the compatibility probe before giving up on an answer and
  /// letting the directory call itself speak (#208).
  static const _compatibilityProbeAttempts = 2;
  static const _compatibilityRetryBackoff = Duration(milliseconds: 300);

  @override
  Future<void> register(VoyageSession session) async {
    _validateConfiguration();
    _validateSession(session);
    await _ensureCompatibility();
    final response = await _send(
      http.Request('PUT', _joinCodeUri(session.voyageCode))
        ..followRedirects = false
        ..headers.addAll({
          'accept': 'application/json',
          'authorization': 'Bearer ${_voyageBearerToken(session)}',
          'content-type': 'application/json',
          ..._clientDescriptor.headers,
        })
        ..body = jsonEncode({
          'voyageId': session.voyageId,
          'inviteSecret': session.inviteSecret,
          'resolveToken': session.joinToken,
        }),
    );
    if (response.statusCode == 204) return;
    throw _directoryFailure(response.statusCode);
  }

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async {
    _validateConfiguration();
    await _ensureCompatibility();
    final normalizedCode = _normaliseCode(voyageCode);
    final response = await _send(
      http.Request('GET', _joinCodeUri(normalizedCode))
        ..followRedirects = false
        ..headers['accept'] = 'application/json'
        ..headers.addAll(_clientDescriptor.headers)
        ..headers.addAll(
          joinToken == null ? {} : {'x-tide-and-seek-join-token': joinToken},
        ),
    );
    final body = await _readBoundedResponse(response);
    if (response.statusCode != 200) {
      throw _directoryFailure(response.statusCode);
    }
    final contentType = response.headers['content-type']?.toLowerCase();
    if (contentType == null || !contentType.contains('application/json')) {
      throw const VoyageCodeDirectoryException(
        'Voyage code service returned an invalid response.',
      );
    }
    try {
      final value = jsonDecode(utf8.decode(body));
      if (value is! Map) {
        throw const FormatException('Response is not an object.');
      }
      final json = Map<String, Object?>.from(value);
      final voyageId = json['voyageId'];
      final returnedCode = json['voyageCode'];
      final secret = json['inviteSecret'];
      final returnedJoinToken = json['resolveToken'];
      if (voyageId is! String ||
          voyageId.isEmpty ||
          voyageId.length > 128 ||
          returnedCode is! String ||
          returnedCode != normalizedCode ||
          secret is! String ||
          secret.length < 16 ||
          secret.length > 512 ||
          returnedJoinToken is! String ||
          returnedJoinToken.length < 16 ||
          returnedJoinToken.length > 128) {
        throw const FormatException('Response fields are invalid.');
      }
      return VoyageCodeCredentials(
        voyageId: voyageId,
        voyageCode: returnedCode,
        inviteSecret: secret,
        joinToken: returnedJoinToken,
      );
    } on Object {
      // Deliberately not interpolated: a transport or TLS error message can
      // carry the relay hostname and port.
      throw const VoyageCodeDirectoryException(
        'Voyage code service returned an invalid response.',
      );
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await _client.send(request).timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const VoyageCodeDirectoryException(
        'Voyage code service timed out. Check your connection and try again.',
        retryable: true,
      );
    } on http.ClientException {
      throw const VoyageCodeDirectoryException(
        'Voyage code service is temporarily unavailable. Check your connection and try again.',
        retryable: true,
      );
    }
  }

  /// Checks compatibility before a directory call, and refuses the call only on
  /// a definite answer that the two ends disagree.
  ///
  /// A probe that times out says nothing about compatibility, and it used to be
  /// fatal: a tester on a working 4G connection could not rejoin her own voyage,
  /// and the sentence she was shown was "Voyage service compatibility check timed
  /// out" (#208). Treating silence as incompatible is the wrong default for an
  /// offline-first app — and it is not even the safe one, because
  /// `InternetRelayWorker`'s `updateRequired` phase is what actually stops an
  /// incompatible client from synchronising. That gate stays where it is.
  ///
  /// So: retry a little, then proceed on anything short of a verdict. A join that
  /// goes ahead against an unreachable relay fails at the directory call itself,
  /// with an error about the connection, which is the truth.
  Future<void> _ensureCompatibility() async {
    for (var attempt = 0; ; attempt += 1) {
      try {
        final result = await _fetchCompatibility(
          configuration: configuration,
          client: _client,
          descriptor: _clientDescriptor,
          clock: _clock,
          cached: _cachedCompatibility,
        );
        _cachedCompatibility = result;
        if (result.canSynchronize ||
            result.disposition ==
                RelayCompatibilityDisposition.temporarilyUnavailable) {
          return;
        }
        // A real disagreement about the protocol. Updating the app is the only
        // way through it, so saying so now beats a confusing failure later.
        throw VoyageCodeDirectoryException(
          result.message ??
              'This app and the voyage service are not compatible.',
        );
      } on InternetRelayException {
        if (attempt >= _compatibilityProbeAttempts - 1) return;
        await Future<void>.delayed(_compatibilityRetryBackoff * (attempt + 1));
      }
    }
  }

  Future<Uint8List> _readBoundedResponse(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > 2048) {
      throw const VoyageCodeDirectoryException(
        'Voyage code service returned an oversized response.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(
        configuration.bodyTimeout,
      )) {
        if (bytes.length + chunk.length > 2048) {
          throw const VoyageCodeDirectoryException(
            'Voyage code service returned an oversized response.',
          );
        }
        bytes.add(chunk);
      }
    } on TimeoutException {
      throw const VoyageCodeDirectoryException(
        'Voyage code service timed out. Check your connection and try again.',
        retryable: true,
      );
    }
    return bytes.takeBytes();
  }

  void _validateConfiguration() {
    final error = configuration.configurationError;
    if (error != null) {
      throw const VoyageCodeDirectoryException(
        'Joining by voyage code needs the Tide and Seek service to be connected.',
      );
    }
  }

  void _validateSession(VoyageSession session) {
    _normaliseCode(session.voyageCode);
    if (session.voyageId.isEmpty ||
        session.voyageId.length > 128 ||
        session.inviteSecret.length < 16 ||
        session.joinToken.length < 16) {
      throw const VoyageCodeDirectoryException(
        'This voyage cannot be shared with a code.',
      );
    }
  }

  VoyageCodeDirectoryException _directoryFailure(int status) =>
      switch (status) {
        400 => const VoyageCodeDirectoryException(
          'Enter a valid six-digit voyage code.',
        ),
        404 => const VoyageCodeDirectoryException(
          'That voyage code is not active. Check it with the voyage lead.',
        ),
        409 => const VoyageCodeDirectoryException(
          'That voyage code is already in use. A new code will be chosen.',
          codeConflict: true,
        ),
        429 => const VoyageCodeDirectoryException(
          'Too many voyage-code attempts. Please wait a moment and try again.',
          retryable: true,
        ),
        401 || 403 => const VoyageCodeDirectoryException(
          'Voyage code service rejected this voyage.',
        ),
        _ => VoyageCodeDirectoryException(
          'Voyage code service returned HTTP $status.',
          retryable: status >= 500,
        ),
      };

  String _normaliseCode(String value) {
    final code = value.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const VoyageCodeDirectoryException(
        'Enter a valid six-digit voyage code.',
      );
    }
    return code;
  }

  Uri _joinCodeUri(String voyageCode) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/join-codes/${Uri.encodeComponent(voyageCode)}',
    );
  }

  @override
  void close() => _client.close();
}

class HttpInternetRelayClient
    implements InternetRelayApi, RelayCompatibilityApi {
  factory HttpInternetRelayClient({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpInternetRelayClient._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpInternetRelayClient._(
    this.configuration,
    this._client,
    this._clientDescriptor,
    this._clock,
  );

  @override
  final InternetRelayConfiguration configuration;
  final http.Client _client;
  final RelayClientDescriptor _clientDescriptor;
  final DateTime Function() _clock;
  RelayCompatibilityResult? _cachedCompatibility;

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async {
    final result = await _fetchCompatibility(
      configuration: configuration,
      client: _client,
      descriptor: _clientDescriptor,
      clock: _clock,
      cached: _cachedCompatibility,
    );
    _cachedCompatibility = result;
    return result;
  }

  @override
  Future<InternetSyncResult> synchronize({
    required VoyageSession session,
    required String? cursor,
    required List<VoyageEvent> events,
  }) async {
    final configurationError = configuration.configurationError;
    if (configurationError != null) {
      throw InternetRelayException(configurationError);
    }
    if (session.inviteSecret.length < 16) {
      throw const InternetRelayException(
        'Internet relay requires an authenticated voyage invitation.',
      );
    }
    if (session.voyageId.isEmpty ||
        session.voyageId.length > 128 ||
        session.localSailorId.isEmpty ||
        session.localSailorId.length > 128) {
      throw const InternetRelayException(
        'Voyage or device identity is invalid.',
      );
    }
    if (events.length > configuration.maximumUploadEvents) {
      throw const InternetRelayException('Upload event limit exceeded.');
    }
    if (cursor != null && cursor.length > 512) {
      throw const InternetRelayException('Stored cursor is invalid.');
    }
    for (final event in events) {
      _validateEventForVoyage(event, session.voyageId);
      if (utf8.encode(jsonEncode(event.toJson())).length >
          configuration.maximumEventBytes) {
        throw InternetRelayException(
          'Event ${event.id} exceeds the size limit.',
        );
      }
    }

    final bodyBytes = utf8.encode(
      jsonEncode({
        'protocolVersion': 1,
        'deviceId': session.localSailorId,
        'cursor': cursor,
        'events': events.map((event) => event.toJson()).toList(growable: false),
      }),
    );
    if (bodyBytes.length > configuration.maximumRequestBytes) {
      throw const InternetRelayException(
        'Sync request exceeds the size limit.',
      );
    }

    final request = http.Request('POST', _syncUri(session.voyageId))
      ..followRedirects = false
      ..headers.addAll({
        'accept': 'application/json',
        'authorization': 'Bearer ${_voyageBearerToken(session)}',
        'content-type': 'application/json',
        'idempotency-key': _idempotencyKey(bodyBytes),
        'x-tide-and-seek-device': session.localSailorId,
        ..._clientDescriptor.headers,
      })
      ..bodyBytes = bodyBytes;

    late http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Internet relay timed out before receiving response headers.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Internet relay is temporarily unavailable. Check your connection and try again.',
        retryable: true,
      );
    }

    late Uint8List responseBytes;
    try {
      responseBytes = await _readBoundedResponse(
        response,
      ).timeout(configuration.bodyTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Internet relay response body timed out.',
        retryable: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failureForResponse(response, responseBytes);
    }
    final contentType = response.headers['content-type']?.toLowerCase();
    if (contentType == null || !contentType.contains('application/json')) {
      throw const InternetRelayException(
        'Internet relay returned a non-JSON response.',
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map) {
        throw const FormatException('Response is not an object.');
      }
      final json = Map<String, Object?>.from(decoded);
      if ((json['protocolVersion'] as num?)?.toInt() != 1) {
        throw const FormatException('Unsupported protocol version.');
      }
      final responseCursor = json['cursor'];
      if (responseCursor is! String || responseCursor.length > 512) {
        throw const FormatException('Invalid response cursor.');
      }
      final acceptedValues = json['acceptedEventIds'];
      final eventValues = json['events'];
      if (acceptedValues is! List || eventValues is! List) {
        throw const FormatException('Missing response event arrays.');
      }
      if (acceptedValues.length > configuration.maximumUploadEvents ||
          eventValues.length > configuration.maximumDownloadEvents) {
        throw const FormatException('Response event limit exceeded.');
      }
      final uploadedIds = events.map((event) => event.id).toSet();
      final acceptedIds = acceptedValues.map((value) {
        if (value is! String ||
            value.length > 128 ||
            !uploadedIds.contains(value)) {
          throw const FormatException('Invalid accepted event ID.');
        }
        return value;
      }).toSet();
      final remoteEvents = <VoyageEvent>[];
      final ignoredTypes = <String>{};
      var ignoredCount = 0;
      for (final value in eventValues) {
        if (value is! Map) {
          throw const FormatException('Invalid event object.');
        }
        final raw = Map<String, Object?>.from(value);
        if (utf8.encode(jsonEncode(raw)).length >
            configuration.maximumEventBytes) {
          throw const FormatException('Response event exceeds the size limit.');
        }
        // A newer peer's event type, schema version or added field must be
        // skipped, not treated as a corrupt batch. Failing the whole response
        // would stall the cursor forever and hide every sailor.
        final unsupported = describeUnsupportedRelayEvent(raw);
        if (unsupported != null) {
          ignoredCount += 1;
          ignoredTypes.add(unsupported);
          continue;
        }
        final event = VoyageEvent.fromJson(raw);
        _validateEventForVoyage(event, session.voyageId);
        remoteEvents.add(event);
      }
      return InternetSyncResult(
        cursor: responseCursor,
        acceptedEventIds: acceptedIds,
        events: List.unmodifiable(remoteEvents),
        ignoredEventCount: ignoredCount,
        ignoredEventTypes: Set.unmodifiable(ignoredTypes),
      );
    } on InternetRelayException {
      rethrow;
    } on Object {
      throw const InternetRelayException(
        'Internet relay returned a response this app could not read.',
      );
    }
  }

  Future<Uint8List> _readBoundedResponse(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null &&
        declaredLength > configuration.maximumResponseBytes) {
      throw const InternetRelayException(
        'Internet relay response exceeds the size limit.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > configuration.maximumResponseBytes) {
        throw const InternetRelayException(
          'Internet relay response exceeds the size limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  InternetRelayException _failureForResponse(
    http.StreamedResponse response,
    Uint8List responseBytes,
  ) {
    final status = response.statusCode;
    final unauthorized = status == 401 || status == 403;
    var retryable = status == 408 || status == 429 || status >= 500;
    String? code;
    String? serverMessage;
    Uri? actionUrl;
    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is Map) {
        code = decoded['code'] as String?;
        serverMessage =
            decoded['message'] as String? ?? decoded['error'] as String?;
        actionUrl = Uri.tryParse(decoded['updateUrl'] as String? ?? '');
        if (status == 400 && serverMessage == 'Invalid cursor') {
          code = 'invalid_cursor';
          retryable = true;
        }
      }
    } on Object {
      // A bounded but invalid error body falls back to the safe status text.
    }
    return InternetRelayException(
      serverMessage ??
          (unauthorized
              ? 'Internet relay rejected this voyage credential.'
              : 'Internet relay returned HTTP $status.'),
      retryable: retryable,
      unauthorized: unauthorized,
      retryAfter: status == 429 ? _parseRetryAfter(response.headers) : null,
      statusCode: status,
      code: code,
      actionUrl: actionUrl,
    );
  }

  Duration? _parseRetryAfter(Map<String, String> headers) {
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds.clamp(0, 300));
  }

  Uri _syncUri(String voyageId) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/voyages/${Uri.encodeComponent(voyageId)}/events:sync',
    );
  }

  String _idempotencyKey(List<int> bodyBytes) =>
      'rr1-${base64Url.encode(sha256.convert(bodyBytes).bytes).replaceAll('=', '')}';

  void _validateEventForVoyage(VoyageEvent event, String voyageId) {
    if (event.schemaVersion != 1 ||
        event.voyageId != voyageId ||
        event.id.isEmpty ||
        event.id.length > 128 ||
        event.deviceId.isEmpty ||
        event.deviceId.length > 128 ||
        event.signature.isEmpty ||
        event.signature.length > 256) {
      throw InternetRelayException(
        'Event ${event.id} is invalid for this voyage.',
      );
    }
  }

  @override
  void close() => _client.close();
}

class HttpPreStartPresenceClient implements PreStartPresenceApi {
  factory HttpPreStartPresenceClient({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpPreStartPresenceClient._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpPreStartPresenceClient._(
    this.configuration,
    this._client,
    this._clientDescriptor,
    this._clock,
  );

  @override
  final InternetRelayConfiguration configuration;
  final http.Client _client;
  final RelayClientDescriptor _clientDescriptor;
  final DateTime Function() _clock;
  RelayCompatibilityResult? _cachedCompatibility;

  @override
  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required VoyageSession session,
    required SailorLocation? position,
    required bool clear,
  }) async {
    final compatibility = await _fetchCompatibility(
      configuration: configuration,
      client: _client,
      descriptor: _clientDescriptor,
      clock: _clock,
      cached: _cachedCompatibility,
    );
    _cachedCompatibility = compatibility;
    final servesLivePresence = compatibility.supports(
      RelayProtocolCapabilities.livePresence,
    );
    if (!servesLivePresence &&
        !compatibility.supports(RelayProtocolCapabilities.preStartPresence)) {
      throw const InternetRelayException(
        'This voyage service does not support live sailor positions yet.',
        code: 'feature_unsupported',
      );
    }
    if (clear && position != null) {
      throw const InternetRelayException(
        'A pre-start position cannot be published and cleared together.',
      );
    }
    if (session.voyageId.isEmpty ||
        session.voyageId.length > 128 ||
        session.localSailorId.isEmpty ||
        session.localSailorId.length > 128 ||
        session.inviteSecret.length < 16) {
      throw const InternetRelayException(
        'Voyage identity is invalid for pre-start positions.',
      );
    }
    if (position != null && position.sailorId != session.localSailorId) {
      throw const InternetRelayException(
        'A sailor can only publish their own pre-start position.',
      );
    }
    final bodyBytes = utf8.encode(
      jsonEncode({
        'protocolVersion': 1,
        'deviceId': session.localSailorId,
        'position': position == null
            ? null
            : {
                'displayName': position.displayName,
                'role': position.role.name,
                'vesselStyle': position.sailorSymbol.wireValue(
                  position.vesselStyle,
                ),
                'sailorColor': position.sailorColor.name,
                'sample': position.sample.toJson(),
              },
        'clear': clear,
      }),
    );
    if (bodyBytes.length > configuration.maximumRequestBytes) {
      throw const InternetRelayException(
        'Pre-start position request exceeds the size limit.',
      );
    }
    final request = http.Request('POST', _presenceUri(session.voyageId))
      ..followRedirects = false
      ..headers.addAll({
        'accept': 'application/json',
        'authorization': 'Bearer ${_voyageBearerToken(session)}',
        'content-type': 'application/json',
        'x-tide-and-seek-device': session.localSailorId,
        ..._clientDescriptor.headers,
      })
      ..bodyBytes = bodyBytes;

    late http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Pre-start position service timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Pre-start positions are temporarily unavailable.',
        retryable: true,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      configuration.bodyTimeout,
    )) {
      if (bytes.length + chunk.length > configuration.maximumResponseBytes) {
        throw const InternetRelayException(
          'Pre-start position response exceeds the size limit.',
        );
      }
      bytes.add(chunk);
    }
    final responseBytes = bytes.takeBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      try {
        final value = jsonDecode(utf8.decode(responseBytes));
        if (value is Map) {
          message = (value['error'] ?? value['message']) as String?;
        }
      } on Object {
        // Use the bounded fallback below.
      }
      throw InternetRelayException(
        message ?? 'Pre-start position service rejected the request.',
        retryable:
            response.statusCode == 404 ||
            response.statusCode == 429 ||
            response.statusCode >= 500,
        unauthorized: response.statusCode == 401 || response.statusCode == 403,
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map ||
          decoded['protocolVersion'] != 1 ||
          decoded['ttlSeconds'] is! int ||
          decoded['positions'] is! List) {
        throw const FormatException('Invalid presence response envelope.');
      }
      final ttlSeconds = (decoded['ttlSeconds'] as int).clamp(15, 300);
      final values = decoded['positions'] as List;
      if (values.length > 1000) {
        throw const FormatException('Too many live positions.');
      }
      final serverTime = DateTime.tryParse(
        decoded['serverTime'] as String? ?? '',
      )?.toLocal();
      final locations = <SailorLocation>[];
      final legacyPeers = <String>{};
      var unreadable = 0;
      for (final value in values) {
        // One unusable position is skipped, never fatal. Discarding the whole
        // reply took every other sailor's position and the roster with it, and a
        // device whose clock ran ahead of the relay hit that on every single
        // poll: the relay had already deleted every expired row on its own
        // clock, so the local re-check could only ever be measuring skew.
        if (value is! Map) {
          unreadable += 1;
          continue;
        }
        final raw = Map<String, Object?>.from(value);
        try {
          final expiresAt = DateTime.parse(raw['expiresAt']! as String);
          final receivedAt = DateTime.parse(raw['receivedAt']! as String);
          // Judged on the relay's own clock when it reports one, and otherwise
          // not judged at all: only the relay can say what it has expired.
          if (!expiresAt.isAfter(serverTime ?? receivedAt)) {
            unreadable += 1;
            continue;
          }
          // Unknown response fields from a newer relay are ignored rather than
          // rejected, so only the fields this build knows are decoded.
          final location = SailorLocation.fromJson({
            for (final field in _presenceLocationFields)
              if (raw.containsKey(field)) field: raw[field],
          });
          if (raw['livePresence'] == false) legacyPeers.add(location.sailorId);
          locations.add(location);
        } on Object {
          unreadable += 1;
        }
      }
      return PreStartPresenceResult(
        locations: List.unmodifiable(locations),
        ttl: Duration(seconds: ttlSeconds),
        phase: _presencePhase(decoded['phase']),
        roster: _presenceRoster(decoded['members']),
        legacyPeerSailorIds: Set.unmodifiable(legacyPeers),
        livePresenceServed: servesLivePresence,
        serverTime: serverTime,
        unreadablePositionCount: unreadable,
      );
    } on InternetRelayException {
      rethrow;
    } on Object {
      throw const InternetRelayException(
        'The live position service returned a response this app could not read.',
      );
    }
  }

  static const _presenceLocationFields = {
    'sailorId',
    'displayName',
    'role',
    'sample',
    'receivedAt',
    'vesselStyle',
    'sailorColor',
  };

  /// An absent or unrecognised phase degrades to
  /// [VoyagePresencePhase.unknown] rather than failing: an older relay does not
  /// report one, and a newer relay may add one this build has never seen.
  static VoyagePresencePhase _presencePhase(Object? value) => switch (value) {
    'open' => VoyagePresencePhase.open,
    'started' => VoyagePresencePhase.started,
    'ended' => VoyagePresencePhase.ended,
    _ => VoyagePresencePhase.unknown,
  };

  static List<PresenceRosterEntry> _presenceRoster(Object? value) {
    if (value is! List) return const [];
    final entries = <PresenceRosterEntry>[];
    for (final item in value.take(1000)) {
      if (item is! Map) continue;
      final sailorId = item['sailorId'];
      final displayName = item['displayName'];
      final role = item['role'];
      final joinedAt = DateTime.tryParse(item['joinedAt'] as String? ?? '');
      if (sailorId is! String ||
          sailorId.isEmpty ||
          sailorId.length > 128 ||
          displayName is! String ||
          displayName.isEmpty ||
          displayName.length > 80 ||
          role is! String ||
          joinedAt == null) {
        continue;
      }
      entries.add(
        PresenceRosterEntry(
          sailorId: sailorId,
          displayName: displayName,
          role: role,
          joinedAt: joinedAt.toLocal(),
          left: item['left'] == true,
          leftAt: DateTime.tryParse(item['leftAt'] as String? ?? '')?.toLocal(),
        ),
      );
    }
    return List.unmodifiable(entries);
  }

  Uri _presenceUri(String voyageId) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/voyages/${Uri.encodeComponent(voyageId)}/presence:sync',
    );
  }

  @override
  void close() => _client.close();
}

Future<RelayCompatibilityResult> _fetchCompatibility({
  required InternetRelayConfiguration configuration,
  required http.Client client,
  required RelayClientDescriptor descriptor,
  required DateTime Function() clock,
  required RelayCompatibilityResult? cached,
}) async {
  final configurationError = configuration.configurationError;
  if (configurationError != null) {
    throw InternetRelayException(configurationError);
  }
  final now = clock();
  if (cached != null && now.isBefore(cached.validUntil)) return cached;
  final base = configuration.baseUri!;
  final baseText = base.toString().endsWith('/')
      ? base.toString().substring(0, base.toString().length - 1)
      : base.toString();
  final request = http.Request('GET', Uri.parse('$baseText/v1/compatibility'))
    ..followRedirects = false
    ..headers.addAll({'accept': 'application/json', ...descriptor.headers});
  try {
    final response = await client
        .send(request)
        .timeout(configuration.headerTimeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      configuration.bodyTimeout,
    )) {
      if (bytes.length + chunk.length > 16 * 1024) {
        throw const InternetRelayException(
          'Compatibility response exceeded the size limit.',
        );
      }
      bytes.add(chunk);
    }
    if (response.statusCode == 404) {
      return RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.legacyCompatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: const {},
        checkedAt: now,
        validUntil: now.add(const Duration(minutes: 5)),
        message: 'Legacy protocol-1 relay; newer voyage features stay local.',
      );
    }
    final body = bytes.takeBytes();
    if (response.statusCode != 200) {
      String? message;
      String? code;
      Uri? updateUri;
      try {
        final value = jsonDecode(utf8.decode(body));
        if (value is Map) {
          message = value['message'] as String?;
          code = value['code'] as String?;
          updateUri = _safeUri(value['updateUrl']);
        }
      } on Object {
        // Fall through to the bounded status message.
      }
      throw InternetRelayException(
        message ?? 'Voyage service compatibility check failed.',
        retryable: response.statusCode == 429 || response.statusCode >= 500,
        statusCode: response.statusCode,
        code: code,
        actionUrl: updateUri,
      );
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) {
      throw const FormatException('Compatibility response is not an object.');
    }
    final serverProtocol = decoded['serverProtocol'];
    final minimumClientProtocol = decoded['minimumClientProtocol'];
    final maximumClientProtocol = decoded['maximumClientProtocol'];
    final rawCapabilities = decoded['capabilities'];
    final rawRequired = decoded['requiredCapabilities'];
    final rawUpdateUrls = decoded['updateUrls'];
    final cacheSeconds = decoded['cacheSeconds'];
    if (serverProtocol is! int ||
        minimumClientProtocol is! int ||
        maximumClientProtocol is! int ||
        rawCapabilities is! List ||
        rawRequired is! List ||
        rawUpdateUrls is! Map ||
        cacheSeconds is! int) {
      throw const FormatException('Compatibility fields are invalid.');
    }
    final capabilities = rawCapabilities.cast<String>().toSet();
    final required = rawRequired.cast<String>().toSet();
    final missingRequired = required.difference(descriptor.capabilities);
    final updateUri = _safeUri(
      rawUpdateUrls[descriptor.platform] ?? rawUpdateUrls['default'],
    );
    final disposition =
        descriptor.protocolVersion < minimumClientProtocol ||
            missingRequired.isNotEmpty
        ? RelayCompatibilityDisposition.updateRequired
        : descriptor.protocolVersion > maximumClientProtocol
        ? RelayCompatibilityDisposition.serverUpgradeRequired
        : RelayCompatibilityDisposition.compatible;
    final message = switch (disposition) {
      RelayCompatibilityDisposition.updateRequired =>
        'Update Tide and Seek before joining or synchronizing this voyage.',
      RelayCompatibilityDisposition.serverUpgradeRequired =>
        'This app is newer than the configured voyage service. Try again after the service is updated.',
      _ => null,
    };
    return RelayCompatibilityResult(
      disposition: disposition,
      serverProtocol: serverProtocol,
      minimumClientProtocol: minimumClientProtocol,
      capabilities: Set.unmodifiable(capabilities),
      checkedAt: now,
      validUntil: now.add(Duration(seconds: cacheSeconds.clamp(30, 3600))),
      message: message,
      updateUri: updateUri,
    );
  } on InternetRelayException {
    rethrow;
  } on TimeoutException {
    if (cached != null && now.isBefore(cached.validUntil)) return cached;
    throw const InternetRelayException(
      'Voyage service compatibility check timed out.',
      retryable: true,
      code: 'temporarily_unavailable',
    );
  } on FormatException {
    throw const InternetRelayException(
      'The voyage service compatibility response could not be read.',
    );
  } on Object {
    // A transport or TLS failure message can name the relay host and port, so
    // it is never surfaced. Treated as retryable because it is a connection
    // class of failure, not a protocol disagreement.
    if (cached != null && now.isBefore(cached.validUntil)) return cached;
    throw const InternetRelayException(
      'Voyage service is temporarily unavailable. Check your connection and try again.',
      retryable: true,
      code: 'temporarily_unavailable',
    );
  }
}

Uri? _safeUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

String _voyageBearerToken(VoyageSession session) {
  final digest = Hmac(
    sha256,
    utf8.encode(session.inviteSecret),
  ).convert(utf8.encode('ride-relay-internet-token-v1\n${session.voyageId}'));
  return 'rr1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
}
