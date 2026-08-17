import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../domain/event_store.dart';
import '../domain/voyage_event.dart';

class SqliteEventStore implements EventStore {
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
      path.join(databasePath, 'ride_relay_v1.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE voyage_events (
            id TEXT PRIMARY KEY,
            voyage_id TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            acknowledged INTEGER NOT NULL DEFAULT 0,
            body TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE INDEX voyage_events_voyage_created_idx
          ON voyage_events (voyage_id, created_at)
        ''');
        await db.execute('''
          CREATE INDEX voyage_events_pending_idx
          ON voyage_events (voyage_id, acknowledged, created_at)
        ''');
      },
    );
    _database = database;
    _opening = null;
    return database;
  }

  @override
  Future<void> append(VoyageEvent event) async {
    final db = await _db;
    await db.insert('voyage_events', {
      'id': event.id,
      'voyage_id': event.voyageId,
      'created_at': event.createdAt.millisecondsSinceEpoch,
      'acknowledged': event.acknowledged ? 1 : 0,
      'body': jsonEncode(event.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
  Future<void> deleteVoyage(String voyageId) async {
    final db = await _db;
    await db.delete(
      'voyage_events',
      where: 'voyage_id = ?',
      whereArgs: [voyageId],
    );
  }

  @override
  Future<void> deleteEvents(String voyageId, Iterable<String> eventIds) async {
    final ids = eventIds.toList(growable: false);
    if (ids.isEmpty) return;
    final db = await _db;
    await db.delete(
      'voyage_events',
      where:
          'voyage_id = ? AND id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: [voyageId, ...ids],
    );
  }

  @override
  Future<List<VoyageEvent>> eventsForVoyage(String voyageId) async {
    final db = await _db;
    final rows = await db.query(
      'voyage_events',
      where: 'voyage_id = ?',
      whereArgs: [voyageId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_decodeRow).toList(growable: false);
  }

  @override
  Future<void> markAcknowledged(String eventId) async {
    final db = await _db;
    await db.update(
      'voyage_events',
      {'acknowledged': 1},
      where: 'id = ?',
      whereArgs: [eventId],
    );
  }

  @override
  Future<List<VoyageEvent>> pendingEvents(String voyageId) async {
    final db = await _db;
    final rows = await db.query(
      'voyage_events',
      where: 'voyage_id = ? AND acknowledged = 0',
      whereArgs: [voyageId],
      orderBy: 'created_at ASC',
    );
    return rows.map(_decodeRow).toList(growable: false);
  }

  VoyageEvent _decodeRow(Map<String, Object?> row) {
    final event = VoyageEvent.fromJson(
      Map<String, Object?>.from(jsonDecode(row['body']! as String) as Map),
    );
    return event.copyWith(acknowledged: row['acknowledged'] == 1);
  }
}
