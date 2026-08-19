import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';

/// #49. `lead` is the road group-riding role this app was scaffolded from; on a
/// boat it is the skipper, and the marine glyph set already said so, which left
/// the icon and the role beside it disagreeing on screen.
///
/// Renaming an enum whose `.name` is written into saved sessions, completed
/// voyages, relay payloads and push registrations is the part that can lose a
/// sailor's passage, so most of this file is about what happens to what earlier
/// builds already wrote.
void main() {
  group('what a person reads', () {
    test('the skipper is called the skipper', () {
      expect(VoyageRole.skipper.label, 'Skipper');
    });

    test('no role is still labelled for a road group', () {
      expect(
        VoyageRole.values.map((role) => role.label),
        isNot(contains('Lead')),
      );
    });
  });

  group('reading what earlier builds wrote', () {
    test('a stored "lead" reads as the skipper', () {
      expect(VoyageRoleWire.tryParse('lead'), VoyageRole.skipper);
      expect(VoyageRoleWire.parse('lead'), VoyageRole.skipper);
    });

    test('every current role round-trips through its wire name', () {
      for (final role in VoyageRole.values) {
        expect(
          VoyageRoleWire.tryParse(role.wireName),
          role,
          reason: '${role.name} should survive a write and a read',
        );
      }
    });

    test('an unknown role is absent rather than fatal', () {
      // A payload from a newer build must degrade to "no role stated" instead
      // of taking the voyage down with it.
      expect(VoyageRoleWire.tryParse('navigator'), isNull);
      expect(VoyageRoleWire.tryParse(''), isNull);
      expect(VoyageRoleWire.tryParse(null), isNull);
    });

    test('parse refuses an unknown role rather than guessing one', () {
      expect(
        () => VoyageRoleWire.parse('navigator'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('a session saved before the rename still restores', () {
    // The failure this guards against is not abstract: `values.byName('lead')`
    // throws, restore catches it, and the sailor is shown "Could not restore
    // your saved voyage" with the passage gone.
    test('a stored session carrying "lead" comes back as the skipper', () {
      final session = VoyageSession.fromJson({
        ..._session().toJson(),
        'role': 'lead',
      });

      expect(session.role, VoyageRole.skipper);
    });

    test('a session written now says skipper on the wire', () {
      expect(_session().toJson()['role'], 'skipper');
    });
  });
}

VoyageSession _session() => VoyageSession(
  voyageId: 'v1',
  voyageCode: '123456',
  inviteSecret: 'secret',
  joinToken: 'token',
  localSailorId: 's1',
  displayName: 'Oliver',
  role: VoyageRole.skipper,
  joinedAt: DateTime.utc(2026, 8, 19),
);
