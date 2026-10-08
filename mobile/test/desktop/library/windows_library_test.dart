// The Windows calls of the folder library on a real Windows: the listing by FindFirstFileExW, the volumes by their
// serial number, the attributes, long and non ASCII paths, junctions. Run by the Windows CI job and on a Windows
// development PC; skipped elsewhere.
@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/library/folder_library.dart';
import 'package:immich_mobile/desktop/library/folder_roots.dart';
import 'package:immich_mobile/desktop/library/library_index.dart';
import 'package:immich_mobile/desktop/library/library_scanner.dart';
import 'package:immich_mobile/desktop/library/library_watcher.dart';
import 'package:immich_mobile/desktop/library/placeholder_check.dart';
import 'package:immich_mobile/desktop/library/volume_id.dart';
import 'package:path/path.dart' as p;

import 'library_fixtures.dart';

void main() {
  late Directory dir;
  final junctions = <String>[];

  void run(List<String> command) {
    final result = Process.runSync('cmd', ['/c', ...command]);
    if (result.exitCode != 0) {
      fail('${command.join(' ')}: ${result.stdout} ${result.stderr}');
    }
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('windows_library_test_'));
  tearDown(() {
    // Junctions first, so that deleting the folder does not walk into their targets
    for (final junction in junctions) {
      Link(junction).deleteSync();
    }
    junctions.clear();
    // rmdir in the \\?\ form: dart:io does not list a folder beyond 260 characters, so it cannot delete one either
    run(['rmdir', '/s', '/q', '\\\\?\\${dir.path}']);
  });

  File write(String relative, List<int> bytes) => File(p.joinAll([dir.path, ...relative.split('/')]))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  void junction(String at, String target) {
    run(['mklink', '/J', at, target]);
    junctions.add(at);
  }

  test('FindFirstFileExW lists what dart:io sees, with sizes, dates and folders', () {
    final photo = write('a/IMG_1.jpg', jpegBytes(width: 4, height: 3));
    write('a/b/VID_2.mp4', mp4Bytes(width: 2, height: 2, durationMs: 1));
    final entries = {for (final entry in WindowsFolderLister().list(p.join(dir.path, 'a'))!) entry.name: entry};

    expect(entries.keys, unorderedEquals(['IMG_1.jpg', 'b']));
    expect(entries['b']!.isDirectory, isTrue);
    final file = entries['IMG_1.jpg']!;
    expect(file.isDirectory, isFalse);
    expect(file.size, photo.lengthSync());
    expect((file.modifiedMs - photo.lastModifiedSync().millisecondsSinceEpoch).abs(), lessThan(2000));
    expect(file.createdMs, greaterThan(0));
    expect(WindowsFolderLister().list(p.join(dir.path, 'missing')), isNull);
  });

  test('names beyond ASCII and paths beyond 260 characters', () {
    final deep = [for (var i = 0; i < 12; i++) 'dossier_très_profond_$i'].join('/');
    final photo = write('$deep/Été 2024 📷.jpg', jpegBytes(width: 1, height: 1));
    expect(photo.path.length, greaterThan(260));

    final entries = WindowsFolderLister().list(photo.parent.path)!;
    expect(entries.single.name, 'Été 2024 📷.jpg');
    expect(systemFileAttributesReader()!(photo.path), isNotNull);
  });

  test('a junction is a link, never followed; a hidden folder is hidden', () {
    write('target/IMG_1.jpg', jpegBytes(width: 1, height: 1));
    junction(p.join(dir.path, 'junction'), p.join(dir.path, 'target'));
    Directory(p.join(dir.path, 'secret')).createSync();
    run(['attrib', '+h', p.join(dir.path, 'secret')]);

    final entries = {for (final entry in WindowsFolderLister().list(dir.path)!) entry.name: entry};
    expect(entries['junction']!.isLink, isTrue);
    expect(entries['target']!.isLink, isFalse);
    expect(isHiddenFolder(entries['secret']!.attributes), isTrue);
    expect(isHiddenFolder(entries['target']!.attributes), isFalse);
    expect(isCloudPlaceholder(entries['target']!.attributes), isFalse);
  });

  test('a folder is on a volume named by its serial number, found again from that name', () {
    final folder = Directory(p.join(dir.path, 'Footage'))..createSync();
    final probe = WindowsVolumeProbe();
    final identity = probe.identify(folder.path)!;

    expect(identity.volumeKey, matches(RegExp(r'^win-[0-9a-f]{8}$')));
    expect(p.isWithin(identity.mountPoint, folder.path), isTrue);
    expect(identity.pathInVolume.toLowerCase(), endsWith('/footage'));
    expect(identity.isNetwork, isFalse);
    expect(p.equals(probe.locate(identity.volumeKey, identity.pathInVolume)!, folder.path), isTrue);
    expect(probe.locate('win-00000000', identity.pathInVolume), isNull);
  });

  test('the Pictures and Videos folders of the account are suggested, by their known folder ids', () async {
    // Only where they are: nothing below them is read
    final suggestions = await folderSuggestions();
    expect(suggestions, isNotEmpty);
    for (final suggestion in suggestions) {
      expect(p.isAbsolute(suggestion.path), isTrue);
      expect(Directory(suggestion.path).existsSync(), isTrue);
    }
  });

  test('the watch of a folder sees a photo written in a folder below it', () async {
    Directory(p.join(dir.path, 'Watched', '2024')).createSync(recursive: true);
    final changed = Completer<void>();
    final watcher = LibraryWatcher(
      onChange: () {
        if (!changed.isCompleted) {
          changed.complete();
        }
      },
      debounce: const Duration(milliseconds: 200),
    );
    try {
      watcher.watchFolders([p.join(dir.path, 'Watched')]);
      // ReadDirectoryChangesW is armed asynchronously
      await Future<void>.delayed(const Duration(milliseconds: 500));
      write('Watched/2024/IMG_9.jpg', jpegBytes(width: 1, height: 1));
      await changed.future.timeout(const Duration(seconds: 10));
    } finally {
      watcher.dispose();
      // The watch handle is closed asynchronously, and Windows does not delete a folder that is still watched
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  });

  test('a scan with the Windows calls: ids by volume, case folded, the junction not followed', () async {
    write('Photos/2024/IMG_1.JPG', jpegBytes(width: 40, height: 30));
    write('Photos/VID_2.mp4', mp4Bytes(width: 16, height: 9, durationMs: 1500));
    junction(p.join(dir.path, 'Photos', 'loop'), p.join(dir.path, 'Photos'));

    final indexPath = p.join(dir.path, 'index.sqlite');
    final library = FolderLibrary(indexPath, scanner: (path, _, _) => runLibraryScan(path));
    final index = LibraryIndex.open(indexPath);
    try {
      final root = library.addRoot(p.join(dir.path, 'Photos'));
      expect(root.id, startsWith('win-'));
      expect(root.id, root.id.toLowerCase());

      final summary = await library.scan();
      expect((summary.written, summary.removed), (2, 0));

      final file = index.file(libraryFileId(root.id, '2024/img_1.jpg'))!;
      expect(file.relativePath, '2024/IMG_1.JPG');
      expect((file.width, file.height), (40, 30));
      expect(library.file(file.id)!.path, p.join(dir.path, 'Photos', '2024', 'IMG_1.JPG'));
    } finally {
      // Before the folder goes: Windows does not delete an open file
      index.close();
      library.close();
    }
  });
}
