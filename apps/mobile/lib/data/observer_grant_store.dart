import '../internet/observer_access_client.dart';

abstract interface class ObserverGrantStore {
  Future<List<ObserverGrantCredentials>> load(String voyageId);

  Future<void> save(
    String voyageId,
    List<ObserverGrantCredentials> credentials,
  );

  Future<void> delete(String voyageId);

  Future<ObserverLocalAssistanceState?> loadLocalAssistance(String voyageId);

  Future<void> saveLocalAssistance(
    String voyageId,
    ObserverLocalAssistanceState state,
  );

  Future<void> deleteLocalAssistance(String voyageId);
}
