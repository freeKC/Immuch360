// The virtual album of the 3D photos Immuch360 makes, "Immuch360 3D (AI)" (design-final 2026-10-26, section 4.3). A
// version written in a folder of the library is a photo of that folder, so a folder chosen for the backup to Immich
// would send it on its own, which the spec refuses (6.6): publishing a generated file is a choice. So the folder
// library declares this album from its first scan, empty or not, and puts every version in it besides its folder
// (FolderLibrarySyncApi). The first time the album reaches the local tables, it is put in the excluded albums of the
// backup, and the query of the backup leaves out any asset of an excluded album, even when its folder is chosen
// (backup.repository.dart). The shared code of the backup is not changed.
//
// Until that exclusion is done (generatedAlbumState in desktop_ai.json), no conversion writes into a folder of the
// library: the album is still empty then, so no version can leave between the scan and the exclusion. A database of
// the local tables made anew loses the album with its exclusion: the state goes back to pending, and the next sync
// that brings the album in excludes it again. "Reset SQLite Database" of the settings does that while the app runs,
// and a sync may bring the album back right after: so the keeper listens to the row of the album, and the moment it
// leaves the local tables the state goes back to pending, before any sync can make it look as if nothing happened.
//
// The switch "Also back up generated 3D photos" of the settings shows the selection of the album and keeps nothing of
// its own: off when the album is excluded, on otherwise. "Select all" of the backup albums selects this album too (an
// explicit gesture on a list where it reads by its name), and the switch then shows on. Turning it on puts the album
// back to no choice, so the versions follow their folders; turning it off excludes it again.

import 'dart:async';

import 'package:drift/drift.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album.drift.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:logging/logging.dart';

/// The id of the album in the local tables; no folder album has it (theirs are "d" and 40 hex digits, folder_roots.dart)
const generatedAlbumId = 'immuch360-generated-3d';

/// Its name, as the backup albums list it
const generatedAlbumName = 'Immuch360 3D (AI)';

final _log = Logger('GeneratedAlbum');

/// The backup selection of the album in the local tables, read and changed without touching the rest of its row
class GeneratedAlbumRow {
  const GeneratedAlbumRow(this._db);

  final Drift _db;

  /// Null while the local tables do not have the album
  Future<BackupSelection?> selection() async {
    final query = _db.localAlbumEntity.select()..where((album) => album.id.equals(generatedAlbumId));
    return (await query.getSingleOrNull())?.backupSelection;
  }

  Stream<BackupSelection?> watchSelection() {
    final query = _db.localAlbumEntity.select()..where((album) => album.id.equals(generatedAlbumId));
    return query.watchSingleOrNull().map((row) => row?.backupSelection);
  }

  /// False when the local tables do not have the album
  Future<bool> setSelection(BackupSelection selection) async {
    final changed = await (_db.localAlbumEntity.update()..where((album) => album.id.equals(generatedAlbumId))).write(
      LocalAlbumEntityCompanion(backupSelection: Value(selection)),
    );
    return changed > 0;
  }
}

/// Keeps the album out of the backup the first time it comes, and turns the switch of the settings. One change at a
/// time: a sync that ends while the user turns the switch never undoes the user's choice.
class GeneratedAlbumKeeper {
  GeneratedAlbumKeeper({required this._album, required this._settings, this._onSelectionChanged});

  final GeneratedAlbumRow _album;
  final DesktopAiSettingsStore _settings;

