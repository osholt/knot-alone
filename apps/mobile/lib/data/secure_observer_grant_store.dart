import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../internet/observer_access_client.dart';
import 'observer_grant_store.dart';

class SecureObserverGrantStore implements ObserverGrantStore {
  const SecureObserverGrantStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _prefix = 'ride_relay_observer_grants_v1_';
  static const _assistancePrefix = 'ride_relay_observer_assistance_v1_';
  final FlutterSecureStorage _storage;

  String _key(String voyageId) =>
      '$_prefix${sha256.convert(utf8.encode(voyageId)).toString()}';
  String _assistanceKey(String voyageId) =>
      '$_assistancePrefix${sha256.convert(utf8.encode(voyageId)).toString()}';

  @override
  Future<List<ObserverGrantCredentials>> load(String voyageId) async {
    final encoded = await _storage.read(key: _key(voyageId));
    if (encoded == null) return const [];
    try {
      final value = jsonDecode(encoded);
      if (value is! Map ||
          value['schemaVersion'] != 1 ||
          value['credentials'] is! List) {
        throw const FormatException('Observer store is invalid.');
      }
      final credentials = (value['credentials'] as List)
          .map(
            (item) => ObserverGrantCredentials.fromJson(
              Map<String, Object?>.from(item as Map),
            ),
          )
          .toList(growable: false);
      if (credentials.length > 50) {
        throw const FormatException('Observer store is too large.');
      }
      return List.unmodifiable(credentials);
    } on Object {
      await delete(voyageId);
      return const [];
    }
  }

  @override
  Future<void> save(
    String voyageId,
    List<ObserverGrantCredentials> credentials,
  ) {
    if (credentials.length > 50) {
      throw const FormatException('Observer store is too large.');
    }
    return _storage.write(
      key: _key(voyageId),
      value: jsonEncode({
        'schemaVersion': 1,
        'credentials': credentials
            .map((credential) => credential.toJson())
            .toList(growable: false),
      }),
    );
  }

  @override
  Future<void> delete(String voyageId) => _storage.delete(key: _key(voyageId));

  @override
  Future<ObserverLocalAssistanceState?> loadLocalAssistance(
    String voyageId,
  ) async {
    final encoded = await _storage.read(key: _assistanceKey(voyageId));
    if (encoded == null) return null;
    try {
      final value = Map<String, Object?>.from(jsonDecode(encoded) as Map);
      if (value['schemaVersion'] != 1 || value['state'] is! Map) {
        throw const FormatException('Observer assistance store is invalid.');
      }
      return ObserverLocalAssistanceState.fromJson(
        Map<String, Object?>.from(value['state']! as Map),
      );
    } on Object {
      await deleteLocalAssistance(voyageId);
      return null;
    }
  }

  @override
  Future<void> saveLocalAssistance(
    String voyageId,
    ObserverLocalAssistanceState state,
  ) => _storage.write(
    key: _assistanceKey(voyageId),
    value: jsonEncode({'schemaVersion': 1, 'state': state.toJson()}),
  );

  @override
  Future<void> deleteLocalAssistance(String voyageId) =>
      _storage.delete(key: _assistanceKey(voyageId));
}
