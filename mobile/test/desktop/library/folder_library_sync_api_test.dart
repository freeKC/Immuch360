import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_library_sync_api.dart';
import 'package:immich_mobile/desktop/library/library_hasher.dart';
import 'package:immich_mobile/desktop/library/native_sha1.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:path/path.dart' as p;

import 'library_fixtures.dart';
import 'library_test_support.dart';

void main() {
  late TestLibrary fixture;
  late String rootId;

  setUp(() {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
    fixture
      ..write(
        'Photos/2024/IMG_1.jpg',
        jpegBytes(
          width: 4000,
          height: 3000,
          tiff: tiffBytes(
            ifd0: const [
              (0x0112, 3, [6]),
            ],
            gps: [(1, 2, 'S'), (2, 5, gpsDegrees(33.8568)), (3, 2, 'E'), (4, 5, gpsDegrees(151.2153))],
          ),
        ),
      )
      ..write('Photos/2024/VID_2.mp4', mp4Bytes(width: 1920, height: 1080, durationMs: 4200))
      ..write('Photos/Trips/2024/IMG_3.png', pngBytes(width: 10, height: 20))
      ..write('Photos/top.gif', gifBytes(width: 4, height: 4));
    rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Photos')).id;
  });
  tearDown(() => fixture.dispose());

  group('what the sync services read', () {
    test('albums sorted by id, named by their folder, with their counts', () async {
      final albums = await fixture.syncApi().getAlbums();

      expect(albums.map((album) => album.id).toList(), [...albums.map((album) => album.id)]..sort());
      final byName = {for (final album in albums) album.name: album};
      // Two folders named 2024: their parents tell them apart
      expect(byName.keys, unorderedEquals(['Photos/2024', 'Trips/2024', 'Photos']));
      expect(byName['Photos/2024']!.assetCount, 2);
      expect(byName['Photos']!.assetCount, 1);
      expect(albums.every((album) => !album.isCloud && album.updatedAt! > 0), isTrue);
    });

    test('assets the way Android gives them: the size as shown, orientation 0, seconds', () async {
      final api = fixture.syncApi();
      await fixture.scan();
      final album = fixture.ids.album(rootId, '2024');
      final assets = {for (final asset in await api.getAssetsForAlbum(album)) asset.name: asset};

      final photo = assets['IMG_1.jpg']!;
      expect(photo.id, fixture.ids.file(rootId, '2024/IMG_1.jpg'));
      expect(photo.type, 1);
      expect((photo.width, photo.height, photo.orientation), (3000, 4000, 0));
      expect(photo.playbackStyle, PlatformAssetPlaybackStyle.image);
      expect(photo.updatedAt, photo.adjustmentTime);
      expect(photo.isFavorite, isFalse);
      expect(photo.latitude, closeTo(-33.8568, 1e-4));
      expect(photo.longitude, closeTo(151.2153, 1e-4));

      final video = assets['VID_2.mp4']!;
      expect((video.type, video.durationMs), (2, 4200));
      expect(video.playbackStyle, PlatformAssetPlaybackStyle.video);
      expect((video.latitude, video.longitude), (null, null));

      expect(await api.getAssetIdsForAlbum(album), unorderedEquals(assets.values.map((asset) => asset.id)));
      final gif = (await api.getAssetsForAlbum(fixture.ids.album(rootId, ''))).single;
      expect(gif.playbackStyle, PlatformAssetPlaybackStyle.imageAnimated);
    });

    test('what was added since a date, and what changed since it', () async {
      final api = fixture.syncApi();
      final album = fixture.ids.album(rootId, '2024');
      await api.getAlbums();
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      expect(await api.getAssetsCountSince(album, now - 3600), 2);
      expect(await api.getAssetsCountSince(album, now + 3600), 0);
      expect(await api.getAssetsForAlbum(album, updatedTimeCond: now + 3600), isEmpty);
      expect(await api.getAssetsForAlbum(album, updatedTimeCond: now - 3600), hasLength(2));
    });
  });

  group('deltas and checkpoints', () {
    test('a full sync first, then the changes since the checkpoint', () async {
      final api = fixture.syncApi();
      expect(await api.shouldFullSync(), isTrue);
      await api.getAlbums();
      await api.checkpointSync();
      expect(await api.shouldFullSync(), isFalse);
      expect((await api.getMediaChanges()).hasChanges, isFalse);

      fixture.write('Photos/2024/IMG_4.jpg', jpegBytes(width: 1, height: 1));
      File(p.join(fixture.files.path, 'Photos', 'top.gif')).deleteSync();
      await fixture.scan();

      final delta = await api.getMediaChanges();
      expect(delta.hasChanges, isTrue);
      final added = fixture.ids.file(rootId, '2024/IMG_4.jpg');
      expect(delta.updates.map((asset) => asset.id), [added]);
      expect(delta.assetAlbums, {
        added: [fixture.ids.album(rootId, '2024')],
      });
      expect(delta.deletes, [fixture.ids.file(rootId, 'top.gif')]);

      await api.checkpointSync();
      expect((await api.getMediaChanges()).hasChanges, isFalse);
    });

    test('the checkpoint commits what the delta carried, not what a scan wrote after it', () async {
      final api = fixture.syncApi(freshScan: false);
      await fixture.scan();
      await api.getAlbums();
      await api.checkpointSync();

      fixture.write('Photos/a.jpg', jpegBytes(width: 1, height: 1));
      await fixture.scan();
      final delta = await api.getMediaChanges();
      // A scan between the delta and its checkpoint, as the watcher may run one
      fixture.write('Photos/b.jpg', jpegBytes(width: 1, height: 1));
      await fixture.scan();
      await api.checkpointSync();

      expect(delta.updates.map((asset) => asset.name), ['a.jpg']);
      expect((await api.getMediaChanges()).updates.map((asset) => asset.name), ['b.jpg']);
    });

    test('forgetting the checkpoint asks for a full sync; so does a change of the roots', () async {
      final api = fixture.syncApi();
      await api.getAlbums();
      await api.checkpointSync();

      await api.clearSyncCheckpoint();
      expect(await api.shouldFullSync(), isTrue);
      await api.getAlbums();
      await api.checkpointSync();
      expect(await api.shouldFullSync(), isFalse);

      Directory(p.join(fixture.files.path, 'More')).createSync();
      fixture.library().addRoot(p.join(fixture.files.path, 'More'));
      expect(await api.shouldFullSync(), isTrue);
    });

    test('the delta reads a fresh scan', () async {
      final api = fixture.syncApi();
      await api.getAlbums();
      await api.checkpointSync();
      fixture.write('Photos/new.jpg', jpegBytes(width: 1, height: 1));
      // The last scan is recent: the delta does not scan again
      expect((await api.getMediaChanges()).hasChanges, isFalse);

      // Once it is stale, the delta scans first
      final index = fixture.library().index;
      index.recordScanEnd(endedMs: 0, rootsVersion: index.rootsVersion);
      expect((await api.getMediaChanges()).updates.map((asset) => asset.name), ['new.jpg']);
    });

    test('a cancelled sync answers with the code the sync services expect', () async {
      final scanning = Completer<void>();
      final api = FolderLibrarySyncApi(
        indexPath: () async => fixture.indexPath,
        freshScan: (_, cancel) async {
          await scanning.future;
        },
      );
      final changes = api.getMediaChanges();
      await Future<void>.delayed(Duration.zero);
      await api.cancelSync();
      scanning.complete();
      await expectLater(
        changes,
        throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'SYNC_CANCELLED')),
      );
    });

    test('no trash and no cloud ids on a computer', () async {
      final api = fixture.syncApi();
      expect(await api.getTrashedAssets(), isEmpty);
      expect(await api.restoreFromTrashById('x', 1), isFalse);
      expect(await api.getCloudIdForAssetIds(['x']), isEmpty);
    });
  });

  group('hashing', () {
    String reference(String relative) => base64.encode(
      crypto.sha1
          .convert(File(p.joinAll([fixture.files.path, 'Photos', ...relative.split('/')])).readAsBytesSync())
          .bytes,
    );

    test('base64 SHA-1 per asset in the order asked, kept for the files as they are', () async {
      final ids = [fixture.ids.file(rootId, '2024/VID_2.mp4'), 'unknown', fixture.ids.file(rootId, '2024/IMG_1.jpg')];
      var hashed = 0;
      final api = FolderLibrarySyncApi(
        indexPath: () async => fixture.indexPath,
        freshScan: (_, _) async {},
        hasher: (jobs, {required network, required cancel}) async {
          hashed += jobs.length;
          return [for (final job in jobs) hashOneFile(job, engine: Sha1Engine.system())];
        },
      );
      // Its connection to the index closed before the folder goes: Windows does not delete an open file
      addTearDown(api.close);
      await fixture.scan();

      final results = await api.hashAssets(ids);
      expect(results.map((result) => result.assetId), ids);
      expect(results[0].hash, reference('2024/VID_2.mp4'));
      expect(results[1].hash, isNull);
      expect(results[1].error, isNotNull);
      expect(results[2].hash, reference('2024/IMG_1.jpg'));
      expect(hashed, 2);

      // Known now, by size and date: nothing read again
      expect((await api.hashAssets(ids)).map((result) => result.hash), [
        reference('2024/VID_2.mp4'),
        null,
        reference('2024/IMG_1.jpg'),
      ]);
      expect(hashed, 2);

      // An edited file is hashed again
      fixture.write('Photos/2024/IMG_1.jpg', jpegBytes(width: 2, height: 2), modified: DateTime(2030));
      await fixture.scan();
      expect((await api.hashAssets([ids[2]])).single.hash, reference('2024/IMG_1.jpg'));
      expect(hashed, 3);
    });

    test('a file kept online only, or on a drive that is not connected, is never read', () async {
      final cloud = fixture.write('Photos/cloud.jpg', jpegBytes(width: 1, height: 1));
      fixture.attributes[cloud.path] = fileAttributeRecallOnDataAccess;
      await fixture.scan();
      final api = fixture.syncApi();

      final refused = await api.hashAssets([fixture.ids.file(rootId, 'cloud.jpg')]);
      expect(refused.single.hash, isNull);
      expect(refused.single.error, contains('online only'));

      fixture.files.renameSync(p.join(fixture.dir.path, 'unplugged'));
      fixture.probe.mounts.clear();
      await fixture.scan();
      final offline = await api.hashAssets([fixture.ids.file(rootId, 'top.gif')]);
      expect(offline.single.error, contains('not connected'));
    });

    test('a cancelled hashing answers with the code the hash service expects', () async {
      await fixture.scan();
      final started = Completer<void>();
      final release = Completer<void>();
      final api = FolderLibrarySyncApi(
        indexPath: () async => fixture.indexPath,
        freshScan: (_, _) async {},
        hasher: (jobs, {required network, required cancel}) async {
          started.complete();
          await release.future;
          return [for (final job in jobs) (id: job.id, hash: null, error: 'Cancelled')];
        },
      );
      addTearDown(api.close);
      final run = api.hashAssets([fixture.ids.file(rootId, 'top.gif')]);
      await started.future;
      await api.cancelHashing();
      release.complete();
      await expectLater(run, throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'HASH_CANCELLED')));
    });
  });
}
