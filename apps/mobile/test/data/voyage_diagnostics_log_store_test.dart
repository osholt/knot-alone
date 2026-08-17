import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/data/voyage_diagnostics_log_store.dart';

void main() {
  late Directory directory;
  late FileVoyageDiagnosticsLogStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('diagnostics-log-store');
    store = FileVoyageDiagnosticsLogStore(
      Directory('${directory.path}/voyage_diagnostics'),
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('a recorded voyage can be read back after it has finished (#456)', () {
    test('nothing is stored before a voyage is recorded', () async {
      expect(await store.list(), isEmpty);
      expect(await store.latest(), isNull);
      expect(await store.read('voyage-1'), isNull);
    });

    test('a written log survives and reads back whole', () async {
      await store.write(voyageId: 'voyage-1', text: _log('ABCD'));

      expect(await store.read('voyage-1'), _log('ABCD'));
    });

    test('writing again replaces rather than accumulates', () async {
      await store.write(voyageId: 'voyage-1', text: _log('ABCD'));
      await store.write(
        voyageId: 'voyage-1',
        text: '${_log('ABCD')}\nlater entry',
      );

      expect(await store.read('voyage-1'), contains('later entry'));
      expect(await store.list(), hasLength(1));
    });

    test('the voyage code is read back out of the log itself', () async {
      await store.write(voyageId: 'voyage-1', text: _log('ABCD'));

      final log = await store.latest();

      // Read rather than stored alongside, so there is no second copy to fall out
      // of step with the file a sailor actually holds.
      expect(log?.voyageCode, 'ABCD');
      expect(log?.fileName, 'tail-end-charlie-diagnostics-ABCD.txt');
    });

    test('a log with no voyage code is still offered', () async {
      await store.write(
        voyageId: 'voyage-1',
        text: 'Tide and Seek · voyage diagnostics',
      );

      final log = await store.latest();

      expect(log, isNotNull);
      expect(log!.voyageCode, isNull);
      expect(log.fileName, contains('voyage-1'));
    });
  });

  group('the store does not grow without bound', () {
    test('only the newest few voyages are kept, and the oldest go', () async {
      final kept = FileVoyageDiagnosticsLogStore.maximumRetainedLogs;

      for (var index = 0; index < kept + 3; index += 1) {
        await store.write(
          voyageId: 'voyage-$index',
          // Minutes apart, as real voyages are. Written a second apart, the file
          // timestamps would tie and pruning kept the right *number* while
          // dropping the wrong ones.
          text: _log('CODE$index', at: DateTime.utc(2026, 8, 12, 9, index)),
        );
      }

      final logs = await store.list();

      expect(logs, hasLength(kept));
      expect(logs.first.voyageCode, 'CODE${kept + 2}', reason: 'newest first');
      expect(
        logs.map((log) => log.voyageId),
        isNot(contains('voyage-0')),
        reason: 'the oldest is the one to drop',
      );
      expect(
        logs.map((log) => log.voyageId),
        contains('voyage-${kept + 2}'),
        reason: 'the newest must never be the one pruned',
      );
    });

    test('logs written inside the same second still order correctly', () async {
      // The case that exposed the file-timestamp ordering: `lastModified` has
      // one-second resolution, so these two are indistinguishable by it.
      await store.write(
        voyageId: 'earlier',
        text: _log('AAAA', at: DateTime.utc(2026, 8, 12, 9, 0, 1)),
      );
      await store.write(
        voyageId: 'later',
        text: _log('BBBB', at: DateTime.utc(2026, 8, 12, 9, 0, 2)),
      );

      expect((await store.list()).map((log) => log.voyageId), [
        'later',
        'earlier',
      ]);
    });

    test('the written-at is read from the header, not the file', () {
      // Asserted directly as well as through ordering: two logs written in the
      // same real second can order correctly by luck, so the ordering test alone
      // does not reliably catch a regression to the filesystem clock.
      expect(
        VoyageDiagnosticsLog.writtenAtIn(
          _log('ABCD', at: DateTime.utc(2026, 8, 12, 9, 41, 30)),
        ),
        DateTime.utc(2026, 8, 12, 9, 41, 30),
      );
      expect(VoyageDiagnosticsLog.writtenAtIn('no header here'), isNull);
    });

    test('a header value further down the log is not read as the header', () {
      // A recorded entry can contain the word, and a log is thousands of lines.
      final log = '${_log('ABCD')}\n${'filler\n' * 20}Voyage:  WRONG';

      expect(VoyageDiagnosticsLog.voyageCodeIn(log), 'ABCD');
    });

    test('a log with no written-at falls back to the file time', () async {
      await store.write(voyageId: 'voyage-1', text: 'Voyage:  ABCD');

      final log = await store.latest();

      expect(log, isNotNull);
      expect(log!.writtenAt.year, greaterThan(2000));
    });
  });

  group('a voyage id is not trusted as a file name', () {
    test('a traversal attempt cannot escape the directory', () async {
      // Voyage ids arrive in relay payloads, so this is untrusted input reaching a
      // path.
      await store.write(voyageId: '../escaped', text: _log('ABCD'));

      expect(await store.read('../escaped'), _log('ABCD'));
      final escaped = File('${directory.path}/escaped.txt');
      expect(await escaped.exists(), isFalse);
      expect(await store.list(), hasLength(1));
    });
  });

  group('a damaged store does not take the rest with it', () {
    test('a non-log file in the directory is ignored', () async {
      await store.write(voyageId: 'voyage-1', text: _log('ABCD'));
      await File('${store.directory.path}/notes.json').writeAsString('{}');

      expect(await store.list(), hasLength(1));
    });
  });

  group('the in-memory store behaves the same way', () {
    test('write, read, latest', () async {
      final memory = InMemoryVoyageDiagnosticsLogStore();

      await memory.write(voyageId: 'voyage-1', text: _log('ABCD'));

      expect(await memory.read('voyage-1'), _log('ABCD'));
      expect((await memory.latest())?.voyageCode, 'ABCD');
    });
  });
}

/// A log shaped the way [VoyageDiagnosticsRecorder.render] shapes one, since the
/// store reads the voyage code and the written-at back out of that header.
String _log(String voyageCode, {DateTime? at}) {
  final written = (at ?? DateTime.utc(2026, 8, 12, 18)).toIso8601String();
  return 'Tide and Seek · voyage diagnostics\n'
      'Voyage:  $voyageCode\n'
      'Build: 1.0.1+51\n'
      'Written: $written\n'
      '\n'
      '$written  NOTE       recording started';
}
