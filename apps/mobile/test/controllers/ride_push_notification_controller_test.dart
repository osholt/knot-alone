import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_push_notification_controller.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/push_registration_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('registers, rotates, opens, updates preferences and revokes', () async {
    final source = _FakePushTokenSource();
    final api = _FakePushRegistrationApi();
    final controller = RidePushNotificationController(
      tokenSource: source,
      registrationApi: api,
      preferencesStore: await SharedPreferences.getInstance(),
    );
    final opened = <PushOpenRequest>[];
    final subscription = controller.openedNotifications.listen(opened.add);

    await controller.start(_session);
    source.rotate('rotated-token-123456789');
    source.open(
      const PushOpenRequest(
        rideId: 'ride-1',
        eventId: 'event-1',
        category: 'safety',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await controller.updatePreferences(
      safety: false,
      status: false,
      administrative: true,
    );
    await controller.stop();

    expect(controller.permission, PushPermissionState.granted);
    expect(api.registrations, hasLength(3));
    expect(api.registrations[1].token.value, 'rotated-token-123456789');
    expect(api.registrations.last.preferences.safety, isFalse);
    expect(opened.single.eventId, 'event-1');
    expect(api.revokedSessions.single.rideId, 'ride-1');
    await subscription.cancel();
    await controller.close();
  });

  test('unconfigured source does not request permission or register', () async {
    final source = _FakePushTokenSource(configured: false);
    final api = _FakePushRegistrationApi();
    final controller = RidePushNotificationController(
      tokenSource: source,
      registrationApi: api,
      preferencesStore: await SharedPreferences.getInstance(),
    );

    await controller.start(_session);

    expect(controller.permission, PushPermissionState.unavailable);
    expect(source.permissionRequests, 0);
    expect(api.registrations, isEmpty);
    expect(api.revokedSessions.single.rideId, 'ride-1');
    await controller.close();
  });

  test(
    'revoked OS permission removes the server registration on refresh',
    () async {
      final source = _FakePushTokenSource();
      final api = _FakePushRegistrationApi();
      final controller = RidePushNotificationController(
        tokenSource: source,
        registrationApi: api,
        preferencesStore: await SharedPreferences.getInstance(),
      );
      await controller.start(_session);
      source.currentPermission = PushPermissionState.denied;

      await controller.refreshRegistration();

      expect(controller.permission, PushPermissionState.denied);
      expect(api.revokedSessions.single.rideId, 'ride-1');
      await controller.close();
    },
  );
}

class _FakePushTokenSource implements PushTokenSource {
  _FakePushTokenSource({this.configured = true});

  final bool configured;
  final _rotations = StreamController<DevicePushToken>.broadcast();
  final _opened = StreamController<PushOpenRequest>.broadcast();
  var permissionRequests = 0;
  var currentPermission = PushPermissionState.granted;

  @override
  bool get isConfigured => configured;

  @override
  Stream<PushOpenRequest> get openedNotifications => _opened.stream;

  @override
  Stream<DevicePushToken> get tokenRotations => _rotations.stream;

  @override
  Future<PushTokenResult> requestPermissionAndToken() async {
    permissionRequests += 1;
    return const PushTokenResult(
      permission: PushPermissionState.granted,
      token: DevicePushToken(
        platform: 'android',
        provider: PushProvider.fcm,
        value: 'initial-token-123456789',
      ),
    );
  }

  @override
  Future<PushTokenResult> currentPermissionAndToken() async => PushTokenResult(
    permission: currentPermission,
    token: currentPermission == PushPermissionState.granted
        ? const DevicePushToken(
            platform: 'android',
            provider: PushProvider.fcm,
            value: 'current-token-123456789',
          )
        : null,
  );

  void rotate(String value) => _rotations.add(
    DevicePushToken(
      platform: 'android',
      provider: PushProvider.fcm,
      value: value,
    ),
  );

  void open(PushOpenRequest request) => _opened.add(request);

  @override
  Future<void> close() async {
    await _rotations.close();
    await _opened.close();
  }
}

class _RegistrationCall {
  const _RegistrationCall({
    required this.session,
    required this.token,
    required this.preferences,
  });

  final RideSession session;
  final DevicePushToken token;
  final PushPreferences preferences;
}

class _FakePushRegistrationApi implements PushRegistrationApi {
  final registrations = <_RegistrationCall>[];
  final revokedSessions = <RideSession>[];

  @override
  Future<void> register({
    required RideSession session,
    required DevicePushToken token,
    required PushPreferences preferences,
  }) async {
    registrations.add(
      _RegistrationCall(
        session: session,
        token: token,
        preferences: preferences,
      ),
    );
  }

  @override
  Future<void> revoke(RideSession session) async {
    revokedSessions.add(session);
  }

  @override
  void close() {}
}

final _session = RideSession(
  rideId: 'ride-1',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'aTokenWithPlentyOfEntropy',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 23),
);
