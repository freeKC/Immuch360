import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/logger/database.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/app/store.drift.dart';
import 'package:immich_mobile/data/db/watch/database.dart';
import 'package:sqlite3_connection_pool/sqlite3_connection_pool.dart';
import 'package:sqlite_async/sqlite_async.dart';

// The databases close their sqlite_async connection with drift, on real SQLite files: a background engine or a worker
// isolate that ends must not leave its connection to the native finalizers, which return its leases while a statement
// isolate may still run on them (the SIGSEGV of the background in sqlite3LocateTable)
void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('immich_db_close');
    path = '${dir.path}/immich.sqlite';
  });

  tearDown(() async => await dir.delete(recursive: true));

  SqliteDatabase openConnection(String file) => SqliteDatabase.withFactory(ImmichSqliteOpenFactory(path: file));

  // Opens the main database as DataController.init does
  Future<(Drift, SqliteDatabase)> openMain() async {
    final connection = openConnection(path);
    await connection.initialize();
    final pool = SqliteConnectionPool.open(
      name: path,
      openConnections: () => throw StateError('the pool is opened by sqlite_async'),
    );
    return (Drift.sqlite(connection, pool), connection);
  }

  group('close()', () {
    test('of the main database closes its sqlite_async connection', () async {
      final (db, connection) = await openMain();
      await db.select(db.storeEntity).get();

      await db.close();

      expect(connection.closed, isTrue);
    });

    test('of the logs database closes its sqlite_async connection', () async {
      final connection = openConnection('${dir.path}/immich_logs.sqlite');
      final db = DriftLogger.sqlite(connection);
      await db.customSelect('SELECT COUNT(*) FROM logger_messages').get();

      await db.close();

      expect(connection.closed, isTrue);
    });

    test('of the watch progress database closes its sqlite_async connection', () async {
      final connection = openConnection('${dir.path}/${DriftWatch.fileName}.sqlite');
      final db = DriftWatch.sqlite(connection);
      await db.customSelect('SELECT COUNT(*) FROM watch_progress').get();

      await db.close();

      expect(connection.closed, isTrue);
    });

    test('waits for an insert left unawaited before it, whose row is in the file afterwards', () async {
      final (db, _) = await openMain();
      final holdsWriter = Completer<void>();

      // Not awaited before close(): the transaction holds the writer when close() starts, and inserts a moment later
      final insert = db.transaction(() async {
        await db.customSelect('SELECT 1').get();
        holdsWriter.complete();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await db.into(db.storeEntity).insert(const StoreEntityCompanion(id: Value(7), intValue: Value(42)));
      });
      await holdsWriter.future;
      await db.close();
      await insert;

      final (reopened, _) = await openMain();
      addTearDown(reopened.close);
      final rows = await reopened.select(reopened.storeEntity).get();
      expect(rows.map((row) => (row.id, row.intValue)), [(7, 42)]);
    });

    test('makes a later query throw instead of reaching a closed connection', () async {
      final (db, connection) = await openMain();
      await db.select(db.storeEntity).get();

      await db.close();

      await expectLater(db.select(db.storeEntity).get(), throwsA(isA<StateError>()));
      await expectLater(connection.getAll('SELECT 1'), throwsA(isA<AbortException>()));
    });

    test('closes this client only: another one of the same file goes on', () async {
      // The UI engine and a background engine of one process are two clients of one native pool
      final (background, _) = await openMain();
      final (ui, _) = await openMain();
      addTearDown(ui.close);
      const row = StoreEntityCompanion(id: Value(1), intValue: Value(1));
      await background.into(background.storeEntity).insert(row);

      await background.close();

      await ui.into(ui.storeEntity).insert(const StoreEntityCompanion(id: Value(2), intValue: Value(2)));
      final rows = await ui.select(ui.storeEntity).get();
      expect(rows.map((row) => row.id), unorderedEquals([1, 2]));
    });
  });

  test('an isolate that exits with a statement in flight leaves the pool to the others', () async {
    // The path of the SIGSEGV of the background: the calling isolate ends while its statement isolate still runs on the
    // leased connection. Up to sqlite_async 0.14.7 its finalizers returned the lease at once, and the next writer used
    // the same connection (opened without a mutex) at the same time.
    final connection = openConnection(path);
    addTearDown(connection.close);
    await connection.execute('CREATE TABLE slow (n INTEGER)');
    await connection.execute('CREATE TABLE writes (n INTEGER)');

    final exited = ReceivePort();
    await Isolate.spawn(_exitWithStatementInFlight, [exited.sendPort, path]);
    expect(await exited.first, 'exiting');

    for (var i = 0; i < 20; i++) {
      await connection.execute('INSERT INTO writes (n) VALUES (?)', [i]);
    }
    final count = await connection.get('SELECT COUNT(*) AS n FROM writes');
    expect(count['n'], 20);
    final check = await connection.get('PRAGMA integrity_check');
    expect(check.values.single, 'ok');
  });
}

/// About a second of work on the writer, in one statement
const _slowWrite =
    'INSERT INTO slow (n) SELECT COUNT(*) FROM '
    '(WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM c WHERE x < 4000000) SELECT x FROM c)';

Future<void> _exitWithStatementInFlight(List<Object> message) async {
  final done = message[0] as SendPort;
  final path = message[1] as String;
  final db = SqliteDatabase.withFactory(ImmichSqliteOpenFactory(path: path));
  // A first statement starts the statement isolate, so that the slow one reaches it at once
  await db.execute('SELECT 1');
  unawaited(db.execute(_slowWrite).then<void>((_) {}, onError: (Object _) {}));
  await Future<void>.delayed(const Duration(milliseconds: 100));
  Isolate.exit(done, 'exiting');
}
