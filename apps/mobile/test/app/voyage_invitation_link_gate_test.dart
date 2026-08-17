import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/app/voyage_invitation_link_gate.dart';
import 'package:tide_and_seek/controllers/voyage_code_preference_controller.dart';
import 'package:tide_and_seek/controllers/voyage_controller.dart';
import 'package:tide_and_seek/controllers/voyage_invitation_link_controller.dart';
import 'package:tide_and_seek/controllers/sailor_profile_controller.dart';
import 'package:tide_and_seek/data/in_memory_event_store.dart';
import 'package:tide_and_seek/data/in_memory_session_store.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/services/nearby_bridge.dart';
import 'package:tide_and_seek/services/voyage_invitation_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'sailor_profile_display_name': 'Sam',
      'sailor_profile_onboarding_completed': true,
    });
  });

  testWidgets(
    'a confirmed link joins through the authenticated directory path',
    (tester) async {
      const token = 'Abcdefghijklmnop12345678';
      final directory = _Directory(
        expectedCode: '123456',
        expectedToken: token,
      );
      final fixture = await _Fixture.create(
        directory: directory,
        link: voyageInvitationUrl('123456', token),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.app);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Join voyage 123456?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('accept-voyage-invitation-link')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(directory.seenToken, token);
      expect(fixture.voyageController.session?.voyageCode, '123456');
      expect(fixture.voyageController.session?.inviteSecret, directory.secret);
      expect(fixture.links.hasNotice, isFalse);
    },
  );

  testWidgets('an invitation cannot silently replace an active voyage', (
    tester,
  ) async {
    final fixture = await _Fixture.create(
      directory: _Directory(
        expectedCode: '654321',
        expectedToken: 'ZYXWVUTSRQPONMLK12345678',
      ),
      link: voyageInvitationUrl('654321', 'ZYXWVUTSRQPONMLK12345678'),
    );
    addTearDown(fixture.dispose);
    await fixture.voyageController.createVoyage('Sam');
    final currentVoyageId = fixture.voyageController.session!.voyageId;

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('A voyage is already open'), findsOneWidget);
    expect(find.textContaining('cannot replace it silently'), findsOneWidget);
    await tester.tap(find.text('Keep current voyage'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.voyageController.session?.voyageId, currentVoyageId);
    expect(fixture.links.hasNotice, isFalse);
  });

  testWidgets('a malformed link explains the problem and does not join', (
    tester,
  ) async {
    final fixture = await _Fixture.create(
      directory: _Directory(
        expectedCode: '123456',
        expectedToken: 'Abcdefghijklmnop12345678',
      ),
      link: 'https://tideandseek.invalid/join.html#broken',
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Cannot open invitation'), findsOneWidget);
    expect(find.textContaining('incomplete or malformed'), findsOneWidget);
    expect(fixture.voyageController.hasActiveVoyage, isFalse);
  });

  testWidgets('an inactive or revoked invitation gets a plain explanation', (
    tester,
  ) async {
    const token = 'Abcdefghijklmnop12345678';
    final fixture = await _Fixture.create(
      directory: const _RejectingDirectory(),
      link: voyageInvitationUrl('123456', token),
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('accept-voyage-invitation-link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Could not join this voyage'), findsOneWidget);
    expect(find.textContaining('no longer active'), findsOneWidget);
    expect(fixture.voyageController.hasActiveVoyage, isFalse);
  });
}

class _Fixture {
  const _Fixture({
    required this.voyageController,
    required this.links,
    required this.profile,
    required this.preference,
  });

  final VoyageController voyageController;
  final VoyageInvitationLinkController links;
  final SailorProfileController profile;
  final VoyageCodePreferenceController preference;

  static Future<_Fixture> create({
    required VoyageCodeDirectory directory,
    required String link,
  }) async {
    final voyageController = VoyageController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      voyageCodeDirectory: directory,
    );
    await voyageController.initialize();
    return _Fixture(
      voyageController: voyageController,
      links: await VoyageInvitationLinkController.load(
        source: _OneLinkSource(link),
      ),
      profile: await SailorProfileController.load(),
      preference: VoyageCodePreferenceController.memory(),
    );
  }

  Widget get app => MaterialApp(
    home: VoyageInvitationLinkGate(
      links: links,
      voyageController: voyageController,
      voyageCodePreference: preference,
      sailorProfile: profile,
      ready: true,
      child: const Scaffold(body: Text('Ready')),
    ),
  );

  void dispose() {
    links.dispose();
    voyageController.dispose();
    profile.dispose();
    preference.dispose();
  }
}

class _OneLinkSource implements IncomingVoyageInvitationLinkSource {
  _OneLinkSource(this.value);

  String? value;

  @override
  Future<String?> consumePending() async {
    final current = value;
    value = null;
    return current;
  }
}

class _Directory implements VoyageCodeDirectory {
  _Directory({required this.expectedCode, required this.expectedToken});

  final String expectedCode;
  final String expectedToken;
  final String secret = 'voyage-secret-abcdefghijklmnop';
  String? seenToken;

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async {
    expect(voyageCode, expectedCode);
    expect(joinToken, expectedToken);
    seenToken = joinToken;
    return VoyageCodeCredentials(
      voyageId: 'voyage-$voyageCode',
      voyageCode: voyageCode,
      inviteSecret: secret,
      joinToken: expectedToken,
    );
  }

  @override
  Future<void> register(VoyageSession session) async {}

  @override
  void close() {}
}

class _RejectingDirectory implements VoyageCodeDirectory {
  const _RejectingDirectory();

  @override
  Future<VoyageCodeCredentials> resolve(
    String voyageCode, {
    String? joinToken,
  }) async => throw const VoyageCodeDirectoryException(
    'That voyage invitation is no longer active. Ask the voyage lead for a new one.',
  );

  @override
  Future<void> register(VoyageSession session) async {}

  @override
  void close() {}
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}
