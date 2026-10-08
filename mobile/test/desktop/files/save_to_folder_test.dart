import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/files/file_pickers.dart';
import 'package:immich_mobile/desktop/files/save_to_folder.dart';
import 'package:immich_mobile/desktop/files/saved_files.dart';
import 'package:path/path.dart' as p;

import 'zip_reader.dart';

/// The dialogs of the system, answered by the test
class _Pickers implements FilePickers {
  String? folderAnswer;
  String? saveAnswer;
  bool fails = false;
  final asked = <String>[];

  @override
  Future<String?> folder({String? initialDirectory, String? confirmButtonText}) async {
    asked.add('folder');
    if (fails) {
      throw PlatformException(code: 'dialog', message: 'no dialog here');
    }
    return folderAnswer;
  }

  @override
  Future<String?> saveLocation({
    required String suggestedName,
    String? initialDirectory,
    String? typeLabel,
    List<String> extensions = const [],
  }) async {
    asked.add('save $suggestedName ${extensions.join(',')}');
    if (fails) {
      throw PlatformException(code: 'dialog', message: 'no dialog here');
    }
    return saveAnswer;
  }
}

void main() {
  late Directory root;
  late _Pickers pickers;

  setUp(() {
    root = Directory.systemTemp.createTempSync('immuch360-save');
    pickers = _Pickers();
    filePickers = pickers;
  });

  tearDown(() {
    filePickers = const SystemFilePickers();
    root.deleteSync(recursive: true);
  });

  File write(String relative, String content) => File(p.join(root.path, relative))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);

  group('safe file names', () {
    test('what Windows refuses is replaced', () {
      expect(safeFileName('a/b\\c:d*?"<>|.jpg'), 'a_b_c_d______.jpg');
      expect(safeFileName('name. . '), 'name');
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName('lpt1'), '_lpt1');
      expect(safeFileName('console.txt'), 'console.txt');
      expect(safeFileName(''), 'file');
      expect(safeFileName('..'), 'file');
      expect(safeFileName('tab\there.png'), 'tab_here.png');
    });

    test('a very long name is cut, its extension kept', () {
      final name = safeFileName('${'x' * 300}.jpeg');
      expect(name.length, 200);
      expect(name, endsWith('.jpeg'));
    });
  });

  group('into a folder', () {
    test('free names are found and nothing of the user is replaced', () async {
      final folder = Directory(p.join(root.path, 'out'))..createSync();
      write('out/a.jpg', 'mine');
      write('out/a (1).jpg', 'mine too');
      final reserved = await reserveFileIn(folder, 'a.jpg');
      expect(p.basename(reserved.path), 'a (2).jpg');
      expect(File(p.join(folder.path, 'a.jpg')).readAsStringSync(), 'mine');
    });

    test('a folder of that name counts as taken', () async {
      final folder = Directory(p.join(root.path, 'out'))..createSync();
      Directory(p.join(folder.path, 'b.jpg')).createSync();
      expect(p.basename((await reserveFileIn(folder, 'b.jpg')).path), 'b (1).jpg');
    });

    test('a folder that cannot be written fails once, without trying ten thousand names', () async {
      await expectLater(
        reserveFileIn(Directory(p.join(root.path, 'missing')), 'a.jpg'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('moving removes the source, copying keeps it', () async {
      final folder = Directory(p.join(root.path, 'out'))..createSync();
      final moved = await moveIntoFolder(write('in/one.jpg', '1'), folder, 'one.jpg');
      expect(moved.readAsStringSync(), '1');
      expect(File(p.join(root.path, 'in', 'one.jpg')).existsSync(), isFalse);

      final source = write('in/two.jpg', '2');
      final copied = await copyIntoFolder(source, folder, 'two.jpg');
      expect(copied.readAsStringSync(), '2');
      expect(source.existsSync(), isTrue);
      expect(folder.listSync().where((entity) => entity.path.endsWith('.part')), isEmpty);
    });
  });

  group('Save to a folder', () {
    test('copies the files into the folder picked, under their own names', () async {
      final target = Directory(p.join(root.path, 'picked'))..createSync();
      pickers.folderAnswer = target.path;
      write('picked/IMG_1.JPG', 'mine');
      final paths = [write('share/IMG_1.JPG', 'one').path, write('share/IMG_2.JPG', 'two').path];

      expect(await saveFilesToFolder(paths, announce: false), 2);
      expect(File(p.join(target.path, 'IMG_1.JPG')).readAsStringSync(), 'mine');
      expect(File(p.join(target.path, 'IMG_1 (1).JPG')).readAsStringSync(), 'one');
      expect(File(p.join(target.path, 'IMG_2.JPG')).readAsStringSync(), 'two');
      expect(File(paths.first).existsSync(), isTrue, reason: 'the caller removes its temporary files');
    });

    test('saves nothing when the dialog is closed, and asks nothing without files', () async {
      expect(await saveFilesToFolder([write('share/a.jpg', 'a').path], announce: false), 0);
      expect(pickers.asked, ['folder']);
      expect(await saveFilesToFolder(const [], announce: false), 0);
      expect(pickers.asked, ['folder']);
    });

    test('a dialog that fails saves nothing and throws nothing at callers that do not wait', () async {
      pickers.fails = true;
      expect(await saveFilesToFolder([write('share/a.jpg', 'a').path], announce: false), 0);
    });

    test('a file gone meanwhile is skipped, the others are saved', () async {
      pickers.folderAnswer = (Directory(p.join(root.path, 'picked'))..createSync()).path;
      final paths = [p.join(root.path, 'gone.jpg'), write('share/b.jpg', 'b').path];
      expect(await saveFilesToFolder(paths, announce: false), 1);
    });
  });

  group('Save logs to a file', () {
    late File log;
    late Directory dumps;

    setUp(() {
      log = write('temp/Immich_log_2026-10-08T10-20-30.log', 'line one\nline two\n');
      dumps = Directory(p.join(root.path, 'crash_dumps'));
    });

    test('the log alone when nothing crashed', () async {
      pickers.saveAnswer = p.join(root.path, 'kept', 'logs.log');
      Directory(p.join(root.path, 'kept')).createSync();

      expect(await saveLogFile(log, crashDumps: dumps, announce: false), isTrue);
      expect(pickers.asked, ['save Immich_log_2026-10-08T10-20-30.log log']);
      expect(File(pickers.saveAnswer!).readAsStringSync(), 'line one\nline two\n');
      expect(Directory(p.join(root.path, 'kept')).listSync(), hasLength(1), reason: 'no partial file left');
    });

    test('a ZIP of the log and the latest crash reports when there are some', () async {
      dumps.createSync();
      final now = DateTime.now();
      for (var index = 0; index < 12; index++) {
        File(p.join(dumps.path, 'immuch360-$index.dmp'))
          ..writeAsBytesSync(Uint8List.fromList(List.filled(100 + index, index)))
          ..setLastModifiedSync(now.subtract(Duration(minutes: 12 - index)));
      }
      File(p.join(dumps.path, 'notes.txt')).writeAsStringSync('not a dump');
      // A name typed without an extension gets the right one
      pickers.saveAnswer = p.join(root.path, 'for the issue');

      expect(await saveLogFile(log, crashDumps: dumps, announce: false), isTrue);
      expect(pickers.asked.single, 'save Immich_log_2026-10-08T10-20-30.zip zip');
      final entries = readZip(File('${pickers.saveAnswer}.zip').readAsBytesSync());
      expect(entries.keys.first, 'Immich_log_2026-10-08T10-20-30.log');
      expect(utf8.decode(entries.values.first), 'line one\nline two\n');
      expect(entries.keys.skip(1).toSet(), {
        for (var index = 2; index < 12; index++) 'crash_dumps/immuch360-$index.dmp',
      });
      expect(entries['crash_dumps/immuch360-11.dmp'], List.filled(111, 11));
    });

    test('nothing written when the dialog is closed, or fails', () async {
      expect(await saveLogFile(log, crashDumps: dumps, announce: false), isFalse);
      pickers.fails = true;
      expect(await saveLogFile(log, crashDumps: dumps, announce: false), isFalse);
    });

    test('the latest dumps first, at most ten', () async {
      expect(await latestCrashDumps(dumps), isEmpty, reason: 'no folder');
      dumps.createSync();
      final now = DateTime.now();
      for (var index = 0; index < 3; index++) {
        File(p.join(dumps.path, '$index.DMP'))
          ..writeAsStringSync('$index')
          ..setLastModifiedSync(now.subtract(Duration(hours: index)));
      }
      expect((await latestCrashDumps(dumps)).map((file) => p.basename(file.path)), ['0.DMP', '1.DMP', '2.DMP']);
    });
  });

  test('dates for file names hold no colon', () {
    final name = fileNameDate(DateTime(2026, 10, 8, 10, 20, 30));
    expect(name, isNot(contains(':')));
    expect(name, startsWith('2026-10-08T10-20-30'));
  });
}
