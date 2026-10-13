// The files opened with the program on a computer (lib/desktop/files/opened_files.dart): what is taken from what the
// program is given, how each file is read (the rules of the folder library and of its 360° scan, so that a 360°
// photo or video opened with the program is told as the same file found in a chosen folder), the ids, the registry
// the storage repository reads, and the other file of an X3 pair.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/files/opened_files.dart';
import 'package:immich_mobile/desktop/library/desktop_storage_repository.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:path/path.dart' as p;

import '../../domain/services/spherical_probe_fixtures.dart';
import '../library/library_fixtures.dart';
import '../library/library_test_support.dart';

/// Ids made of the names, for the tests that do not look at them
Future<Map<String, String>> _nameIds(List<String> paths) async => {
  for (final path in paths) path: 'f-${p.basename(path)}',
};

// An equirect 360° photo of a camera: GPano XMP and a 2:1 frame
final _panoramaJpeg = jpegBytes(width: 4000, height: 2000, gpanoProjection: 'equirectangular');

// A 360° video with the spherical metadata of YouTube (sv3d), its frame size in the sample entry only
final _sphericalMp4 = mp4File(
  mp4Moov([
    mp4VideoTrack([mp4Sv3dEquirectangular()], width: 3840, height: 1920),
  ]),
);

