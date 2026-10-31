import 'package:drift/drift.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:immich_mobile/data/db/watch/database.drift.dart';
import 'package:immich_mobile/data/db/watch/table/watch_progress.dart';
import 'package:sqlite_async/sqlite_async.dart';

/// The database of the watch progress (see WatchProgressStore), a file of its own, `immuch_watch.sqlite`, next to the
/// main one: not a table of the main schema, whose versions are upstream's (a version of ours would collide with their
/// next one), and which logging out or Clear database wipes (Drift.reset). The logs and the library of the computers
/// have their own file the same way.
@DriftDatabase(tables: [WatchProgressEntity])
class DriftWatch extends $DriftWatch {
  DriftWatch.fromExecutor(super.executor);

  DriftWatch.sqlite(SqliteConnection db) : super(SqliteAsyncDriftConnection(db));

  /// The name of its file, without the extension
  static const fileName = 'immuch_watch';

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      await customStatement('PRAGMA synchronous = NORMAL');
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA busy_timeout = 30000');
    },
  );
}
