import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tide_and_seek/controllers/observer_access_controller.dart';
import 'package:tide_and_seek/data/observer_grant_store.dart';
import 'package:tide_and_seek/domain/voyage_role.dart';
import 'package:tide_and_seek/domain/voyage_session.dart';
import 'package:tide_and_seek/internet/internet_relay_client.dart';
import 'package:tide_and_seek/internet/observer_access_client.dart';

void main() {
  test('secure credentials survive a controller restart', () async {
    final store = _MemoryObserverGrantStore();
    final firstApi = _FakeObserverApi();
    final first = ObserverAccessController(firstApi, store, clock: _clock);
    await first.attach(_session);
    await first.create(
      label: 'Home contact',
      duration: const Duration(hours: 4),
    );

    expect(first.latestInvite?.shareUri.fragment, contains('ro1_'));
    expect(store.saved[_session.voyageId], hasLength(1));

    final restarted = ObserverAccessController(
      _FakeObserverApi(),
      store,
      clock: _clock,
    );
    await restarted.attach(_session);
    expect(restarted.grants.single.label, 'Home contact');
  });

  test(
    'rapid locations coalesce to one in-flight and one latest snapshot',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(delayFirstPublish: true);
      final controller = ObserverAccessController(
        api,
        store,
        clock: _clock,
        publishInterval: Duration.zero,
      );
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );

      controller.publishSnapshot(_snapshot(0));
      await api.firstPublishStarted.future;
      for (var index = 1; index < 100; index += 1) {
        controller.publishSnapshot(_snapshot(index));
      }
      api.releaseFirstPublish.complete();
      await controller.waitForPendingPublishes();

      expect(api.published, hasLength(2));
      expect(api.published.last.position?.latitude, 99);
    },
  );

  test(
    'delayed unavailable publish cannot erase a concurrently created grant',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(
        delayFirstPublish: true,
        failFirstPublishUnavailable: true,
      );
      final controller = ObserverAccessController(api, store, clock: _clock);
      await controller.attach(_session);
      await controller.create(
        label: 'First',
        duration: const Duration(hours: 4),
      );

      controller.publishSnapshot(_snapshot(1));
      await api.firstPublishStarted.future;
      await controller.create(
        label: 'Second',
        duration: const Duration(hours: 4),
      );
      api.releaseFirstPublish.complete();
      await controller.waitForPendingPublishes();

      expect(controller.grants.map((grant) => grant.label), ['Second']);
      expect(store.saved[_session.voyageId]?.single.grant.label, 'Second');
    },
  );

  test(
    'snapshot generation time remains monotonic when the clock stalls',
    () async {
      final controller = ObserverAccessController(
        _FakeObserverApi(),
        _MemoryObserverGrantStore(),
        clock: _clock,
      );
      final first = controller.nextSnapshotGeneratedAt();
      final second = controller.nextSnapshotGeneratedAt();
      expect(second.isAfter(first), isTrue);
    },
  );

  test('delayed publish cannot restore a concurrently revoked grant', () async {
    final store = _MemoryObserverGrantStore();
    final api = _FakeObserverApi(delayFirstPublish: true);
    final controller = ObserverAccessController(api, store, clock: _clock);
    await controller.attach(_session);
    await controller.create(label: 'Home', duration: const Duration(hours: 4));

    controller.publishSnapshot(_snapshot(1));
    await api.firstPublishStarted.future;
    await controller.revoke('grant-1');
    api.releaseFirstPublish.complete();
    await controller.waitForPendingPublishes();

    expect(controller.grants, isEmpty);
    expect(store.saved[_session.voyageId], isNull);
  });

  test('routine fast samples are rate bounded and latest wins', () async {
    final store = _MemoryObserverGrantStore();
    final api = _FakeObserverApi();
    final controller = ObserverAccessController(api, store, clock: _clock);
    await controller.attach(_session);
    await controller.create(label: 'Home', duration: const Duration(hours: 4));

    for (var index = 0; index < 100; index += 1) {
      controller.publishSnapshot(_snapshot(index, routine: true));
    }
    await controller.waitForPendingPublishes();
    expect(api.published, hasLength(1));

    await controller.flushPendingSnapshot();
    expect(api.published, hasLength(2));
    expect(api.published.last.position?.latitude, 99);
  });

  test(
    'stationary critical snapshot retries after a transient failure',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(failFirstPublishRetryable: true);
      final controller = ObserverAccessController(api, store, clock: _clock);
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );
      final critical = _snapshot(1);

      controller.publishSnapshot(critical);
      await controller.waitForPendingPublishes();
      expect(api.published, [critical]);

      await controller.flushPendingSnapshot();
      expect(api.published, [critical, critical]);
    },
  );

  test(
    'local assistance and its explicit resolution survive restart',
    () async {
      final store = _MemoryObserverGrantStore();
      final controller = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );
      await controller.recordLocalAssistance('assistance');

      final restarted = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await restarted.attach(_session);
      expect(restarted.localAssistance?.kind, 'assistance');

      await restarted.recordLocalAssistance(null);
      final afterResolution = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await afterResolution.attach(_session);
      expect(afterResolution.localAssistance, isNull);
      expect(
        afterResolution.localAssistanceUpdatedAt.isAfter(
          DateTime.utc(2026, 7, 24, 13),
        ),
        isTrue,
      );
    },
  );

  test(
    'personal and group grants receive only their scoped snapshot',
    () async {
      final api = _FakeObserverApi();
      final controller = ObserverAccessController(
        api,
        _MemoryObserverGrantStore(),
        clock: _clock,
        publishInterval: Duration.zero,
      );
      await controller.attach(_session);
      await controller.create(
        label: 'Personal',
        duration: const Duration(hours: 1),
      );
      await controller.create(
        label: 'Group',
        duration: const Duration(hours: 1),
        scope: ObserverAccessScope.group,
      );
      final sailor = _snapshot(1);
      final group = ObserverPublishedSnapshot(
        scope: ObserverAccessScope.group,
        subjectName: 'Group voyage',
        snapshotGeneratedAt: sailor.snapshotGeneratedAt,
        voyageStatus: 'active',
        statusUpdatedAt: sailor.statusUpdatedAt,
        assistanceUpdatedAt: sailor.assistanceUpdatedAt,
        participants: const [
          ObserverPublishedGroupParticipant(
            displayName: 'Oliver',
            role: 'lead',
            color: '#B58CFF',
          ),
        ],
      );

      controller.publishSnapshots(sailor: sailor, group: group);
      await controller.waitForPendingPublishes();

      expect(api.published, hasLength(2));
      expect(
        api.publishedByGrant['grant-1']?.scope,
        ObserverAccessScope.sailor,
      );
      expect(api.publishedByGrant['grant-2']?.scope, ObserverAccessScope.group);
    },
  );
}

