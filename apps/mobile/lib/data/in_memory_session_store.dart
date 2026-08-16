import '../domain/ride_session.dart';
import '../domain/session_store.dart';

class InMemorySessionStore implements SessionStore {
  RideSession? _session;

  @override
  Future<void> clear() async {
    _session = null;
  }

  @override
  Future<RideSession?> load() async => _session;

  @override
  Future<void> save(RideSession session) async {
    _session = session;
  }
}
