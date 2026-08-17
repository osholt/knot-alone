abstract interface class VoyageSecretStore {
  Future<void> delete(String voyageId);

  Future<String?> read(String voyageId);

  Future<void> write(String voyageId, String secret);
}
