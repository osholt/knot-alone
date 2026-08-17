import '../data/voyage_diagnostics_log_store.dart';

/// Keeps a stored log in step with a recorder that is still filling up (#456).
///
/// Two things it has to get right, and they pull in opposite directions:
///
/// - **Nothing may be lost.** The sailor who force-quits the app after noticing a
///   defect is exactly the sailor whose log matters, so a write cannot wait for a
///   tidy end-of-voyage moment that may never arrive.
/// - **The voyage comes first.** The phone is running navigation, and a burst of
///   entries — a reroute storm, a run of closely spaced junctions — must not turn
///   into a queue of whole-file writes.
///
/// So writes are *coalesced* rather than either debounced or queued: one write
/// runs at a time, and any entries recorded while it is in flight are covered by a
/// single follow-up write. Recording is never made to wait, and n entries during
/// one write cost one more write rather than n.
class VoyageDiagnosticsLogWriter {
  VoyageDiagnosticsLogWriter({
    required this.store,
    required this.voyageId,
    required this.render,
  });

  final VoyageDiagnosticsLogStore store;
  final String voyageId;

  /// The log as it stands. A callback rather than a string so the writer never
  /// holds a stale copy, and so rendering only happens when a write is about to
  /// use it.
  final String Function() render;

  Future<void>? _inFlight;
  bool _dirty = false;
  Object? _lastError;

  /// The failure from the most recent write, or null. Read by the shell so a
  /// storage failure is recorded in the log itself rather than swallowed.
  Object? get lastError => _lastError;

  /// How many writes have actually reached the store. Exposed so a test can show
  /// that a burst of entries did not become a burst of writes.
  int get writeCount => _writeCount;
  int _writeCount = 0;

  /// The recorder has something new. Returns immediately.
  void markDirty() {
    _dirty = true;
    _inFlight ??= _drain();
  }

  /// Writes anything outstanding and waits for it — for app pause, voyage end and
  /// dispose, where the next thing that happens may be the process dying.
  Future<void> flush() async {
    _dirty = true;
    final drain = _inFlight ??= _drain();
    await drain;
  }

  Future<void> _drain() async {
    try {
      // Re-checked rather than written once: an entry recorded during the write
      // below sets the flag again, and this is the loop that catches it without
      // starting a second concurrent write.
      while (_dirty) {
        _dirty = false;
        try {
          await store.write(voyageId: voyageId, text: render());
          _writeCount += 1;
          _lastError = null;
        } on Object catch (error) {
          // Kept rather than rethrown: a full disk must not end the voyage. The
          // shell reads [lastError] and records it, so the log says why it may be
          // short instead of appearing complete.
          _lastError = error;
        }
      }
    } finally {
      _inFlight = null;
    }
  }
}
