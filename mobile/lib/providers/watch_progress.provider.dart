import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/watch/database.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/infrastructure/repositories/watch_progress.repository.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';

/// The film rule of the settings ("Remember where I stopped", see WatchRule). Declares its dependency, so that a scope
/// that overrides the settings (the tests, a viewer) gets its own
final watchRuleProvider = Provider.autoDispose<WatchRule>((ref) {
  try {
    return ref.watch(appConfigProvider.select((config) => WatchRule.of(config.viewer)));
  } on StateError {
    // The settings are not read yet (a test without them): the defaults
    return const WatchRule();
  }
}, dependencies: [appConfigProvider]);

/// Opens the database of the watch progress (see openWatchDatabase); the tests open none (flutter_test_config.dart),
/// the rows then live in memory
@visibleForTesting
Future<DriftWatch> Function() watchDatabaseOpener = openWatchDatabase;

/// The database of the watch progress, opened at the first read of a row
final watchProgressRepositoryProvider = Provider<WatchProgressRepository>((ref) {
  final repository = WatchProgressRepository(watchDatabaseOpener);
  ref.onDispose(() => unawaited(repository.close()));
  return repository;
});

/// The time of a save, replaced by the tests
final watchProgressClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// The rows of the watch progress by key, as [WatchProgressStore] holds them in memory
class WatchProgressRows {
  WatchProgressRows(this.byKey);

  final Map<String, WatchProgress> byKey;

  /// The keys of the rows by fingerprint, made at the first lookup that needs it
  late final Map<String, List<String>> _byFingerprint = () {
    final index = <String, List<String>>{};
    for (final row in byKey.values) {
      final fingerprint = row.fingerprint;
      if (fingerprint != null) {
        (index[fingerprint] ??= []).add(row.key);
      }
    }
    return index;
  }();

  /// The row of [key]: under its key, else under its alias, else the one row with its fingerprint (a file of a share
  /// renamed or moved); null when none is found, or when two rows have the fingerprint
  WatchProgress? find(WatchKey key) {
    for (final lookup in key.lookups) {
      final row = byKey[lookup];
      if (row != null) {
        return row;
      }
    }
    final fingerprint = key.fingerprint;
    if (fingerprint == null) {
      return null;
    }
    final keys = _byFingerprint[fingerprint];
    return keys != null && keys.length == 1 ? byKey[keys.single] : null;
  }
}

/// Where the videos were left, on this device only: nothing goes to the server, which has no watched state. The rows
/// are read once from their database (see WatchProgressRepository), held in memory so that a tile shows a save in the
/// same frame, and written back in the order of the changes, one after the other, so that an older write never lands
/// after a newer one. A row found under the alias or the fingerprint of a key moves to the key at its next change.
///
/// The players save through [record], the menus through [restart] and [markUnwatched]; the film rule is theirs (see
/// WatchRule): this store keeps whatever it is given, by the watched rule of [recordWatch].
class WatchProgressStore extends Notifier<WatchProgressRows> {
  late WatchProgressRepository _repository;
  late DateTime Function() _now;

  /// The keys changed before the rows of the database arrived: the rows read do not replace them
  final _changedBeforeLoad = <String>{};
  bool _isLoaded = false;
  Future<void> _writes = Future.value();
  late Future<void> _loaded;

  /// Completes once the rows of the database are in memory
  Future<void> get loaded => _loaded;

  /// Completes once every change made so far is written
  Future<void> get flushed => _writes;

  @override
  WatchProgressRows build() {
    _repository = ref.watch(watchProgressRepositoryProvider);
    _now = ref.watch(watchProgressClockProvider);
    _loaded = _load();
    _writes = _loaded;
    return WatchProgressRows(const {});
  }

  Future<void> _load() async {
    final rows = await _repository.load();
    final merged = {for (final row in rows) row.key: row};
    for (final key in _changedBeforeLoad) {
      final changed = state.byKey[key];
      if (changed == null) {
        merged.remove(key);
      } else {
        merged[key] = changed;
      }
    }
    _changedBeforeLoad.clear();
    _isLoaded = true;
    state = WatchProgressRows(merged);
  }

  /// The row of [key], see [WatchProgressRows.find]
  WatchProgress? find(WatchKey key) => state.find(key);

  /// A player stopped the video of [key] at [position] in [duration] (see [recordWatch]): kept, watched in its end tail,
  /// forgotten under its start margin
  void record(WatchKey key, {required Duration position, required Duration duration}) {
    final previous = find(key);
    final row = recordWatch(
      key: key.key,
      previous: previous,
      position: position,
      duration: duration,
      now: _now(),
      fingerprint: key.fingerprint,
    );
    // Nothing to change: no row before nor after, or a save that told nothing (no duration)
    if (row == null ? previous == null : row == previous && previous?.key == key.key) {
      return;
    }
    _put(key, row, previous);
  }

  /// "Play from the start": the position goes, the check of a watched film stays
  void restart(WatchKey key) {
    final previous = find(key);
    if (previous == null) {
      return;
    }
    final row = previous.watched
        ? previous.copyWith(key: key.key, position: Duration.zero, updatedAt: _now(), fingerprint: key.fingerprint)
        : null;
    _put(key, row, previous);
  }

  /// "Mark as not watched": the row goes, position and check
  void markUnwatched(WatchKey key) {
    final previous = find(key);
    if (previous == null) {
      return;
    }
    _put(key, null, previous);
  }

  /// [row] in place of [previous] under [key], deleted when null: the row found under another key moves
  void _put(WatchKey key, WatchProgress? row, WatchProgress? previous) {
    final moved = previous != null && previous.key != key.key ? previous.key : null;
    final rows = {...state.byKey};
    if (moved != null) {
      rows.remove(moved);
    }
    if (row == null) {
      rows.remove(key.key);
    } else {
      rows[key.key] = row;
    }
    if (!_isLoaded) {
      _changedBeforeLoad.addAll([key.key, ?moved]);
    }
    state = WatchProgressRows(rows);

    final repository = _repository;
    _writes = _writes.then((_) async {
      if (moved != null) {
        await repository.delete(moved);
      }
      if (row == null) {
        await repository.delete(key.key);
      } else {
        await repository.upsert(row);
      }
    });
  }
}

/// The rows of the watch progress, see [WatchProgressStore]. Declares its dependencies, so that a scope that gives its
/// own database (the tests) gets its own store
final watchProgressProvider = NotifierProvider<WatchProgressStore, WatchProgressRows>(
  WatchProgressStore.new,
  dependencies: [watchProgressRepositoryProvider, watchProgressClockProvider],
);
