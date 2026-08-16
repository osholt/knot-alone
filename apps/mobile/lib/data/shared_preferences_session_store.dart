import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/ride_session.dart';
import '../domain/ride_secret_store.dart';
import '../domain/session_store.dart';
import 'secure_ride_secret_store.dart';

class SharedPreferencesSessionStore implements SessionStore {
  SharedPreferencesSessionStore({RideSecretStore? secretStore})
    : _secretStore = secretStore ?? const SecureRideSecretStore();

  static const _sessionKey = 'active_ride_session_v1';
  final RideSecretStore _secretStore;

  @override
  Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    final metadata = _decodeMetadata(preferences.getString(_sessionKey));
    await preferences.remove(_sessionKey);
    final rideId = metadata?['rideId'];
    if (rideId is String) await _secretStore.delete(rideId);
  }

  @override
  Future<RideSession?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = preferences.getString(_sessionKey);
    if (encoded == null) {
      return null;
    }

    final metadata = _decodeMetadata(encoded);
    if (metadata == null) {
      await preferences.remove(_sessionKey);
      return null;
    }

    try {
      final rideId = metadata['rideId']! as String;
      var secret = await _secretStore.read(rideId);
      final secretFlag = metadata.remove('hasInviteSecret');
      final legacySecret = metadata.remove('inviteSecret');
      final expectsSecret = secretFlag is bool
          ? secretFlag
          : legacySecret is String
          ? legacySecret.isNotEmpty
          : true;
      if (legacySecret is String) {
        if (legacySecret.isNotEmpty) {
          secret = legacySecret;
          await _secretStore.write(rideId, legacySecret);
        } else {
          secret = '';
          await _secretStore.delete(rideId);
        }
        metadata['hasInviteSecret'] = legacySecret.isNotEmpty;
        await preferences.setString(_sessionKey, jsonEncode(metadata));
      }
      if (expectsSecret && (secret == null || secret.isEmpty)) {
        await preferences.remove(_sessionKey);
        return null;
      }
      return RideSession.fromJson({
        ...metadata,
        'inviteSecret': expectsSecret ? secret : '',
      });
    } on FormatException {
      await preferences.remove(_sessionKey);
      return null;
    } on TypeError {
      await preferences.remove(_sessionKey);
      return null;
    }
  }

  @override
  Future<void> save(RideSession session) async {
    final preferences = await SharedPreferences.getInstance();
    if (session.inviteSecret.isEmpty) {
      await _secretStore.delete(session.rideId);
    } else {
      await _secretStore.write(session.rideId, session.inviteSecret);
    }
    final metadata = session.toJson()..remove('inviteSecret');
    metadata['hasInviteSecret'] = session.inviteSecret.isNotEmpty;
    await preferences.setString(_sessionKey, jsonEncode(metadata));
  }

  static Map<String, Object?>? _decodeMetadata(String? encoded) {
    if (encoded == null) return null;
    try {
      return Map<String, Object?>.from(jsonDecode(encoded) as Map);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
