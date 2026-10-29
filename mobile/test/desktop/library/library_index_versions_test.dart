// Schemas 3 and 4 of the index of the folder library: what the XMP of a file made by Immuch360 says, read by the scan,
// kept in six columns (its kind since schema 4: a 3D photo, a 3D scene, a 360° panorama, a 360° 3D panorama), and how
// an index of schema 2 or 3 gets them.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
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
      expect(version.immersiveKind, ImmersiveKind.stereoPhoto);
      expect(version.version, (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto));

      for (final name in ['salon.jpg', 'beach_LRF_Full_SBS.jpg']) {
        final file = index.file(fixture.ids.file(rootId, name))!;
        expect(
          (file.stereo, file.origin, file.sourceSha1, file.derivativeId, file.derivedSettings, file.isGenerated),
          (null, null, null, null, null, false),
          reason: name,
        );
        expect((file.immersiveKind, file.version), (null, null), reason: name);
      }
    });

    test('reads the kind of a 3D scene, a 360° panorama and a 360° 3D panorama, each with its own settings', () async {
      final scene = sceneVersionXmp(original);
      final panorama = panoramaVersionXmp(original);
      final ofPanorama = stereoPanoramaVersionXmp(original, parent: panorama);
      final ofPhoto360 = stereoPanoramaVersionXmp(original);
      fixture
        ..write('Photos/salon_scene3D.jpg', versionFileOf(scene))
        ..write('Photos/salon_360.jpg', versionFileOf(panorama))
        ..write('Photos/salon_360_3D.jpg', versionFileOf(ofPanorama))
        // Renamed: the XMP decides, never the name
        ..write('Photos/my sphere in 3D.jpg', versionFileOf(ofPhoto360));
      await fixture.scan();
      final index = fixture.index();
      IndexedFile file(String name) => index.file(fixture.ids.file(rootId, name))!;

      final read = {
        for (final name in ['salon_scene3D.jpg', 'salon_360.jpg', 'salon_360_3D.jpg', 'my sphere in 3D.jpg'])
          name: file(name),
      };
      expect(
        {for (final MapEntry(key: name, value: file) in read.entries) name: file.version},
        {
          'salon_scene3D.jpg': (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
          'salon_360.jpg': (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360),
          'salon_360_3D.jpg': (origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360),
          'my sphere in 3D.jpg': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPanorama360),
        },
      );
      // None is a side by side 3D photo; the panoramas are 360° for the rules of the app
      expect(read.values.map((file) => file.stereo), everyElement(isNull));
      expect(read.values.map((file) => file.projection), [
        null,
        'equirectangular',
        'equirectangular',
        'equirectangular',
      ]);
      expect(read.values.map((file) => file.sourceSha1), everyElement(sha1Base64(original)));
      // The settings of each kind (design-final 2026-10-27, section 8.6), the key of "a version with the same settings"
      expect(file('salon_scene3D.jpg').derivedSettings, scene.settingsKey);
      expect(scene.settingsKey, startsWith('${scene.geometryModelSha256}|${scene.inpaintModelSha256}|scene-v1|'));
      expect(file('salon_360.jpg').derivedSettings, panorama.settingsKey);
      expect(file('salon_360_3D.jpg').derivedSettings, ofPanorama.settingsKey);
      expect(read.values.map((file) => file.derivedSettings), everyElement(isNotNull));

      expect(
        index.filesDerivedFrom(sha1Base64(original)).map((file) => file.name),
        unorderedEquals(['salon_3D_LRF_Full_SBS.jpg', ...read.keys]),
      );
      expect(index.generatedFileIds(), hasLength(5));
      expect(index.generatedVersions(), {
        fixture.ids.file(rootId, 'salon_3D_LRF_Full_SBS.jpg'): (
          origin: IndexedOrigin.estimated,
          kind: ImmersiveKind.stereoPhoto,
        ),
        for (final file in read.values) file.id: file.version,
      });
    });

    test('reads the fixtures of the contracts of phases 2 and 3', () async {
      String sample(String name) => File('test/fixtures/ai_immersive/$name').readAsStringSync();
      final tiny = File('test/fixtures/ai_immersive/tiny_scene3D.jpg').readAsBytesSync();
      fixture
        ..write('Photos/tiny_scene3D.jpg', tiny)
        ..write('Photos/scene.jpg', jpegBytes(width: 32, height: 24, xmp: sample('xmp_v1_scene_sample.xmp')))
        ..write('Photos/pano.jpg', jpegBytes(width: 64, height: 32, xmp: sample('xmp_v1_panorama_sample.xmp')))
        ..write(
          'Photos/pano3d.jpg',
          jpegBytes(width: 64, height: 64, xmp: sample('xmp_v1_stereo_panorama_sample.xmp')),
        );
      await fixture.scan();
      final index = fixture.index();
      IndexedFile file(String name) => index.file(fixture.ids.file(rootId, name))!;

      for (final (name, xmp) in [
        ('tiny_scene3D.jpg', ImmersiveXmp.findIn(tiny)!),
        ('scene.jpg', ImmersiveXmp.parse(sample('xmp_v1_scene_sample.xmp'))!),
        ('pano.jpg', ImmersiveXmp.parse(sample('xmp_v1_panorama_sample.xmp'))!),
        ('pano3d.jpg', ImmersiveXmp.parse(sample('xmp_v1_stereo_panorama_sample.xmp'))!),
      ]) {
        final indexed = file(name);
        expect(indexed.immersiveKind, xmp.kind, reason: name);
        expect(indexed.derivedSettings, xmp.settingsKey, reason: name);
        expect(indexed.derivativeId, xmp.derivativeId, reason: name);
        expect(indexed.sourceSha1, xmp.sourceSha1, reason: name);
        expect(indexed.stereo, isNull, reason: name);
      }
      expect(file('tiny_scene3D.jpg').version, (
        origin: IndexedOrigin.reconstructed,
        kind: ImmersiveKind.volumetricScene,
      ));
      expect(file('scene.jpg').version, (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene));
      expect(file('pano.jpg').version, (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360));
      expect(file('pano3d.jpg').immersiveKind, ImmersiveKind.stereoPanorama360);
    });

    test('a kind this build does not know keeps the link and the place out of the backup, without a kind', () async {
      final later = versionXmp(
        original,
      ).toXml().replaceFirst('Immuch360:Kind="StereoPhoto"', 'Immuch360:Kind="Hologram"');
      fixture.write('Photos/salon_hologram.jpg', jpegBytes(width: 16, height: 6, xmp: later));
      await fixture.scan();
      final index = fixture.index();

      final file = index.file(fixture.ids.file(rootId, 'salon_hologram.jpg'))!;
      expect((file.isGenerated, file.immersiveKind, file.stereo), (true, null, null));
      expect(file.sourceSha1, sha1Base64(original));
      expect(index.generatedVersions()[file.id], (origin: IndexedOrigin.estimated, kind: null));
    });

    test('a scene changed and not readable keeps its kind and its settings until it is read again', () async {
      final scene = sceneVersionXmp(original);
      fixture.write('Photos/salon_scene3D.jpg', versionFileOf(scene));
      await fixture.scan();
      final id = fixture.ids.file(rootId, 'salon_scene3D.jpg');

      fixture
        ..write('Photos/salon_scene3D.jpg', versionFileOf(scene), modified: DateTime(2030))
        ..failing.add(p.join(fixture.files.path, 'Photos', 'salon_scene3D.jpg'));
      await fixture.scan();

      final held = fixture.index().file(id)!;
      expect(held.readFailed, isTrue);
      expect(held.version, (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene));
      expect(held.derivedSettings, scene.settingsKey);
    });

    test('a new version of any kind that cannot be read waits for a scan that can; other files never wait', () async {
      final versions = {
        'salon_scene3D.jpg': versionFileOf(sceneVersionXmp(original)),
        'salon_360 (2).jpg': versionFileOf(panoramaVersionXmp(original)),
        'salon_360_3D.jpg': versionFileOf(stereoPanoramaVersionXmp(original)),
      };
      final others = {
        'trip_3D.mp4': mp4Bytes(width: 32, height: 9, durationMs: 1000),
        'salon_3600.jpg': jpegBytes(width: 40, height: 30),
      };
      for (final MapEntry(key: name, value: bytes) in {...versions, ...others}.entries) {
        fixture
          ..write('Photos/$name', bytes)
          ..failing.add(p.join(fixture.files.path, 'Photos', name));
      }
      await fixture.scan();
      final index = fixture.index();

      for (final name in versions.keys) {
        expect(index.file(fixture.ids.file(rootId, name)), isNull, reason: name);
      }
      for (final name in others.keys) {
        expect(index.file(fixture.ids.file(rootId, name))!.readFailed, isTrue, reason: name);
      }

      fixture.failing.clear();
      await fixture.scan();
      for (final name in versions.keys) {
        expect(index.file(fixture.ids.file(rootId, name))!.isGenerated, isTrue, reason: name);
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
        // Those of one folder alone, without the original nor another tool's file beside them
        final beside = index.file(fixture.ids.file(rootId, 'salon_3D_LRF_Full_SBS.jpg'))!;
        expect(index.generatedFilesOfAlbum(beside.albumId).map((file) => file.relativePath), [
          'salon_3D_LRF_Full_SBS.jpg',
        ]);
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
      expect(
        (file('no_id.jpg').origin, file('no_id.jpg').isGenerated, file('no_id.jpg').immersiveKind),
        (null, false, null),
      );
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
      expect(db.select('PRAGMA user_version').first.values.first, 4);
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

  group('an index of schema 3', () {
    const rootId = 'win-0000beef:/Photos';
    final key = Uint8List.fromList(List.generate(libraryIdKeyLength, (i) => (i * 29 + 7) & 0xff));
    final ids = LibraryIds(key);
    late Uint8List original;
    late Map<String, ImmersiveXmp> made;

    // The schema of phase 1, as library_index.dart created it, with the files a build of phase 1 scanned and what it
    // made of them: an original, a 3D photo, then a 3D scene, a 360° panorama and its 3D version another computer
    // wrote. Phase 1 read every kind with the reader of the 3D photos: a scene had the Origin it did not know ("other"),
    // no settings, and none had a kind.
    void writeSchema3() {
      original = jpegBytes(width: 40, height: 30);
      final panorama = panoramaVersionXmp(original);
      made = {
        'salon_3D_LRF_Full_SBS.jpg': versionXmp(original),
        'salon_scene3D.jpg': sceneVersionXmp(original),
        'salon_360.jpg': panorama,
        'salon_360_3D.jpg': stereoPanoramaVersionXmp(original, parent: panorama),
      };
      final files = {
        'salon.jpg': fixture.write('Photos/salon.jpg', original, modified: DateTime(2026, 10, 1)),
        for (final (index, MapEntry(key: name, value: xmp)) in made.entries.indexed)
          name: fixture.write(
            'Photos/$name',
            xmp is StereoPhotoXmp ? fakeSbsJpeg(xmp: xmp) : versionFileOf(xmp),
            modified: DateTime(2026, 10, 2 + index),
          ),
      };
      // What the scan of phase 1 kept: stereo, origin, the sum of the original, the id, the settings
      final phase1 = <String, List<Object?>>{
        'salon_3D_LRF_Full_SBS.jpg': ['sbsFull', 'estimated', made['salon_3D_LRF_Full_SBS.jpg']!.settingsKey],
        'salon_scene3D.jpg': [null, 'other', null],
        'salon_360.jpg': [null, 'generated', null],
        'salon_360_3D.jpg': [null, 'generated', null],
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
            read_failed INTEGER NOT NULL DEFAULT 0,
            stereo TEXT,
            origin TEXT,
            source_sha1 TEXT,
            derivative_id TEXT,
            derived_settings TEXT
          )''')
        ..execute('CREATE INDEX files_by_album ON files (album_id)')
        ..execute('CREATE INDEX files_by_root ON files (root_id)')
        ..execute('CREATE INDEX files_by_change ON files (change_seq)')
        ..execute('CREATE INDEX files_by_source ON files (source_sha1)')
        ..execute('CREATE INDEX files_generated ON files (id) WHERE origin IS NOT NULL')
        ..execute('CREATE TABLE tombstones (id TEXT PRIMARY KEY, change_seq INTEGER NOT NULL)')
        ..execute('INSERT INTO meta (key, value) VALUES (?, ?)', ['id_key', key])
        ..execute("INSERT INTO meta (key, value) VALUES ('seq', 1)")
        ..execute("INSERT INTO meta (key, value) VALUES ('checkpoint', 1)")
        ..execute("INSERT INTO meta (key, value) VALUES ('full_sync', 0)")
        ..execute(
          'INSERT INTO roots (id, path, volume_key, path_in_volume, added_ms, scanned_ms) VALUES (?, ?, ?, ?, 1, 1)',
          [rootId, p.join(fixture.files.path, 'Photos'), 'win-0000beef', '/Photos'],
        );
      for (final MapEntry(key: name, value: file) in files.entries) {
        final stat = file.statSync();
        final xmp = made[name];
        final [stereo, origin, settings] = phase1[name] ?? const [null, null, null];
        db.execute(
          'INSERT INTO files (id, root_id, album_id, rel_path, type, size, modified_ms, added_s, created_s, width, '
          'height, change_seq, stereo, origin, source_sha1, derivative_id, derived_settings) '
          'VALUES (?, ?, ?, ?, 1, ?, ?, 1, 1, 16, 9, 1, ?, ?, ?, ?, ?)',
          [
            ids.file(rootId, name),
            rootId,
            ids.album(rootId, ''),
            name,
            stat.size,
            stat.modified.millisecondsSinceEpoch,
            stereo,
            origin,
            xmp?.sourceSha1,
            xmp?.derivativeId,
            settings,
          ],
        );
      }
      db
        ..execute('PRAGMA user_version = 3')
        ..close();
    }

    test('gets the kind column, and asks for a full sync, its files kept as they were', () {
      writeSchema3();
      final index = fixture.index();

      final db = sqlite3.open(fixture.indexPath);
      addTearDown(db.close);
      expect(db.select('PRAGMA user_version').first.values.first, 4);
      final columns = {for (final row in db.select('PRAGMA table_info(files)')) row['name'] as String};
      expect(columns, contains('immersive_kind'));

      final photo = index.file(ids.file(rootId, 'salon.jpg'))!;
      expect((photo.origin, photo.immersiveKind, photo.readFailed), (null, null, false));
      final scene = index.file(ids.file(rootId, 'salon_scene3D.jpg'))!;
      expect((scene.origin, scene.immersiveKind, scene.isGenerated), (IndexedOrigin.other, null, true));
      // The album of the versions has a new name, which a full sync brings to the local tables
      expect(index.fullSyncNeeded, isTrue);
      // Nothing changed for the app: no new generation
      expect(index.seq, 1);
      expect(index.changesSince(index.checkpoint).updates, isEmpty);
    });

    test('the next scan reads again only the files phase 1 knew as made by the app, and fills their kind', () async {
      writeSchema3();
      final index = fixture.index();
      for (final name in made.keys) {
        expect(index.file(ids.file(rootId, name))!.readFailed, isTrue, reason: name);
      }

      await fixture.scan();

      expect(fixture.opened.map(p.basename), unorderedEquals(made.keys));
      IndexedFile file(String name) => index.file(ids.file(rootId, name))!;
      expect(
        {for (final name in made.keys) name: file(name).version},
        {
          'salon_3D_LRF_Full_SBS.jpg': (origin: IndexedOrigin.estimated, kind: ImmersiveKind.stereoPhoto),
          // Read again with its kind: a scene, no longer "other"
          'salon_scene3D.jpg': (origin: IndexedOrigin.reconstructed, kind: ImmersiveKind.volumetricScene),
          'salon_360.jpg': (origin: IndexedOrigin.generated, kind: ImmersiveKind.panorama360),
          'salon_360_3D.jpg': (origin: IndexedOrigin.generated, kind: ImmersiveKind.stereoPanorama360),
        },
      );
      for (final MapEntry(key: name, value: xmp) in made.entries) {
        expect((file(name).derivedSettings, file(name).readFailed), (xmp.settingsKey, false), reason: name);
      }
      expect(file('salon_3D_LRF_Full_SBS.jpg').stereo, IndexedStereo.sbsFull);
      // The app hears of them; they stay in the album of the versions all along
      expect(index.changesSince(index.checkpoint).updates.map((file) => file.name), unorderedEquals(made.keys));
      expect(index.generatedFileIds(), hasLength(made.length));
    });

    test('a version not readable at that scan keeps what phase 1 said, and is read again later', () async {
      writeSchema3();
      final index = fixture.index();
      final path = p.join(fixture.files.path, 'Photos', 'salon_scene3D.jpg');
      fixture.failing.add(path);

      await fixture.scan();
      final held = index.file(ids.file(rootId, 'salon_scene3D.jpg'))!;
      expect((held.origin, held.immersiveKind, held.readFailed), (IndexedOrigin.other, null, true));

      fixture.failing.clear();
      await fixture.scan();
      final read = index.file(ids.file(rootId, 'salon_scene3D.jpg'))!;
      expect(
        (read.origin, read.immersiveKind, read.readFailed),
        (IndexedOrigin.reconstructed, ImmersiveKind.volumetricScene, false),
      );
    });
  });

  test('names like a version, which a scan that cannot read the file holds back', () {
    for (final name in [
      'salon_3D_LRF_Full_SBS.jpg',
      'salon_3D_LRF_Full_SBS (1).png',
      'salon_scene3D.jpg',
      'salon_scene3d (2).JPG',
      'salon_360.jpg',
      'salon_360_3D.jpeg',
      'PANO_0001_3D.jpg',
    ]) {
      expect(isNamedLikeVersion(name), isTrue, reason: name);
    }
    for (final name in ['salon.jpg', 'salon_3600.jpg', 'salon_360.mp4', 'trip_3D.mkv', 'salon_scene3Dmax.jpg']) {
      expect(isNamedLikeVersion(name), isFalse, reason: name);
    }
  });

  test('an index made new has schema 4 at once', () {
    final index = fixture.index();
    expect(index.generatedFileIds(), isEmpty);
    final db = sqlite3.open(fixture.indexPath);
    addTearDown(db.close);
    expect(db.select('PRAGMA user_version').first.values.first, 4);
  });
}
