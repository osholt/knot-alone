import '../domain/geo_point.dart';
import '../domain/quick_message.dart';
import '../domain/voyage_event.dart';
import 'geo_calculations.dart';
import 'voyage_event_authenticator.dart';
import 'voyage_lifecycle.dart';

/// One sailor's acknowledgement of another sailor's quick message.
class QuickMessageAcknowledgement {
  const QuickMessageAcknowledgement({
    required this.sailorId,
    required this.displayName,
    required this.acknowledgedAt,
  });

  final String sailorId;
  final String displayName;
  final DateTime acknowledgedAt;
}

/// A quick message as the phone receiving it has to present it: who raised it,
/// what they raised, when, and whether anybody has said they have seen it.
///
/// The send path has always worked; nothing rendered the result anywhere except
/// one row in the dashboard event log, on a tab the sailor was not looking at
/// (#151). This is the model every receive surface reads, so the map card, the
/// interrupt and the sender's own receipt cannot disagree.
class ReceivedQuickMessage {
  const ReceivedQuickMessage({
    required this.eventId,
    required this.senderSailorId,
    required this.senderDisplayName,
    required this.label,
    required this.priority,
    required this.raisedAt,
    required this.raisedFromLocalSailor,
    this.message,
    this.raisedAtPosition,
    this.addressedToLocalSailor = false,
    this.acknowledgements = const [],
  });

  /// The journal event this came from — the identity an acknowledgement names.
  final String eventId;
  final String senderSailorId;
  final String senderDisplayName;

  /// The kind, or null when a newer build raised a kind this one has never
  /// heard of. [label] is always present, so an unknown kind is still shown
  /// with the words the sender chose rather than dropped.
  final QuickMessage? message;

  /// What the sender called it. Their own words, always relayed.
  final String label;
  final EventPriority priority;
  final DateTime raisedAt;

  /// Where the sender was when they raised it, when they relayed one.
  ///
  /// Deliberately the raised-at fix rather than a live one: a sailor who has
  /// stopped for fuel is not moving, and this position survives their location
  /// events ageing out of the 30-minute retention band.
  final GeoPoint? raisedAtPosition;

  /// True when this phone raised it, so its own surfaces show a receipt rather
  /// than an alert.
  final bool raisedFromLocalSailor;

  /// True when the sender addressed it to this sailor specifically (the skipper
  /// and TEC recipient list the map's SOS and issue controls build), rather
  /// than to the whole group.
  final bool addressedToLocalSailor;

  final List<QuickMessageAcknowledgement> acknowledgements;

  bool get isAcknowledged => acknowledgements.isNotEmpty;

  /// Whether this may take the screen over.
  ///
  /// Only the critical band does. "Need fuel" must not blank the map at 60 mph,
  /// which is the whole reason [QuickMessage.priority] exists.
  bool get interrupts => priority == EventPriority.critical;

  /// Whether this warrants the alert palette without interrupting: a mechanical
  /// problem or a blocked route is not an emergency, and is not routine either.
  bool get isPressing => priority == EventPriority.important;

  QuickMessageAcknowledgement? get firstAcknowledgement =>
      acknowledgements.isEmpty ? null : acknowledgements.first;

  /// The sentence a sailor reads: "Bill needs fuel".
  ///
  /// Falls back to the sender's own label for a kind this build does not know.
  String get headline =>
      message?.sentenceFor(senderDisplayName) ?? '$senderDisplayName: $label';

  bool acknowledgedBy(String sailorId) =>
      acknowledgements.any((entry) => entry.sailorId == sailorId);

  ReceivedQuickMessage withAcknowledgements(
    List<QuickMessageAcknowledgement> entries,
  ) => ReceivedQuickMessage(
    eventId: eventId,
    senderSailorId: senderSailorId,
    senderDisplayName: senderDisplayName,
    label: label,
    priority: priority,
    raisedAt: raisedAt,
    raisedFromLocalSailor: raisedFromLocalSailor,
    message: message,
    raisedAtPosition: raisedAtPosition,
    addressedToLocalSailor: addressedToLocalSailor,
    acknowledgements: List.unmodifiable(entries),
  );
}

