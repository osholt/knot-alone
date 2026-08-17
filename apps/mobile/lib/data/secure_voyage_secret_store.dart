import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/voyage_secret_store.dart';

class SecureVoyageSecretStore implements VoyageSecretStore {
  const SecureVoyageSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'ride_relay_invite_secret_v1_';
  final FlutterSecureStorage _storage;

  String _key(String voyageId) =>
      '$_prefix${sha256.convert(utf8.encode(voyageId)).toString()}';

  @override
  Future<void> delete(String voyageId) => _storage.delete(key: _key(voyageId));

  @override
  Future<String?> read(String voyageId) => _storage.read(key: _key(voyageId));

  @override
  Future<void> write(String voyageId, String secret) =>
      _storage.write(key: _key(voyageId), value: secret);
}
