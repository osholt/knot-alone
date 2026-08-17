import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/data/shared_preferences_session_store.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_secret_store.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stores invitation secrets outside SharedPreferences', () async {
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesSessionStore(secretStore: secrets);
    final session = _session();

    await store.save(session);

    final preferences = await SharedPreferences.getInstance();
    final metadata = preferences.getString('active_voyage_session_v1')!;
    expect(metadata, isNot(contains(session.inviteSecret)));
    expect(jsonDecode(metadata), isNot(contains('inviteSecret')));
    expect(await store.load(), _matches(session));

    await store.clear();
    expect(await secrets.read(session.voyageId), isNull);
    expect(await store.load(), isNull);
  });

  test('migrates a legacy plaintext session on first load', () async {
    final session = _session();
    SharedPreferences.setMockInitialValues({
      'active_voyage_session_v1': jsonEncode(session.toJson()),
    });
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesSessionStore(secretStore: secrets);

    expect(await store.load(), _matches(session));
    expect(await secrets.read(session.voyageId), session.inviteSecret);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('active_voyage_session_v1'),
      isNot(contains(session.inviteSecret)),
    );
  });

  test('preserves an intentional code-only local voyage', () async {
    final store = SharedPreferencesSessionStore(
      secretStore: _MemorySecretStore(),
    );
    final localOnly = VoyageSession(
      voyageId: 'pending-ABC234',
      voyageCode: 'ABC234',
      inviteSecret: '',
      joinToken: 'test-join-token-0123456789',
      localSailorId: 'sailor-1',
      displayName: 'Oliver',
      role: VoyageRole.sailor,
      joinedAt: DateTime.utc(2026, 7, 16, 12),
    );

    await store.save(localOnly);

    expect(await store.load(), _matches(localOnly));
  });

  test(
    'always sanitizes legacy plaintext even when secure copy exists',
    () async {
      final session = _session();
      SharedPreferences.setMockInitialValues({
        'active_voyage_session_v1': jsonEncode(session.toJson()),
      });
      final secrets = _MemorySecretStore();
      await secrets.write(session.voyageId, session.inviteSecret);
      final store = SharedPreferencesSessionStore(secretStore: secrets);

      expect(await store.load(), _matches(session));
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('active_voyage_session_v1'),
        isNot(contains(session.inviteSecret)),
      );
    },
  );
}

VoyageSession _session() => VoyageSession(
  voyageId: 'voyage-1',
  voyageCode: 'ABC234',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localSailorId: 'sailor-1',
  displayName: 'Oliver',
  role: VoyageRole.lead,
  joinedAt: DateTime.utc(2026, 7, 16, 12),
);

Matcher _matches(VoyageSession expected) => isA<VoyageSession>()
    .having((value) => value.voyageId, 'voyageId', expected.voyageId)
    .having(
      (value) => value.inviteSecret,
      'inviteSecret',
      expected.inviteSecret,
    );

class _MemorySecretStore implements VoyageSecretStore {
  final _values = <String, String>{};

  @override
  Future<void> delete(String voyageId) async => _values.remove(voyageId);

  @override
  Future<String?> read(String voyageId) async => _values[voyageId];

  @override
  Future<void> write(String voyageId, String secret) async {
    _values[voyageId] = secret;
  }
}
