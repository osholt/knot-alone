/// A rider's in-case-of-emergency details, shared into a ride either with
/// the whole group (an explicit share) or with whoever currently holds the
/// lead role (the opt-in default-share setting).
class IceShare {
  const IceShare({
    required this.eventId,
    required this.sharedByRiderId,
    required this.sharedByDisplayName,
    required this.contactName,
    required this.contactPhone,
    required this.medicalNotes,
    required this.sharedAt,
    required this.toWholeGroup,
    this.viewedAt,
    this.viewedByRiderId,
  });

  final String eventId;
  final String sharedByRiderId;
  final String sharedByDisplayName;
  final String contactName;
  final String contactPhone;
  final String medicalNotes;
  final DateTime sharedAt;
  final bool toWholeGroup;

  /// Set once the recipient has opened this share, so the sharer can see it
  /// was seen. Only ever populated on a share the local rider sent.
  final DateTime? viewedAt;
  final String? viewedByRiderId;
}