/// Where the sailor who raised a quick message is, relative to the sailor reading
/// it.
///
/// Two forms, because only one of them is ever honest: along the loaded route
/// when both sailors are demonstrably on it, and a straight line with a compass
/// bearing when they are not. A distance along a route neither sailor is on is a
/// number that means nothing.
class QuickMessageOrigin {
  const QuickMessageOrigin({
    required this.distanceMeters,
    required this.alongRoute,
    this.senderIsBehind,
    this.bearingDegrees,
    this.positionIsLive = false,
  });

  final double distanceMeters;

  /// True when [distanceMeters] was measured along the loaded route rather than
  /// as a straight line.
  final bool alongRoute;

  /// Whether the sender is behind the reader along the route. Null when
  /// [alongRoute] is false — off the route there is no "back".
  final bool? senderIsBehind;

  /// Degrees clockwise from true north towards the sender. Set whenever
  /// [alongRoute] is false, so the reader knows which way to look.
  final double? bearingDegrees;

  /// True when this was measured from the sender's live position rather than
  /// the fix they relayed with the message.
  final bool positionIsLive;

  /// The eight-point compass label for [bearingDegrees].
  ///
  /// Eight points, not sixteen: a sailor glancing at a phone on a mount needs
  /// "NE", and "NNE" costs reading time for precision a straight-line bearing
  /// does not have anyway.
  String? get compassLabel {
    final bearing = bearingDegrees;
    if (bearing == null) return null;
    const points = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    return points[(((bearing % 360) + 22.5) ~/ 45) % 8];
  }

  /// Resolves the honest form for one pair of positions.
  ///
  /// [maximumOnRouteDistanceMeters] mirrors
  /// `SkipperVoyageStatusCalculator.maximumOnRouteDistanceMeters`, so "on the
  /// route" means the same thing here as it does in the TEC gap.
  static QuickMessageOrigin? between({
    required GeoPoint? readerPosition,
    required GeoPoint? senderPosition,
    List<GeoPoint> route = const [],
    bool positionIsLive = false,
    double maximumOnRouteDistanceMeters = 250,
  }) {
    if (readerPosition == null || senderPosition == null) return null;
    if (route.length >= 2) {
      final reader = GeoCalculations.projectOntoPolyline(readerPosition, route);
      final sender = GeoCalculations.projectOntoPolyline(senderPosition, route);
      if (reader.distanceFromRouteMeters <= maximumOnRouteDistanceMeters &&
          sender.distanceFromRouteMeters <= maximumOnRouteDistanceMeters) {
        final delta =
            sender.distanceAlongRouteMeters - reader.distanceAlongRouteMeters;
        return QuickMessageOrigin(
          distanceMeters: delta.abs(),
          alongRoute: true,
          senderIsBehind: delta < 0,
          positionIsLive: positionIsLive,
        );
      }
    }
    return QuickMessageOrigin(
      distanceMeters: GeoCalculations.distanceMeters(
        readerPosition,
        senderPosition,
      ),
      alongRoute: false,
      bearingDegrees: GeoCalculations.bearingDegrees(
        readerPosition,
        senderPosition,
      ),
      positionIsLive: positionIsLive,
    );
  }
}

/// A received quick message together with where its sender is — everything the
/// voyage surfaces need to present one, and nothing they have to work out.
class VoyageQuickMessageAlert {
  const VoyageQuickMessageAlert({
    required this.message,
    this.origin,
    this.repeats = const [],
  });

  final ReceivedQuickMessage message;

