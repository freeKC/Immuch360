// Schema 3 of the index of the folder library: what the XMP of a 3D photo made by Immuch360 says, read by the scan,
// kept in five columns, and how an index of schema 2 gets them.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../ai/fakes/fake_immersive_engine.dart';
import '../ai/library/version_fixtures.dart';
import 'library_fixtures.dart';
import 'library_test_support.dart';

void main() {
  late TestLibrary fixture;

  setUp(() {
    fixture = TestLibrary();
    fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
  });
  tearDown(() => fixture.dispose());

  group('a scan', () {
    late Uint8List original;
    late StereoPhotoXmp xmp;
    late String rootId;

    setUp(() {
      original = jpegBytes(width: 40, height: 30);
      xmp = versionXmp(original);
      fixture
        ..write('Photos/salon.jpg', original)
        ..write('Photos/salon_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: xmp))
        // Another tool's side by side photo: the name alone makes nothing of it
        ..write('Photos/beach_LRF_Full_SBS.jpg', jpegBytes(width: 80, height: 30));
      rootId = fixture.library().addRoot(p.join(fixture.files.path, 'Photos')).id;
    });

    test('fills the columns of a version from its XMP, and leaves every other file without them', () async {
      await fixture.scan();
      final index = fixture.index();

      final version = index.file(fixture.ids.file(rootId, 'salon_3D_LRF_Full_SBS.jpg'))!;
      expect(version.stereo, IndexedStereo.sbsFull);
      expect(version.origin, IndexedOrigin.estimated);
      expect(version.isGenerated, isTrue);
      expect(version.sourceSha1, sha1Base64(original));
      expect(version.derivativeId, xmp.derivativeId);
      expect(version.derivedSettings, xmp.settingsKey);
      expect(version.derivedSettings, '$depthModelOnnxSha256|relief-v1|0.02|0.5|0');

      for (final name in ['salon.jpg', 'beach_LRF_Full_SBS.jpg']) {
        final file = index.file(fixture.ids.file(rootId, name))!;
        expect(
          (file.stereo, file.origin, file.sourceSha1, file.derivativeId, file.derivedSettings, file.isGenerated),
          (null, null, null, null, null, false),
          reason: name,
        );
      }
    });

    test(
      'finds the versions of an original in every folder, and keeps them as the album of the generated photos',
      () async {
        // A second version, with other settings, moved to another folder
        fixture.write(
          'Photos/3D/salon_3D_LRF_Full_SBS (1).jpg',
          fakeSbsJpeg(xmp: versionXmp(original, quarterTurns: 1)),
        );
        await fixture.scan();
        final index = fixture.index();
        final sha1 = sha1Base64(original);

        final versions = index.filesDerivedFrom(sha1);
        expect(
          versions.map((file) => file.relativePath),
          unorderedEquals(['salon_3D_LRF_Full_SBS.jpg', '3D/salon_3D_LRF_Full_SBS (1).jpg']),
        );
        expect(versions.map((file) => file.derivedSettings).toSet(), hasLength(2));
        expect(index.filesDerivedFrom('AAAAAAAAAAAAAAAAAAAAAAAAAAA='), isEmpty);

        expect(index.generatedFileIds(), unorderedEquals(versions.map((file) => file.id)));
        expect(index.generatedFiles().map((file) => file.id), unorderedEquals(versions.map((file) => file.id)));
        final summary = index.generatedSummary();
        expect(summary.assetCount, 2);
        expect(summary.updatedSeconds, greaterThan(0));
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        expect(index.countGeneratedAddedSince(now - 3600), 2);
        expect(index.countGeneratedAddedSince(now + 3600), 0);
        expect(index.generatedFiles(changedAfterSeconds: now + 3600), isEmpty);
      },
    );

    test('a file of a newer format keeps its link and its place in the album, but is not shown in 3D', () async {
      final newer = versionXmp(
        original,
      ).toXml().replaceFirst('Immuch360:FormatVersion="1"', 'Immuch360:FormatVersion="2"');
      final half = versionXmp(original).toXml().replaceFirst('SideBySideFull', 'SideBySideHalf');
      fixture
        ..write('Photos/newer.jpg', jpegBytes(width: 16, height: 6, xmp: newer))
        ..write('Photos/half.jpg', jpegBytes(width: 16, height: 6, xmp: half));
      await fixture.scan();
      final index = fixture.index();

      final fromNewer = index.file(fixture.ids.file(rootId, 'newer.jpg'))!;
      expect((fromNewer.stereo, fromNewer.origin, fromNewer.isGenerated), (null, IndexedOrigin.estimated, true));
      expect(fromNewer.sourceSha1, isNotNull);
      expect(index.file(fixture.ids.file(rootId, 'half.jpg'))!.stereo, IndexedStereo.sbsHalf);
    });

    test('a file the app made is in the album whatever its Origin says, as long as it has our id', () async {
      String withOrigin(String origin) =>
          versionXmp(original).toXml().replaceFirst('Immuch360:Origin="EstimatedDepth"', 'Immuch360:Origin="$origin"');
      // A later format, the "two views" variant of a newer computer for example
      final later = withOrigin('TwoViews');
      fixture
        ..write('Photos/generated.jpg', jpegBytes(width: 16, height: 6, xmp: withOrigin('GeneratedContent')))
        ..write('Photos/later.jpg', jpegBytes(width: 16, height: 6, xmp: later))
        ..write(
          'Photos/no_id.jpg',
          jpegBytes(width: 16, height: 6, xmp: later.replaceFirst(RegExp('Immuch360:DerivativeId="[^"]*"'), '')),
        );
      await fixture.scan();
      final index = fixture.index();
      IndexedFile file(String name) => index.file(fixture.ids.file(rootId, name))!;

      expect((file('generated.jpg').origin, file('generated.jpg').isGenerated), (IndexedOrigin.generated, true));
      expect(
        (file('later.jpg').origin, file('later.jpg').isGenerated, file('later.jpg').sourceSha1),
        (IndexedOrigin.other, true, sha1Base64(original)),
      );
      expect((file('no_id.jpg').origin, file('no_id.jpg').isGenerated), (null, false));
      expect(
        index.generatedFileIds(),
        unorderedEquals([
          for (final name in ['salon_3D_LRF_Full_SBS.jpg', 'generated.jpg', 'later.jpg']) file(name).id,
        ]),
      );
    });

    test('a version rewritten without its XMP becomes a plain photo, in the next delta', () async {
      await fixture.scan();
      final index = fixture.index();
      index.setCheckpoint(index.changesSince(0).seq);
      expect(index.generatedFileIds(), hasLength(1));

      fixture.write('Photos/salon_3D_LRF_Full_SBS.jpg', jpegBytes(width: 16, height: 6), modified: DateTime(2030));
      await fixture.scan();

      final changed = index.changesSince(index.checkpoint).updates.single;
      expect((changed.name, changed.origin, changed.sourceSha1), ('salon_3D_LRF_Full_SBS.jpg', null, null));
      expect(index.generatedFileIds(), isEmpty);
      expect(index.generatedSummary(), (assetCount: 0, updatedSeconds: 0));
    });

    test('a version kept online only is never read, so never in the album', () async {
      final cloud = fixture.write('Photos/cloud_3D_LRF_Full_SBS.jpg', fakeSbsJpeg(xmp: versionXmp(original)));
      // What OneDrive sets on a file it keeps in the cloud
      fixture.attributes[cloud.path] = fileAttributeReparsePoint | fileAttributeRecallOnDataAccess;
      await fixture.scan();

      expect(fixture.opened, isNot(contains(cloud.path)));
      expect(fixture.index().generatedFileIds(), [fixture.ids.file(rootId, 'salon_3D_LRF_Full_SBS.jpg')]);
    });
  });

  group('an index of schema 2', () {
    const rootId = 'win-0000beef:/Photos';
    final key = Uint8List.fromList(List.generate(libraryIdKeyLength, (i) => (i * 37 + 11) & 0xff));
    final ids = LibraryIds(key);
    late Uint8List original;

    // The schema of the second version, as library_index.dart created it, with three files the old build scanned:
    // a photo, a 3D photo another computer wrote (its XMP not read by that build) and a video
    void writeSchema2() {
      original = jpegBytes(width: 40, height: 30);
      final files = {
        'salon.jpg': fixture.write('Photos/salon.jpg', original, modified: DateTime(2026, 10, 1)),
        'salon_3D_LRF_Full_SBS.jpg': fixture.write(
          'Photos/salon_3D_LRF_Full_SBS.jpg',
          fakeSbsJpeg(xmp: versionXmp(original)),
          modified: DateTime(2026, 10, 2),
        ),
        'clip.mp4': fixture.write(
          'Photos/clip.mp4',
          mp4Bytes(width: 16, height: 9, durationMs: 1000),
          modified: DateTime(2026, 10, 3),
        ),
      };
      final db = sqlite3.open(fixture.indexPath)
        ..execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value)')
        ..execute('''
          CREATE TABLE roots (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            volume_key TEXT NOT NULL,
            path_in_volume TEXT NOT NULL,
            network INTEGER NOT NULL DEFAULT 0,
            include_cloud_only INTEGER NOT NULL DEFAULT 0,
            available INTEGER NOT NULL DEFAULT 1,
            added_ms INTEGER NOT NULL,
            scanned_ms INTEGER
          )''')
        ..execute('''
          CREATE TABLE files (
            id TEXT PRIMARY KEY,
            root_id TEXT NOT NULL,
            album_id TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            type INTEGER NOT NULL,
            size INTEGER NOT NULL,
            modified_ms INTEGER NOT NULL,
            added_s INTEGER NOT NULL,
            created_s INTEGER NOT NULL,
            width INTEGER,
            height INTEGER,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            playback_style INTEGER NOT NULL DEFAULT 0,
            latitude REAL,
            longitude REAL,
            projection TEXT,
            cloud_only INTEGER NOT NULL DEFAULT 0,
            checksum TEXT,
            checksum_size INTEGER,
            checksum_modified_ms INTEGER,
            change_seq INTEGER NOT NULL,
            read_failed INTEGER NOT NULL DEFAULT 0
          )''')
        ..execute('CREATE INDEX files_by_album ON files (album_id)')
        ..execute('CREATE INDEX files_by_root ON files (root_id)')
        ..execute('CREATE INDEX files_by_change ON files (change_seq)')
        ..execute('CREATE TABLE tombstones (id TEXT PRIMARY KEY, change_seq INTEGER NOT NULL)')
        ..execute('INSERT INTO meta (key, value) VALUES (?, ?)', ['id_key', key])
        ..execute("INSERT INTO meta (key, value) VALUES ('seq', 1)")
        ..execute("INSERT INTO meta (key, value) VALUES ('checkpoint', 1)")
        ..execute(
          'INSERT INTO roots (id, path, volume_key, path_in_volume, added_ms, scanned_ms) VALUES (?, ?, ?, ?, 1, 1)',
          [rootId, p.join(fixture.files.path, 'Photos'), 'win-0000beef', '/Photos'],
        );
      for (final MapEntry(key: name, value: file) in files.entries) {
        final stat = file.statSync();
        db.execute(
          'INSERT INTO files (id, root_id, album_id, rel_path, type, size, modified_ms, added_s, created_s, width, '
          'height, change_seq) VALUES (?, ?, ?, ?, ?, ?, ?, 1, 1, 16, 9, 1)',
          [
            ids.file(rootId, name),
            rootId,
            ids.album(rootId, ''),
            name,
            name.endsWith('.mp4') ? 2 : 1,
            stat.size,
            stat.modified.millisecondsSinceEpoch,
          ],
        );
      }
      db
        ..execute('PRAGMA user_version = 2')
        ..close();
    }

    test('gets the five columns and the index on the checksum of the original, its files kept as they were', () {
      writeSchema2();
      final index = fixture.index();

      final db = sqlite3.open(fixture.indexPath);
      addTearDown(db.close);
      expect(db.select('PRAGMA user_version').first.values.first, 3);
      final columns = {for (final row in db.select('PRAGMA table_info(files)')) row['name'] as String};
      expect(columns, containsAll(['stereo', 'origin', 'source_sha1', 'derivative_id', 'derived_settings']));
      final indexes = {for (final row in db.select('PRAGMA index_list(files)')) row['name'] as String};
      expect(indexes, containsAll(['files_by_source', 'files_generated']));

      expect(index.ids.file(rootId, 'salon.jpg'), ids.file(rootId, 'salon.jpg'));
      final photo = index.file(ids.file(rootId, 'salon.jpg'))!;
      expect((photo.width, photo.height, photo.origin, photo.readFailed), (16, 9, null, false));
      // Nothing changed for the app: no new generation
      expect(index.seq, 1);
      expect(index.changesSince(index.checkpoint).updates, isEmpty);
    });

    test('the next scan reads again only the files named like a 3D photo, and fills their columns', () async {
      writeSchema2();
      final index = fixture.index();
      final versionId = ids.file(rootId, 'salon_3D_LRF_Full_SBS.jpg');
      expect(index.file(versionId)!.readFailed, isTrue);

      await fixture.scan();

      expect(fixture.opened.map(p.basename), ['salon_3D_LRF_Full_SBS.jpg']);
      final version = index.file(versionId)!;
      expect(
        (version.origin, version.stereo, version.readFailed),
        (IndexedOrigin.estimated, IndexedStereo.sbsFull, false),
      );
      expect(version.sourceSha1, sha1Base64(original));
      // The app hears of it, so the version joins the album of the generated photos
      expect(index.changesSince(index.checkpoint).updates.map((file) => file.id), [versionId]);
      expect(index.generatedFileIds(), [versionId]);
    });
  });

  test('an index made new has schema 3 at once', () {
    final index = fixture.index();
    expect(index.generatedFileIds(), isEmpty);
    final db = sqlite3.open(fixture.indexPath);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').first.values.first, 3);
  });
}
