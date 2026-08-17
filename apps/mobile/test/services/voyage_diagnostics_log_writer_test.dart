import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/data/voyage_diagnostics_log_store.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_log_writer.dart';
import 'package:tide_and_seek/services/voyage_diagnostics_recorder.dart';

void main() {
  group('the stored log keeps up with the recorder (#456)', () {
    test('an entry reaches the store without being asked to flush', () async {
      final store = InMemoryVoyageDiagnosticsLogStore();
      final recorder = VoyageDiagnosticsRecorder();
      final writer = _writer(store, recorder);

      recorder.recordNote('recording started');
      writer.markDirty();
      await writer.flush();

      expect(await store.read('voyage-1'), contains('recording started'));
    });

    test('a force-quit after the last write loses nothing', () async {
      // The sailor who kills the app because something went wrong is exactly the
      // sailor whose log matters. Nothing here calls flush.
      final store = InMemoryVoyageDiagnosticsLogStore();
      final recorder = VoyageDiagnosticsRecorder();
      late final VoyageDiagnosticsLogWriter writer;
      final wired = VoyageDiagnosticsRecorder(
        onEntry: () => writer.markDirty(),
      );
      writer = _writer(store, wired);

      wired.recordNote('the thing that went wrong');
      // One microtask turn, which is all a coalesced write needs to start.
      await Future<void>.delayed(Duration.zero);

      expect(
        await store.read('voyage-1'),
        contains('the thing that went wrong'),
      );
      expect(recorder.isEmpty, isTrue, reason: 'the unwired one is untouched');
    });
  });

  group('a burst of entries is one extra write, not one each', () {
    test(
      'entries recorded during a write are covered by a single follow-up',
      () async {
        final store = _BlockingStore();
        final recorder = VoyageDiagnosticsRecorder();
        final writer = _writer(store, recorder);

        // First write starts and blocks.
        recorder.recordNote('first');
        writer.markDirty();
        await Future<void>.delayed(Duration.zero);
        expect(store.started, 1, reason: 'one write in flight');

        // Twenty entries arrive while it is in flight.
        for (var index = 0; index < 20; index += 1) {
          recorder.recordNote('entry $index');
          writer.markDirty();
        }
        store.release();
        await writer.flush();

        // Two: the one that was in flight, and one covering everything after it.
        expect(store.started, 2);
        expect(writer.writeCount, 2);
        expect(await store.read('voyage-1'), contains('entry 19'));
      },
    );

    test('flush waits for a write already in flight', () async {
      final store = _BlockingStore();
      final recorder = VoyageDiagnosticsRecorder()..recordNote('first');
      final writer = _writer(store, recorder);

      writer.markDirty();
      await Future<void>.delayed(Duration.zero);
      var flushed = false;
      final pending = writer.flush().then((_) => flushed = true);

      expect(flushed, isFalse, reason: 'a write is still running');
      store.release();
      await pending;
      expect(flushed, isTrue);
    });
  });

  group('a storage failure does not end the voyage', () {
    test('the error is kept rather than thrown', () async {
      final recorder = VoyageDiagnosticsRecorder()..recordNote('first');
      final writer = VoyageDiagnosticsLogWriter(
        store: _FailingStore(),
        voyageId: 'voyage-1',
        render: () => recorder.render(),
      );

      // No throw: a full disk must not take navigation with it.
      await writer.flush();

      expect(writer.lastError, isNotNull);
      expect(writer.writeCount, 0);
    });

    test('a later write clears the error', () async {
      final store = _FailingStore();
      final recorder = VoyageDiagnosticsRecorder()..recordNote('first');
      final writer = VoyageDiagnosticsLogWriter(
        store: store,
        voyageId: 'voyage-1',
        render: () => recorder.render(),
      );

      await writer.flush();
      expect(writer.lastError, isNotNull);

      store.failing = false;
      await writer.flush();

      expect(writer.lastError, isNull);
      expect(writer.writeCount, 1);
    });
  });
}

VoyageDiagnosticsLogWriter _writer(
  VoyageDiagnosticsLogStore store,
  VoyageDiagnosticsRecorder recorder,
) => VoyageDiagnosticsLogWriter(
  store: store,
  voyageId: 'voyage-1',
  render: () => recorder.render(voyageCode: 'ABCD', appBuild: '1.0.1+51'),
);

/// A store whose writes do not complete until released, so coalescing can be
/// observed rather than inferred from timing.
class _BlockingStore implements VoyageDiagnosticsLogStore {
  final _gates = <Completer<void>>[];
  final Map<String, String> _written = {};
  int started = 0;
  bool _open = false;

  /// Lets the blocked write through, and any that follow it. Both are needed: the
  /// point of coalescing is that a *second* write runs after the first, so a gate
  /// that only released the first would deadlock the very behaviour under test.
  void release() {
    _open = true;
    for (final gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
    _gates.clear();
  }

  @override
  Future<void> write({required String voyageId, required String text}) async {
    started += 1;
    if (!_open) {
      final gate = Completer<void>();
      _gates.add(gate);
      await gate.future;
    }
    _written[voyageId] = text;
  }

  @override
  Future<String?> read(String voyageId) async => _written[voyageId];

  @override
  Future<List<VoyageDiagnosticsLog>> list() async => const [];

  @override
  Future<VoyageDiagnosticsLog?> latest() async => null;
}

class _FailingStore implements VoyageDiagnosticsLogStore {
  bool failing = true;

  @override
  Future<void> write({required String voyageId, required String text}) async {
    if (failing) throw const FileSystemException('no space left on device');
  }

  @override
  Future<String?> read(String voyageId) async => null;

  @override
  Future<List<VoyageDiagnosticsLog>> list() async => const [];

  @override
  Future<VoyageDiagnosticsLog?> latest() async => null;
}
