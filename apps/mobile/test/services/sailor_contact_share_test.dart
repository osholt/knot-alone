import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_event.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/services/voyage_event_authenticator.dart';
import 'package:tide_and_seek/services/sailor_contact_share.dart';

/// Issue #188. A sailor's **own** number reaches the people who might have to
/// ring them, and nobody else; it is never mistaken for the ICE contact; and it
/// is gone from a recipient's phone once the voyage is over.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const voyageId = 'voyage-188';
  final sharedAt = DateTime.utc(2026, 7, 27, 11);

  VoyageEvent share({
    String id = 'share-1',
    String deviceId = 'bill',
    String sailorId = 'bill',
    String displayName = 'Bill',
    String phone = '+44 7700 900321',
    VoyageRole role = VoyageRole.sailor,
    DateTime? createdAt,
    List<String>? recipientSailorIds = const ['skipper'],
    String voyageIdOverride = voyageId,
    bool signed = true,
  }) {
    final unsigned = VoyageEvent(
      id: id,
      voyageId: voyageIdOverride,
      deviceId: deviceId,
      type: VoyageEventType.sailorContactShared,
      priority: EventPriority.important,
      createdAt: createdAt ?? sharedAt,
      payload: {
        'contact': {
          'sailorId': sailorId,
          'displayName': displayName,
          'phone': phone,
          'sharedByRole': role.name,
        },
        'recipientSailorIds': ?recipientSailorIds,
      },
      signature: '',
    );
    return VoyageEvent(
      id: unsigned.id,
      voyageId: unsigned.voyageId,
      deviceId: unsigned.deviceId,
      type: unsigned.type,
      priority: unsigned.priority,
      createdAt: unsigned.createdAt,
      payload: unsigned.payload,
      signature: signed
          ? VoyageEventAuthenticator.sign(unsigned, secret)
          : 'f' * 64,
    );
  }

  Map<String, SailorContactShare> reduce(
    List<VoyageEvent> events, {
    String localSailorId = 'skipper',
    DateTime? now,
    Iterable<String> departedSailorIds = const [],
    bool voyageEnded = false,
  }) => const SailorContactShareReducer().fromEvents(
    voyageId: voyageId,
    inviteSecret: secret,
    events: events,
    localSailorId: localSailorId,
    now: now ?? sharedAt.add(const Duration(minutes: 1)),
    departedSailorIds: departedSailorIds,
    voyageEnded: voyageEnded,
  );

  group('who a number reaches', () {
    test('an addressed share reaches its recipient', () {
      final result = reduce([
        share(recipientSailorIds: const ['skipper', 'sweeper']),
      ]);

      expect(result.keys, ['bill']);
      expect(result['bill']!.phoneNumber, '+44 7700 900321');
      expect(result['bill']!.displayName, 'Bill');
      expect(result['bill']!.toVoyageGroup, isFalse);
    });

    test("a non-recipient's journal holds the event but never the "
        'number', () {
      final events = [
        share(recipientSailorIds: const ['skipper', 'sweeper']),
      ];

      // The relay is voyage-scoped, so an ordinary sailor's phone can receive the
      // event. What must never happen is the number becoming *available* to
      // them: the one reducer every surface reads yields nothing at all.
      expect(reduce(events, localSailorId: 'ordinary-sailor'), isEmpty);
      expect(reduce(events, localSailorId: 'another-sailor'), isEmpty);
      expect(reduce(events, localSailorId: 'sweeper').keys, ['bill']);
    });

    test('a coordination role publishes to the voyage, so a stopped sailor can '
        'reach them', () {
      // The case in the original request: a sailor who has stopped needs the
      // skipper's number, and a contact for the role is useless addressed only
      // to the other role-holder.
      final result = reduce([
        share(
          deviceId: 'skipper',
          sailorId: 'skipper',
          displayName: 'Oliver',
          role: VoyageRole.lead,
          recipientSailorIds: null,
        ),
      ], localSailorId: 'ordinary-sailor');

      expect(result['skipper']!.toVoyageGroup, isTrue);
      expect(result['skipper']!.sharedByRole, VoyageRole.lead);
    });

    test('a malformed recipient list fails closed rather than reading as '
        'voyage-wide', () {
      final malformed = VoyageEvent(
        id: 'malformed',
        voyageId: voyageId,
        deviceId: 'bill',
        type: VoyageEventType.sailorContactShared,
        priority: EventPriority.important,
        createdAt: sharedAt,
        payload: const {
          'contact': {
            'sailorId': 'bill',
            'displayName': 'Bill',
            'phone': '+44 7700 900321',
          },
          'recipientSailorIds': 'skipper',
        },
        signature: '',
      );
      final signed = VoyageEvent(
        id: malformed.id,
        voyageId: malformed.voyageId,
        deviceId: malformed.deviceId,
        type: malformed.type,
        priority: malformed.priority,
        createdAt: malformed.createdAt,
        payload: malformed.payload,
        signature: VoyageEventAuthenticator.sign(malformed, secret),
      );

      expect(reduce([signed]), isEmpty);
      expect(
        SailorContactShareReducer.isAddressedTo(signed, 'skipper'),
        isFalse,
      );
    });
  });

  group('what the reducer refuses', () {
    test('an unsigned or forged event', () {
      expect(reduce([share(signed: false)]), isEmpty);
    });

    test('a number planted on another sailor', () {
      expect(reduce([share(deviceId: 'mallory', sailorId: 'bill')]), isEmpty);
    });

    test("the local sailor's own share, so nobody is offered a control to "
        'ring themselves', () {
      expect(
        reduce([
          share(deviceId: 'skipper', sailorId: 'skipper'),
        ], localSailorId: 'skipper'),
        isEmpty,
      );
    });

    test('a share from a sailor who has left', () {
      expect(reduce([share()], departedSailorIds: const ['bill']), isEmpty);
    });

    test('a share past its lifetime, on the client as well as the '
        'relay', () {
      expect(
        reduce([share()], now: sharedAt.add(sailorContactShareLifetime)),
        isEmpty,
      );
      expect(
        reduce(
          [share()],
          now: sharedAt.add(
            sailorContactShareLifetime - const Duration(minutes: 1),
          ),
        ),
        isNotEmpty,
      );
    });

    test('every share once the voyage has ended', () {
      expect(reduce([share()], voyageEnded: true), isEmpty);
    });

    test('an event from another voyage', () {
      expect(
        reduce([share(voyageIdOverride: 'someone-elses-voyage')]),
        isEmpty,
      );
    });

    test('a number the phone cannot dial', () {
      for (final rejected in [
        'tel:+447700900321',
        '+44 7700 900321?body=hi',
        'ring me on the mobile',
        '',
        '12',
        'sms:07700900321',
        '+44 7700 900321\nx',
      ]) {
        expect(reduce([share(phone: rejected)]), isEmpty, reason: rejected);
      }
    });

    test('the latest share per sailor wins', () {
      final result = reduce([
        share(id: 'old', phone: '+44 7700 900111'),
        share(
          id: 'new',
          phone: '+44 7700 900222',
          createdAt: sharedAt.add(const Duration(seconds: 30)),
        ),
      ]);

      expect(result['bill']!.phoneNumber, '+44 7700 900222');
      expect(result['bill']!.eventId, 'new');
    });
  });

  group('the recipient rule', () {
    test('an ordinary sailor addresses the skipper and TEC, and nobody '
        'else', () {
      final recipients = SailorContactRecipients.resolve(
        localRole: VoyageRole.sailor,
        skipperSailorId: 'skipper',
        sweeperSailorIds: const ['sweeper-a', 'sweeper-b'],
      );

      expect(recipients.toVoyageGroup, isFalse);
      expect(recipients.sailorIds, ['skipper', 'sweeper-a', 'sweeper-b']);
      expect(recipients.isEmpty, isFalse);
    });

    test('a sailor with no skipper and no TEC has nobody to share with', () {
      final recipients = SailorContactRecipients.resolve(
        localRole: VoyageRole.sailor,
        skipperSailorId: null,
        sweeperSailorIds: const [],
      );

      expect(recipients.isEmpty, isTrue);
    });

    for (final role in [VoyageRole.lead, VoyageRole.sweeper]) {
      test('a ${role.name} offers theirs to the voyage', () {
        final recipients = SailorContactRecipients.resolve(
          localRole: role,
          skipperSailorId: null,
          sweeperSailorIds: const [],
        );

        expect(recipients.toVoyageGroup, isTrue);
        expect(recipients.isEmpty, isFalse);
      });
    }

    test('the payload names its recipients, and omits the key entirely for a '
        'voyage-wide share', () {
      final contact = SailorContactShare(
        eventId: '',
        sailorId: 'bill',
        displayName: 'Bill',
        phoneNumber: '+44 7700 900321',
        sharedAt: sharedAt,
        sharedByRole: VoyageRole.sailor,
        toVoyageGroup: false,
      );

      final addressed = SailorContactShareReducer.payload(
        share: contact,
        recipients: const SailorContactRecipients.addressed([
          'skipper',
          'skipper',
          'sweeper',
        ]),
      );
      final voyageWide = SailorContactShareReducer.payload(
        share: contact,
        recipients: const SailorContactRecipients.voyageGroup(),
      );

      expect(addressed['recipientSailorIds'], ['skipper', 'sweeper']);
      expect(voyageWide.containsKey('recipientSailorIds'), isFalse);
      // The payload carries the number and nothing else personal: no ICE
      // contact, no medical notes, no position.
      expect((addressed['contact'] as Map).keys, {
        'sailorId',
        'displayName',
        'phone',
        'sharedByRole',
      });
    });
  });

  group('a dialable number', () {
    test('keeps exactly what the sailor typed', () {
      for (final accepted in [
        '+44 7700 900321',
        '07700900321',
        '(01234) 567890',
        '+1 555-0100',
        '  +44 7700 900321  ',
      ]) {
        final normalised = SailorContactShare.normalisePhoneNumber(accepted);
        expect(normalised, accepted.trim(), reason: accepted);
      }
    });

    test('never carries a scheme, a query or free text into a tel: URI', () {
      for (final rejected in [
        'tel:07700900321',
        '07700900321?body=x',
        '07700900321&x=1',
        '07700900321#1',
        'call the skipper',
        '07700900321,,123',
        '+',
        '0770 <b>0900321</b>',
      ]) {
        expect(
          SailorContactShare.normalisePhoneNumber(rejected),
          isNull,
          reason: rejected,
        );
      }
    });

    test('is bounded in length so it cannot be used as a message channel', () {
      expect(SailorContactShare.normalisePhoneNumber('0' * 25), isNull);
      expect(SailorContactShare.normalisePhoneNumber('0' * 24), isNotNull);
    });
  });
}
