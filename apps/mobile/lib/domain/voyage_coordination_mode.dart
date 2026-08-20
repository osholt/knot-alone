/// How a voyage uses Tide and Seek's crew-coordination features.
enum VoyageCoordinationMode {
  /// One sailor, with route recording and navigation but no join code or crew
  /// controls.
  solo,

  /// The crew share one voyage: roster, positions and quick messages.
  crew,

  /// Recorded by builds that offered the junction drop-off system.
  ///
  /// The marker surfaces it selected are gone, so nothing offers it now and it
  /// behaves exactly as [crew]. Kept so a voyage stored by an earlier build
  /// still decodes instead of failing to load.
  @Deprecated('Junction drop-offs were removed with the marker surfaces.')
  secondBikeDropOff;

  bool get isGroup => this != VoyageCoordinationMode.solo;

  String get label => switch (this) {
    VoyageCoordinationMode.solo => 'Solo voyage',
    VoyageCoordinationMode.crew => 'Crew voyage',
    // ignore: deprecated_member_use_from_same_package
    VoyageCoordinationMode.secondBikeDropOff => 'Crew voyage',
  };

  String get description => switch (this) {
    VoyageCoordinationMode.solo =>
      'Navigation and voyage recording for just you. No join code or crew '
          'controls; you can still share a private watcher link.',
    VoyageCoordinationMode.crew =>
      'Share a six-digit code so the crew see one roster, one route and each '
          "other's positions.",
    // ignore: deprecated_member_use_from_same_package
    VoyageCoordinationMode.secondBikeDropOff =>
      'Share a six-digit code so the crew see one roster, one route and each '
          "other's positions.",
  };

  static VoyageCoordinationMode fromName(String? name) =>
      VoyageCoordinationMode.values.firstWhere(
        (mode) => mode.name == name,
        orElse: () => VoyageCoordinationMode.crew,
      );
}
