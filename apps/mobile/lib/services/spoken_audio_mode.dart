/// What the app is allowed to say out loud (#415).
///
/// One switch is not enough: a sailor may silence passage prompts while keeping
/// stale-position and crew-safety warnings, or may explicitly choose silence.
///
/// The distinction is **navigation against safety**, and it is drawn here rather
/// than at each call site so it cannot drift: a new thing to say has to declare
/// which class it belongs to, and the answer is in one place where it can be
/// argued with.
enum SpokenAudioMode {
  /// Everything: passage prompts, distances, and warnings.
  everything,

  /// Warnings only. Ordinary passage prompts are silent; instrument and group
  /// safety warnings are not.
  alertsOnly,

  /// Nothing at all, including warnings. A sailor who chooses this has chosen it.
  silent,
}

/// The class a thing to say belongs to.
enum SpokenAudioClass {
  /// Passage guidance: where the next mark and alteration are.
  navigation,

  /// Something the sailor needs to know regardless of whether they asked for
  /// passage guidance: a stale fix or a sailor in trouble.
  safety,
}

/// Whether [audioClass] may be spoken in [mode].
///
/// Deliberately total over both enums rather than a chain of ifs, so adding a
/// mode or a class is a compile error at this one function instead of a silent
/// omission somewhere else.
bool spokenAudioAllows(SpokenAudioMode mode, SpokenAudioClass audioClass) =>
    switch ((mode, audioClass)) {
      (SpokenAudioMode.everything, _) => true,
      (SpokenAudioMode.silent, _) => false,
      (SpokenAudioMode.alertsOnly, SpokenAudioClass.safety) => true,
      (SpokenAudioMode.alertsOnly, SpokenAudioClass.navigation) => false,
    };

/// What the control on the map says it will do next, so a sailor pressing it by
/// feel knows what they are getting.
String spokenAudioModeLabel(SpokenAudioMode mode) => switch (mode) {
  SpokenAudioMode.everything => 'Voice on',
  SpokenAudioMode.alertsOnly => 'Alerts only',
  SpokenAudioMode.silent => 'Muted',
};

/// The order the map control cycles through.
///
/// Everything → alerts only → muted → everything. Three states on one control
/// because a mounted phone in gloves has room for one, and the order goes from
/// most to least talkative so a sailor who wants quiet presses in one direction.
SpokenAudioMode nextSpokenAudioMode(SpokenAudioMode mode) => switch (mode) {
  SpokenAudioMode.everything => SpokenAudioMode.alertsOnly,
  SpokenAudioMode.alertsOnly => SpokenAudioMode.silent,
  SpokenAudioMode.silent => SpokenAudioMode.everything,
};
