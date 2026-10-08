// The sync services of the phones, unchanged, with the folder library behind NativeSyncApi and the real local tables:
// what the timeline, the backup and the computer share read on a computer.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/services/hash.service.dart';
import 'package:immich_mobile/domain/services/local_sync.service.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:path/path.dart' as p;

import '../../repository.mocks.dart';
import 'library_fixtures.dart';
import 'library_test_support.dart';

void main() {
  late Drift db;
  late TestLibrary fixture;
  late FolderLibrarySyncApi api;
  late LocalAlbumRepository albums;
  late LocalAssetRepository assets;
  late String rootId;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    fixture
      ..write('Pictures/2024/IMG_1.jpg', jpegBytes(width: 40, height: 30))
      ..write('Pictures/2024/VID_2.mp4', mp4Bytes(width: 16, height: 9, durationMs: 2000))
      ..write('Pictures/Screens/S_3.png', pngBytes(width: 8, height: 8));
    rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Pictures')).id;
    api = fixture.syncApi();
    albums = LocalAlbumRepository(db);
    assets = LocalAssetRepository(db);
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    fixture.dispose();
    await db.close();
  });

  LocalSyncService syncService() => LocalSyncService(
    localAlbumRepository: albums,
    nativeSyncApi: api,
    trashedLocalAssetRepository: TrashedLocalAssetRepository(db),
    assetMediaRepository: MockAssetMediaRepository(),
    permissionRepository: MockPermissionRepository(),
  );

  HashService hashService() => HashService(
    localAlbumRepository: albums,
    localAssetRepository: assets,
    trashedLocalAssetRepository: TrashedLocalAssetRepository(db),
    nativeSyncApi: api,
  );

  String sha1Of(String relative) => base64.encode(
    crypto.sha1
        .convert(File(p.joinAll([fixture.files.path, 'Pictures', ...relative.split('/')])).readAsBytesSync())
        .bytes,
  );

  test('the first sync fills the local tables with the folders as albums', () async {
    await syncService().sync();

    final local = await albums.getAll(sortBy: {SortLocalAlbumsBy.name});
    expect(local.map((album) => (album.name, album.assetCount)), [('2024', 2), ('Screens', 1)]);
    final photo = await assets.getById(libraryFileId(rootId, '2024/IMG_1.jpg'));
    expect(photo, isNotNull);
    expect((photo!.name, photo.width, photo.height, photo.checksum), ('IMG_1.jpg', 40, 30, null));
    expect(await api.shouldFullSync(), isFalse);
  });

  test('the folders chosen for backup are hashed, and an edited file again', () async {
    await syncService().sync();
    final album = (await albums.getAll()).firstWhere((album) => album.name == '2024');
    await albums.upsert(album.copyWith(backupSelection: BackupSelection.selected));

    await hashService().hashAssets();
    final id = libraryFileId(rootId, '2024/IMG_1.jpg');
    expect((await assets.getById(id))!.checksum, sha1Of('2024/IMG_1.jpg'));
    // The other folder is not chosen: not hashed
    expect((await assets.getById(libraryFileId(rootId, 'Screens/S_3.png')))!.checksum, isNull);

    fixture.write('Pictures/2024/IMG_1.jpg', jpegBytes(width: 41, height: 30), modified: DateTime(2030));
    await fixture.scan();
    await syncService().sync();
    final edited = (await assets.getById(id))!;
    expect((edited.width, edited.checksum), (41, null));

    await hashService().hashAssets();
    expect((await assets.getById(id))!.checksum, sha1Of('2024/IMG_1.jpg'));
  });

  test('new and deleted files reach the local tables through the delta', () async {
    await syncService().sync();
    fixture.write('Pictures/2024/IMG_4.jpg', jpegBytes(width: 1, height: 1));
    File(p.join(fixture.files.path, 'Pictures', 'Screens', 'S_3.png')).deleteSync();
    await fixture.scan();

    await syncService().sync();

    expect(await assets.getById(libraryFileId(rootId, '2024/IMG_4.jpg')), isNotNull);
    expect(await assets.getById(libraryFileId(rootId, 'Screens/S_3.png')), isNull);
    final local = await albums.getAll(sortBy: {SortLocalAlbumsBy.name});
    expect(local.map((album) => (album.name, album.assetCount)), [('2024', 3)]);
  });

  test('a folder taken out of the library leaves the local tables at the next sync', () async {
    await syncService().sync();
    fixture.library().removeRoot(rootId);

    await syncService().sync();

    expect(await albums.getAll(), isEmpty);
    expect(await assets.getById(libraryFileId(rootId, '2024/IMG_1.jpg')), isNull);
  });

  test('a drive back under another letter changes nothing in the local tables', () async {
    await syncService().sync();
    final before = await assets.getById(libraryFileId(rootId, '2024/VID_2.mp4'));

    final moved = fixture.files.renameSync(p.join(fixture.dir.path, 'F'));
    fixture.probe.mounts
      ..clear()
      ..[moved.path] = 'win-0000beef';
    await fixture.scan();
    await syncService().sync();

    final after = await assets.getById(libraryFileId(rootId, '2024/VID_2.mp4'));
    expect(after, isNotNull);
    expect(after!.updatedAt, before!.updatedAt);
    expect((await albums.getAll()).length, 2);
  });
}