DateTime _clock() => DateTime.utc(2026, 7, 24, 13);

final _session = VoyageSession(
  voyageId: 'voyage-observer',
  voyageCode: '123456',
  inviteSecret: 'observer-secret-0123456789012345',
  joinToken: 'join-token-0123456789',
  localSailorId: 'sailor-a',
  displayName: 'Oliver',
  role: VoyageRole.sailor,
  joinedAt: DateTime.utc(2026, 7, 24),
);

ObserverPublishedSnapshot _snapshot(int sequence, {bool routine = false}) {
  final timestamp = DateTime.utc(2026, 7, 24, 12, 0, sequence);
  final componentTimestamp = routine
      ? DateTime.utc(2026, 7, 24, 12)
      : timestamp;
  return ObserverPublishedSnapshot(
    subjectName: 'Oliver',
    snapshotGeneratedAt: timestamp,
    voyageStatus: 'active',
    statusUpdatedAt: componentTimestamp,
    assistanceUpdatedAt: componentTimestamp,
    position: ObserverPublishedPosition(
      latitude: sequence.toDouble(),
      longitude: -1,
      accuracyMeters: 5,
      recordedAt: timestamp,
    ),
  );
}

class _MemoryObserverGrantStore implements ObserverGrantStore {
  final saved = <String, List<ObserverGrantCredentials>>{};
  final assistance = <String, ObserverLocalAssistanceState>{};

