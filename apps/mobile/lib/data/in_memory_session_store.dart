import '../domain/voyage_session.dart';
import '../domain/session_store.dart';

class InMemorySessionStore implements SessionStore {
  VoyageSession? _session;

  @override
  Future<void> clear() async {
    _session = null;
  }

  @override
  Future<VoyageSession?> load() async => _session;

  @override
  Future<void> save(VoyageSession session) async {
    _session = session;
  }
}
