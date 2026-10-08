import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/computer_share_files.dart';
import 'package:immich_mobile/desktop/platform/desktop_share_files_api.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;
  late Map<String, File> library;
  late Set<String> placeholders;
  late ComputerShareFiles files;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('computer_share_files');
    // A few bytes stand for the media: the share reads sizes, names and dates, never the content
    File(p.join(folder.path, 'IMG_0001.jpg')).writeAsBytesSync(List.filled(1234, 1));
    File(p.join(folder.path, 'VID_20260904_101010_00_001.insv')).writeAsBytesSync(List.filled(4321, 2));
    File(p.join(folder.path, 'Online only.mp4')).writeAsBytesSync(List.filled(10, 3));
    File(p.join(folder.path, 'IMG_0001.jpg')).setLastModifiedSync(DateTime.utc(2026, 9, 4, 10, 10, 10));
    Directory(p.join(folder.path, 'A folder')).createSync();
    library = {
      'photo': File(p.join(folder.path, 'IMG_0001.jpg')),
      'video': File(p.join(folder.path, 'VID_20260904_101010_00_001.insv')),
      'cloud': File(p.join(folder.path, 'Online only.mp4')),
      'gone': File(p.join(folder.path, 'deleted.jpg')),
      'folder': File(p.join(folder.path, 'A folder')),
    };
    placeholders = {library['cloud']!.path};
    files = ComputerShareFiles(fileOf: (id) async => library[id], isPlaceholder: placeholders.contains);
  });

  tearDown(() => folder.deleteSync(recursive: true));

  group('fileInfos', () {
    test('size, type, name and date of each file, read without opening it', () async {
      final infos = {
        for (final info in await files.fileInfos(['photo', 'video', 'cloud'])) info.assetId: info,
      };

      expect(infos.keys, unorderedEquals(['photo', 'video', 'cloud']));
      expect(infos['photo']!.size, 1234);
      expect(infos['photo']!.mimeType, 'image/jpeg');
      expect(infos['photo']!.fileName, 'IMG_0001.jpg');
      expect(infos['photo']!.modifiedMs, DateTime.utc(2026, 9, 4, 10, 10, 10).millisecondsSinceEpoch);
      expect(infos['video']!.mimeType, 'video/mp4');
      expect(infos['video']!.size, 4321);
      // Kept online only: listed with what the system knows of it
      expect(infos['cloud']!.size, 10);
    });

    test('an asset without a file, a file gone since, or a folder, is left out', () async {
      final infos = await files.fileInfos(['photo', 'unknown', 'gone', 'folder']);
      expect(infos.map((info) => info.assetId), ['photo']);
    });

    test('a failing library leaves the asset out instead of failing the listing', () async {
      final failing = ComputerShareFiles(
        fileOf: (id) async => id == 'photo' ? library['photo'] : throw const FileSystemException('locked'),
        isPlaceholder: placeholders.contains,
      );
      expect((await failing.fileInfos(['photo', 'video'])).map((info) => info.assetId), ['photo']);
    });
  });

  group('openFile', () {
    test('gives the file itself, never a copy', () async {
      final opened = await files.openFile('video');
      expect(opened, isNotNull);
      expect(opened!.path, library['video']!.path);
      expect(opened.size, 4321);
      expect(opened.isTemporary, isFalse);
    });

    test('refuses a file kept online only: reading it would download it', () async {
      expect(await files.openFile('cloud'), isNull);
    });

    test('a file of a local disk is not taken for a placeholder by the system check', () async {
      // The attributes of the system (GetFileAttributesW on Windows, nothing elsewhere), as in the app
      final system = ComputerShareFiles(fileOf: (id) async => library[id]);
      expect((await system.openFile('photo'))?.path, library['photo']!.path);
    });

    test('nothing for an unknown asset, a file gone since, or a folder', () async {
      expect(await files.openFile('unknown'), isNull);
      expect(await files.openFile('gone'), isNull);
      expect(await files.openFile('folder'), isNull);
    });
  });

  test('DesktopShareFilesApi answers from the folder library, keeps nothing alive and copies nothing', () async {
    final api = DesktopShareFilesApi(files: files);
    await api.startKeepAlive('title', 'text', 'Stop');
    await api.updateKeepAlive('text');

    expect((await api.fileInfos(['photo', 'gone'])).map((info) => info.assetId), ['photo']);
    expect((await api.openFile('photo'))?.path, library['photo']!.path);
    expect(await api.openFile('cloud'), isNull);

    await api.releaseTemporaryFiles();
    await api.stopKeepAlive();
    expect(library['photo']!.existsSync(), isTrue);
  });

  test('MIME types of the photo and video formats of the cameras', () {
    expect(computerShareMimeTypeOf(r'C:\Photos\IMG_1.JPG'), 'image/jpeg');
    expect(computerShareMimeTypeOf('/photos/IMG_20260904_101010_00_002.insp'), 'image/jpeg');
    expect(computerShareMimeTypeOf('a.heic'), 'image/heic');
    expect(computerShareMimeTypeOf('a.dng'), 'image/x-adobe-dng');
    for (final video in ['a.mp4', 'a.insv', 'a.lrv', 'a.360', 'a.osv', 'a.m4v']) {
      expect(computerShareMimeTypeOf(video), 'video/mp4', reason: video);
    }
    expect(computerShareMimeTypeOf('a.mov'), 'video/quicktime');
    expect(computerShareMimeTypeOf('a.mts'), 'video/mp2t');
    expect(computerShareMimeTypeOf('notes.txt'), 'application/octet-stream');
    expect(computerShareMimeTypeOf('no_extension'), 'application/octet-stream');
  });
}