  /// Lets the backup pages read the selection again
  final void Function()? _onSelectionChanged;

  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() step) {
    final next = _queue.then((_) => step());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  /// Excludes the album from the backup if it reached the local tables and was never excluded there, and keeps
  /// desktop_ai.json in step; the state reached. Called after each local sync, and by the guard before a write.
  Future<AiGeneratedAlbumState> ensureExcluded() => _serial(_ensureExcluded);

  Future<AiGeneratedAlbumState> _ensureExcluded() async {
    // The row first: read after desktop_ai.json, an album a sync brought back in between would pass for one whose
    // exclusion still holds
    final selection = await _album.selection();
    final state = (await _settings.read()).generatedAlbumState;
    if (selection == null) {
      // Not in the local tables yet, or no more (a database made anew): nothing is excluded, nothing may be written
      if (state != AiGeneratedAlbumState.pending) {
        await _settings.update((settings) => settings.copyWith(generatedAlbumState: AiGeneratedAlbumState.pending));
      }
      return AiGeneratedAlbumState.pending;
    }
    if (state == AiGeneratedAlbumState.pending) {
      if (selection != BackupSelection.excluded) {
        await _album.setSelection(BackupSelection.excluded);
        _onSelectionChanged?.call();
      }
      await _settings.update((settings) => settings.copyWith(generatedAlbumState: AiGeneratedAlbumState.excluded));
    }
    return AiGeneratedAlbumState.excluded;
  }

  /// The album left the local tables (heard from its row): its exclusion went with it, whatever comes next. The row is
  /// not read again, since a sync may already have brought the album back with no choice.
  Future<void> albumLeft() => _serial(() async {
    if ((await _settings.read()).generatedAlbumState != AiGeneratedAlbumState.pending) {
      await _settings.update((settings) => settings.copyWith(generatedAlbumState: AiGeneratedAlbumState.pending));
    }
  });

  /// "Also back up generated 3D photos": on when the album is selected or has no choice, off when it is excluded, null
  /// while the local tables do not have it yet
  Future<bool?> backsUpGenerated() async {
    final selection = await _album.selection();
    return selection == null ? null : selection != BackupSelection.excluded;
  }

  /// Turns the switch: on puts an excluded album back to no choice, so the versions follow their folders (a selected
  /// album stays selected); off excludes it. False while the local tables do not have the album, which has no switch
  /// to turn yet.
  Future<bool> setBacksUpGenerated(bool on) => _serial(() async {
    if (await _ensureExcluded() == AiGeneratedAlbumState.pending) {
      return false;
    }
    final selection = await _album.selection();
    if (selection == null) {
      return false;
    }
    var wanted = selection;
    if (!on) {
      wanted = BackupSelection.excluded;
    } else if (selection == BackupSelection.excluded) {
      wanted = BackupSelection.none;
    }
    if (wanted != selection && await _album.setSelection(wanted)) {
      _onSelectionChanged?.call();
    }
    return true;
  });
}

/// Whether a conversion may write into a folder now (design 4.3, point 3)
class GeneratedAlbumGuard {
  GeneratedAlbumGuard({required this._keeper, required this._inLibrary});

  final GeneratedAlbumKeeper _keeper;
  final Future<bool> Function(String folder) _inLibrary;

  /// A folder outside the library always may; a folder of the library only once the album of the versions was
  /// excluded from the backup. The exclusion is tried first, in case the album reached the local tables meanwhile.
  Future<bool> mayWriteInto(String folder) async =>
      !await _inLibrary(folder) || await _keeper.ensureExcluded() == AiGeneratedAlbumState.excluded;
}

/// desktop_ai.json, replaced in tests
final generatedAlbumSettingsProvider = Provider<DesktopAiSettingsStore>((ref) => DesktopAiSettingsStore.instance);

/// The keeper of the app. While it lives (FolderLibraryHost keeps it), every local sync that ends excludes the album
/// if it is new: the start, the sign in and a rescan each sync the local tables. It also looks once as the app starts,
/// so that local tables made anew are seen without the album, and it listens to the row of the album from the start:
/// the moment the row leaves (a database reset while the app runs), the exclusion is known to be gone.
final generatedAlbumKeeperProvider = Provider<GeneratedAlbumKeeper>((ref) {
  final album = GeneratedAlbumRow(ref.watch(driftProvider));
  final keeper = GeneratedAlbumKeeper(
    album: album,
    settings: ref.watch(generatedAlbumSettingsProvider),
    onSelectionChanged: () => unawaited(ref.read(backupAlbumProvider.notifier).getAll()),
  );
  void run(Future<void> Function() step) => unawaited(() async {
    try {
      await step();
    } catch (error, stackTrace) {
      _log.warning('Could not keep the album of the generated photos out of the backup', error, stackTrace);
    }
  }());
  ref.listen(syncStatusProvider.select((status) => status.localSyncStatus), (_, status) {
    if (status == SyncStatus.success) {
      run(keeper.ensureExcluded);
    }
  });
  final rows = album.watchSelection().listen((selection) {
    if (selection == null) {
      run(keeper.albumLeft);
    }
  });
  ref.onDispose(rows.cancel);
  run(keeper.ensureExcluded);
  return keeper;
});

/// The switch of the settings, following the album as the backup pages and the syncs change it
final generatedAlbumBackupProvider = StreamProvider<bool?>((ref) {
  final album = GeneratedAlbumRow(ref.watch(driftProvider));
  return album.watchSelection().map((selection) => selection == null ? null : selection != BackupSelection.excluded);
});

/// The guard the conversions ask before they write
final generatedAlbumGuardProvider = Provider<GeneratedAlbumGuard>(
  (ref) => GeneratedAlbumGuard(
    keeper: ref.watch(generatedAlbumKeeperProvider),
    inLibrary: (folder) async => (await FolderLibrary.shared()).holdsFolder(folder),
  ),
);
