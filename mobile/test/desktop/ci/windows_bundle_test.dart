import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _kernel = ['KERNEL32.dll', 'api-ms-win-crt-runtime-l1-1-0.dll'];
const _runtime = ['MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll'];

void main() {
  late Directory root;

  void writePe(String path, Uint8List bytes) => File(p.joinAll([root.path, ...path.split('/')]))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  /// A Flutter Windows Release folder as the build leaves it, the Visual C++ redistributable folder and the System32
  /// folder of a clean Windows, all fakes
  void writeBuild({List<String> pluginImports = const ['flutter_windows.dll', ..._runtime, ..._kernel]}) {
    writePe('Release/immuch360.exe', fakePe(imports: ['flutter_windows.dll', 'plugin.dll', ..._runtime, ..._kernel]));
    writePe('Release/flutter_windows.dll', fakePe(imports: _kernel, delayImports: ['dbghelp.dll']));
    writePe('Release/plugin.dll', fakePe(imports: pluginImports));
    writePe('Release/dartjni.dll', fakePe(imports: ['jvm.dll', ..._kernel]));
    writeFiles(root, {
      'Release/immuch360.pdb': 'symbols',
      'Release/data/app.so': 'snapshot',
      'Release/data/flutter_assets/AssetManifest.bin': 'assets',
      'System32/kernel32.dll': '',
      'System32/dbghelp.dll': '',
      // Visual Studio installs the runtime in System32 of the build machine; a clean Windows has none
      'System32/msvcp140_2.dll': '',
    });
    writePe('CRT/msvcp140.dll', fakePe(imports: ['VCRUNTIME140.dll', ..._kernel]));
    writePe('CRT/msvcp140_1.dll', fakePe(imports: ['MSVCP140.dll', ..._kernel]));
    writePe('CRT/vcruntime140.dll', fakePe(imports: _kernel));
    writePe('CRT/vcruntime140_1.dll', fakePe(imports: ['VCRUNTIME140.dll', ..._kernel]));
    writePe('CRT/concrt140.dll', fakePe(imports: _kernel));
  }

  String path(String relative) => p.joinAll([root.path, ...relative.split('/')]);

  /// The default version is a release label (desktop_version.py on a release tag); --libmpv points into the fixture
  /// tree so that no libmpv folder of the machine is ever read
  ScriptRun bundle({List<String> extra = const [], String version = '3.3.0-rc.0-20', String release = 'Release'}) =>
      runCiScript('windows_bundle.py', [
        '--release',
        path(release),
        '--out',
        path('dist'),
        '--crt-dir',
        path('CRT'),
        '--system-dir',
        path('System32'),
        '--zip',
        path('dist/Immuch360-Desktop-test-windows-x64.zip'),
        '--symbols',
        path('dist/symbols'),
        '--info',
        'version=$version',
        '--info',
        'commit=abc1234',
        if (release == 'Release') ...['--libmpv', path('x64/libmpv')],
        ...extra,
      ]);

  Set<String> bundled() => Directory(path('dist/Immuch360 Desktop'))
      .listSync(recursive: true)
      .whereType<File>()
      .map((file) => p.relative(file.path, from: path('dist/Immuch360 Desktop')).replaceAll(r'\', '/'))
      .toSet();

  setUp(() => root = Directory.systemTemp.createTempSync('immuch360_bundle_'));

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  group('windows_bundle.py --imports', () {
    test('reads the machine, the imports and the delay loaded imports of a PE file', () {
      writePe('a.dll', fakePe(imports: ['KERNEL32.dll', 'flutter_windows.dll'], delayImports: ['dwmapi.dll']));
      writePe('b.dll', fakePe(imports: ['USER32.dll'], machine: 0x14C, pe32: true));
      writePe('c.dll', fakePe(machine: 0xAA64));
      final run = runCiScript('windows_bundle.py', ['--imports', path('a.dll'), path('b.dll'), path('c.dll')]);
      expect(run.exitCode, 0, reason: '$run');
      final result = jsonDecode(run.output) as Map<String, dynamic>;
      expect(result['a.dll'], {
        'machine': 'x64',
        'imports': ['KERNEL32.dll', 'flutter_windows.dll'],
        'delay_imports': ['dwmapi.dll'],
      });
      expect(result['b.dll'], {
        'machine': 'x86',
        'imports': ['USER32.dll'],
        'delay_imports': <String>[],
      });
      expect((result['c.dll'] as Map)['machine'], 'arm64');
    });

    test('says when a file is not a PE file', () {
      writeFiles(root, {'notes.dll': 'MZ but nothing else of a PE file, long enough to read a header offset....'});
      final run = runCiScript('windows_bundle.py', ['--imports', path('notes.dll')]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('"error"'));
    });
  }, skip: skipCiScripts);

  group('windows_bundle.py', () {
    test('makes the folder: runtime added, dartjni.dll and the symbols left out, every import resolved', () {
      writeBuild(pluginImports: ['flutter_windows.dll', 'MSVCP140_1.dll', ..._runtime, ..._kernel]);
      final run = bundle();
      expect(run.exitCode, 0, reason: '$run');
      expect(bundled(), {
        'immuch360.exe',
        'flutter_windows.dll',
        'plugin.dll',
        'msvcp140.dll',
        'msvcp140_1.dll',
        'vcruntime140.dll',
        'vcruntime140_1.dll',
        'data/app.so',
        'data/flutter_assets/AssetManifest.bin',
        'BUILD-INFO.txt',
      });
      expect(File(path('dist/symbols/immuch360.pdb')).existsSync(), isTrue);
      final info = File(path('dist/Immuch360 Desktop/BUILD-INFO.txt')).readAsStringSync();
      expect(info, contains('version: 3.3.0-rc.0-20'));
      expect(info, contains('commit: abc1234'));
      expect(info, contains('not signed'));
      expect(run.output, contains('left out: dartjni.dll'));
      expect(run.output, contains('SHA-256'));
    });

    test('the ZIP holds the folder under its name', () {
      writeBuild();
      expect(bundle().exitCode, 0);
      final zip = Process.runSync(python!.first, [
        ...python!.skip(1),
        '-m',
        'zipfile',
        '-l',
        path('dist/Immuch360-Desktop-test-windows-x64.zip'),
      ]);
      expect(zip.exitCode, 0, reason: '${zip.stderr}');
      expect(zip.stdout, contains('Immuch360 Desktop/immuch360.exe'));
      expect(zip.stdout, contains('Immuch360 Desktop/vcruntime140_1.dll'));
      expect(zip.stdout, contains('Immuch360 Desktop/data/app.so'));
      expect(zip.stdout, isNot(contains('dartjni.dll')));
      expect(zip.stdout, isNot(contains('.pdb')));
    });

    test('refuses an import found nowhere, and makes no ZIP', () {
      writeBuild(pluginImports: ['flutter_windows.dll', 'libmpv-2.dll', ..._kernel]);
      final run = bundle();
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('plugin.dll: imports libmpv-2.dll, found neither in the folder nor in Windows'));
      expect(File(path('dist/Immuch360-Desktop-test-windows-x64.zip')).existsSync(), isFalse);
    });

    test('refuses a Visual C++ runtime that only the build machine has in System32', () {
      writeBuild(pluginImports: ['MSVCP140_2.dll', ..._kernel]);
      final run = bundle();
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('imports MSVCP140_2.dll'));
    });

    test('refuses a debug build', () {
      writeBuild(pluginImports: ['MSVCP140D.dll', 'VCRUNTIME140D.dll', 'ucrtbased.dll', ..._kernel]);
      final run = bundle();
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('imports MSVCP140D.dll, a debug runtime'));
      expect(run.output, contains('imports ucrtbased.dll, a debug runtime'));
    });

    test('refuses a DLL of another architecture', () {
      writeBuild();
      writePe('Release/plugin.dll', fakePe(imports: _kernel, machine: 0xAA64));
      final run = bundle();
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('plugin.dll: built for arm64, the folder is x64'));
    });

    group('--file-version', () {
      Uint8List executable(List<int>? version) => Uint8List.fromList([
        ...fakePe(imports: ['flutter_windows.dll', 'plugin.dll', ..._runtime, ..._kernel]),
        if (version != null) ...fakeVersionInfo(version),
      ]);

      test('passes when the executable carries the version of the build number', () {
        writeBuild();
        writePe('Release/immuch360.exe', executable([3, 3, 0, 20]));
        final run = bundle(extra: ['--file-version', '3.3.0.20']);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('immuch360.exe: file version 3.3.0.20'));
      });

      test('refuses an executable built without the build number', () {
        writeBuild();
        writePe('Release/immuch360.exe', executable([3, 3, 0, 3030018 & 0xFFFF]));
        final run = bundle(extra: ['--file-version', '3.3.0.20']);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('immuch360.exe: file version 3.3.0.15362, expected 3.3.0.20'));
        expect(File(path('dist/Immuch360-Desktop-test-windows-x64.zip')).existsSync(), isFalse);
      });

      test('refuses an executable without a version resource, and a version that is not four numbers', () {
        writeBuild();
        final run = bundle(extra: ['--file-version', '3.3.0.20']);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('immuch360.exe: no version resource'));
        expect(bundle(extra: ['--file-version', '3.3.0-rc.0']).exitCode, 2);
      });
    });

    group('the licences of the video player', () {
      const internal = '3.3.0-rc.0-20-abc1234';
      const notices = [
        'licenses/NOTICES.md',
        'licenses/LGPL-3.0.txt',
        'licenses/GPL-3.0.txt',
        'licenses/Apache-2.0.txt',
        'licenses/ANGLE-BSD-3-Clause.txt',
      ];
      const zipFile = 'dist/Immuch360-Desktop-test-windows-x64.zip';
      String buildInfo() => File(path('dist/Immuch360 Desktop/BUILD-INFO.txt')).readAsStringSync();

      /// libmpv-2.dll and ANGLE's libEGL.dll, as media_kit_libs_windows_video bundles them
      void writeVideo([String release = 'Release']) {
        writePe('$release/libmpv-2.dll', fakePe(imports: _kernel));
        writePe('$release/libEGL.dll', fakePe(imports: _kernel));
      }

      /// The archive of the fork's workflow as the Windows build extracts it: the same DLL, BUILDINFO.txt, licenses/
      void writeForkArchive() {
        writePe('x64/libmpv/libmpv-2.dll', fakePe(imports: _kernel));
        writeFiles(root, {
          'x64/libmpv/BUILDINFO.txt': 'libmpv-2.dll for Windows x86_64, built for Immuch360 Desktop',
          'x64/libmpv/licenses/ffmpeg/COPYING.LGPLv2.1': 'GNU LESSER GENERAL PUBLIC LICENSE',
        });
      }

      test('travel with the video player: NOTICES.md and the texts of the repository in licenses/', () {
        writeBuild();
        writeVideo();
        final run = bundle(version: internal);
        expect(run.exitCode, 0, reason: '$run');
        expect(bundled(), containsAll(notices));
        expect(
          File(path('dist/Immuch360 Desktop/licenses/LGPL-3.0.txt')).readAsStringSync(),
          contains('GNU LESSER GENERAL PUBLIC LICENSE'),
        );
        expect(buildInfo(), contains('licenses/NOTICES.md'));
        expect(buildInfo(), contains("not a build of the fork's workflow"));
        final zip = Process.runSync(python!.first, [...python!.skip(1), '-m', 'zipfile', '-l', path(zipFile)]);
        expect(zip.stdout, contains('Immuch360 Desktop/licenses/GPL-3.0.txt'));
      });

      test('a release ZIP is refused with a libmpv the fork did not build, and made on the owner\'s decision', () {
        writeBuild();
        writeVideo();
        var run = bundle();
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('no ZIP: a release ZIP would carry a libmpv-2.dll (LGPL)'));
        expect(File(path(zipFile)).existsSync(), isFalse);
        expect(bundled(), containsAll(notices));

        run = bundle(version: internal, extra: ['--public']);
        expect(run.exitCode, 1, reason: '$run');
        expect(File(path(zipFile)).existsSync(), isFalse);

        run = bundle(extra: ['--accept-2024-libmpv']);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('warning: release ZIP'));
        expect(File(path(zipFile)).existsSync(), isTrue);
      });

      test(
        'a version without a pre-release part: the tag build is a release, a build with an all-digit commit is not',
        () {
          writeBuild();
          writeVideo();
          var run = bundle(version: '3.3.0-20');
          expect(run.exitCode, 1, reason: '$run');
          expect(File(path(zipFile)).existsSync(), isFalse);

          run = bundle(version: '3.3.0-20-1234567');
          expect(run.exitCode, 0, reason: '$run');
          expect(File(path(zipFile)).existsSync(), isTrue);
        },
      );

      test("the fork's libmpv: the release ZIP is made, with its licences and BUILDINFO.txt", () {
        writeBuild();
        writeVideo();
        writeForkArchive();
        final run = bundle();
        expect(run.exitCode, 0, reason: '$run');
        expect(
          bundled(),
          containsAll([...notices, 'licenses/libmpv/BUILDINFO.txt', 'licenses/libmpv/ffmpeg/COPYING.LGPLv2.1']),
        );
        expect(buildInfo(), contains('built by the fork'));
        expect(File(path(zipFile)).existsSync(), isTrue);
      });

      test('an archive of the fork holding another DLL does not count', () {
        writeBuild();
        writeVideo();
        writeForkArchive();
        writePe('x64/libmpv/libmpv-2.dll', fakePe(imports: ['USER32.dll', ..._kernel]));
        final run = bundle();
        expect(run.exitCode, 1, reason: '$run');
        expect(bundled(), isNot(contains('licenses/libmpv/BUILDINFO.txt')));
      });

      test('finds the extracted archive two levels above the Release folder, as flutter build lays them out', () {
        writeBuild();
        Directory(path('x64/runner')).createSync(recursive: true);
        Directory(path('Release')).renameSync(path('x64/runner/Release'));
        writeVideo('x64/runner/Release');
        writeForkArchive();
        final run = bundle(release: 'x64/runner/Release');
        expect(run.exitCode, 0, reason: '$run');
        expect(bundled(), contains('licenses/libmpv/BUILDINFO.txt'));
      });

      test('stops when a licence text is missing', () {
        writeBuild();
        writeVideo();
        writeFiles(root, {'notices/NOTICES.md': '# Notices'});
        final run = bundle(version: internal, extra: ['--notices', path('notices')]);
        expect(run.exitCode, 2, reason: '$run');
        expect(run.output, contains('the licences of the video player must travel with it'));
        expect(run.output, contains('LGPL-3.0.txt'));
        expect(File(path(zipFile)).existsSync(), isFalse);
      });
    });

    test('stops on a redistributable folder without the runtime or on a folder that is not a build', () {
      writeBuild();
      File(path('CRT/vcruntime140_1.dll')).deleteSync();
      expect(bundle().exitCode, 2);
      Directory(path('Release/data')).deleteSync(recursive: true);
      final run = bundle();
      expect(run.exitCode, 2, reason: '$run');
      expect(run.output, contains('not a Flutter Windows build output'));
    });
  }, skip: skipCiScripts);
}
