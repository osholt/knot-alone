/// What to do to the recorder when the diagnostics switch moves (#457).
///
/// ## What was wrong
///
/// The recorder was built in the voyage shell's `initState` and nowhere else, and
/// nothing listened to the controller afterwards. So the switch was read **once**,
/// when the voyage screen was first built, and never again.
///
/// The consequence for a sailor: reaching Settings through the *voyage menu* — the
/// door closest to hand once you are already riding — turned recording on, showed
/// it on, and recorded nothing for the rest of that voyage. The switch lied about
/// what it was doing.
///
/// It is also the more likely way to arrive at it. A sailor decides to record
/// *because* something has just gone wrong, and by then they are mid-voyage.
///
/// ## Why this is a function and not an `if` in the shell
///
/// No widget test in this repo constructs `ActiveVoyageShell` — it needs a session, a
/// relay, a location stream and a map — so an `if` inside the state class is
/// reachable only by riding. Every interesting case lives in the three booleans
/// below, so they are lifted out and enumerated in a test instead.
library;

/// The action to take on the recorder.
enum VoyageDiagnosticsTransition {
  /// No recorder yet: build one, and say in the log that the voyage was already
  /// under way so a reader is not misled into thinking the earlier part was quiet
  /// rather than unrecorded.
  start,

  /// A recorder exists but was stopped: take it up again, keeping its entries.
  resume,

  /// Stop accepting entries and write out what there is.
  stop,

  /// Already in the asked-for state.
  nothing,
}

/// The transition implied by [switchedOn], given what the shell currently holds.
///
/// [hasRecorder] and [isRecording] are separate because they are separately
/// reachable: no recorder at all is the state a voyage starts in with the switch
/// off, while a stopped recorder holding entries is what switching off mid-voyage
/// leaves behind.
VoyageDiagnosticsTransition voyageDiagnosticsTransition({
  required bool switchedOn,
  required bool hasRecorder,
  required bool isRecording,
}) {
  if (switchedOn) {
    if (!hasRecorder) return VoyageDiagnosticsTransition.start;
    return isRecording
        ? VoyageDiagnosticsTransition.nothing
        : VoyageDiagnosticsTransition.resume;
  }
  if (!hasRecorder) return VoyageDiagnosticsTransition.nothing;
  return isRecording
      ? VoyageDiagnosticsTransition.stop
      : VoyageDiagnosticsTransition.nothing;
}

/// The note a recorder built mid-voyage opens with.
///
/// Says what is *missing*, not just when it started. A log that begins in the
/// middle of a voyage and does not say so reads as a record of the whole voyage with a
/// quiet first half.
const voyageDiagnosticsStartedMidVoyageNote =
    'recording started mid-voyage — nothing before this point was recorded';

/// The note a recorder built at the start of a voyage opens with.
const voyageDiagnosticsStartedNote = 'recording started';
