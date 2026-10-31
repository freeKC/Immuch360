import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// The rows in memory, as the database would keep them, with the writes in the order they came; [gate] holds the load
class _MemoryRepository implements WatchProgressRepository {
  _MemoryRepository([Iterable<WatchProgress> rows = const []]) : rows = {for (final row in rows) row.key: row};

  final Map<String, WatchProgress> rows;
  final writes = <String>[];
  Completer<void>? gate;
  Completer<void>? writeGate;

  @override
  Future<List<WatchProgress>> load({int maxRows = watchProgressMaxRows}) async {
    await gate?.future;
    return rows.values.toList();
  }

  @override
  Future<void> upsert(WatchProgress row) async {
    await writeGate?.future;
    rows[row.key] = row;
    writes.add('upsert ${row.key} ${row.position.inMinutes}${row.watched ? ' watched' : ''}');
  }

  @override
  Future<void> delete(String key) async {
    await writeGate?.future;
    rows.remove(key);
    writes.add('delete $key');
  }

  @override
  Future<void> close() async {}
}

void main() {
  const minute = Duration(minutes: 1);
  const film = Duration(minutes: 98);
  final now = DateTime.utc(2026, 10, 31, 9);

  WatchProgress row(String key, {int minutes = 42, bool watched = false, String? fingerprint}) => WatchProgress(
    key: key,
    position: Duration(minutes: minutes),
    duration: film,
    watched: watched,
    updatedAt: now,
    fingerprint: fingerprint,
  );

  ProviderContainer containerWith(_MemoryRepository repository) {
    final container = ProviderContainer(
      overrides: [
        watchProgressRepositoryProvider.overrideWithValue(repository),
        watchProgressClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<WatchProgressStore> loaded(ProviderContainer container) async {
    final store = container.read(watchProgressProvider.notifier);
    await store.loaded;
    return store;
  }

  test('loads the rows of the database once', () async {
    final container = containerWith(_MemoryRepository([row('asset:a')]));

    final store = await loaded(container);

    expect(store.find(const WatchKey('asset:a')), row('asset:a'));
    expect(container.read(watchProgressProvider).find(const WatchKey('asset:b')), isNull);
  });

  test('a save shows at once and goes to the database', () async {
    final repository = _MemoryRepository();
    final container = containerWith(repository);
    final store = await loaded(container);

    store.record(const WatchKey('asset:a'), position: minute * 42, duration: film);

    expect(container.read(watchProgressProvider).find(const WatchKey('asset:a'))?.position, minute * 42);
    await store.flushed;
    expect(repository.rows['asset:a']?.position, minute * 42);
  });

  test('a save in the last two minutes marks the film watched, from 0 next time', () async {
    final container = containerWith(_MemoryRepository());
    final store = await loaded(container);

    store.record(const WatchKey('asset:a'), position: film - minute, duration: film);

    final saved = store.find(const WatchKey('asset:a'));
    expect(saved?.watched, isTrue);
    expect(saved?.position, Duration.zero);
  });

  test('a save near the start deletes the row of a film not watched', () async {
    final repository = _MemoryRepository([row('asset:a')]);
    final container = containerWith(repository);
    final store = await loaded(container);

    store.record(const WatchKey('asset:a'), position: const Duration(seconds: 3), duration: film);

    expect(store.find(const WatchKey('asset:a')), isNull);
    await store.flushed;
    expect(repository.writes, ['delete asset:a']);
  });

  test('the writes reach the database in the order they were made', () async {
    final repository = _MemoryRepository()..writeGate = Completer<void>();
    final container = containerWith(repository);
    final store = await loaded(container);

    store.record(const WatchKey('asset:a'), position: minute * 20, duration: film);
    store.record(const WatchKey('asset:a'), position: minute * 30, duration: film);
    store.record(const WatchKey('asset:a'), position: minute * 40, duration: film);
    repository.writeGate!.complete();
    await store.flushed;

    expect(repository.writes, ['upsert asset:a 20', 'upsert asset:a 30', 'upsert asset:a 40']);
    expect(repository.rows['asset:a']?.position, minute * 40);
  });

  test('a save made before the load finished is not lost when the rows arrive', () async {
    final repository = _MemoryRepository([row('asset:a', minutes: 10), row('asset:b', minutes: 15)])
      ..gate = Completer<void>();
    final container = containerWith(repository);
    final store = container.read(watchProgressProvider.notifier);

    store.record(const WatchKey('asset:a'), position: minute * 50, duration: film);
    repository.gate!.complete();
    await store.loaded;
    await store.flushed;

    expect(store.find(const WatchKey('asset:a'))?.position, minute * 50);
    expect(store.find(const WatchKey('asset:b'))?.position, minute * 15);
    expect(repository.rows['asset:a']?.position, minute * 50);
  });

  group('a video of the device uploaded since', () {
    const uploaded = WatchKey('asset:r', alias: 'local:l');

    test('finds the row made before the upload', () async {
      final container = containerWith(_MemoryRepository([row('local:l')]));
      final store = await loaded(container);

      expect(store.find(uploaded), row('local:l'));
    });

    test('moves it to the server id at the next save', () async {
      final repository = _MemoryRepository([row('local:l', watched: true)]);
      final container = containerWith(repository);
      final store = await loaded(container);

      store.record(uploaded, position: minute * 50, duration: film);
      await store.flushed;

      expect(repository.rows.keys, ['asset:r']);
      expect(repository.rows['asset:r']?.watched, isTrue, reason: 'the check stays');
      expect(store.find(const WatchKey('local:l')), isNull);
    });

    test('the row of the server id wins over the one made before the upload', () async {
      final container = containerWith(_MemoryRepository([row('local:l', minutes: 5), row('asset:r', minutes: 60)]));
      final store = await loaded(container);

      expect(store.find(uploaded)?.position, minute * 60);
    });
  });

  group('a file of a share renamed or moved', () {
    const renamed = WatchKey('share:nas:/Films/New name.mkv', fingerprint: 'fp:nas:4200:99');

    test('is found by its fingerprint, and moves to its new path at the next save', () async {
      final repository = _MemoryRepository([row('share:nas:/Films/Old name.mkv', fingerprint: 'fp:nas:4200:99')]);
      final container = containerWith(repository);
      final store = await loaded(container);

      expect(store.find(renamed)?.position, minute * 42);

      store.record(renamed, position: minute * 43, duration: film);
      await store.flushed;
      expect(repository.rows.keys, [renamed.key]);
      expect(repository.rows[renamed.key]?.fingerprint, 'fp:nas:4200:99');
    });

    test('is not found when two rows have the fingerprint', () async {
      final container = containerWith(
        _MemoryRepository([
          row('share:nas:/a.mkv', fingerprint: 'fp:nas:4200:99'),
          row('share:nas:/b.mkv', fingerprint: 'fp:nas:4200:99'),
        ]),
      );
      final store = await loaded(container);

      expect(store.find(renamed), isNull);
    });
  });

  group('restart', () {
    test('forgets the position, and keeps the check of a watched film', () async {
      final repository = _MemoryRepository([row('asset:a', minutes: 40, watched: true), row('asset:b', minutes: 40)]);
      final container = containerWith(repository);
      final store = await loaded(container);

      store.restart(const WatchKey('asset:a'));
      store.restart(const WatchKey('asset:b'));
      await store.flushed;

      expect(store.find(const WatchKey('asset:a'))?.watched, isTrue);
      expect(store.find(const WatchKey('asset:a'))?.position, Duration.zero);
      expect(store.find(const WatchKey('asset:b')), isNull);
      expect(repository.rows.keys, ['asset:a']);
    });

    test('does nothing for a video without a row', () async {
      final repository = _MemoryRepository();
      final container = containerWith(repository);
      final store = await loaded(container);

      store.restart(const WatchKey('asset:a'));
      await store.flushed;

      expect(repository.writes, isEmpty);
    });
  });

  test('markUnwatched deletes the row, wherever it was found', () async {
    final repository = _MemoryRepository([row('local:l', watched: true)]);
    final container = containerWith(repository);
    final store = await loaded(container);

    store.markUnwatched(const WatchKey('asset:r', alias: 'local:l'));
    await store.flushed;

    expect(store.find(const WatchKey('asset:r', alias: 'local:l')), isNull);
    expect(repository.rows, isEmpty);
  });

  test('a tile that watches its own row is not told of the saves of another video', () async {
    final container = containerWith(_MemoryRepository());
    final store = await loaded(container);
    var changes = 0;
    container.listen(watchProgressProvider.select((rows) => rows.find(const WatchKey('asset:a'))), (_, _) => changes++);

    store.record(const WatchKey('asset:b'), position: minute * 42, duration: film);
    store.record(const WatchKey('asset:b'), position: minute * 43, duration: film);
    expect(changes, 0);

    store.record(const WatchKey('asset:a'), position: minute * 42, duration: film);
    expect(changes, 1);
  });

  test('the rule follows the settings', () {
    final container = ProviderContainer(
      overrides: [
        appConfigProvider.overrideWithValue(
          const AppConfig(viewer: ViewerConfig(resumeVideos: true, resumeMinMinutes: 25)),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(watchRuleProvider), const WatchRule(minMinutes: 25));
  });
}
