import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/ride_session.dart';
import 'internet_relay_client.dart';

enum PushProvider { apns, fcm }

class DevicePushToken {
  const DevicePushToken({
    required this.platform,
    required this.provider,
    required this.value,
  });

  final String platform;
  final PushProvider provider;
  final String value;
}

class PushPreferences {
  const PushPreferences({
    this.safety = true,
    this.status = true,
    this.administrative = true,
  });

  final bool safety;
  final bool status;
  final bool administrative;

  Map<String, bool> toJson() => {
    'safety': safety,
    'status': status,
    'administrative': administrative,
  };
}

abstract interface class PushRegistrationApi {
  Future<void> register({
    required RideSession session,
    required DevicePushToken token,
    required PushPreferences preferences,
  });

  Future<void> revoke(RideSession session);

  void close();
}

class HttpPushRegistrationClient implements PushRegistrationApi {
  HttpPushRegistrationClient({
    required this.configuration,
    required this.client,
    RelayClientDescriptor? clientDescriptor,
  }) : _clientDescriptor = clientDescriptor ?? RelayClientDescriptor.current();

  final InternetRelayConfiguration configuration;
  final http.Client client;
  final RelayClientDescriptor _clientDescriptor;

  @override
  Future<void> register({
    required RideSession session,
    required DevicePushToken token,
    required PushPreferences preferences,
  }) async {
    _validate(session);
    final body = jsonEncode({
      'platform': token.platform,
      'provider': token.provider.name,
      'token': token.value,
      'role': session.role.name,
      'preferences': preferences.toJson(),
    });
    final response = await _send(
      http.Request('PUT', _registrationUri(session))
        ..followRedirects = false
        ..headers.addAll(_headers(session))
        ..body = body,
    );
    await _expect(response, expectedStatus: 200);
  }

  @override
  Future<void> revoke(RideSession session) async {
    _validate(session);
    final response = await _send(
      http.Request('DELETE', _registrationUri(session))
        ..followRedirects = false
        ..headers.addAll(_headers(session)),
    );
    await _expect(response, expectedStatus: 204);
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await client.send(request).timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Notification registration timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Notification registration is temporarily unavailable.',
        retryable: true,
      );
    }
  }

  Future<void> _expect(
    http.StreamedResponse response, {
    required int expectedStatus,
  }) async {
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(
      configuration.bodyTimeout,
    )) {
      if (bytes.length + chunk.length > 8192) {
        throw const InternetRelayException(
          'Notification service returned an oversized response.',
        );
      }
      bytes.addAll(chunk);
    }
    if (response.statusCode == expectedStatus) return;
    String? message;
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Map) message = decoded['error'] as String?;
    } on Object {
      // A bounded invalid body falls back to a safe status message.
    }
    throw InternetRelayException(
      message ?? 'Notification service returned HTTP ${response.statusCode}.',
      retryable: response.statusCode == 429 || response.statusCode >= 500,
      unauthorized: response.statusCode == 401 || response.statusCode == 403,
      statusCode: response.statusCode,
    );
  }

  Map<String, String> _headers(RideSession session) => {
    'accept': 'application/json',
    'authorization': 'Bearer ${_rideBearerToken(session)}',
    'content-type': 'application/json',
    'x-ride-relay-device': session.localRiderId,
    ..._clientDescriptor.headers,
  };

  Uri _registrationUri(RideSession session) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/rides/${Uri.encodeComponent(session.rideId)}'
      '/push-registrations/${Uri.encodeComponent(session.localRiderId)}',
    );
  }

  void _validate(RideSession session) {
    final error = configuration.configurationError;
    if (error != null) throw InternetRelayException(error);
    if (session.inviteSecret.length < 16 ||
        session.rideId.isEmpty ||
        session.rideId.length > 128 ||
        session.localRiderId.isEmpty ||
        session.localRiderId.length > 128) {
      throw const InternetRelayException(
        'Notification registration requires an authenticated ride.',
      );
    }
  }

  @override
  void close() => client.close();
}

String _rideBearerToken(RideSession session) {
  final digest = Hmac(
    sha256,
    utf8.encode(session.inviteSecret),
  ).convert(utf8.encode('ride-relay-internet-token-v1\n${session.rideId}'));
  return 'rr1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
}
