import 'voyage_event.dart';

enum QuickMessage {
  stopped,
  mechanical,
  fuel,
  assistance,
  routeBlocked,
  emergencyStop,
  allPassed,
  resolved,
}

extension QuickMessageDetails on QuickMessage {
  String get label => switch (this) {
    QuickMessage.stopped => 'Stopped',
    QuickMessage.mechanical => 'Mechanical',
    QuickMessage.fuel => 'Need fuel',
    QuickMessage.assistance => 'Need help',
    QuickMessage.routeBlocked => 'Route blocked',
    QuickMessage.emergencyStop => 'Emergency stop',
    QuickMessage.allPassed => 'All sailors passed',
    QuickMessage.resolved => 'Resolved',
  };

  EventPriority get priority => switch (this) {
    QuickMessage.emergencyStop ||
    QuickMessage.assistance => EventPriority.critical,
    QuickMessage.mechanical ||
    QuickMessage.routeBlocked => EventPriority.important,
    _ => EventPriority.routine,
  };

  /// What a sailor raising this needs the group to be told, as a sentence naming
  /// them.
  ///
  /// A received alert has to say "Bill needs fuel", not "a status message
  /// arrived" (#151), and the sender's own [label] is the wrong half of that
  /// sentence — it is written for the button they pressed, not for the sailor
  /// reading it on another phone.
  String sentenceFor(String sailorName) => switch (this) {
    QuickMessage.stopped => '$sailorName has stopped',
    QuickMessage.mechanical => '$sailorName has a mechanical problem',
    QuickMessage.fuel => '$sailorName needs fuel',
    QuickMessage.assistance => '$sailorName needs help',
    QuickMessage.routeBlocked => '$sailorName says the route is blocked',
    QuickMessage.emergencyStop => '$sailorName has made an emergency stop',
    QuickMessage.allPassed => '$sailorName says all sailors have passed',
    QuickMessage.resolved => '$sailorName says it is resolved',
  };

  /// Whether raising this retires the sender's earlier outstanding messages.
  ///
  /// "Resolved" is the sailor saying the thing they raised is dealt with, so it
  /// must clear their own card rather than adding a second one to it.
  bool get retiresEarlierMessages => this == QuickMessage.resolved;
}

/// The [QuickMessage] a relayed payload names, or null when this build does not
/// know it.
///
/// A newer build can raise a kind this one has never heard of. The relayed
/// event still carries the sender's own `label`, so the message is presented
/// with what the sender called it rather than being dropped — the same
/// forwards-compatibility rule `relay_event_compatibility.dart` applies to
/// whole events.
QuickMessage? tryParseQuickMessage(Object? name) {
  if (name is! String) return null;
  for (final candidate in QuickMessage.values) {
    if (candidate.name == name) return candidate;
  }
  return null;
}
