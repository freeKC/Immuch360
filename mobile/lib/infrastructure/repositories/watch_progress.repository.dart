import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/watch/database.dart';
import 'package:immich_mobile/data/db/watch/table/watch_progress.drift.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:logging/logging.dart';
import 'package:sqlite3/common.dart';

final _log = Logger('WatchProgress');

/// Past this many videos, the rows written first go at the next start of the app
const watchProgressMaxRows = 5000;

/// Opens the database of the watch progress in the folder of the databases (see DriftWatch), made again when it is
/// damaged, as the logs are: what it held is lost, the videos then start from the beginning
Future<DriftWatch> openWatchDatabase() async {
  Future<DriftWatch> open() async => DriftWatch.sqlite(await openSqliteConnection(name: DriftWatch.fileName));

  final db = await open();
  try {
    await db.customSelect('SELECT COUNT(*) FROM watch_progress').get();
  } on SqliteException catch (error) {
    await db.close();
    if (error.resultCode != SqlError.SQLITE_CORRUPT && error.resultCode != SqlError.SQLITE_NOTADB) {
      rethrow;
    }
    _log.warning('The database of the watch progress is damaged, made again');
    await deleteSqliteDatabase(name: DriftWatch.fileName);
    return open();
  }
  return db;
}

/// The rows of the watch progress in their database, opened with [open] at the first call. A database that cannot open
/// or write is logged and leaves the rows to memory (see WatchProgressStore): nothing is thrown, the app goes on.
class WatchProgressRepository {
  WatchProgressRepository(this._open);

  final Future<DriftWatch> Function() _open;
  Future<DriftWatch?>? _db;

  Future<DriftWatch?> get _database => _db ??= _open().then<DriftWatch?>((db) => db).catchError((Object error) {
    _log.warning('The watch progress is kept in memory only: $error');
    return null;
  });

  /// Every row, once the oldest beyond [maxRows] are deleted
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async {
    final db = await _database;
    if (db == null) {
      return const [];
    }
    try {
      final table = db.watchProgressEntity;
      final count = await table.count().getSingle();
      if (count > maxRows) {
        final oldest = table.selectOnly()
          ..addColumns([table.mediaKey])
          ..orderBy([OrderingTerm.asc(table.updatedAt)])
          ..limit(count - maxRows);
        await (db.delete(table)..where((row) => row.mediaKey.isInQuery(oldest))).go();
      }
      final rows = await table.select().get();
      return [for (final row in rows) _toModel(row)];
    } catch (error, stackTrace) {
      _log.warning('Could not read the watch progress', error, stackTrace);
      return const [];
    }
  }

  /// Writes [row], in place of the one of its key
  Future<void> upsert(WatchProgress row) async {
    final db = await _database;
    if (db == null) {
      return;
    }
    try {
      await db.watchProgressEntity.insertOnConflictUpdate(
        WatchProgressEntityCompanion.insert(
          mediaKey: row.key,
          positionMs: row.position.inMilliseconds,
          durationMs: row.duration.inMilliseconds,
          watched: row.watched,
          updatedAt: row.updatedAt.toUtc().millisecondsSinceEpoch,
          fingerprint: Value(row.fingerprint),
        ),
      );
    } catch (error, stackTrace) {
      _log.warning('Could not write the watch progress of ${row.key}', error, stackTrace);
    }
  }

  /// Deletes the row of [key], if any
  Future<void> delete(String key) async {
    final db = await _database;
    if (db == null) {
      return;
    }
    try {
      await (db.delete(db.watchProgressEntity)..where((row) => row.mediaKey.equals(key))).go();
    } catch (error, stackTrace) {
      _log.warning('Could not delete the watch progress of $key', error, stackTrace);
    }
  }

  Future<void> close() async {
    final db = await _db;
    await db?.close();
  }

  static WatchProgress _toModel(WatchProgressEntityData row) => WatchProgress(
    key: row.mediaKey,
    position: Duration(milliseconds: row.positionMs),
    duration: Duration(milliseconds: row.durationMs),
    watched: row.watched,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt, isUtc: true),
    fingerprint: row.fingerprint,
  );
}
