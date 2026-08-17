import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/geo_point.dart';
import 'package:tide_and_seek/domain/quick_message.dart';
import 'package:tide_and_seek/features/voyage/active_voyage_shell.dart';
import 'package:tide_and_seek/services/received_quick_message.dart';

/// The shell's half of #151: given the journal's admissible quick messages plus
/// whatever this phone knows about where everybody is, what does the voyage map
/// get? This is the decision a two-device test exercises, made testable without
/// two devices.
void main() {
  ReceivedQuickMessage message({
    String eventId = 'msg-1',
    String senderSailorId = 'bill',
    String senderDisplayName = 'Bill',
    QuickMessage kind = QuickMessage.fuel,
    GeoPoint? raisedAtPosition,
    bool raisedFromLocalSailor = false,
    List<String> acknowledgedBy = const [],
  }) => ReceivedQuickMessage(
    eventId: eventId,
    senderSailorId: senderSailorId,
    senderDisplayName: senderDisplayName,
    label: kind.label,
    priority: kind.priority,
    raisedAt: DateTime.utc(2026, 7, 26, 12),
    raisedFromLocalSailor: raisedFromLocalSailor,
    message: kind,
    raisedAtPosition: raisedAtPosition,
    acknowledgements: [
      for (final sailorId in acknowledgedBy)
        QuickMessageAcknowledgement(
          sailorId: sailorId,
          displayName: sailorId,
          acknowledgedAt: DateTime.utc(2026, 7, 26, 12, 1),
        ),
    ],
  );

  const route = [
    GeoPoint(latitude: 53, longitude: -1.03),
    GeoPoint(latitude: 53, longitude: -1.02),
    GeoPoint(latitude: 53, longitude: -1.01),
    GeoPoint(latitude: 53, longitude: -1),
  ];
  const readerPosition = GeoPoint(latitude: 53, longitude: -1.01);

  test('another sailor message reaches the map with where they are', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localSailorId: 'skipper',
      readerPosition: readerPosition,
      route: route,
    );

    expect(presented.alerts, hasLength(1));
    final alert = presented.alerts.single;
    expect(alert.message.headline, 'Bill needs fuel');
    expect(alert.origin?.alongRoute, isTrue);
    expect(alert.origin?.senderIsBehind, isTrue);
    expect(alert.origin?.positionIsLive, isFalse);
    // And their marker is the one that has to say what they raised.
    expect(presented.bySender.keys, const ['bill']);
  });

  test('a live fix wins over the fix relayed with the message', () {
    // Bill raised it a mile back and has since ridden up to the skipper. Where he
    // is *now* is what a skipper turning round needs.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localSailorId: 'skipper',
      readerPosition: readerPosition,
      livePositions: const {'bill': GeoPoint(latitude: 53, longitude: -1.005)},
      route: route,
    );

    final origin = presented.alerts.single.origin!;
    expect(origin.positionIsLive, isTrue);
    expect(origin.senderIsBehind, isFalse);
    expect(origin.distanceMeters, closeTo(335, 30));
  });

  test('a sender with no fix at all is presented without an origin', () {
    // Honest absence, not a zero distance: the card says "position not reported".
    final presented = presentableQuickMessageAlerts(
      messages: [message()],
      localSailorId: 'skipper',
      readerPosition: readerPosition,
      route: route,
    );

    expect(presented.alerts.single.origin, isNull);
  });

  test('acknowledging is what clears it from this phone', () {
    final messages = [
      message(acknowledgedBy: const ['skipper']),
    ];

    // Gone for the sailor who acknowledged it.
    expect(
      presentableQuickMessageAlerts(
        messages: messages,
        localSailorId: 'skipper',
        readerPosition: readerPosition,
      ).alerts,
      isEmpty,
    );
    // Still outstanding for everybody else who can see it.
    expect(
      presentableQuickMessageAlerts(
        messages: messages,
        localSailorId: 'charlie',
        readerPosition: readerPosition,
      ).alerts,
      hasLength(1),
    );
  });

  test('this sailor own message appears only as a receipt', () {
    final unseen = message(
      senderSailorId: 'skipper',
      senderDisplayName: 'Me',
      raisedFromLocalSailor: true,
    );
    final seen = message(
      senderSailorId: 'skipper',
      senderDisplayName: 'Me',
      raisedFromLocalSailor: true,
      acknowledgedBy: const ['bill'],
    );

    // Nobody needs their own alert read back to them.
    expect(
      presentableQuickMessageAlerts(
        messages: [unseen],
        localSailorId: 'skipper',
        readerPosition: readerPosition,
      ).alerts,
      isEmpty,
    );
    // Once somebody has seen it, that is worth saying - and it is not an alert,
    // so it never claims a sender marker.
    final receipt = presentableQuickMessageAlerts(
      messages: [seen],
      localSailorId: 'skipper',
      readerPosition: readerPosition,
    );
    expect(receipt.alerts, hasLength(1));
    expect(
      receipt.alerts.single.message.firstAcknowledgement?.sailorId,
      'bill',
    );
    expect(receipt.bySender, isEmpty);
  });

  test('one marker per sender, the most urgent thing they raised', () {
    // The reducer hands them over most urgent first, so the first message from a
    // sailor is the one their marker should carry.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(eventId: 'help', kind: QuickMessage.assistance),
        message(eventId: 'fuel'),
      ],
      localSailorId: 'skipper',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(2));
    expect(presented.bySender['bill']?.eventId, 'help');
    expect(presented.bySender['bill']?.interrupts, isTrue);
  });

  test('a reader with no fix of their own still gets the message', () {
    // The message is the point; the distance is the bonus. A phone that has not
    // got a fix yet must still be told somebody needs help.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          kind: QuickMessage.assistance,
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localSailorId: 'skipper',
      readerPosition: null,
      route: route,
    );

    expect(presented.alerts.single.message.headline, 'Bill needs help');
    expect(presented.alerts.single.origin, isNull);
  });

  // #178: the same sailor saying the same thing three times produced three
  // identical prompts, one after another, which a tester read as one prompt that
  // would not go away:
  //
  //   "cancelling multiple 'voyage stop's seems a bit flaky, think I got repeated
  //    requests to cancel same ones."
  test('repeated identical messages from one sailor collapse into one', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(eventId: 'stop-1', kind: QuickMessage.stopped),
        message(eventId: 'stop-2', kind: QuickMessage.stopped),
        message(eventId: 'stop-3', kind: QuickMessage.stopped),
      ],
      localSailorId: 'me',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(1));
    expect(presented.alerts.single.repeatCount, 3);
    expect(
      presented.alerts.single.acknowledgeable.map((item) => item.eventId),
      ['stop-1', 'stop-2', 'stop-3'],
      reason: 'acknowledging the card must answer for all three',
    );
  });

  test('different kinds from one sailor stay separate', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(eventId: 'stop-1', kind: QuickMessage.stopped),
        message(eventId: 'mech-1', kind: QuickMessage.mechanical),
      ],
      localSailorId: 'me',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(2));
    expect(presented.alerts.every((alert) => alert.repeatCount == 1), isTrue);
  });

  test('the same kind from different sailors stays separate', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          eventId: 'stop-1',
          senderSailorId: 'bill',
          kind: QuickMessage.stopped,
        ),
        message(
          eventId: 'stop-2',
          senderSailorId: 'kate',
          senderDisplayName: 'Kate',
          kind: QuickMessage.stopped,
        ),
      ],
      localSailorId: 'me',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(2));
    expect(presented.alerts.every((alert) => alert.repeatCount == 1), isTrue);
  });

  test('an already-acknowledged repeat is not counted again', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(eventId: 'stop-1', kind: QuickMessage.stopped),
        message(
          eventId: 'stop-2',
          kind: QuickMessage.stopped,
          acknowledgedBy: const ['me'],
        ),
      ],
      localSailorId: 'me',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(1));
    expect(presented.alerts.single.repeatCount, 1);
    expect(presented.alerts.single.acknowledgeable.single.eventId, 'stop-1');
  });
}
