// The work folder of a splat scene (lib/desktop/ai/splat/splat_work_folder.dart, lot SP4): where COLMAP and Brush read
// and write, and the ASCII path COLMAP is given: its own, its short name on Windows, or another root. On Windows, the
// short name of a real folder with accents (GetShortPathNameW), when its volume keeps short names.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory folder;

  setUp(() => folder = Directory.systemTemp.createTempSync('splat-work-'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('the paths of a job: the dataset Brush reads, the database and the models of COLMAP, the export, the logs', () {
    final work = SplatWorkFolder(Directory(p.join('w', 'splat-1')));
    String path(Directory directory) => p.relative(directory.path, from: 'w');
    expect(path(work.dataset), p.join('splat-1', 'dataset'));
    expect(path(work.images), p.join('splat-1', 'dataset', 'images'));
    expect(path(work.aligned), p.join('splat-1', 'dataset', 'sparse', '0'));
    expect(path(work.colmap), p.join('splat-1', 'colmap'));
    expect(p.relative(work.database.path, from: 'w'), p.join('splat-1', 'colmap', 'database.db'));
    expect(path(work.sparse), p.join('splat-1', 'colmap', 'sparse'));
    expect(path(work.export), p.join('splat-1', 'brush'));
    expect(p.relative(work.logOf('colmap-features').path, from: 'w'), p.join('splat-1', 'logs', 'colmap-features.log'));
  });

  test('an ASCII path is its own; another one its short name on Windows, if ASCII; none elsewhere', () {
    expect(isAsciiPath(r'C:\Users\freek\AppData\Local\Temp'), isTrue);
    expect(isAsciiPath(r'C:\Users\Frédéric\AppData\Local\Temp'), isFalse);
    final plain = Directory(p.join(folder.path, 'plain'))..createSync();
    final accented = Directory(p.join(folder.path, 'Frédéric'))..createSync();
    expect(asciiPathOf(plain, isWindows: true, shortPathOf: (_) => fail('not asked')), plain.absolute.path);
    expect(asciiPathOf(accented, isWindows: false), isNull);
    expect(
      asciiPathOf(accented, isWindows: true, shortPathOf: (_) => r'C:\Users\FRDRI~1\Temp'),
      r'C:\Users\FRDRI~1\Temp',
    );
    // A volume without short names gives the long path back
    expect(asciiPathOf(accented, isWindows: true, shortPathOf: (path) => path), isNull);
    expect(asciiPathOf(accented, isWindows: true, shortPathOf: (_) => null), isNull);
  });

  test('the work root: the first with an ASCII path, made if missing; none when no root has one', () {
    final temp = Directory(p.join(folder.path, 'Frédéric', 'Temp', 'immuch360-ai'));
    final programData = Directory(p.join(folder.path, 'ProgramData', 'Immuch360', 'ai-work'));
    final root = asciiWorkRoot([temp, programData], isWindows: true, shortPathOf: (path) => path);
    expect(root!.path, programData.absolute.path);
    expect(programData.existsSync(), isTrue);
    expect(temp.existsSync(), isTrue);
    expect(asciiWorkRoot([temp], isWindows: false), isNull);
    expect(asciiWorkRoot([programData, temp])!.path, programData.absolute.path);
  });

  test('the roots of the app: the temporary folder, then ProgramData on Windows', () {
    final temp = Directory(p.join('t', 'Temp'));
    expect(
      splatWorkRoots(environment: {'ProgramData': r'C:\ProgramData'}, isWindows: true, temp: temp).map((d) => d.path),
      [p.join('t', 'Temp', 'immuch360-ai'), p.join(r'C:\ProgramData', 'Immuch360', 'ai-work')],
    );
    expect(
      splatWorkRoots(environment: {'ProgramData': r'C:\ProgramData'}, isWindows: false, temp: temp).map((d) => d.path),
      [p.join('t', 'Temp', 'immuch360-ai')],
    );
    expect(splatWorkRoots(environment: const {}, isWindows: true, temp: temp), hasLength(1));
  });

  test(
    'Windows: the short name of a folder with accents, when its volume keeps short names, names the same folder',
    () {
      final accented = Directory(p.join(folder.path, 'Frédéric été'))..createSync();
      File(p.join(accented.path, 'mark.txt')).writeAsStringSync('here');
      final short = windowsShortPath(accented.path);
      // Whatever its form, it names the same folder
      expect(File(p.join(short!, 'mark.txt')).readAsStringSync(), 'here');
      if (isAsciiPath(short)) {
        expect(asciiPathOf(accented), short);
      } else {
        // No short name made of ASCII (a volume without short names gives the long path back, the runner's D: may not
        // keep them; an accent of the OEM code page may stay in it): COLMAP then gets another root
        expect(asciiPathOf(accented), isNull);
        markTestSkipped('No ASCII short name for ${accented.path}: $short');
      }
      expect(windowsShortPath(p.join(folder.path, 'missing')), isNull);
    },
    skip: !Platform.isWindows ? 'GetShortPathNameW is Windows only' : false,
  );
}
