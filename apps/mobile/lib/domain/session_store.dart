import 'voyage_session.dart';

abstract interface class SessionStore {
  Future<VoyageSession?> load();

  Future<void> save(VoyageSession session);

  Future<void> clear();
}
