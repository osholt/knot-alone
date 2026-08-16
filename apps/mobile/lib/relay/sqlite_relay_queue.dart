import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/ride_event.dart';
import 'relay_queue.dart';

class SqliteRelayQueue implements RelayQueueStore {
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get _db {
    final database = _database;
    if (database != null) {
      return Future.value(database);
    }
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final databasePath = await getDatabasesPath();
    final database = await openDatabase(
      path.join(databasePath, 'ride_relay_transport_v1.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE relay_queue (
            event_id TEXT PRIMARY KEY,
            ride_id TEXT NOT NULL,
            priority INTEGER NOT NULL,
            first_seen_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            hop_count INTEGER NOT NULL,
            acknowledged_peers TEXT NOT NULL,
            event_body TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX relay_queue_pending_idx
          ON relay_queue (ride_id, expires_at, priority, first_seen_at)
        ''');
      },
    );
    _database = database;
    _opening = null;
    return database;
  }

  @override
  Future<void> acknowledge(String peerId, Iterable<String> eventIds) async {
    final db = await _db;
    await db.transaction((transaction) async {
      for (final eventId in eventIds.toSet()) {
        final rows = await transaction.query(
          'relay_queue',
          columns: ['acknowledged_peers'],
          where: 'event_id = ?',
          whereArgs: [eventId],
          limit: 1,
        );
        if (rows.isEmpty) {
          continue;
        }
        final peers = Set<String>.from(
          (jsonDecode(rows.single['acknowledged_peers']! as String) as List)
              .cast<String>(),
        )..add(peerId);
        await transaction.update(
          'relay_queue',
          {'acknowledged_peers': jsonEncode(peers.toList()..sort())},
          where: 'event_id = ?',
          whereArgs: [eventId],
        );
      }
    });
  }

  @override
  Future<void> close() async {
    final database = _database;
    _database = null;
    if (database != null) {
      await database.close();
    }
  }

  @override
  Future<bool> contains(String eventId) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      columns: ['event_id'],
      where: 'event_id = ?',
      whereArgs: [eventId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<int> count(String rideId, {required DateTime now}) async {
    final db = await _db;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM relay_queue '
      'WHERE ride_id = ? AND expires_at > ?',
      [rideId, now.millisecondsSinceEpoch],
    );
    return (result.single['count']! as num).toInt();
  }

  @override
  Future<void> enqueue(QueuedRelayEvent item) async {
    final db = await _db;
    await db.insert('relay_queue', {
      'event_id': item.event.id,
      'ride_id': item.event.rideId,
      'priority': item.event.priority.index,
      'first_seen_at': item.firstSeenAt.millisecondsSinceEpoch,
      'expires_at': item.expiresAt.millisecondsSinceEpoch,
      'hop_count': item.hopCount,
      'acknowledged_peers': jsonEncode(item.acknowledgedPeers.toList()..sort()),
      'event_body': jsonEncode(item.event.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<List<QueuedRelayEvent>> pendingForPeer(
    String rideId,
    String peerId, {
    required DateTime now,
    required int limit,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'relay_queue',
      where: 'ride_id = ? AND expires_at > ? AND hop_count < ?',
      whereArgs: [rideId, now.millisecondsSinceEpoch, maxRelayHops],
      orderBy: 'priority DESC, first_seen_at ASC',
    );
    return rows
        .map(_decode)
        .where((item) => !item.acknowledgedPeers.contains(peerId))
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> prune({required DateTime now, required int maxItems}) async {
    final db = await _db;
    var deleted = await db.delete(
      'relay_queue',
      where: 'expires_at <= ?',
      whereArgs: [now.millisecondsSinceEpoch],
    );
    final keepRows = await db.query(
      'relay_queue',
      columns: ['event_id'],
      orderBy: 'priority DESC, first_seen_at DESC',
      limit: maxItems,
    );
    final keep = keepRows.map((row) => row['event_id']! as String).toList();
    final countResult = await db.rawQuery(
      'SELECT COUNT(*) AS count FROM relay_queue',
    );
    final count = (countResult.single['count']! as num).toInt();
    if (count > keep.length && keep.isNotEmpty) {
      final placeholders = List.filled(keep.length, '?').join(',');
      deleted += await db.delete(
        'relay_queue',
        where: 'event_id NOT IN ($placeholders)',
        whereArgs: keep,
      );
    }
    return deleted;
  }

  QueuedRelayEvent _decode(Map<String, Object?> row) => QueuedRelayEvent(
    event: RideEvent.fromJson(
      Map<String, Object?>.from(
        jsonDecode(row['event_body']! as String) as Map,
      ),
    ),
    firstSeenAt: DateTime.fromMillisecondsSinceEpoch(
      row['first_seen_at']! as int,
    ),
    expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at']! as int),
    hopCount: row['hop_count']! as int,
    acknowledgedPeers: Set<String>.from(
      (jsonDecode(row['acknowledged_peers']! as String) as List).cast<String>(),
    ),
  );
}
