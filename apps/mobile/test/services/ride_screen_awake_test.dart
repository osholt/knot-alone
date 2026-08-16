import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/ride_screen_awake.dart';

void main() {
  testWidgets(
    'keeps the wake lock enforced while foregrounded and disables on exit',
    (tester) async {
      await tester.pumpWidget(const SizedBox());
      final wakeLock = _FakeScreenWakeLock();
      final coordinator = RideScreenAwakeCoordinator(
        wakeLock: wakeLock,
        reassertInterval: const Duration(seconds: 5),
      );

      coordinator.start();
      await coordinator.settled;
      expect(wakeLock.requests, [true]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 6));
      await coordinator.settled;
      expect(wakeLock.requests, [true]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await coordinator.settled;
      expect(wakeLock.requests, [true, true]);

      await tester.pump(const Duration(seconds: 5));
      await coordinator.settled;
      expect(wakeLock.requests, [true, true, true]);

      await coordinator.stop();
      expect(wakeLock.requests, [true, true, true, false]);
    },
  );

  testWidgets('a failed first enable is retried when the app resumes', (
    tester,
  ) async {
    await tester.pumpWidget(const SizedBox());
    final errors = <Object>[];
    final wakeLock = _FakeScreenWakeLock(enableFailures: 1);
    final coordinator = RideScreenAwakeCoordinator(
      wakeLock: wakeLock,
      onError: (error, _) => errors.add(error),
    );

    coordinator.start();
    await coordinator.settled;
    expect(wakeLock.requests, [true]);
    expect(errors, hasLength(1));

    coordinator.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await coordinator.settled;
    expect(wakeLock.requests, [true, true]);

    await coordinator.stop();
    expect(wakeLock.requests.last, isFalse);
  });
}

class _FakeScreenWakeLock implements ScreenWakeLock {
  _FakeScreenWakeLock({this.enableFailures = 0});

  int enableFailures;
  final List<bool> requests = [];

  @override
  Future<void> setEnabled(bool enabled) async {
    requests.add(enabled);
    if (enabled && enableFailures > 0) {
      enableFailures -= 1;
      throw StateError('Wake lock temporarily unavailable');
    }
  }
}
