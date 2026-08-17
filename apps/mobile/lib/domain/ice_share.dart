/// A sailor's in-case-of-emergency details, shared into a voyage either with
/// the whole group (an explicit share) or with whoever currently holds the
/// lead role (the opt-in default-share setting).
class IceShare {
  const IceShare({
    required this.eventId,
    required this.sharedBySailorId,
    required this.sharedByDisplayName,
    required this.contactName,
    required this.contactPhone,
    required this.medicalNotes,
    required this.sharedAt,
    required this.toWholeGroup,
    this.viewedAt,
    this.viewedBySailorId,
  });

  final String eventId;
  final String sharedBySailorId;
  final String sharedByDisplayName;
  final String contactName;
  final String contactPhone;
  final String medicalNotes;
  final DateTime sharedAt;
  final bool toWholeGroup;

  /// Set once the recipient has opened this share, so the sharer can see it
  /// was seen. Only ever populated on a share the local sailor sent.
  final DateTime? viewedAt;
  final String? viewedBySailorId;
}
