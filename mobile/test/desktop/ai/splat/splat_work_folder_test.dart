// The work folder of a splat scene (lib/desktop/ai/splat/splat_work_folder.dart, lot SP4): where COLMAP and Brush read
// and write, and the ASCII path COLMAP is given: its own, its short name on Windows, or another root; that root, under
// ProgramData, one folder per account made readable by its account and SYSTEM alone, else not used. On Windows, the
// short name of a real folder with accents (GetShortPathNameW), when its volume keeps short names, and a real folder
// made private by icacls, its rules read back by PowerShell.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/process/managed_process.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_work_folder.dart';
import 'package:path/path.dart' as p;

/// Whether a test can make a folder whose files cannot be deleted: chmod, on Linux or macOS, as another user than root
final _canLock = !Platform.isWindows && Process.runSync('id', ['-u']).stdout.toString().trim() != '0';

/// What [folder] holds made impossible to delete (read and enter only), as a file Windows still holds; undone after the
/// test
void _lock(Directory folder) {
  File(p.join(folder.path, 'held.jpg')).writeAsStringSync('held');
  Process.runSync('chmod', ['500', folder.path]);
  addTearDown(() => Process.runSync('chmod', ['700', folder.path]));
}

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

  group('the logs of a job that failed, kept in the logs folder of the app', () {
    late SplatWorkFolder work;
    late Directory logs;

    setUp(() {
      work = SplatWorkFolder(Directory(p.join(folder.path, 'work', 'splat-0123456789abcdef')));
      logs = Directory(p.join(folder.path, 'app', 'logs'));
    });

    /// [lines] written as the log of [program], changed [minutes] after 10:00
    void written(String program, List<String> lines, int minutes) {
      work.logOf(program)
        ..createSync(recursive: true)
        ..writeAsStringSync('${lines.join('\n')}\n')
        ..setLastModifiedSync(DateTime(2026, 11, 2, 10, minutes));
    }

    test(
      'the logs of its programs in the order they were written, after what failed, under the key and the time',
      () async {
        written('colmap-matching', ['=== Feature matching ===', 'Processing block [2/9, 5/9]'], 20);
        written('colmap-features', ['=== Feature extraction ===', 'Processed file [150/150]'], 12);

        final kept = await keepSplatFailureLogs(
          work,
          logs,
          header: 'Splat scene conversion-1 failed at the step matching: posesStalled: COLMAP (exhaustive_matcher) ...',
          now: DateTime(2026, 11, 2, 10, 31, 7),
        );

        expect(p.basename(kept!.path), 'splat-0123456789abcdef-2026-11-02T10-31-07.log');
        expect(p.dirname(kept.path), logs.path);
        final text = kept.readAsStringSync();
        expect(text, startsWith('Splat scene conversion-1 failed at the step matching: posesStalled: COLMAP'));
        expect(text, contains('Work folder: ${work.root.path}'));
        final features = text.indexOf('===== colmap-features.log, ');
        final matching = text.indexOf('===== colmap-matching.log, ');
        expect(features, greaterThan(0));
        expect(matching, greaterThan(features), reason: 'the extraction ran first');
        expect(text, contains('Processed file [150/150]'));
        expect(text, endsWith('Processing block [2/9, 5/9]\n'));
      },
    );

    test('the end of a long log only; nothing without a log; the five newest kept', () async {
      written('brush', [for (var step = 0; step < 4000; step++) 'Refine iter $step, 150000 splats.'], 40);
      final kept = await keepSplatFailureLogs(work, logs, header: 'failed', now: DateTime(2026, 11, 2, 11), tail: 1000);
      final text = kept!.readAsStringSync();
      expect(text, contains('===== brush.log, ${work.logOf('brush').lengthSync()} bytes, the last 1000 ====='));
      expect(text, endsWith('Refine iter 3999, 150000 splats.\n'));
      expect(text, isNot(contains('Refine iter 100,')));
      expect(text.length, lessThan(1200));

      final empty = SplatWorkFolder(Directory(p.join(folder.path, 'work', 'splat-fedcba9876543210')));
      expect(await keepSplatFailureLogs(empty, logs, header: 'failed'), isNull, reason: 'no log was written');

      // Six failures before: the oldest goes, another file of the folder stays
      final other = File(p.join(logs.path, 'Immich_log.log'))..writeAsStringSync('not a splat');
      for (var k = 0; k < 6; k++) {
        File(p.join(logs.path, 'splat-00000000000000a$k-2026-11-01T09-0$k-00.log'))
          ..writeAsStringSync('old $k')
          ..setLastModifiedSync(DateTime(2026, 11, 1, 9, k));
      }
      final last = await keepSplatFailureLogs(work, logs, header: 'failed', now: DateTime(2026, 11, 2, 12));
      final names = [
        for (final entry in logs.listSync())
          if (p.basename(entry.path).startsWith('splat-')) p.basename(entry.path),
      ]..sort();
      // The newest by their last change: the two of today, then the three last of the day before
      expect(names, [
        'splat-00000000000000a3-2026-11-01T09-03-00.log',
        'splat-00000000000000a4-2026-11-01T09-04-00.log',
        'splat-00000000000000a5-2026-11-01T09-05-00.log',
        p.basename(kept.path),
        p.basename(last!.path),
      ]);
      expect(splatFailureLogsKept, 5);
      expect(other.existsSync(), isTrue);
    });
  });

  test(
    'the work folders of the splat scenes a day old go, under each root; the young ones and the rest stay',
    () async {
      final temp = SplatWorkRoot(Directory(p.join(folder.path, 'temp', 'immuch360-ai')));
      final shared = SplatWorkRoot(
        Directory(p.join(folder.path, 'ProgramData', 'ai-work', 'S-1-5-21-1')),
        shared: true,
      );
      final old = Directory(p.join(temp.folder.path, splatWorkFolderName('a' * 40)))..createSync(recursive: true);
      final young = Directory(p.join(shared.folder.path, splatWorkFolderName('b' * 40)))..createSync(recursive: true);
      final other = Directory(p.join(temp.folder.path, 'panorama-1'))..createSync(recursive: true);
      final later = DateTime.now().add(const Duration(hours: 25));
      // A job that failed during its training last used it an hour ago
      touchAiWorkFolder(young, at: later.subtract(const Duration(hours: 1)));

      expect(
        await deleteOldSplatWork([temp, shared, SplatWorkRoot(Directory(p.join(folder.path, 'none')))], now: later),
        1,
      );
      expect(old.existsSync(), isFalse);
      expect(young.existsSync(), isTrue);
      expect(other.existsSync(), isTrue, reason: 'not a folder of a splat scene: the rule of an hour of its owner');
      expect(splatWorkFolderName('0123456789abcdef0123'), 'splat-0123456789abcdef');
    },
  );

  test('a work folder that cannot be deleted now stays for the next time, the others of its root go', () async {
    final temp = SplatWorkRoot(Directory(p.join(folder.path, 'temp')));
    final later = DateTime.now().add(const Duration(hours: 25));
    final held = <Directory>[];
    final free = <Directory>[];
    for (var k = 0; k < 20; k++) {
      final work = Directory(p.join(temp.folder.path, splatWorkFolderName('$k'.padLeft(2, '0').padRight(40, 'c'))))
        ..createSync(recursive: true);
      if (k.isEven) {
        _lock(Directory(p.join(work.path, 'dataset'))..createSync());
        held.add(work);
      } else {
        free.add(work);
      }
    }

    expect(await deleteOldSplatWork([temp], now: later), free.length);
    expect(free.where((work) => work.existsSync()), isEmpty);
    expect(held.every((work) => work.existsSync()), isTrue);
  }, skip: _canLock ? false : 'a folder that cannot be deleted needs chmod, as another user than root');

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

  test('the account of whoami /user, and the rules of a private folder: protected, the account and SYSTEM alone', () {
    expect(
      sidOfWhoami('"laptop\\frédéric","S-1-5-21-1004336348-1177238915-682003330-1001"\r\n'),
      'S-1-5-21-1004336348-1177238915-682003330-1001',
    );
    expect(sidOfWhoami('ERROR: something'), isNull);
    // In SDDL: protected from its parent, full control to both, inherited by its folders and files
    expect(windowsPrivateDacl('S-1-5-21-7-1001'), 'D:P(A;OICI;FA;;;S-1-5-21-7-1001)(A;OICI;FA;;;SY)');
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

  test('Windows: a folder made private keeps no rule but those of the account and SYSTEM, its folders and files too', () {
    final sid = windowsUserSid() ?? fail('whoami gave no security id');
    expect(sid, matches(RegExp(r'^S-1-5-\d+(-\d+)*$')));
    final private = Directory(p.join(folder.path, 'ai-work', sid))..createSync(recursive: true);
    final job = Directory(p.join(private.path, 'job-1'))..createSync();
    // Rules of its own beside those it inherits: Users, as ProgramData gives, and Administrators, as a folder made by an
    // elevated account with nothing to inherit holds (the runner of the CI, run 41361256501)
    final granted = Process.runSync('icacls', [
      private.path,
      '/grant',
      '*S-1-5-32-545:(OI)(CI)RX',
      '*S-1-5-32-544:(OI)(CI)F',
      '/q',
    ]);
    expect(granted.exitCode, 0, reason: '${granted.stdout}${granted.stderr}');
    expect(windowsMakePrivate(private, sid: sid), isTrue);
    File(p.join(private.path, 'photo.jpg')).writeAsStringSync('pixels');
    // The rules of each path, read back: whether it is protected from its parent, then the account of each rule
    const read =
        r'$a = Get-Acl -LiteralPath $env:IMMUCH360_ACL_PATH; $a.AreAccessRulesProtected; $a.Access | '
        r'ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }';
    for (final path in [private.path, job.path, p.join(private.path, 'photo.jpg')]) {
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
      // The folder protected from its parent; what is in it inherits from it alone
      expect(lines.first, path == private.path ? 'True' : 'False', reason: path);
      expect(lines.skip(1).toSet(), {sid, 'S-1-5-18'}, reason: '$path: ${Process.runSync('icacls', [path]).stdout}');
    }
  }, skip: !Platform.isWindows ? 'the rules of a folder are of Windows' : false);
}