void main() {
  late TestLibrary fixture;

  setUp(() {
    fixture = TestLibrary();
    OpenedFiles.clear();
  });

  tearDown(() {
    OpenedFiles.clear();
    fixture.dispose();
  });

  String write(String relative, List<int> bytes, {DateTime? modified}) =>
      fixture.write(relative, bytes, modified: modified).path;

  group('what is opened', () {
    test('a photo or a video as given, the photos and videos of a folder by name, nothing else', () {
      final photo = write('a/IMG_1.jpg', jpegBytes(width: 40, height: 30));
      final text = write('a/notes.txt', utf8.encode('not a photo'));
      final folder = p.join(fixture.files.path, 'card');
      write('card/IMG_10.JPG', jpegBytes(width: 40, height: 30));
      write('card/IMG_2.jpg', jpegBytes(width: 40, height: 30));
      write('card/VID_3.mp4', mp4Bytes(width: 16, height: 9, durationMs: 1000));
      write('card/.hidden.jpg', jpegBytes(width: 40, height: 30));
      write('card/readme.pdf', utf8.encode('%PDF'));
      write('card/sub/IMG_4.jpg', jpegBytes(width: 40, height: 30));

      final listing = listOpenedPaths([photo, text, folder, p.join(fixture.files.path, 'missing.jpg')]);

      expect(listing.fromFolder, isTrue);
      expect(listing.paths.map(p.basename), ['IMG_1.jpg', 'IMG_2.jpg', 'IMG_10.JPG', 'VID_3.mp4']);
    });

    test('one file is not a folder; the same file given twice is taken once; at most so many files', () {
      final photo = write('IMG_1.jpg', jpegBytes(width: 40, height: 30));
      for (var i = 0; i < 5; i++) {
        write('many/IMG_$i.jpg', jpegBytes(width: 40, height: 30));
      }

      final single = listOpenedPaths([photo, photo]);
      expect(single.paths, [photo]);
      expect(single.fromFolder, isFalse);
      expect(listOpenedPaths([p.join(fixture.files.path, 'many')], maxFiles: 3).paths, hasLength(3));
    });

    test('a file a cloud client keeps online only is left out of a folder, as the library leaves it out', () {
      final online = write('cloud/IMG_1.jpg', jpegBytes(width: 40, height: 30));
      write('cloud/IMG_2.jpg', jpegBytes(width: 40, height: 30));

      final listing = listOpenedPaths([
        p.join(fixture.files.path, 'cloud'),
      ], attributes: (path) => path == online ? fileAttributeRecallOnDataAccess : 0);

      expect(listing.paths.map(p.basename), ['IMG_2.jpg']);
    });

    test('file names sort as a file manager sorts them', () {
      final names = ['IMG_10.jpg', 'img_9.jpg', 'IMG_100.jpg', 'a.jpg', 'IMG_9b.jpg']..sort(compareNatural);
      expect(names, ['a.jpg', 'img_9.jpg', 'IMG_9b.jpg', 'IMG_10.jpg', 'IMG_100.jpg']);
    });
  });

  group('each file read as the library and its 360° scan read it', () {
    test('a 360° photo with GPano tags is 360°, with its frame, its date taken and no raw flag', () async {
      final tiff = tiffBytes(exif: [(0x9003, 2, '2024:06:01 12:30:00')]);
      final path = write(
        'trip.jpg',
        jpegBytes(width: 6000, height: 3000, tiff: tiff, gpanoProjection: 'equirectangular'),
      );

      final batch = await readOpenedPaths([path], ids: _nameIds);

      final opened = batch.files.single;
      expect(opened.asset.id, 'f-trip.jpg');
      expect(opened.asset.type, AssetType.image);
      expect((opened.asset.width, opened.asset.height), (6000, 3000));
      // An EXIF date without an offset is a time of the computer's zone, as the library reads it
      expect(opened.asset.createdAt, DateTime(2024, 6, 1, 12, 30).toUtc());
      expect(opened.asset.playbackStyle, AssetPlaybackStyle.image);
      expect(opened.record.isPanorama, isTrue);
      expect(opened.record.raw360, isFalse);
      expect(opened.is360, isTrue);
      expect(opened.file.path, path);
      expect(opened.file.assetId, 'f-trip.jpg');
      expect(batch.fromFolder, isFalse);
    });

    test('a 360° video is told by its spherical metadata, a flat photo and a flat 2:1 video are not 360°', () async {
      final video = write('trip_360.mp4', _sphericalMp4);
      final flatVideo = write('wide.mp4', mp4Bytes(width: 3840, height: 1920, durationMs: 12000));
      final flatPhoto = write('IMG_1.jpg', jpegBytes(width: 4000, height: 3000));

      final batch = await readOpenedPaths([video, flatVideo, flatPhoto], ids: _nameIds);

      final byName = {for (final file in batch.files) file.asset.name: file};
      expect(byName['trip_360.mp4']!.record.isPanorama, isTrue);
      expect(byName['trip_360.mp4']!.record.halfSphere, isFalse);
      expect(byName['trip_360.mp4']!.asset.type, AssetType.video);
      expect(byName['wide.mp4']!.record.isPanorama, isFalse);
      expect(byName['wide.mp4']!.asset.durationMs, 12000);
      expect((byName['wide.mp4']!.asset.width, byName['wide.mp4']!.asset.height), (3840, 1920));
      expect(byName['IMG_1.jpg']!.record.isPanorama, isFalse);
    });

    test('the raw files of 360° cameras are raw 360° files by their names, as for the scan', () async {
      final names = ['IMG_20240908_193126_00_001.insp', 'VID_20240908_193126_00_004.insv', 'GS010013.360', 'CAM_1.OSV'];
      final paths = [
        for (final name in names)
          write(name, name.endsWith('.insp') ? _panoramaJpeg : mp4Bytes(width: 2880, height: 2880, durationMs: 1000)),
      ];

      final batch = await readOpenedPaths(paths, ids: _nameIds);

      expect(batch.files.map((file) => file.asset.name), names);
      for (final file in batch.files) {
        expect(file.record.raw360, isTrue, reason: file.asset.name);
        expect(file.record.isPanorama, isTrue, reason: file.asset.name);
      }
    });

    test('the same file gives the same asset as the folder library gives it, and the same id', () async {
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
      final tiff = tiffBytes(exif: [(0x9003, 2, '2023:12:24 18:00:00')]);
      final photo = write('Photos/pano_1.jpg', jpegBytes(width: 4000, height: 2000, tiff: tiff));
      final video = write('Photos/VID_2.mp4', mp4Bytes(width: 1920, height: 1080, durationMs: 61500, rotation: 90));
      final library = fixture.library();
      final rootId = library.addRoot(p.join(fixture.files.path, 'Photos')).id;
      await library.scan();

      final batch = await readOpenedPaths([
        photo,
        video,
      ], ids: (paths) async => {for (final path in paths) path: library.idOfPath(path)!});

      final index = fixture.index();
      for (final opened in batch.files) {
        final indexed = index.file(fixture.ids.file(rootId, opened.asset.name))!;
        expect(opened.asset.id, indexed.id);
        expect((opened.asset.width, opened.asset.height), (indexed.width, indexed.height), reason: opened.asset.name);
        expect(opened.asset.createdAt.millisecondsSinceEpoch ~/ 1000, indexed.createdSeconds);
        expect(opened.asset.durationMs, indexed.durationMs);
        expect(opened.asset.playbackStyle.index, indexed.playbackStyle);
      }
      // The video turns by a quarter: shown 1080 x 1920, as the gallery of a phone gives it
      expect((batch.files.last.asset.width, batch.files.last.asset.height), (1080, 1920));
    });

    test('a file outside the library gets the id a scan would give it once its folder is added', () async {
      fixture.probe.mounts[fixture.files.path] = 'win-0000beef';
      final path = write('Later/IMG_5.jpg', jpegBytes(width: 40, height: 30));
      final library = fixture.library();
      final before = library.idOfPath(path);
      final rootId = library.addRoot(p.join(fixture.files.path, 'Later')).id;

      expect(before, isNotNull);
      expect(before, fixture.ids.file(rootId, 'IMG_5.jpg'));
      expect(library.idsInFolder(p.join(fixture.files.path, 'Later'))!('IMG_5.jpg'), before);
      expect(before, isNot(contains('IMG_5')), reason: 'no path in an id');
    });

    test('a file on a volume the library cannot read gets an id of its own, never a path', () {
      final library = fixture.library();
      final path = p.join(fixture.files.path, 'IMG_6.jpg');
      expect(library.idOfPath(path), isNull);

      final id = openedFileId(library, path);
      expect(id, startsWith('o'));
      expect(id, hasLength(41));
      expect(openedFileId(library, path), id);
      expect(openedFileId(library, p.join(fixture.files.path, 'IMG_7.jpg')), isNot(id));
    });
  });

  group('the files of opened assets', () {
    test('the storage repository finds an opened file by its asset, without the library', () async {
      final path = write('IMG_1.jpg', jpegBytes(width: 40, height: 30));
      final batch = await readOpenedPaths([path], ids: _nameIds);
      final storage = DesktopStorageRepository(library: () async => throw StateError('the library is not asked'));

      OpenedFiles.remember(batch.files);

      expect((await storage.getFileForAsset('f-IMG_1.jpg'))?.path, path);
      expect(await storage.isAssetAvailableLocally('f-IMG_1.jpg'), isTrue);
      expect(OpenedFiles.file('f-IMG_1.jpg')?.mimeType, 'image/jpeg');
      File(path).deleteSync();
      expect(await storage.getFileForAsset('f-IMG_1.jpg'), isNull);
    });

    test('the other file of an X3 pair is found next to an opened one, and opened too', () async {
      final first = write('x3/VID_20240908_193126_00_004.insv', mp4Bytes(width: 2880, height: 2880, durationMs: 9000));
      write('x3/VID_20240908_193126_10_004.insv', mp4Bytes(width: 2880, height: 2880, durationMs: 9000));
      final batch = await readOpenedPaths([first], ids: _nameIds);
      OpenedFiles.remember(batch.files);

      final sibling = await OpenedFiles.sibling(
        'f-VID_20240908_193126_00_004.insv',
        'VID_20240908_193126_10_004.insv',
        ids: _nameIds,
      );

      expect(sibling?.id, 'f-VID_20240908_193126_10_004.insv');
      expect(sibling?.type, AssetType.video);
      expect(OpenedFiles.file(sibling!.id)?.path, p.join(fixture.files.path, 'x3', 'VID_20240908_193126_10_004.insv'));
      expect(await OpenedFiles.sibling('f-VID_20240908_193126_00_004.insv', 'VID_missing_10_004.insv'), isNull);
      expect(await OpenedFiles.sibling('f-other', 'VID_20240908_193126_10_004.insv'), isNull);
    });
  });

  test('every extension the installers register for "Open with" is a photo or a video of the app', () {
    final root = Directory.current.parent;
    final associations =
        jsonDecode(File(p.join(root.path, '.github', 'desktop', 'file-associations.json')).readAsStringSync())
            as Map<String, dynamic>;
    final photos = associations['photos'] as Map<String, dynamic>;
    final videos = associations['videos'] as Map<String, dynamic>;

    expect(
      photos.keys,
      containsAll(['jpg', 'jpeg', 'png', 'heic', 'heif', 'avif', 'webp', 'tif', 'tiff', 'dng', 'insp']),
    );
    expect(videos.keys, containsAll(['mp4', 'mov', 'm4v', 'mkv', 'webm', 'insv', '360', 'osv']));
    for (final MapEntry(key: extension, value: description) in photos.entries) {
      expect(mediaKindOfName('x.$extension'), LibraryMediaKind.image, reason: extension);
      expect(description, isA<String>().having((text) => text.trim(), 'description', isNotEmpty));
    }
    for (final MapEntry(key: extension, value: description) in videos.entries) {
      expect(mediaKindOfName('x.$extension'), LibraryMediaKind.video, reason: extension);
      expect(description, isA<String>().having((text) => text.trim(), 'description', isNotEmpty));
    }
  });
}
