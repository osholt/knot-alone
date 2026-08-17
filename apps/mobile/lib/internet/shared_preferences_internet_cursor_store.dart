import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'internet_cursor_store.dart';

class SharedPreferencesInternetCursorStore implements InternetCursorStore {
  static const _prefix = 'internet_relay_cursor_v1_';

  String _key(String voyageId) =>
      '$_prefix${sha256.convert(utf8.encode(voyageId)).toString()}';

  @override
  Future<void> clear(String voyageId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(voyageId));
  }

  @override
  Future<String?> load(String voyageId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_key(voyageId));
  }

  @override
  Future<void> save(String voyageId, String cursor) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key(voyageId), cursor);
  }
}
