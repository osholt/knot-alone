/// How a voyage uses Tide and Seek's group-coordination features.
enum VoyageCoordinationMode {
  /// One sailor, with route recording and navigation but no join code or group
  /// controls.
  solo,

  /// The classic second-bike drop-off system: junction marker prompts, marker
  /// passes and Tide and Seek statistics are enabled.
  secondBikeDropOff,

  /// Sailors stay together as one group, without junction drop-off prompts.
  ///
  /// "Keep-together" describes the coordination policy without suggesting
  /// sailors should follow at an unsafe close distance.
  keepTogether;

  bool get isGroup => this != VoyageCoordinationMode.solo;

  bool get usesSecondBikeDropOff =>
      this == VoyageCoordinationMode.secondBikeDropOff;

  String get label => switch (this) {
    VoyageCoordinationMode.solo => 'Solo voyage',
    VoyageCoordinationMode.secondBikeDropOff => 'Second-bike drop-off',
    VoyageCoordinationMode.keepTogether => 'Keep-together group',
  };

  String get description => switch (this) {
    VoyageCoordinationMode.solo =>
      'Navigation and voyage recording for just you. No join code or group '
          'controls; you can still share a private watcher link.',
    VoyageCoordinationMode.secondBikeDropOff =>
      'Use junction drop-offs, marker prompts and Tide and Seek tracking.',
    VoyageCoordinationMode.keepTogether =>
      'Voyage as one group without junction drop-offs or marker prompts.',
  };

  static VoyageCoordinationMode fromName(String? name) =>
      VoyageCoordinationMode.values.firstWhere(
        (mode) => mode.name == name,
        // Every voyage created before this choice existed used this system.
        orElse: () => VoyageCoordinationMode.secondBikeDropOff,
      );
}