  @override
  Future<void> delete(String voyageId) async => saved.remove(voyageId);

  @override
  Future<void> deleteLocalAssistance(String voyageId) async =>
      assistance.remove(voyageId);

  @override
  Future<List<ObserverGrantCredentials>> load(String voyageId) async =>
      List.of(saved[voyageId] ?? const []);

  @override
  Future<ObserverLocalAssistanceState?> loadLocalAssistance(
    String voyageId,
  ) async => assistance[voyageId];

  @override
  Future<void> save(
    String voyageId,
    List<ObserverGrantCredentials> credentials,
  ) async {
    saved[voyageId] = List.of(credentials);
  }

  @override
  Future<void> saveLocalAssistance(
    String voyageId,
    ObserverLocalAssistanceState state,
  ) async => assistance[voyageId] = state;
}

class _FakeObserverApi implements ObserverAccessApi {
  _FakeObserverApi({
    this.delayFirstPublish = false,
    this.failFirstPublishUnavailable = false,
    this.failFirstPublishRetryable = false,
  });

  final bool delayFirstPublish;
  final bool failFirstPublishUnavailable;
  final bool failFirstPublishRetryable;
  final firstPublishStarted = Completer<void>();
  final releaseFirstPublish = Completer<void>();
  final published = <ObserverPublishedSnapshot>[];
  final publishedByGrant = <String, ObserverPublishedSnapshot>{};
  var _nextGrant = 0;

  @override
  final configuration = ObserverAccessConfiguration(
    relay: InternetRelayConfiguration(
      baseUri: Uri.parse('https://relay.example/api'),
    ),
    webBaseUri: Uri.parse('https://relay.example/observer.html'),
  );

  @override
  Future<ObserverGrantCredentials> create(
    VoyageSession session, {
    required String label,
    required Duration duration,
    ObserverAccessScope scope = ObserverAccessScope.sailor,
  }) async {
    _nextGrant += 1;
    return ObserverGrantCredentials(
      grant: ObserverGrant(
        id: 'grant-$_nextGrant',
        label: label,
        createdAt: _clock(),
        expiresAt: _clock().add(duration),
        scope: scope,
      ),
      managementToken: 'om1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      publisherToken: 'op1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      observerToken: 'ro1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
    );
  }

  @override
  Future<ObserverGrant> inspect(ObserverGrantCredentials credentials) async =>
      credentials.grant;

  @override
  Future<void> publish(
    ObserverGrantCredentials credentials,
    ObserverPublishedSnapshot snapshot,
  ) async {
    published.add(snapshot);
    publishedByGrant[credentials.grant.id] = snapshot;
    if (published.length == 1 && failFirstPublishRetryable) {
      throw const InternetRelayException(
        'Temporary outage',
        retryable: true,
        statusCode: 503,
      );
    }
    if (published.length == 1 && delayFirstPublish) {
      firstPublishStarted.complete();
      await releaseFirstPublish.future;
      if (failFirstPublishUnavailable) {
        throw const InternetRelayException('Unavailable', statusCode: 404);
      }
    }
  }

  @override
  Future<void> revoke(ObserverGrantCredentials credentials) async {}

  @override
  Uri shareUri(ObserverGrantCredentials credentials) =>
      configuration.webBaseUri!.replace(
        fragment: '${credentials.grant.id}.${credentials.observerToken}',
      );

  @override
  void close() {}
}