  /// The other outstanding messages this alert stands for: the same sailor saying
  /// the same thing again, with [message] the one presented.
  ///
  /// One card is shown at a time and acknowledging it reveals the next, so three
  /// `Stopped` messages from one sailor produced three identical prompts and read
  /// as one prompt that would not go away (#178). Three `Stopped` from one sailor
  /// is one fact, so they are collapsed into a single alert and acknowledged
  /// together - which is why the messages are carried rather than counted.
  final List<ReceivedQuickMessage> repeats;

  /// Every message this alert answers for, the presented one first.
  List<ReceivedQuickMessage> get acknowledgeable => [message, ...repeats];

  int get repeatCount => repeats.length + 1;

  /// Null when the sender has never reported a position and did not relay one:
  /// a surface says so rather than showing a zero or an empty gap, the rule
  /// #88 anchored for the TEC surfaces.
  final QuickMessageOrigin? origin;
}

/// Rebuilds the quick messages this phone should be presenting, from the
/// journal.
///
/// Every rule lives here so the map card, the critical interrupt, the sender's
/// receipt and any later companion surface cannot disagree:
///
/// * signature-verified for this voyage, like every other relayed fact;
/// * addressed to the local sailor, or group-visible — a message with a
///   recipient list this sailor is not on is not theirs to see;
/// * inside its own expiry;
/// * retired by a later "Resolved" from the same sailor, and by that sailor
///   leaving the voyage;
/// * acknowledgements folded onto the message they name.
///
/// ### Why an acknowledgement is itself a `statusMessage`
///
/// It carries `acknowledgesQuickMessageEventId`, exactly as `iceInfoViewed`
/// carries `sharedEventId`. A new `VoyageEventType` would have needed the relay's
/// own event-type allowlist and a capability to negotiate, so acknowledgement
/// would have silently not relayed until a server deploy reached production. A
/// `statusMessage` is already allowlisted, already capped at two hours'
/// retention and already carries `recipientSailorIds`, so this works on the relay
/// that is running today. An older build shows it in the event log as its label
/// and otherwise ignores it.
class ReceivedQuickMessageReducer {
  const ReceivedQuickMessageReducer();

  /// The payload key that makes a `statusMessage` an acknowledgement of another
  /// one rather than a new message.
  static const acknowledgesKey = 'acknowledgesQuickMessageEventId';

