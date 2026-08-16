import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../controllers/ride_push_notification_controller.dart';
import '../internet/push_registration_client.dart';

class NativePushConfiguration {
  const NativePushConfiguration({
    required this.enabled,
    required this.apiKey,
    required this.projectId,
    required this.messagingSenderId,
    required this.iosAppId,
    required this.androidAppId,
  });

  factory NativePushConfiguration.fromEnvironment() =>
      const NativePushConfiguration(
        enabled: bool.fromEnvironment('RIDE_RELAY_PUSH_ENABLED'),
        apiKey: String.fromEnvironment('RIDE_RELAY_FIREBASE_API_KEY'),
        projectId: String.fromEnvironment('RIDE_RELAY_FIREBASE_PROJECT_ID'),
        messagingSenderId: String.fromEnvironment(
          'RIDE_RELAY_FIREBASE_MESSAGING_SENDER_ID',
        ),
        iosAppId: String.fromEnvironment('RIDE_RELAY_FIREBASE_IOS_APP_ID'),
        androidAppId: String.fromEnvironment(
          'RIDE_RELAY_FIREBASE_ANDROID_APP_ID',
        ),
      );

  final bool enabled;
  final String apiKey;
  final String projectId;
  final String messagingSenderId;
  final String iosAppId;
  final String androidAppId;

  bool get isConfigured {
    if (!enabled ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      return false;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return iosAppId.isNotEmpty;
    }
    return apiKey.isNotEmpty &&
        projectId.isNotEmpty &&
        messagingSenderId.isNotEmpty &&
        androidAppId.isNotEmpty;
  }

  Map<String, String> get nativeArguments => {
    'apiKey': apiKey,
    'projectId': projectId,
    'messagingSenderId': messagingSenderId,
    'appId': defaultTargetPlatform == TargetPlatform.iOS
        ? iosAppId
        : androidAppId,
  };
}

class NativePushTokenSource implements PushTokenSource {
  NativePushTokenSource(
    this.configuration, {
    this.channel = const MethodChannel(_channelName),
  });

  static const _channelName = 'me.osholt.ride_relay/push';

  final NativePushConfiguration configuration;
  final MethodChannel channel;
  final StreamController<DevicePushToken> _rotations =
      StreamController.broadcast();
  final StreamController<PushOpenRequest> _opened =
      StreamController.broadcast();
  bool _initialised = false;

  @override
  bool get isConfigured => configuration.isConfigured;

  @override
  Stream<DevicePushToken> get tokenRotations => _rotations.stream;

  @override
  Stream<PushOpenRequest> get openedNotifications => _opened.stream;

  @override
  Future<PushTokenResult> requestPermissionAndToken() =>
      _status('configureAndRequest');

  @override
  Future<PushTokenResult> currentPermissionAndToken() =>
      _status('currentStatus');

  Future<PushTokenResult> _status(String method) async {
    if (!isConfigured) {
      return const PushTokenResult(permission: PushPermissionState.unavailable);
    }
    await _initialise();
    final value = await channel.invokeMapMethod<String, Object?>(
      method,
      configuration.nativeArguments,
    );
    return _tokenResult(value);
  }

  Future<void> _initialise() async {
    if (_initialised) return;
    channel.setMethodCallHandler(_handleNativeCall);
    _initialised = true;
    final initial = await channel.invokeMapMethod<String, Object?>(
      'consumeInitialNotification',
    );
    if (initial != null) _addOpened(initial);
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final value = Map<String, Object?>.from(arguments);
    switch (call.method) {
      case 'tokenRotated':
        final token = _deviceToken(value);
        if (token != null) _rotations.add(token);
        return null;
      case 'notificationOpened':
        _addOpened(value);
        return null;
      default:
        return null;
    }
  }

  PushTokenResult _tokenResult(Map<String, Object?>? value) {
    if (value == null) {
      return const PushTokenResult(permission: PushPermissionState.unavailable);
    }
    final permission = switch (value['permission']) {
      'granted' => PushPermissionState.granted,
      'denied' => PushPermissionState.denied,
      'unknown' => PushPermissionState.unknown,
      _ => PushPermissionState.unavailable,
    };
    return PushTokenResult(
      permission: permission,
      token: permission == PushPermissionState.granted
          ? _deviceToken(value)
          : null,
    );
  }

  DevicePushToken? _deviceToken(Map<String, Object?> value) {
    final token = value['token'];
    final platform = value['platform'];
    final provider = value['provider'];
    if (token is! String ||
        token.isEmpty ||
        platform is! String ||
        provider is! String) {
      return null;
    }
    final parsedProvider = switch (provider) {
      'apns' => PushProvider.apns,
      'fcm' => PushProvider.fcm,
      _ => null,
    };
    return parsedProvider == null
        ? null
        : DevicePushToken(
            platform: platform,
            provider: parsedProvider,
            value: token,
          );
  }

  void _addOpened(Map<String, Object?> value) {
    final rideId = value['rideId'];
    final eventId = value['eventId'];
    final category = value['category'];
    if (rideId is String &&
        eventId is String &&
        category is String &&
        rideId.isNotEmpty &&
        eventId.isNotEmpty) {
      _opened.add(
        PushOpenRequest(rideId: rideId, eventId: eventId, category: category),
      );
    }
  }

  @override
  Future<void> close() async {
    channel.setMethodCallHandler(null);
    await _rotations.close();
    await _opened.close();
  }
}
