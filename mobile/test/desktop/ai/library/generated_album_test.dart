// The album of the versions the app makes (3D photos, 3D scenes, 360° panoramas), with the folder library behind the
// sync services of the phones, the real local tables in memory and the real query of the backup
// (backup.repository.dart): a version never leaves for Immich on its own, even from a folder chosen for the backup,
// until the user chooses so; the album renamed for phase 2 keeps that.

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album.drift.dart';
import 'package:immich_mobile/desktop/ai/library/generated_album.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_album.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/providers/backup/backup_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:path/path.dart' as p;

import '../../../repository.mocks.dart';
import '../../library/library_fixtures.dart';
import '../../library/library_test_support.dart';
import '../fakes/fake_immersive_engine.dart';
import 'version_fixtures.dart';

const _userId = 'user-1';

void main() {
  // Two databases at once in one test, each in memory with its own executor: the case the warning is not about
  drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Drift db;
  late TestLibrary fixture;
  late FolderLibrarySyncApi api;
  late Directory support;
  late DesktopAiSettingsStore settings;
  late GeneratedAlbumKeeper keeper;
  late List<int> original;
  var selectionChanges = 0;

  Drift memoryDatabase() => Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    db = memoryDatabase();
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    original = jpegBytes(width: 40, height: 30);
    fixture
      ..write('Pictures/Salon/salon.jpg', original)
      ..write('Pictures/Trips/beach.jpg', jpegBytes(width: 20, height: 10));
    fixture.library().addRoot(p.join(fixture.files.path, 'Pictures'));
    api = fixture.syncApi();
    support = Directory.systemTemp.createTempSync('generated_album_test_');
    settings = DesktopAiSettingsStore(settingsDirectory: () async => support);
    selectionChanges = 0;
    keeper = GeneratedAlbumKeeper(
      album: GeneratedAlbumRow(db),
      settings: settings,
      onSelectionChanged: () => selectionChanges++,
    );
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    fixture.dispose();
    await db.close();
    support.deleteSync(recursive: true);
  });

  LocalSyncService syncService([Drift? on]) => LocalSyncService(
    localAlbumRepository: LocalAlbumRepository(on ?? db),
    nativeSyncApi: api,
    trashedLocalAssetRepository: TrashedLocalAssetRepository(on ?? db),
    assetMediaRepository: MockAssetMediaRepository(),
    permissionRepository: MockPermissionRepository(),
  );

  Future<void> hash() => HashService(
    localAlbumRepository: LocalAlbumRepository(db),
    localAssetRepository: LocalAssetRepository(db),
    trashedLocalAssetRepository: TrashedLocalAssetRepository(db),
    nativeSyncApi: api,
  ).hashAssets();

  Future<LocalAlbum?> albumNamed(String name) async =>
      (await LocalAlbumRepository(db).getAll()).where((album) => album.name == name).firstOrNull;

  Future<BackupSelection?> generatedSelection() => GeneratedAlbumRow(db).selection();

  Future<void> chooseForBackup(String folder) async {
    final album = (await albumNamed(folder))!;
    await LocalAlbumRepository(db).upsert(album.copyWith(backupSelection: BackupSelection.selected));
  }

  Future<List<String>> candidates() async =>
      [for (final asset in await BackupRepository(db).getCandidates(_userId)) asset.name]..sort();

  void writeVersion([String name = 'salon_3D_LRF_Full_SBS.jpg']) =>
      fixture.write('Pictures/Salon/$name', fakeSbsJpeg(xmp: versionXmp(original)));

  test('the album reaches the local tables empty with the first sync, and is excluded once', () async {
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.pending);
    expect(await generatedSelection(), isNull);

    await syncService().sync();
    final album = (await albumNamed(generatedAlbumName))!;
    expect((album.id, album.assetCount, album.backupSelection), (generatedAlbumId, 0, BackupSelection.none));
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);

    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await generatedSelection(), BackupSelection.excluded);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.excluded);
    expect(selectionChanges, 1);

    // Once only: the next ones change nothing
    await syncService().sync(full: true);
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await generatedSelection(), BackupSelection.excluded);
    expect(selectionChanges, 1);
  });

  test('versions never reach the backup candidates, even from a folder chosen for the backup', () async {
    writeVersion();
    await syncService().sync();
    await keeper.ensureExcluded();
    await chooseForBackup('Salon');
    await hash();

    expect(await candidates(), ['salon.jpg']);
    expect((await BackupRepository(db).getAllCounts(_userId)).total, 1);

    // A version made later reaches the local tables by a delta: left out as well
    writeVersion('salon_3D_LRF_Full_SBS (1).jpg');
    await fixture.scan();
    await syncService().sync();
    await hash();

    expect(await candidates(), ['salon.jpg']);
    final inAlbum = await LocalAlbumRepository(db).getAssetIds(generatedAlbumId);
    expect(inAlbum, hasLength(2));
    final inFolder = await LocalAlbumRepository(db).getAssetIds((await albumNamed('Salon'))!.id);
    expect(inFolder, containsAll(inAlbum));
  });

  test('versions of every kind stay out of the backup, even from a folder chosen for it', () async {
    final panorama = panoramaVersionXmp(original);
    writeVersion();
    fixture
      ..write('Pictures/Salon/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)))
      ..write('Pictures/Salon/salon_360.jpg', versionFileOf(panorama))
      ..write('Pictures/Salon/salon_360_3D.jpg', versionFileOf(stereoPanoramaVersionXmp(original, parent: panorama)))
      // The 3D version of a 360° photo of the user, saved beside it
      ..write('Pictures/Trips/beach_3D.jpg', versionFileOf(stereoPanoramaVersionXmp(original, name: 'beach.jpg')));
    await syncService().sync();
    await keeper.ensureExcluded();
    await chooseForBackup('Salon');
    await chooseForBackup('Trips');
    await hash();

    expect(await candidates(), ['beach.jpg', 'salon.jpg']);
    final album = (await albumNamed(generatedAlbumName))!;
    expect((album.id, album.assetCount, album.backupSelection), (generatedAlbumId, 5, BackupSelection.excluded));
  });

  test('the album renamed keeps its exclusion: by the full sync the index of schema 4 asks, and by a delta', () async {
    writeVersion();
    await syncService().sync();
    await keeper.ensureExcluded();
    await chooseForBackup('Salon');
    // As a build of phase 1 left the local tables: the album under its former name, excluded
    await (db.localAlbumEntity.update()..where((row) => row.id.equals(generatedAlbumId))).write(
      const LocalAlbumEntityCompanion(name: drift.Value('Immuch360 3D (AI)')),
    );
    expect(await albumNamed('Immuch360 3D (AI)'), isNotNull);

    // Nothing changed in the folders, the index asks for a full sync (its migration to schema 4 does)
    fixture.index().clearCheckpoint();
    await syncService().sync();
    expect(await albumNamed('Immuch360 3D (AI)'), isNull);
    final renamed = (await albumNamed(generatedAlbumName))!;
    expect((renamed.id, renamed.backupSelection), (generatedAlbumId, BackupSelection.excluded));
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(selectionChanges, 1, reason: 'excluded once, at the first sync, never again');

    // A delta that brings a scene renames it too, still excluded
    await (db.localAlbumEntity.update()..where((row) => row.id.equals(generatedAlbumId))).write(
      const LocalAlbumEntityCompanion(name: drift.Value('Immuch360 3D (AI)')),
    );
    fixture.write('Pictures/Salon/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)));
    await fixture.scan();
    await syncService().sync();
    await hash();
    final album = (await albumNamed(generatedAlbumName))!;
    expect((album.assetCount, album.backupSelection), (2, BackupSelection.excluded));
    expect(await candidates(), ['salon.jpg']);
  });

  test(
    'a new scene or panorama that cannot be read waits for the next scan, never a plain photo of its folder',
    () async {
      await syncService().sync();
      await keeper.ensureExcluded();
      await chooseForBackup('Salon');

      fixture
        ..write('Pictures/Salon/salon_scene3D.jpg', versionFileOf(sceneVersionXmp(original)))
        ..write('Pictures/Salon/salon_360.jpg', versionFileOf(panoramaVersionXmp(original)));
      for (final name in ['salon_scene3D.jpg', 'salon_360.jpg']) {
        fixture.failing.add(p.join(fixture.files.path, 'Pictures', 'Salon', name));
      }
      await fixture.scan();
      await syncService().sync();
      await hash();
      expect(await candidates(), ['salon.jpg']);

      fixture.failing.clear();
      await fixture.scan();
      await syncService().sync();
      await hash();
      expect(await candidates(), ['salon.jpg']);
      expect(await LocalAlbumRepository(db).getAssetIds(generatedAlbumId), hasLength(2));
    },
  );

  test('without the exclusion the folder would send its version: the album is what keeps it out', () async {
    writeVersion();
    await syncService().sync();
    await chooseForBackup('Salon');
    await hash();

    expect(await candidates(), ['salon.jpg', 'salon_3D_LRF_Full_SBS.jpg']);
  });

  test('a new version that cannot be read waits for the next scan, never a plain photo of its folder', () async {
    await syncService().sync();
    await keeper.ensureExcluded();
    await chooseForBackup('Salon');

    // Held by another program as the scan comes: a sharing violation on Windows, a NAS that drops
    writeVersion();
    fixture.failing.add(p.join(fixture.files.path, 'Pictures', 'Salon', 'salon_3D_LRF_Full_SBS.jpg'));
    await fixture.scan();
    await syncService().sync();
    await keeper.ensureExcluded();
    await hash();
    expect(await candidates(), ['salon.jpg']);

    // Read at the next scan: in its folder and in the album, still out of the backup
    fixture.failing.clear();
    await fixture.scan();
    await syncService().sync();
    await hash();
    expect(await candidates(), ['salon.jpg']);
    expect(await LocalAlbumRepository(db).getAssetIds(generatedAlbumId), hasLength(1));
  });

  test('a version changed and not readable keeps what its XMP said until it is read again', () async {
    writeVersion();
    await syncService().sync();
    await keeper.ensureExcluded();
    await chooseForBackup('Salon');
    await hash();
    expect(await candidates(), ['salon.jpg']);

    // Written over (made again, or copied over it), and held as the scan comes
    final path = p.join(fixture.files.path, 'Pictures', 'Salon', 'salon_3D_LRF_Full_SBS.jpg');
    fixture
      ..write(
        'Pictures/Salon/salon_3D_LRF_Full_SBS.jpg',
        fakeSbsJpeg(xmp: versionXmp(original)),
        modified: DateTime(2030),
      )
      ..failing.add(path);
    await fixture.scan();
    await syncService().sync();
    await hash();

    expect(await candidates(), ['salon.jpg']);
    expect(await LocalAlbumRepository(db).getAssetIds(generatedAlbumId), hasLength(1));
  });

  test('Select all selects the album too and the switch shows on; turned off, the album is excluded again', () async {
    writeVersion();
    await syncService().sync();
    await keeper.ensureExcluded();
    expect(await keeper.backsUpGenerated(), isFalse);

    // What "Select all" of the backup albums does (backup_album_selection.page.dart, _SelectAllButton)
    final backupAlbums = BackupAlbumNotifier(LocalAlbumService(LocalAlbumRepository(db)));
    addTearDown(backupAlbums.dispose);
    await backupAlbums.getAll();
    for (final album in backupAlbums.state) {
      if (album.backupSelection != BackupSelection.selected) {
        await backupAlbums.selectAlbum(album);
      }
    }
    expect(await generatedSelection(), BackupSelection.selected);
    expect(await keeper.backsUpGenerated(), isTrue);
    // A sync after it keeps the user's gesture
    await syncService().sync(full: true);
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await generatedSelection(), BackupSelection.selected);
    await hash();
    expect(await candidates(), ['beach.jpg', 'salon.jpg', 'salon_3D_LRF_Full_SBS.jpg']);

    expect(await keeper.setBacksUpGenerated(false), isTrue);
    expect(await generatedSelection(), BackupSelection.excluded);
    expect(await keeper.backsUpGenerated(), isFalse);
    expect(await candidates(), ['beach.jpg', 'salon.jpg']);

    // On again: no choice, so the versions follow their folders
    expect(await keeper.setBacksUpGenerated(true), isTrue);
    expect(await generatedSelection(), BackupSelection.none);
    expect(await candidates(), ['beach.jpg', 'salon.jpg', 'salon_3D_LRF_Full_SBS.jpg']);
    // Turning on a switch already on leaves a selected album selected
    await backupAlbums.getAll();
    await backupAlbums.selectAlbum(backupAlbums.state.firstWhere((album) => album.id == generatedAlbumId));
    expect(await keeper.setBacksUpGenerated(true), isTrue);
    expect(await generatedSelection(), BackupSelection.selected);
  });

  test('the switch cannot be turned before the album is in the local tables', () async {
    expect(await keeper.backsUpGenerated(), isNull);
    expect(await keeper.setBacksUpGenerated(true), isFalse);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);
  });

  test('a choice of the user survives the next syncs and checks', () async {
    await syncService().sync();
    await keeper.ensureExcluded();
    await keeper.setBacksUpGenerated(true);

    writeVersion();
    await fixture.scan();
    await syncService().sync();
    await syncService().sync(full: true);
    await keeper.ensureExcluded();

    expect(await generatedSelection(), BackupSelection.none);
    expect((await albumNamed(generatedAlbumName))!.assetCount, 1);
  });

  test('the guard refuses a folder of the library until the album is excluded, never a folder outside it', () async {
    final elsewhere = Directory(p.join(fixture.dir.path, 'elsewhere'))..createSync();
    fixture.probe.mounts[elsewhere.path] = 'win-0000cafe';
    // As the app asks, in an isolate of its own
    final guard = GeneratedAlbumGuard(
      keeper: keeper,
      inLibrary: (folder) =>
          FolderLibrary.holdsFolderOffWindow(fixture.indexPath, folder, probe: fixture.probe, rules: fixture.rules),
    );
    final salon = p.join(fixture.files.path, 'Pictures', 'Salon');

    expect(await guard.mayWriteInto(salon), isFalse);
    expect(await guard.mayWriteInto(p.join(fixture.files.path, 'Pictures')), isFalse);
    // A folder of the library not scanned yet, and one whose volume cannot be read: in the library as far as it knows
    expect(await guard.mayWriteInto(p.join(salon, 'new')), isFalse);
    expect(await guard.mayWriteInto(p.join(fixture.dir.path, 'unknown')), isFalse);
    expect(await guard.mayWriteInto(elsewhere.path), isTrue);
    // Beside the library, on its drive
    expect(await guard.mayWriteInto(fixture.files.path), isTrue);

    await syncService().sync();
    // The album has come: the guard excludes it itself before it lets the write go
    expect(await guard.mayWriteInto(salon), isTrue);
    expect(await generatedSelection(), BackupSelection.excluded);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.excluded);
  });

  test('the album is excluded before desktop_ai.json says so: a failed write leaves it excluded', () async {
    await syncService().sync();
    final failing = GeneratedAlbumKeeper(album: GeneratedAlbumRow(db), settings: _FailingWrites(support));

    await expectLater(failing.ensureExcluded(), throwsA(isA<FileSystemException>()));
    expect(await generatedSelection(), BackupSelection.excluded);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);
    // The next check only writes the state down
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await generatedSelection(), BackupSelection.excluded);
  });

  test('the switch turned while a check runs waits for it, so the check never undoes the choice', () async {
    await syncService().sync();
    final reads = _HeldReads(support);
    final both = GeneratedAlbumKeeper(album: GeneratedAlbumRow(db), settings: reads);
    final release = Completer<void>();
    reads.hold = release.future;

    // The check of a sync that ends, held once it has read desktop_ai.json, and the switch turned on meanwhile
    final check = both.ensureExcluded();
    await _until(() async => reads.holding);
    final turned = both.setBacksUpGenerated(true);
    // Not in turn, the switch would be done by now, and the check would then exclude the album again
    await Future.any([turned, Future<void>.delayed(const Duration(milliseconds: 300))]);
    release.complete();

    expect(await check, AiGeneratedAlbumState.excluded);
    expect(await turned, isTrue);
    expect(await generatedSelection(), BackupSelection.none);
  });

  test('the switch turned before the first exclusion does that exclusion first, so no check undoes it', () async {
    await syncService().sync();
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);

    expect(await keeper.setBacksUpGenerated(true), isTrue);
    expect(await generatedSelection(), BackupSelection.none);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.excluded);
    // The check of the next sync keeps the user's choice
    expect(await keeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await generatedSelection(), BackupSelection.none);
  });

  test('a check reads the album first, so a sync in between cannot hide local tables made anew', () async {
    await syncService().sync();
    await keeper.ensureExcluded();
    final fresh = memoryDatabase();
    addTearDown(fresh.close);
    final reads = _HeldReads(support);
    final freshKeeper = GeneratedAlbumKeeper(album: GeneratedAlbumRow(fresh), settings: reads);
    final release = Completer<void>();
    reads.hold = release.future;

    // The look at the start, held once it has read desktop_ai.json, and the first sync of the window meanwhile
    final check = freshKeeper.ensureExcluded();
    await _until(() async => reads.holding);
    await syncService(fresh).sync(full: true);
    release.complete();

    expect(await check, AiGeneratedAlbumState.pending);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);
    expect(await freshKeeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await GeneratedAlbumRow(fresh).selection(), BackupSelection.excluded);
  });

  test('a database made anew brings the exclusion back with the album', () async {
    await syncService().sync();
    await keeper.ensureExcluded();

    final fresh = memoryDatabase();
    addTearDown(fresh.close);
    final freshKeeper = GeneratedAlbumKeeper(album: GeneratedAlbumRow(fresh), settings: settings);
    expect(await freshKeeper.ensureExcluded(), AiGeneratedAlbumState.pending);
    expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.pending);

    await syncService(fresh).sync(full: true);
    expect(await freshKeeper.ensureExcluded(), AiGeneratedAlbumState.excluded);
    expect(await GeneratedAlbumRow(fresh).selection(), BackupSelection.excluded);
  });

  group('the providers of the app', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [driftProvider.overrideWithValue(db), generatedAlbumSettingsProvider.overrideWithValue(settings)],
      );
    });
    tearDown(() => container.dispose());

    test('a local sync that ends excludes the album, whoever started it', () async {
      // Its look at the start done first (one check at a time): nothing to exclude yet
      expect(await container.read(generatedAlbumKeeperProvider).ensureExcluded(), AiGeneratedAlbumState.pending);
      await syncService().sync();
      expect(await generatedSelection(), BackupSelection.none);

      // What the sync manager reports when it is done (background_sync.provider.dart)
      container.read(syncStatusProvider.notifier).completeLocalSync();
      // The album first, then desktop_ai.json: a crash between the two leaves the album excluded
      await _until(() async => (await settings.read()).generatedAlbumState == AiGeneratedAlbumState.excluded);

      expect(await generatedSelection(), BackupSelection.excluded);
      // The backup pages read the albums again
      await _until(() async => container.read(backupAlbumProvider).any((album) => album.id == generatedAlbumId));
      expect(
        container.read(backupAlbumProvider).firstWhere((album) => album.id == generatedAlbumId).backupSelection,
        BackupSelection.excluded,
      );
    });

    test('as the app starts on local tables made anew, the album is seen gone before the first sync', () async {
      await syncService().sync();
      await keeper.ensureExcluded();
      final fresh = memoryDatabase();
      addTearDown(fresh.close);
      final restarted = ProviderContainer(
        overrides: [driftProvider.overrideWithValue(fresh), generatedAlbumSettingsProvider.overrideWithValue(settings)],
      );
      addTearDown(restarted.dispose);

      restarted.read(generatedAlbumKeeperProvider);
      await _until(() async => (await settings.read()).generatedAlbumState == AiGeneratedAlbumState.pending);

      await syncService(fresh).sync(full: true);
      restarted.read(syncStatusProvider.notifier).completeLocalSync();
      await _until(() async => (await settings.read()).generatedAlbumState == AiGeneratedAlbumState.excluded);
      expect(await GeneratedAlbumRow(fresh).selection(), BackupSelection.excluded);
    });

    test('Reset SQLite Database while the app runs, then a sync: the album comes back excluded', () async {
      container.read(generatedAlbumKeeperProvider);
      final status = container.read(syncStatusProvider.notifier);
      await syncService().sync();
      status.completeLocalSync();
      await _until(() async => (await settings.read()).generatedAlbumState == AiGeneratedAlbumState.excluded);
      expect(await generatedSelection(), BackupSelection.excluded);

      // What the settings page does (sync_status_and_actions.dart), the app going on, and a sync before any restart:
      // the sync button of the same page, or a file changed in a watched folder
      status.startLocalSync();
      await db.reset();
      await syncService().sync(full: true);
      status.completeLocalSync();

      await _until(() async => await generatedSelection() == BackupSelection.excluded);
      expect((await settings.read()).generatedAlbumState, AiGeneratedAlbumState.excluded);
    });

    test('the switch of the settings follows the album', () async {
      final values = <bool?>[];
      // Each change of the table may be heard more than once: the values in turn
      container.listen(generatedAlbumBackupProvider, (_, next) {
        if (next case AsyncData(:final value) when values.isEmpty || values.last != value) {
          values.add(value);
        }
      }, fireImmediately: true);
      await _until(() async => values.isNotEmpty);
      expect(values.last, isNull);

      await syncService().sync();
      await _until(() async => values.last == true);
      await keeper.ensureExcluded();
      await _until(() async => values.last == false);
      await keeper.setBacksUpGenerated(true);
      await _until(() async => values.last == true);
      expect(values, [null, true, false, true]);
    });
  });
}

/// desktop_ai.json on a disk that refuses every write
class _FailingWrites extends DesktopAiSettingsStore {
  _FailingWrites(Directory directory) : super(settingsDirectory: () async => directory);

  @override
  Future<DesktopAiSettings> update(DesktopAiSettings Function(DesktopAiSettings settings) change) async =>
      throw const FileSystemException('No space left on device');
}

/// desktop_ai.json whose next read, once done, is held until [hold] completes
class _HeldReads extends DesktopAiSettingsStore {
  _HeldReads(Directory directory) : super(settingsDirectory: () async => directory);

  Future<void>? hold;

  /// The held read is waiting
  var holding = false;

  @override
  Future<DesktopAiSettings> read() async {
    final settings = await super.read();
    final held = hold;
    hold = null;
    if (held != null) {
      holding = true;
      await held;
    }
    return settings;
  }
}

/// Waits until [done] holds, a few seconds at most
Future<void> _until(Future<bool> Function() done) async {
  for (var i = 0; i < 200; i++) {
    if (await done()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('Not reached in time');
}