  List<ReceivedQuickMessage> fromEvents({
    required String voyageId,
    required String inviteSecret,
    required Iterable<VoyageEvent> events,
    required String localSailorId,
    required DateTime now,
    Map<String, String> displayNames = const {},
    Iterable<String> departedSailorIds = const [],
    bool voyageEnded = false,
  }) {
    if (voyageEnded) return const [];
    final ordered =
        events
            .where(
              (event) =>
                  event.voyageId == voyageId &&
                  event.type == VoyageEventType.statusMessage &&
                  VoyageEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(VoyageLifecycleReducer.compareEvents);
    final departed = departedSailorIds.toSet();
    final messages = <String, ReceivedQuickMessage>{};
    final acknowledgements = <String, List<QuickMessageAcknowledgement>>{};
    for (final event in ordered) {
      final acknowledged = event.payload[acknowledgesKey];
      if (acknowledged is String) {
        (acknowledgements[acknowledged] ??= []).add(
          QuickMessageAcknowledgement(
            sailorId: event.deviceId,
            displayName: _nameFor(event, displayNames),
            acknowledgedAt: event.createdAt,
          ),
        );
        continue;
      }
      if (!_isVisibleTo(event, localSailorId)) continue;
      final message = tryParseQuickMessage(event.payload['message']);
      final label = event.payload['label'];
      if (label is! String || label.isEmpty) continue;
      if (message?.retiresEarlierMessages ?? false) {
        // The sailor says the thing they raised is dealt with. That clears their
        // card rather than adding a second one to it.
        messages.removeWhere(
          (_, existing) => existing.senderSailorId == event.deviceId,
        );
        continue;
      }
      messages[event.id] = ReceivedQuickMessage(
        eventId: event.id,
        senderSailorId: event.deviceId,
        senderDisplayName: _nameFor(event, displayNames),
        label: label,
        // The sender's own priority is authoritative when this build knows the
        // kind; otherwise the relayed envelope priority is what there is.
        priority: message?.priority ?? event.priority,
        raisedAt: event.createdAt,
        raisedFromLocalSailor: event.deviceId == localSailorId,
        message: message,
        raisedAtPosition: _positionFrom(event.payload['position']),
        addressedToLocalSailor: _recipients(event).contains(localSailorId),
      );
    }
    final live =
        messages.values
            .where(
              (message) =>
                  !departed.contains(message.senderSailorId) &&
                  !_isExpired(message, ordered, now),
            )
            .map(
              (message) => message.withAcknowledgements(
                acknowledgements[message.eventId] ?? const [],
              ),
            )
            .toList()
          ..sort(_mostUrgentFirst);
    return List.unmodifiable(live);
  }

  /// The payload one sailor records to tell the sender their message was seen.
  ///
  /// Addressed to the sender, so an acknowledgement is not group noise, and
  /// labelled so the dashboard event log reads as a sentence on both phones.
  static Map<String, Object?> acknowledgementPayload({
    required ReceivedQuickMessage message,
  }) => {
    acknowledgesKey: message.eventId,
    'label': 'Seen: ${message.label}',
    'recipientSailorIds': [message.senderSailorId],
  };

  /// Whether [event] is an acknowledgement rather than a new quick message.
  static bool isAcknowledgement(VoyageEvent event) =>
      event.type == VoyageEventType.statusMessage &&
      event.payload[acknowledgesKey] is String;

  static int _mostUrgentFirst(
    ReceivedQuickMessage first,
    ReceivedQuickMessage second,
  ) {
    final byPriority = second.priority.index.compareTo(first.priority.index);
    if (byPriority != 0) return byPriority;
    final byUnacknowledged = (first.isAcknowledged ? 1 : 0).compareTo(
      second.isAcknowledged ? 1 : 0,
    );
    if (byUnacknowledged != 0) return byUnacknowledged;
    return second.raisedAt.compareTo(first.raisedAt);
  }

  /// A quick message with no recipient list is group-visible, which is what the
  /// dashboard grid sends. One with a list is only for the sailors on it —
  /// deliberately the opposite default from a rejoin share, because the sender
  /// chose the whole group when they left the list off.
  static bool _isVisibleTo(VoyageEvent event, String localSailorId) {
    if (event.deviceId == localSailorId) return true;
    final recipients = _recipients(event);
    return recipients.isEmpty || recipients.contains(localSailorId);
  }

  static Set<String> _recipients(VoyageEvent event) {
    final recipients = event.payload['recipientSailorIds'];
    if (recipients is! List) return const {};
    return recipients.whereType<String>().toSet();
  }

  static String _nameFor(VoyageEvent event, Map<String, String> displayNames) {
    final relayed = event.payload['senderDisplayName'];
    if (relayed is String && relayed.trim().isNotEmpty) return relayed.trim();
    return displayNames[event.deviceId] ?? 'A sailor';
  }

  static GeoPoint? _positionFrom(Object? value) {
    if (value is! Map) return null;
    final latitude = value['latitude'];
    final longitude = value['longitude'];
    if (latitude is! num || longitude is! num) return null;
    if (latitude.abs() > 90 || longitude.abs() > 180) return null;
    return GeoPoint(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  static bool _isExpired(
    ReceivedQuickMessage message,
    List<VoyageEvent> events,
    DateTime now,
  ) {
    for (final event in events) {
      if (event.id != message.eventId) continue;
      final expiresAt = event.expiresAt;
      return expiresAt != null && !expiresAt.isAfter(now);
    }
    return false;
  }
}
