import 'package:flutter/services.dart';

class NearbyCapabilities {
  const NearbyCapabilities({
    required this.platform,
    required this.nativeBridgeReady,
    required this.nearbyApiLinked,
    required this.status,
  });

  const NearbyCapabilities.unavailable()
    : platform = 'unknown',
      nativeBridgeReady = false,
      nearbyApiLinked = false,
      status = 'unavailable';

  final String platform;
  final bool nativeBridgeReady;
  final bool nearbyApiLinked;
  final String status;

  factory NearbyCapabilities.fromMap(Map<Object?, Object?> map) =>
      NearbyCapabilities(
        platform: map['platform'] as String? ?? 'unknown',
        nativeBridgeReady: map['nativeBridgeReady'] as bool? ?? false,
        nearbyApiLinked: map['nearbyApiLinked'] as bool? ?? false,
        status: map['status'] as String? ?? 'unknown',
      );
}

class NearbyBridge {
  const NearbyBridge();

  static const _channel = MethodChannel('me.osholt.ride_relay/nearby');

  Future<NearbyCapabilities> capabilities() async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getCapabilities',
      );
      if (result == null) {
        return const NearbyCapabilities.unavailable();
      }
      return NearbyCapabilities.fromMap(result);
    } on PlatformException {
      return const NearbyCapabilities.unavailable();
    } on MissingPluginException {
      return const NearbyCapabilities.unavailable();
    }
  }
}
