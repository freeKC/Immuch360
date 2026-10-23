import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_connection_pool/sqlite3_connection_pool.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'generated/schema.dart';
import 'generated/schema_v34.dart' as v34;

// A database whose schema is ahead of its user_version: a build at an older schema opened a database a newer build
// had migrated, and drift wrote the older version while the newer columns stayed. The steps of the migration then run
// again on columns that exist (desktop builds 6 to 8 failed every start on "duplicate column name: group_date")

/// The same app at schema 34, as desktop builds 1 to 3 and the phone builds up to 21 were
class _BuildAtV34 extends Drift {
  _BuildAtV34(super.executor);

  @override
  int get schemaVersion => 34;
}

const _fixture = 'test/drift/main/fixtures/desktop_v35_at_user_version_34.sql';

List<String> _columns(CommonDatabase db, String table) => [
  for (final row in db.select('SELECT name FROM pragma_table_info(?)', [table])) row['name'] as String,
];

void _expectV35(CommonDatabase db) {
  expect(db.userVersion, 35);
  for (final table in ['remote_asset_entity', 'local_asset_entity']) {
    expect(_columns(db, table).where((name) => name == 'group_date'), hasLength(1), reason: table);
  }
  final indexes = db.select("SELECT name FROM sqlite_master WHERE type = 'index'").map((row) => row['name']);
  expect(indexes, containsAll(['idx_remote_asset_group', 'idx_local_asset_group']));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('step 34 to 35 on a database that already has group_date', () {
    test('a build at 34 on a database at 35 writes 34 and keeps the columns, the build at 35 then opens it', () async {
      final schema = await verifier.schemaAt(35);
      final older = _BuildAtV34(schema.newConnection());
      await older.customSelect('SELECT 1').get();
      await older.close();
      expect(schema.rawDatabase.userVersion, 34);
      expect(_columns(schema.rawDatabase, 'remote_asset_entity'), contains('group_date'));

      final db = Drift(schema.newConnection());
      await verifier.migrateAndValidate(db, 35);
      await db.close();
      _expectV35(schema.rawDatabase);
    });

    test('the schema of 35 at user_version 34 keeps its rows', () async {
      final schema = await verifier.schemaAt(35);
      schema.rawDatabase.execute('''
        INSERT INTO user_entity (id, name, email) VALUES ('user-1', 'User', 'user@example.com');
        INSERT INTO remote_asset_entity (id, name, type, checksum, owner_id, visibility, created_at, group_date)
          VALUES ('remote-1', 'r1.jpg', 1, 'c1', 'user-1', 0, '2026-07-24T10:00:00.000Z', '2026-07-24'),
                 ('remote-2', 'r2.jpg', 1, 'c2', 'user-1', 0, '2026-07-25T10:00:00.000Z', NULL);
        INSERT INTO local_asset_entity (id, name, type, created_at, group_date)
          VALUES ('local-1', 'l1.jpg', 1, '2026-07-24T10:00:00.000Z', '2026-07-24'),
                 ('local-2', 'l2.jpg', 1, '2026-07-25T10:00:00.000Z', NULL);
        PRAGMA user_version = 34;
      ''');

      final db = Drift(schema.newConnection());
      await verifier.migrateAndValidate(db, 35);
      await db.close();

      _expectV35(schema.rawDatabase);
      final remote = schema.rawDatabase.select('SELECT id, group_date FROM remote_asset_entity ORDER BY id');
      expect(
        [for (final row in remote) (row['id'], row['group_date'])],
        [('remote-1', '2026-07-24'), ('remote-2', null)],
      );
      final local = schema.rawDatabase.select('SELECT id, group_date FROM local_asset_entity ORDER BY id');
      expect([for (final row in local) (row['id'], row['group_date'])], [('local-1', '2026-07-24'), ('local-2', null)]);
    });

    test('half migrated: only remote_asset_entity has group_date', () async {
      final schema = await verifier.schemaAt(34);
      schema.rawDatabase.execute('ALTER TABLE "remote_asset_entity" ADD COLUMN "group_date" TEXT NULL;');

      final db = Drift(schema.newConnection());
      await verifier.migrateAndValidate(db, 35);
      await db.close();
      _expectV35(schema.rawDatabase);
    });
  });

  // The connection of the app (sqlite_async, its pool and pragmas), where the start failed
  group('through the sqlite_async connection of the app', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('immich_migration_rerun');
      path = '${dir.path}/immich.sqlite';
    });

    tearDown(() async => await dir.delete(recursive: true));

    // Opens the database as DataController.init does and reads the store, the first query of a start
    Future<void> start() async {
      final connection = SqliteDatabase.withFactory(ImmichSqliteOpenFactory(path: path));
      await connection.initialize();
      final pool = SqliteConnectionPool.open(
        name: path,
        openConnections: () => throw StateError('the pool is opened by sqlite_async'),
      );
      final db = Drift.sqlite(connection, pool);
      try {
        await db.select(db.storeEntity).get();
      } finally {
        await db.close();
        await connection.close();
      }
    }

    test('the database of the fixture opens and ends at 35', () async {
      final raw = sqlite3.open(path);
      raw.execute(File(_fixture).readAsStringSync());
      raw.execute('PRAGMA journal_mode = WAL');
      expect(raw.userVersion, 34);
      raw.close();

      await start();

      final after = sqlite3.open(path);
      addTearDown(after.close);
      _expectV35(after);
      expect(after.select('PRAGMA integrity_check').single.values.single, 'ok');
    });

    test('a step that fails leaves no column of the migration behind', () async {
      final old = v34.DatabaseAtV34(NativeDatabase(File(path)));
      await old.customStatement('PRAGMA journal_mode = WAL');
      await old.close();
      // A table holding the name of the last index of step 34 to 35 makes that statement fail
      final raw = sqlite3.open(path);
      raw.execute('CREATE TABLE idx_local_asset_group (id INTEGER)');
      expect(raw.userVersion, 34);
      raw.close();

      await expectLater(start(), throwsA(predicate((error) => '$error'.contains('idx_local_asset_group'))));

      final after = sqlite3.open(path);
      addTearDown(after.close);
      expect(after.userVersion, 34);
      expect(_columns(after, 'remote_asset_entity'), isNot(contains('group_date')));
      expect(_columns(after, 'local_asset_entity'), isNot(contains('group_date')));
    });
  });
}
