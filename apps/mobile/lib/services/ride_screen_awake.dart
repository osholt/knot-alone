import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

abstract interface class ScreenWakeLock {
  Future<void> setEnabled(bool enabled);
}

class WakelockPlusScreenWakeLock implements ScreenWakeLock {
  const WakelockPlusScreenWakeLock();

  @override
  Future<void> setEnabled(bool enabled) => WakelockPlus.toggle(enable: enabled);
}

/// Keeps the display awake while the active-ride shell exists.
///
/// Mobile operating systems may release a previously acquired screen wake
/// lock after lifecycle or window changes. Reasserting it on resume and at a
/// restrained interval keeps the mounted navigation view usable without
/// requesting a background CPU wake lock.
class RideScreenAwakeCoordinator with WidgetsBindingObserver {
  RideScreenAwakeCoordinator({
    this.wakeLock = const WakelockPlusScreenWakeLock(),
    this.reassertInterval = const Duration(seconds: 15),
    this.onError,
  }) : assert(reassertInterval > Duration.zero);

  final ScreenWakeLock wakeLock;
  final Duration reassertInterval;
  final void Function(Object error, StackTrace stackTrace)? onError;

  Timer? _timer;
  Future<void> _operation = Future<void>.value();
  bool _started = false;
  bool _foreground = true;

  @visibleForTesting
  Future<void> get settled => _operation;

  void start() {
    if (_started) return;
    _started = true;
    _foreground = true;
    WidgetsBinding.instance.addObserver(this);
    _setEnabled(true);
    _timer = Timer.periodic(reassertInterval, (_) {
      if (_started && _foreground) _setEnabled(true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_started && _foreground) _setEnabled(true);
  }

  Future<void> stop() {
    if (!_started) return _operation;
    _started = false;
    _foreground = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _setEnabled(false);
    return _operation;
  }

  void _setEnabled(bool enabled) {
    _operation = _operation.then((_) async {
      try {
        await wakeLock.setEnabled(enabled);
      } on Object catch (error, stackTrace) {
        onError?.call(error, stackTrace);
      }
    });
  }
}
