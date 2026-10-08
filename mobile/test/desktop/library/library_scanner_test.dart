import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'library_fixtures.dart';
import 'library_test_support.dart';

void main() {
  late TestLibrary fixture;

  setUp(() {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
  });
  tearDown(() => fixture.dispose());

  LibraryIndex openIndex() => fixture.index();

  group('a first scan', () {
    test('takes the photos and videos of each folder as albums, and skips what is no media', () async {
      final taken = DateTime.utc(2024, 7, 14, 16, 30, 5);
      fixture
        ..write(
          'Pictures/Trips/IMG_0001.JPG',
          jpegBytes(
            width: 4000,
            height: 3000,
            tiff: tiffBytes(exif: const [(0x9003, 2, '2024:07:14 18:30:05'), (0x9011, 2, '+02:00')]),
          ),
        )
        ..write('Pictures/Trips/VID_0002.mp4', mp4Bytes(width: 3840, height: 1920, durationMs: 12000, created: taken))
        ..write('Pictures/pano.jpg', jpegBytes(width: 6000, height: 3000, gpanoProjection: 'equirectangular'))
        // Not media, or hidden, or in folders a scan never enters
        ..write('Pictures/notes.txt', [1, 2, 3])
        ..write('Pictures/Trips/VID_0002.lrv', [0])
        ..write('Pictures/Trips/._IMG_0001.JPG', [0])
        ..write('Pictures/.hidden/a.jpg', jpegBytes(width: 1, height: 1))
        ..write(r'Pictures/$RECYCLE.BIN/b.jpg', jpegBytes(width: 1, height: 1))
        ..write('Pictures/@eaDir/c.jpg', jpegBytes(width: 1, height: 1))
        ..write('Pictures/.thumbnails/d.png', pngBytes(width: 1, height: 1));
      // A link back to the root: never followed, so no loop and no double
      Link(p.join(fixture.files.path, 'Pictures', 'Trips', 'loop')).createSync(p.join(fixture.files.path, 'Pictures'));

      final library = fixture.library();
      final root = library.addRoot(p.join(fixture.files.path, 'Pictures'));
      expect(root.id, 'win-0000beef:/Pictures');

      final summary = await library.scan();
      expect(summary.written, 3);
      expect(summary.removed, 0);

      final index = openIndex();
      final albums = index.albums();
      expect(albums, hasLength(2));
      final trips = albums.firstWhere((album) => album.relativeDir == 'Trips');
      expect(trips.id, fixture.ids.album(root.id, 'Trips'));
      expect(trips.assetCount, 2);

      final photo = index.file(fixture.ids.file(root.id, 'Trips/IMG_0001.JPG'))!;
      expect(photo.type, LibraryMediaKind.image.assetType);
      expect((photo.width, photo.height), (4000, 3000));
      expect(photo.createdSeconds, taken.millisecondsSinceEpoch ~/ 1000);
      expect(photo.playbackStyle, 1);

      final video = index.file(fixture.ids.file(root.id, 'Trips/VID_0002.mp4'))!;
      expect(video.type, LibraryMediaKind.video.assetType);
      expect(video.durationMs, 12000);
      expect(video.playbackStyle, 2);

      expect(index.file(fixture.ids.file(root.id, 'pano.jpg'))!.projection, 'equirectangular');
      expect(fixture.opened.map(p.basename), unorderedEquals(['IMG_0001.JPG', 'VID_0002.mp4', 'pano.jpg']));
      expect(library.roots().single.fileCount, 3);
    });

    test('a file with no date taken is dated by the file', () async {
      final modified = DateTime(2021, 3, 4, 5, 6, 7);
      fixture.write('Photos/plain.png', pngBytes(width: 2, height: 2), modified: modified);
      final library = fixture.library()..addRoot(p.join(fixture.files.path, 'Photos'));
      await library.scan();

      final file = openIndex().file(fixture.ids.file('win-0000beef:/Photos', 'plain.png'))!;
      expect(file.createdSeconds, lessThanOrEqualTo(modified.millisecondsSinceEpoch ~/ 1000));
      expect(file.modifiedMs ~/ 1000, modified.millisecondsSinceEpoch ~/ 1000);
    });
  });

  group('later scans', () {
    late String rootId;

    setUp(() async {
      fixture
        ..write('Photos/a.jpg', jpegBytes(width: 10, height: 10), modified: DateTime(2024))
        ..write('Photos/b.jpg', jpegBytes(width: 20, height: 20), modified: DateTime(2024))
        ..write('Photos/2023/c.mp4', mp4Bytes(width: 8, height: 8, durationMs: 1000), modified: DateTime(2023));
      rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Photos')).id;
      await fixture.scan();
      fixture.opened.clear();
    });

    test('read nothing again when nothing changed', () async {
      final summary = await fixture.scan();
      expect((summary.written, summary.removed, summary.hasChanges), (0, 0, false));
      expect(fixture.opened, isEmpty);
    });

    test('carry what changed and what went as the next generations', () async {
      final index = openIndex();
      final first = index.changesSince(0);
      expect(first.updates, hasLength(3));
      index.setCheckpoint(first.seq);

      fixture.write('Photos/a.jpg', jpegBytes(width: 30, height: 30), modified: DateTime(2025));
      File(p.join(fixture.files.path, 'Photos', 'b.jpg')).deleteSync();
      fixture.write('Photos/new.png', pngBytes(width: 5, height: 5));

      final summary = await fixture.scan();
      expect((summary.written, summary.removed), (2, 1));
      expect(fixture.opened.map(p.basename), unorderedEquals(['a.jpg', 'new.png']));

      final delta = index.changesSince(index.checkpoint);
      expect(delta.updates.map((file) => file.name), unorderedEquals(['a.jpg', 'new.png']));
      expect(delta.updates.firstWhere((file) => file.name == 'a.jpg').width, 30);
      expect(delta.deletes, [fixture.ids.file(rootId, 'b.jpg')]);
    });

    test('a file that comes back before the next sync is a change, not a deletion', () async {
      final index = openIndex();
      index.setCheckpoint(index.changesSince(0).seq);
      final bytes = File(p.join(fixture.files.path, 'Photos', 'b.jpg')).readAsBytesSync();
      File(p.join(fixture.files.path, 'Photos', 'b.jpg')).deleteSync();
      await fixture.scan();
      fixture.write('Photos/b.jpg', bytes);
      await fixture.scan();

      final delta = index.changesSince(index.checkpoint);
      expect(delta.deletes, isEmpty);
      expect(delta.updates.map((file) => file.name), ['b.jpg']);
    });

    test('a folder that cannot be read removes nothing below it', () async {
      final locked = Directory(p.join(fixture.files.path, 'Photos', '2023'));
      Process.runSync('chmod', ['000', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
      try {
        locked.listSync();
        markTestSkipped('The tests run with rights that read every folder');
        return;
      } on FileSystemException {
        // As expected: the folder cannot be read
      }
      final summary = await fixture.scan();
      expect(summary.removed, 0);
      expect(openIndex().file(fixture.ids.file(rootId, '2023/c.mp4')), isNotNull);
    }, skip: Platform.isWindows ? 'chmod is a POSIX tool' : null);

    test('a cancelled scan stops and is not taken as fresh', () async {
      fixture.write('Photos/d.jpg', jpegBytes(width: 1, height: 1));
      final before = openIndex().lastScan.endedMs;
      final summary = await runLibraryScan(
        fixture.indexPath,
        probe: fixture.probe,
        lister: const IoFolderLister(),
        rules: fixture.rules,
        isCancelled: () => true,
      );
      expect(summary.cancelled, isTrue);
      expect(openIndex().lastScan.endedMs, before);
      expect(openIndex().file(fixture.ids.file(rootId, 'd.jpg')), isNull);
    });

    test('a second scan while one holds the index says so and does nothing', () async {
      final index = openIndex();
      // Another isolate of this process
      final owner = '$pid-1-0';
      expect(index.tryAcquireScanLease(owner, const Duration(minutes: 1)), isTrue);
      final summary = await fixture.scan();
      expect(summary.busy, isTrue);
      index.releaseScanLease(owner);
      expect((await fixture.scan()).busy, isFalse);
    });

    test(
      'a lease left by a process that ended mid scan: taken over at once on Windows, after a minute elsewhere',
      () async {
        final start = DateTime(2030);
        final left = '${pid + 1}-1-0';
        expect(leaseOwnerPid(left), pid + 1);
        expect(openIndex().tryAcquireScanLease(left, const Duration(minutes: 1), now: start), isTrue);

        final soon = await fixture.scan(clock: () => start.add(const Duration(seconds: 30)));
        expect(soon.busy, !Platform.isWindows);
        final later = await fixture.scan(clock: () => start.add(const Duration(seconds: 61)));
        expect(later.busy, isFalse);
      },
    );

    test('a scan that lost its lease to another one stops, and the other one holds the index', () async {
      for (var i = 0; i < 3; i++) {
        fixture.write('Photos/new_$i.jpg', jpegBytes(width: 1, height: 1));
      }
      var now = DateTime(2030);
      final other = openIndex();
      final owner = '$pid-2-0';
      fixture.onRead = (_) {
        // The scan stalls past its lease (a share that stopped answering), and another one takes the index
        now = now.add(const Duration(minutes: 2));
        other.tryAcquireScanLease(owner, const Duration(minutes: 1), now: now);
      };
      final lost = await fixture.scan(clock: () => now);
      expect(lost.busy, isTrue);
      expect(fixture.opened, hasLength(1), reason: 'stopped at the next file');
      fixture.onRead = null;
      expect((await fixture.scan(clock: () => now)).busy, isTrue, reason: 'the lease is still the other scan\'s');

      other.releaseScanLease(owner);
      final again = await fixture.scan(clock: () => now);
      expect((again.busy, again.written), (false, 3));
    });

    test('what a scan that lost its lease wrote still counts once the next one went through', () {
      final summary = const ScanSummary(written: 2, busy: true).then(const ScanSummary(written: 1, removed: 1));
      expect((summary.busy, summary.written, summary.removed, summary.hasChanges), (false, 3, 1, true));
    });

    test('a file that could not be read is read again at the next scans, until it can be', () async {
      final index = openIndex();
      index.setCheckpoint(index.changesSince(0).seq);
      final path = p.join(fixture.files.path, 'Photos', 'held.jpg');
      fixture
        ..write('Photos/held.jpg', jpegBytes(width: 30, height: 20))
        ..failing.add(path);
      await fixture.scan();
      final id = fixture.ids.file(rootId, 'held.jpg');
      expect((index.file(id)!.width, index.file(id)!.readFailed), (null, true));
      // The app shows it already, dated by the file
      expect(index.changesSince(index.checkpoint).updates.map((file) => file.name), ['held.jpg']);
      index.setCheckpoint(index.seq);

      fixture.opened.clear();
      await fixture.scan();
      expect(fixture.opened, [path]);
      expect(index.seq, index.checkpoint, reason: 'still not readable: nothing new for the app');

      fixture.failing.clear();
      await fixture.scan();
      final read = index.file(id)!;
      expect((read.width, read.height, read.readFailed), (30, 20, false));
      expect(index.changesSince(index.checkpoint).updates.map((file) => file.name), ['held.jpg']);

      fixture.opened.clear();
      await fixture.scan();
      expect(fixture.opened, isEmpty);
    });
  });

  group('ids', () {
    test('are keyed per library: the same in every connection, another library gets another key', () {
      final id = openIndex().ids.file('win-0000beef:/Photos', 'a.jpg');
      expect(openIndex().ids.file('win-0000beef:/Photos', 'a.jpg'), id);
      expect(fixture.ids.file('win-0000beef:/Photos', 'a.jpg'), id);

      final other = TestLibrary();
      addTearDown(other.dispose);
      expect(other.ids.file('win-0000beef:/Photos', 'a.jpg'), isNot(id));
    });

    test('an index of the first version gets a key, and its files their keyed ids at the next scan', () async {
      fixture.write('Photos/a.jpg', jpegBytes(width: 10, height: 10));
      final rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Photos')).id;
      // The first schema: no key, no read_failed column, a file under the unkeyed id of that version
      const oldId = 'f0123456789abcdef0123456789abcdef01234567';
      sqlite3.open(fixture.indexPath)
        ..execute('ALTER TABLE files DROP COLUMN read_failed')
        ..execute("DELETE FROM meta WHERE key = 'id_key'")
        ..execute(
          'INSERT INTO files (id, root_id, album_id, rel_path, type, size, modified_ms, added_s, created_s, '
          "change_seq) VALUES (?, ?, 'd0', 'a.jpg', 1, 1, 1, 1, 1, 1)",
          [oldId, rootId],
        )
        ..execute("UPDATE meta SET value = 1 WHERE key = 'seq'")
        ..execute('PRAGMA user_version = 1')
        ..close();

      final index = openIndex();
      await fixture.scan();
      expect(index.file(oldId), isNull);
      expect(index.file(fixture.ids.file(rootId, 'a.jpg'))!.width, 10);
      final delta = index.changesSince(0);
      expect(delta.deletes, [oldId]);
      expect(delta.updates.map((file) => file.id), [fixture.ids.file(rootId, 'a.jpg')]);
    });
  });

  group('files kept online only', () {
    late String rootId;
    late File cloud;

    setUp(() {
      fixture.write('OneDrive/Pictures/local.jpg', jpegBytes(width: 10, height: 10));
      cloud = fixture.write('OneDrive/Pictures/cloud.jpg', jpegBytes(width: 20, height: 20));
      // What OneDrive sets on a file it keeps in the cloud
      fixture.attributes[cloud.path] = fileAttributeReparsePoint | fileAttributeRecallOnDataAccess;
      rootId = fixture.library().addRoot(p.join(fixture.files.path, 'OneDrive', 'Pictures')).id;
    });

    test('are counted, never read and never shown', () async {
      final summary = await fixture.scan();
      expect(summary.cloudOnly, 1);
      expect(fixture.opened, isNot(contains(cloud.path)));

      final index = openIndex();
      expect(index.changesSince(0).updates.map((file) => file.name), ['local.jpg']);
      expect(index.albums().single.assetCount, 1);
      final root = fixture.library().roots().single;
      expect((root.fileCount, root.cloudOnlyCount), (1, 1));
    });

    test('come in, read, once the user chooses "Download and include"', () async {
      await fixture.scan();
      final index = openIndex();
      index.setCheckpoint(index.changesSince(0).seq);

      fixture.library().includeCloudOnly(rootId);
      await fixture.scan();

      expect(fixture.opened, contains(cloud.path));
      expect(index.changesSince(index.checkpoint).updates.map((file) => file.name), ['cloud.jpg']);
      expect(index.file(fixture.ids.file(rootId, 'cloud.jpg'))!.width, 20);
    });

    test('a shown file whose space the cloud client freed leaves the local tables', () async {
      final local = File(p.join(fixture.files.path, 'OneDrive', 'Pictures', 'local.jpg'));
      await fixture.scan();
      final index = openIndex();
      index.setCheckpoint(index.changesSince(0).seq);

      fixture.attributes[local.path] = fileAttributeRecallOnDataAccess;
      // The cloud client changes the attributes; the date tells the scan to look again
      local.setLastModifiedSync(DateTime(2030));
      await fixture.scan();

      expect(index.changesSince(index.checkpoint).deletes, [fixture.ids.file(rootId, 'local.jpg')]);
    });
  });

  group('drives', () {
    late Directory driveE;
    late String rootId;
    late List<String> ids;

    setUp(() async {
      driveE = Directory(p.join(fixture.dir.path, 'E'))..createSync();
      fixture.probe.mounts
        ..clear()
        ..[driveE.path] = 'win-1a2b3c4d';
      fixture
        ..write('Footage/X4/VID_1.insv', mp4Bytes(width: 2880, height: 2880, durationMs: 5000), base: driveE)
        ..write('Footage/X4/IMG_2.insp', jpegBytes(width: 6080, height: 3040), base: driveE);
      rootId = fixture.library().addRoot(p.join(driveE.path, 'Footage')).id;
      await fixture.scan();
      final index = openIndex();
      ids = index.changesSince(0).updates.map((file) => file.id).toList()..sort();
      index.setCheckpoint(index.seq);
      fixture.opened.clear();
    });

    test('a drive that comes back under another letter keeps its ids, with nothing to sync', () async {
      // E: becomes F:
      final driveF = driveE.renameSync(p.join(fixture.dir.path, 'F'));
      fixture.probe.mounts
        ..clear()
        ..[driveF.path] = 'win-1a2b3c4d';

      final summary = await fixture.scan();
      expect((summary.moved, summary.written, summary.removed), (1, 0, 0));
      expect(fixture.opened, isEmpty);

      final index = openIndex();
      expect(index.changesSince(index.checkpoint).updates, isEmpty);
      expect(index.changesSince(index.checkpoint).deletes, isEmpty);
      final library = fixture.library();
      expect(library.roots().single.path, p.join(driveF.path, 'Footage'));
      expect(library.roots().single.id, rootId);
      for (final id in ids) {
        expect(library.file(id)!.path, startsWith(driveF.path));
      }
    });

    test('a drive that is not connected keeps its files as they were', () async {
      driveE.renameSync(p.join(fixture.dir.path, 'unplugged'));
      fixture.probe.mounts.clear();

      final summary = await fixture.scan();
      expect((summary.unavailable, summary.removed), (1, 0));

      final library = fixture.library();
      expect(library.roots().single.available, isFalse);
      final file = library.file(ids.first)!;
      expect((file.available, file.readable), (false, false));
      final index = openIndex();
      expect(index.changesSince(index.checkpoint).deletes, isEmpty);
    });

    test('another drive under the old letter is not taken for the old one', () async {
      driveE.renameSync(p.join(fixture.dir.path, 'away'));
      final other = Directory(p.join(fixture.dir.path, 'E'))..createSync();
      fixture.write('Footage/other.jpg', jpegBytes(width: 1, height: 1), base: other);
      fixture.probe.mounts
        ..clear()
        ..[other.path] = 'win-99999999';

      final summary = await fixture.scan();
      expect(summary.unavailable, 1);
      expect(fixture.opened, isEmpty);
    });
  });

  group('network folders', () {
    late Directory share;
    late DateTime start;

    setUp(() async {
      share = Directory(p.join(fixture.dir.path, 'nas'))..createSync();
      fixture.probe.mounts[share.path] = 'net-//nas/photos';
      fixture
        ..write('2024/IMG_1.jpg', jpegBytes(width: 1, height: 1), base: share)
        ..write('Local/IMG_1.jpg', jpegBytes(width: 1, height: 1));
      final library = fixture.library();
      expect(library.addRoot(share.path).isNetwork, isTrue);
      library.addRoot(p.join(fixture.files.path, 'Local'));
      start = DateTime.now();
      expect((await fixture.scan(clock: () => start)).written, 2);
      fixture.opened.clear();
    });

    DateTime Function() after(int minutes) =>
        () => start.add(Duration(minutes: minutes));

    test('are rescanned only now and then, while the local folders are scanned every time', () async {
      fixture
        ..write('2024/IMG_2.jpg', jpegBytes(width: 1, height: 1), base: share)
        ..write('Local/IMG_2.jpg', jpegBytes(width: 1, height: 1));

      final soon = await fixture.scan(clock: after(5));
      expect(soon.written, 1, reason: 'the local folder only');
      expect(fixture.opened.where((path) => p.isWithin(share.path, path)), isEmpty);

      final later = await fixture.scan(clock: after(16));
      expect(later.written, 1, reason: 'the share, due again');
    });

    test('are rescanned when the user asks (Refresh)', () async {
      fixture.write('2024/IMG_2.jpg', jpegBytes(width: 1, height: 1), base: share);
      expect((await fixture.scan(clock: after(1), everyRoot: true)).written, 1);
    });

    test('a share that dropped keeps its files, is looked for at every scan, and is read once back', () async {
      final away = share.renameSync(p.join(fixture.dir.path, 'away'));
      fixture.probe.mounts.remove(share.path);
      // Not probed in between: a share that dropped can take the system's whole time out to answer
      expect((await fixture.scan(clock: after(1))).unavailable, 0);
      final dropped = await fixture.scan(clock: after(16));
      expect((dropped.unavailable, dropped.removed), (1, 0));

      away.renameSync(share.path);
      fixture.probe.mounts[share.path] = 'net-//nas/photos';
      final back = await fixture.scan(clock: after(17));
      expect((back.unavailable, back.removed), (0, 0));
      expect(fixture.library().roots().every((root) => root.available), isTrue);
    });
  });

  group('roots', () {
    test('a folder inside a root is already there; a folder around roots replaces them, keeping the ids', () async {
      fixture
        ..write('Photos/2024/a.jpg', jpegBytes(width: 1, height: 1))
        ..write('Photos/2025/b.jpg', jpegBytes(width: 1, height: 1));
      final library = fixture.library();
      final inner = library.addRoot(p.join(fixture.files.path, 'Photos', '2024'));
      await library.scan();
      final id = openIndex().changesSince(0).updates.single.id;

      expect(library.addRoot(p.join(fixture.files.path, 'Photos', '2024')).id, inner.id);
      final outer = library.addRoot(p.join(fixture.files.path, 'Photos'));
      expect(library.roots().map((root) => root.id), [outer.id]);
      await library.scan();

      final index = openIndex();
      expect(index.file(id), isNotNull, reason: 'same file, same id under the wider root');
      expect(index.changesSince(0).deletes, isEmpty, reason: 'the file came back in the same sync');
      expect(library.addRoot(p.join(fixture.files.path, 'Photos', '2025')).id, outer.id);
    });

    test('removing a root takes its files out of the library, not off the disk', () async {
      final file = fixture.write('Photos/a.jpg', jpegBytes(width: 1, height: 1));
      final library = fixture.library();
      final root = library.addRoot(p.join(fixture.files.path, 'Photos'));
      await library.scan();
      final index = openIndex();
      index.setCheckpoint(index.changesSince(0).seq);

      library.removeRoot(root.id);
      expect(library.roots(), isEmpty);
      expect(index.fullSyncNeeded, isTrue);
      expect(index.changesSince(index.checkpoint).deletes, [fixture.ids.file(root.id, 'a.jpg')]);
      expect(file.existsSync(), isTrue);
    });

    test('a path that is no folder is refused', () {
      final library = fixture.library();
      expect(() => library.addRoot(p.join(fixture.files.path, 'missing')), throwsA(isA<Exception>()));
    });
  });
}
