// The work folder of a splat scene (lib/desktop/ai/splat/splat_work_folder.dart, lot SP4): where COLMAP and Brush read
// and write, and the ASCII path COLMAP is given: its own, its short name on Windows, or another root; that root, under
// ProgramData, one folder per account made readable by its account and SYSTEM alone, else not used. On Windows, the
// short name of a real folder with accents (GetShortPathNameW), when its volume keeps short names, and a real folder
// made private by icacls, its rules read back by PowerShell.

import 'dart:convert';
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
    final programData = Directory(p.join(folder.path, 'ProgramData', 'Immuch360', 'ai-work', 'S-1-5-21-7-1001'));
    final private = <String>[];
    bool makePrivate(Directory root) {
      private.add(root.path);
      return true;
    }

    final roots = [SplatWorkRoot(temp), SplatWorkRoot(programData, shared: true)];
    final root = asciiWorkRoot(roots, isWindows: true, shortPathOf: (path) => path, makePrivate: makePrivate);
    expect(root!.path, programData.absolute.path);
    expect(programData.existsSync(), isTrue);
    expect(temp.existsSync(), isTrue);
    // Only the shared root is made private, once it is there
    expect(private, [programData.path]);
    expect(asciiWorkRoot([SplatWorkRoot(temp)], isWindows: false), isNull);
    expect(asciiWorkRoot([SplatWorkRoot(folder), SplatWorkRoot(temp)])!.path, folder.absolute.path);
  });

  test('a shared root that cannot be made private is never used', () {
    final temp = Directory(p.join(folder.path, 'Frédéric', 'Temp', 'immuch360-ai'));
    final programData = Directory(p.join(folder.path, 'ProgramData', 'Immuch360', 'ai-work', 'S-1-5-21-7-1001'));
    final roots = [SplatWorkRoot(temp), SplatWorkRoot(programData, shared: true)];
    expect(asciiWorkRoot(roots, isWindows: true, shortPathOf: (path) => path, makePrivate: (_) => false), isNull);
  });

  test('the roots of the app: the temporary folder, then on Windows a folder of ProgramData for the account', () {
    final temp = Directory(p.join('t', 'Temp'));
    const sid = 'S-1-5-21-1004336348-1177238915-682003330-1001';
    final windows = splatWorkRoots(
      environment: {'ProgramData': r'C:\ProgramData'},
      isWindows: true,
      temp: temp,
      userSid: () => sid,
    );
    expect(windows.map((root) => (root.folder.path, root.shared)), [
      (p.join('t', 'Temp', 'immuch360-ai'), false),
      (p.join(r'C:\ProgramData', 'Immuch360', 'ai-work', sid), true),
    ]);
    expect(
      splatWorkRoots(
        environment: {'ProgramData': r'C:\ProgramData'},
        isWindows: false,
        temp: temp,
        userSid: () => sid,
      ).map((root) => root.folder.path),
      [p.join('t', 'Temp', 'immuch360-ai')],
    );
    expect(splatWorkRoots(environment: const {}, isWindows: true, temp: temp, userSid: () => sid), hasLength(1));
    // No account known, no folder of ProgramData: it would be one for every account
    expect(
      splatWorkRoots(environment: {'ProgramData': r'C:\ProgramData'}, isWindows: true, temp: temp, userSid: () => null),
      hasLength(1),
    );
  });

  test('the account of whoami /user, and the rules icacls is given: no inheritance, the account and SYSTEM alone', () {
    expect(
      sidOfWhoami('"laptop\\frédéric","S-1-5-21-1004336348-1177238915-682003330-1001"\r\n'),
      'S-1-5-21-1004336348-1177238915-682003330-1001',
    );
    expect(sidOfWhoami('ERROR: something'), isNull);
    expect(windowsPrivateFolderArguments(r'C:\ProgramData\Immuch360\ai-work\S-1-5-21-7-1001', 'S-1-5-21-7-1001'), [
      r'C:\ProgramData\Immuch360\ai-work\S-1-5-21-7-1001',
      '/inheritance:r',
      '/grant:r',
      '*S-1-5-21-7-1001:(OI)(CI)F',
      '*S-1-5-18:(OI)(CI)F',
      '/q',
    ]);
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

  test('Windows: a folder made private keeps no rule it inherited, only the account and SYSTEM, its files too', () {
    final sid = windowsUserSid() ?? fail('whoami gave no security id');
    expect(sid, matches(RegExp(r'^S-1-5-\d+(-\d+)*$')));
    final private = Directory(p.join(folder.path, 'ai-work', sid))..createSync(recursive: true);
    // The rules of each path, read back: whether it is protected from its parent, then the account of each rule
    const read =
        r'$a = Get-Acl -LiteralPath $env:IMMUCH360_ACL_PATH; $a.AreAccessRulesProtected; $a.Access | '
        r'ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }';
    expect(windowsMakePrivate(private, sid: sid), isTrue);
    File(p.join(private.path, 'photo.jpg')).writeAsStringSync('pixels');
    for (final path in [private.path, p.join(private.path, 'photo.jpg')]) {
      final rules = Process.runSync(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', read],
        environment: {'IMMUCH360_ACL_PATH': path},
      );
      expect(rules.exitCode, 0, reason: '${rules.stderr}');
      final lines = [
        for (final line in LineSplitter.split('${rules.stdout}'))
          if (line.trim().isNotEmpty) line.trim(),
      ];
      // The folder protected from its parent; the file inherits from the folder alone
      expect(lines.first, path == private.path ? 'True' : 'False', reason: path);
      expect(lines.skip(1).toSet(), {sid, 'S-1-5-18'}, reason: path);
    }
  }, skip: !Platform.isWindows ? 'icacls is Windows only' : false);
}
