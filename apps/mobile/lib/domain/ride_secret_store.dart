abstract interface class RideSecretStore {
  Future<void> delete(String rideId);

  Future<String?> read(String rideId);

  Future<void> write(String rideId, String secret);
}
