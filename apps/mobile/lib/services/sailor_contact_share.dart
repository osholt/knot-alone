import '../domain/voyage_event.dart';
import '../domain/voyage_role.dart';
import 'voyage_event_authenticator.dart';
import 'voyage_lifecycle.dart';

/// One sailor's **own** phone number, as it travels to the people who might need
/// to ring them (issue #188).
///
/// This is not [VoyageEventType.iceInfoShared] and must never be built from it.
/// An ICE share carries a sailor's next of kin — the person to ring *about* them
/// — so dialling it to "call the skipper" would ring the skipper's partner to say
/// the skipper is fine but somebody else has stopped. The two are separate
/// fields, separate events and separate consents.
///
/// Privacy, stated plainly, the same way [VoyageEventType.rejoinRouteShared]
/// states it: the voyage relay is voyage-scoped rather than per-recipient
/// encrypted, so "addressed to the skipper and TEC" means the event names its
/// intended recipients, the sharer only sends when a recipient is known, and
/// every consumer drops a share it is not addressed to. It is not a
/// cryptographic guarantee against a voyage member who already holds the voyage
/// secret. Retention is bounded like an ICE share: a hard per-share TTL on the
/// client, a matching server-side retention cap, and a purge of anything
/// unused the moment the voyage ends.
///
/// Never a sailor's identity. A number is for dialling from the emergency sheet.
/// Nothing here belongs beside a name in the roster, in an observer surface or
/// in a snapshot export.
class SailorContactShare {
  const SailorContactShare({
    required this.eventId,
    required this.sailorId,
    required this.displayName,
    required this.phoneNumber,
    required this.sharedAt,
    required this.sharedByRole,
    required this.toVoyageGroup,
  });

  final String eventId;

  /// The sailor the number belongs to. Always the event author: nobody may
  /// publish a number on somebody else's behalf.
  final String sailorId;

  /// Carried on the event for the same reason `iceInfoShared` carries it: a
  /// recipient may not have this sailor in their roster yet. Only ever used to
  /// label the dial control, never to establish who a sailor is.
  final String displayName;

  final String phoneNumber;
  final DateTime sharedAt;

  /// The role the sharer held when they shared. Why the recipient set is what it
  /// is, recorded so a reader can tell a coordination role's published contact
  /// from a sailor's addressed one without re-deriving roles.
  final VoyageRole sharedByRole;

  /// True when the sharer holds a coordination role and is therefore reachable
  /// by the sailors they are leading — the case in the original request, where a
  /// stopped sailor needs to ring the skipper or the TEC.
  final bool toVoyageGroup;

  Map<String, Object?> toJson() => {
    'sailorId': sailorId,
    'displayName': displayName,
    'phone': phoneNumber,
    'sharedByRole': sharedByRole.name,
  };

  /// Strict decode. Returns null rather than throwing, because one malformed
  /// share from a peer must never take the rest of a batch down with it.
  ///
  /// [event] supplies the author, the time and the recipient form: none of the
  /// three is read from the payload, so a peer cannot claim to be somebody else
  /// or backdate a share.
  static SailorContactShare? tryFromEvent(VoyageEvent event) {
    if (event.type != VoyageEventType.sailorContactShared) return null;
    final raw = event.payload['contact'];
    if (raw is! Map) return null;
    final json = <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final sailorId = _string(json['sailorId'], 128);
    final displayName = _string(json['displayName'], 80);
    final phoneNumber = normalisePhoneNumber(json['phone']);
    // Only the sailor a number belongs to may publish it.
    if (sailorId == null || sailorId != event.deviceId) return null;
    if (displayName == null || phoneNumber == null) return null;
    return SailorContactShare(
      eventId: event.id,
      sailorId: sailorId,
      displayName: displayName,
      phoneNumber: phoneNumber,
      sharedAt: event.createdAt,
      sharedByRole:
          _enumByName(VoyageRole.values, json['sharedByRole']) ??
          VoyageRole.sailor,
      toVoyageGroup: event.payload['recipientSailorIds'] == null,
    );
  }

  /// The characters a dialable number may contain, and nothing else.
  ///
  /// This value is put into a `tel:`/`sms:` URI built from data another voyage
  /// member sent, so the charset is a security bound rather than a formatting
  /// nicety: no scheme, no path separator, no query, no control character and
  /// no whitespace beyond a single separating space can survive it. A number
  /// that does not survive is rejected outright rather than sanitised into
  /// something that dials somewhere unintended.
  static final _allowedPattern = RegExp(r'^\+?[0-9(](?:[0-9 ()./-]*[0-9])?$');
  static final _digitPattern = RegExp(r'[0-9]');

  static const minimumDigits = 5;
  static const maximumLength = 24;

  /// Returns the trimmed, validated number, or null when it is absent, empty or
  /// not a plain dialable string. Never guesses and never rewrites: what the
  /// sailor typed is what is dialled.
  static String? normalisePhoneNumber(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
    if (!_allowedPattern.hasMatch(trimmed)) return null;
    if (_digitPattern.allMatches(trimmed).length < minimumDigits) return null;
    return trimmed;
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }

  static String? _string(Object? value, int maximumLength) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
    return trimmed;
  }
}

