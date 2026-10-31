import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/watch/database.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';

void main() {
  late DriftWatch db;
  late WatchProgressRepository repository;
  final now = DateTime.utc(2026, 10, 31, 9);

  WatchProgress row(String key, {int minutes = 42, bool watched = false, int age = 0, String? fingerprint}) =>
      WatchProgress(
        key: key,
        position: Duration(minutes: minutes),
        duration: const Duration(minutes: 98),
        watched: watched,
        updatedAt: now.subtract(Duration(minutes: age)),
        fingerprint: fingerprint,
      );

  setUpAll(() {
    // A database per test, as the app opens one
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });

  setUp(() {
    db = DriftWatch.fromExecutor(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    repository = WatchProgressRepository(() async => db);
  });

  tearDown(() async {
    await repository.close();
  });

  test('keeps a row and gives it back', () async {
    await repository.upsert(row('asset:a', fingerprint: 'fp:s:1:2'));

    expect(await repository.load(), [row('asset:a', fingerprint: 'fp:s:1:2')]);
  });

  test('a second write of a key replaces its row', () async {
    await repository.upsert(row('asset:a'));
    await repository.upsert(row('asset:a', minutes: 0, watched: true));

    expect(await repository.load(), [row('asset:a', minutes: 0, watched: true)]);
  });

  test('deletes a row', () async {
    await repository.upsert(row('asset:a'));
    await repository.upsert(row('asset:b'));
    await repository.delete('asset:a');

    expect((await repository.load()).map((r) => r.key), ['asset:b']);
  });

  test('the oldest rows beyond the limit go at load', () async {
    for (var index = 0; index < 6; index++) {
      // asset:0 is the oldest
      await repository.upsert(row('asset:$index', age: 6 - index));
    }

    final rows = await repository.load(maxRows: 4);

    expect(rows.map((r) => r.key).toSet(), {'asset:2', 'asset:3', 'asset:4', 'asset:5'});
    expect((await repository.load(maxRows: 10)).length, 4, reason: 'deleted from the file, not only skipped');
  });

  test('the fingerprints are indexed', () async {
    final indexes = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'watch_progress'")
        .get();

    expect(indexes.map((r) => r.read<String>('name')), contains('idx_watch_progress_fingerprint'));
  });

  test('a database that cannot open leaves the rows to memory: nothing is thrown', () async {
    final broken = WatchProgressRepository(() async => throw StateError('no database here'));

    expect(await broken.load(), isEmpty);
    await broken.upsert(row('asset:a'));
    await broken.delete('asset:a');
    await broken.close();
  });
}
