import 'package:drift/drift.dart';

/// Where a video was left, one row per video (see WatchProgress and WatchKey), in the database of the watch progress
/// (see DriftWatch): the position and the duration in milliseconds, whether it was watched, when the row was last
/// written (milliseconds since the epoch, for the pruning of the oldest), and the fingerprint of a file of a share
@TableIndex.sql('CREATE INDEX IF NOT EXISTS idx_watch_progress_fingerprint ON watch_progress (fingerprint)')
class WatchProgressEntity extends Table {
  const WatchProgressEntity();

  @override
  String get tableName => 'watch_progress';

  TextColumn get mediaKey => text().named('key')();
  IntColumn get positionMs => integer()();
  IntColumn get durationMs => integer()();
  BoolColumn get watched => boolean()();
  IntColumn get updatedAt => integer()();
  TextColumn get fingerprint => text().nullable()();

  @override
  Set<Column> get primaryKey => {mediaKey};
}
