/// Who someone is on a passage.
///
/// [skipper] was `lead` until #49. "Lead" is the road group-riding role this app
/// was scaffolded from; on a boat the word is skipper, and it is not a synonym -
/// it names the person with responsibility for the vessel, which is exactly what
/// this role carries. The marine glyph set drawn for #30 already said Skipper,
/// so the icon and the role beside it disagreed on screen.
enum VoyageRole { skipper, sailor, sweeper, marker }

extension VoyageRoleLabel on VoyageRole {
  String get label => switch (this) {
    VoyageRole.skipper => 'Skipper',
    VoyageRole.sailor => 'Sailor',
    VoyageRole.sweeper => 'Sweeper',
    VoyageRole.marker => 'Marker',
  };
}

/// How a role crosses a wire or a restart.
///
/// Separate from `.name` on purpose. Roles are written into saved sessions,
/// completed voyages, relay payloads and push registrations, and the old builds
/// that wrote them spelled this role `lead`. `VoyageRole.values.byName('lead')`
/// throws, and the place it throws is session restore - which surfaces as
/// "Could not restore your saved voyage" and loses the passage.
///
/// So the wire name is stated rather than derived, and parsing accepts what
/// earlier builds wrote. New payloads say `skipper`; anything that still says
/// `lead` is read as one.
extension VoyageRoleWire on VoyageRole {
  /// The value written to storage and to the relay.
  String get wireName => name;

  /// Reads a stored or received role, tolerating the pre-#49 spelling.
  ///
  /// Returns null rather than throwing for anything unrecognised, so a payload
  /// from a newer build with a role this one does not know degrades to "no role
  /// stated" instead of taking the voyage down with it.
  static VoyageRole? tryParse(String? value) => switch (value) {
    null => null,
    'lead' => VoyageRole.skipper,
    _ => VoyageRole.values.where((role) => role.name == value).firstOrNull,
  };

  /// Reads a role that must be present, with the same tolerance as [tryParse].
  static VoyageRole parse(String value) =>
      tryParse(value) ??
      (throw FormatException('Unknown voyage role: $value', value));
}