/// How long a shared number lives, on the client as well as the relay.
///
/// Two hours, the band [VoyageEventType.iceInfoShared] already uses: long enough
/// to cover the voyage a sailor shared it for, short enough that a phone which
/// never syncs again is not left holding somebody's number for days. The
/// voyage-end purge normally gets there first.
const sailorContactShareLifetime = Duration(hours: 2);

/// Who a sailor's number goes to, in one place so the rule is reversible.
///
/// Issue #188 settles two questions, and they resolve differently by role:
///
/// * A sailor who holds no coordination role addresses their number to **the
///   skipper and the TEC, and nobody else**. Those two have a reason to phone a
///   sailor who has stopped or gone quiet; the group does not, and a number that
///   reaches everyone is a number sailors will not share.
/// * A sailor who **holds** the lead or TEC role is sharing for the opposite
///   reason: the case in the request is a stopped sailor needing to reach them.
///   A contact for the role is of no use addressed to the other role-holder, so
///   it is offered to the voyage — which also keeps it usable by a sailor who
///   joins after it was shared, rather than silently excluding them.
///
/// Either way it is opt-in, per-voyage, and purged when the voyage ends. Reverse the
/// second branch here and the whole feature narrows to coordination roles only.
class SailorContactRecipients {
  const SailorContactRecipients._(this.sailorIds, this.toVoyageGroup);

  /// The empty recipient list means "the whole voyage", exactly as it does for
  /// `iceInfoShared` and `statusMessage`.
  const SailorContactRecipients.voyageGroup() : this._(const [], true);

  const SailorContactRecipients.addressed(List<String> sailorIds)
    : this._(sailorIds, false);

  final List<String> sailorIds;
  final bool toVoyageGroup;

  /// Nothing to share with: there is no skipper and no TEC to address, so the
  /// sailor is told rather than having an event recorded that reaches nobody.
  bool get isEmpty => !toVoyageGroup && sailorIds.isEmpty;

  /// [localRole] is the role the sharer holds now. [skipperSailorId] and
  /// [sweeperSailorIds] are the current coordination roles, excluding the sharer.
  static SailorContactRecipients resolve({
    required VoyageRole localRole,
    required String? skipperSailorId,
    required Iterable<String> sweeperSailorIds,
  }) {
    if (localRole == VoyageRole.lead || localRole == VoyageRole.sweeper) {
      return const SailorContactRecipients.voyageGroup();
    }
    return SailorContactRecipients.addressed([
      ?skipperSailorId,
      ...sweeperSailorIds,
    ]);
  }
}

/// Rebuilds the numbers shared **with the local sailor** from the journal.
///
/// Every filter is a rule from #188, applied in one place so the emergency
/// sheet, the roster and any companion surface cannot disagree:
///
/// * signed with the voyage secret, so a number cannot be planted by an
///   unauthenticated event;
/// * authored by the sailor it describes;
/// * addressed to the local sailor, or explicitly to the voyage;
/// * inside its own TTL;
/// * not from a sailor who has left the voyage, and never the local sailor's own —
///   nobody needs a control to ring themselves;
/// * gone entirely once the voyage has ended.
class SailorContactShareReducer {
  const SailorContactShareReducer();

  /// Keyed by sailor id, latest share per sailor wins.
  Map<String, SailorContactShare> fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
    required String localSailorId,
    required DateTime now,
    Iterable<String> departedSailorIds = const [],
    bool voyageEnded = false,
  }) {
    if (voyageEnded) return const {};
    final ordered =
        events
            .where(
              (event) =>
                  event.voyageId == voyageId &&
                  event.type == VoyageEventType.sailorContactShared &&
                  VoyageEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(VoyageLifecycleReducer.compareEvents);
    final departed = departedSailorIds.toSet();
    final latest = <String, SailorContactShare>{};
    for (final event in ordered) {
      if (!isAddressedTo(event, localSailorId)) continue;
      final share = SailorContactShare.tryFromEvent(event);
      if (share == null) continue;
      if (share.sailorId == localSailorId) continue;
      if (departed.contains(share.sailorId)) continue;
      if (!now.isBefore(share.sharedAt.add(sailorContactShareLifetime))) {
        continue;
      }
      latest[share.sailorId] = share;
    }
    return Map.unmodifiable(latest);
  }

  /// Builds the payload a sailor records.
  static Map<String, Object?> payload({
    required SailorContactShare share,
    required SailorContactRecipients recipients,
  }) => {
    'contact': share.toJson(),
    if (!recipients.toVoyageGroup)
      'recipientSailorIds': recipients.sailorIds.toSet().toList(
        growable: false,
      ),
  };

  /// A share with no recipient list is the explicit voyage-wide form a
  /// coordination role publishes; any other list must name the reader.
  ///
  /// Fails closed on a malformed list: a `recipientSailorIds` that is present but
  /// not a list is never treated as voyage-wide.
  static bool isAddressedTo(VoyageEvent event, String sailorId) {
    final recipients = event.payload['recipientSailorIds'];
    if (recipients == null) return true;
    if (recipients is! List) return false;
    return recipients.contains(sailorId);
  }
}
