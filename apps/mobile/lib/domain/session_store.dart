import 'ride_session.dart';

abstract interface class SessionStore {
  Future<RideSession?> load();

  Future<void> save(RideSession session);

  Future<void> clear();
}
