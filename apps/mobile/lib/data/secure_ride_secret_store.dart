import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/ride_secret_store.dart';

class SecureRideSecretStore implements RideSecretStore {
  const SecureRideSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'ride_relay_invite_secret_v1_';
  final FlutterSecureStorage _storage;

  String _key(String rideId) =>
      '$_prefix${sha256.convert(utf8.encode(rideId)).toString()}';

  @override
  Future<void> delete(String rideId) => _storage.delete(key: _key(rideId));

  @override
  Future<String?> read(String rideId) => _storage.read(key: _key(rideId));

  @override
  Future<void> write(String rideId, String secret) =>
      _storage.write(key: _key(rideId), value: secret);
}
