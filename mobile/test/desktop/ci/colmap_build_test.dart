// Runs .github/desktop/ai/colmap_build.py, the script of the colmap jobs (lot SP1 of the splat maker: COLMAP built by
// our CI without its GPL parts), on fixture trees: the lock, the licences of the vcpkg ports against our list (a GPL
// entry must fail), the table of THIRD-PARTY.md, the forbidden names, imports and strings, the help of the commands
// against the fixtures, and the Windows archive.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'ai/colmap_build.py';

/// A vcpkg.spdx.json as vcpkg writes it for a port: the port first, then its binary
String _spdx(String name, String version, String licence) => jsonEncode({
  'spdxVersion': 'SPDX-2.2',
  'packages': [
    {
      'name': name,
      'SPDXID': 'SPDXRef-port',
      'versionInfo': version,
      'licenseConcluded': licence,
      'licenseDeclared': 'NOASSERTION',
    },
    {'name': '$name:x64-linux-release', 'SPDXID': 'SPDXRef-binary', 'licenseConcluded': 'NOASSERTION'},
  ],
});

/// The ports of a small installed tree: permissive ones, a reviewed metapackage and CLAPACK
const _ports = {
  'zlib': ('1.3.2#2', 'Zlib'),
  'boost-core': ('1.90.0', 'BSL-1.0'),
  'fmt': ('12.1.0', 'MIT'),
  'libjpeg-turbo': ('3.1.3', 'BSD-3-Clause AND IJG AND Zlib'),
  'eigen3': ('3.4.1', 'MPL-2.0'),
  'blas': ('2023-04-14#6', 'LicenseRef-vcpkg-null'),
  'clapack': ('3.2.1#25', 'LicenseRef-vcpkg-null'),
  'tiff': ('4.7.2', 'libtiff'),
};

String _table(Map<String, (String, String)> ports, {String systems = 'linux-x64'}) {
  final rows = [
    for (final entry in ports.entries)
      '| `${entry.key}` | ${entry.value.$1} | ${entry.value.$2} | $systems | `licenses/vcpkg/${entry.key}.txt` |',
  ];
  return '# Third party\n\n<!-- vcpkg ports: written by colmap_build.py table, checked by the colmap jobs -->\n\n'
      '| Port | Version | Licence (SPDX of vcpkg) | Systems | Text in the archive |\n|---|---|---|---|---|\n'
      '${rows.join('\n')}\n\n<!-- end of the vcpkg ports -->\n';
}

/// A fake colmap in Python: its help, with the log lines of glog that the comparison leaves out
String _fakeColmap({String commit = 'bd1fcf6', String extraOption = ''}) =>
    '''
import sys
args = sys.argv[1:]
if args == ['help']:
    print('COLMAP 4.2.1 (Commit $commit on 2026-09-29 without GPU support, boost hash maps)')
    print('Usage:')
    print('  colmap [command] [options]')
    sys.exit(0)
sys.stderr.write('I20261101 15:23:53.425428 29732 option_manager.cc:1319] COLMAP 4.2.1\\n')
print('  -h [ --help ]')
print('  --database_path arg')
print('  --' + args[0] + '.num_threads arg (=-1)')
if '$extraOption':
    print('  --$extraOption arg')
''';

void main() {
  final folders = <Directory>[];

  Directory tree(Map<String, String> files) {
    final root = fixtureTree(files);
    folders.add(root);
    return root;
  }

  tearDown(() {
    for (final folder in folders) {
      if (folder.existsSync()) {
        folder.deleteSync(recursive: true);
      }
    }
    folders.clear();
  });

  ScriptRun colmap(List<String> arguments) => runCiScript(_script, arguments);

  group('colmap_build.py', () {
    final lockPath = p.join(ciScriptsDir, 'ai', 'colmap.lock.json');

    test('the lock of the repository names the commits, the triplets and the artifacts of both systems', () {
      final windows = colmap(['lock', '--system', 'windows-x64']);
      expect(windows.exitCode, 0, reason: '$windows');
      expect(windows.output, contains('id=4.2.1-imm1'));
      expect(windows.output, contains('artifact=Immuch360-AI-colmap-4.2.1-imm1-windows-x64.zip'));
      expect(windows.output, contains('commit=bd1fcf654d2dd8fefa1466999c190a246f83f4b9'));
      expect(windows.output, contains('triplet=x64-windows-static-md-release'));
      expect(windows.output, contains('cache_key=windows-x64-127402f1c75b'));
      final linux = colmap(['lock', '--system', 'linux-x64']);
      expect(linux.exitCode, 0, reason: '$linux');
      expect(linux.output, contains('artifact=Immuch360-AI-colmap-4.2.1-imm1-linux-x64.zip'));
      expect(linux.output, contains('triplet=x64-linux-release'));
    });

    test('the lock builds without the GPL parts and asks for the help of the commands of the runner', () {
      final lock = jsonDecode(File(lockPath).readAsStringSync()) as Map<String, dynamic>;
      final common = (lock['cmake'] as Map<String, dynamic>)['common'] as List<dynamic>;
      for (final option in [
        '-DGUI_ENABLED=OFF',
        '-DOPENGL_ENABLED=OFF',
        '-DCUDA_ENABLED=OFF',
        '-DCGAL_ENABLED=OFF',
        '-DLSD_ENABLED=OFF',
        '-DCHOLMOD_ENABLED=OFF',
        '-DONNX_ENABLED=OFF',
        '-DDOWNLOAD_ENABLED=OFF',
      ]) {
        expect(common, contains(option));
      }
      expect(lock['help'], [
        'feature_extractor',
        'exhaustive_matcher',
        'sequential_matcher',
        'mapper',
        'model_orientation_aligner',
        'model_analyzer',
      ]);
      for (final command in ['help', ...lock['help'] as List<dynamic>]) {
        final fixture = File(
          p.join(repositoryRoot, 'mobile', 'test', 'fixtures', 'ai_immersive', 'colmap_help', '$command.txt'),
        );
        expect(fixture.existsSync(), isTrue, reason: fixture.path);
      }
      final patches = Directory(p.join(repositoryRoot, 'licenses', 'colmap', 'patches')).listSync();
      expect(patches.map((file) => p.basename(file.path)), unorderedEquals(lock['patches'] as List<dynamic>));
      final cholmod = File(p.join(repositoryRoot, 'licenses', 'colmap', 'patches', '0001-without-cholmod.patch'));
      expect(cholmod.readAsStringSync(), contains('Eigen::SimplicialLDLT'));
      expect(cholmod.readAsStringSync(), contains('#ifdef COLMAP_CHOLMOD_ENABLED'));
    });

    test('a lock without a full commit, or whose id is not of its tag, is refused', () {
      final lock = File(lockPath).readAsStringSync();
      for (final (changed, message) in [
        (
          lock.replaceFirst('bd1fcf654d2dd8fefa1466999c190a246f83f4b9', 'bd1fcf6'),
          'the commit of colmap is not a full',
        ),
        (lock.replaceFirst('"id": "4.2.1-imm1"', '"id": "4.2.0-imm1"'), 'is not of the tag 4.2.1'),
        (lock.replaceFirst('"id": "4.2.1-imm1"', '"id": "bd1fcf6-1"'), 'is not <version of COLMAP>-imm<build>'),
        (lock.replaceFirst('"0001-without-cholmod.patch"', '"0009-missing.patch"'), 'the patch 0009-missing.patch'),
      ]) {
        expect(changed, isNot(lock));
        final root = tree({'colmap.lock.json': changed});
        final run = colmap(['--lock', p.join(root.path, 'colmap.lock.json'), 'lock', '--system', 'linux-x64']);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains(message));
      }
    });

    group('licences', () {
      ScriptRun licences(Map<String, (String, String)> ports, {Map<String, (String, String)>? table}) {
        final root = tree({
          for (final entry in ports.entries)
            'installed/x64-linux-release/share/${entry.key}/vcpkg.spdx.json': _spdx(
              entry.key,
              entry.value.$1,
              entry.value.$2,
            ),
          'THIRD-PARTY.md': _table(table ?? ports),
        });
        return colmap([
          'licences',
          '--system',
          'linux-x64',
          '--installed',
          p.join(root.path, 'installed'),
          '--table',
          p.join(root.path, 'THIRD-PARTY.md'),
          '--ports-json',
          p.join(root.path, 'report', 'ports.json'),
        ]);
      }

      test('passes permissive licences, the reviewed ports and a table that says the same', () {
        final run = licences(_ports);
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('8 ports for x64-linux-release'));
        expect(run.output, contains('reviewed: a metapackage without code'));
      });

      test('fails on a GPL, LGPL or AGPL entry, or on a licence out of the list', () {
        for (final licence in [
          'GPL-3.0-or-later',
          'GPL-2.0-only',
          'LGPL-2.1-or-later',
          'AGPL-3.0-only',
          'CC-BY-NC-4.0',
          'LicenseRef-proprietary',
          'MIT AND GPL-2.0-or-later',
          'GPL-2.0-or-later WITH Classpath-exception-2.0',
        ]) {
          final ports = {..._ports, 'readline': ('8.3', licence)};
          final run = licences(ports);
          expect(run.exitCode, 1, reason: '$licence: $run');
          expect(run.output, contains('readline 8.3 is under $licence, not in our list'));
        }
      });

      test('a choice with a permissive licence, or an allowed exception, passes', () {
        for (final licence in [
          'GPL-2.0-only OR MIT',
          '(MIT OR Apache-2.0) AND Zlib',
          'Apache-2.0 WITH LLVM-exception',
        ]) {
          final ports = {..._ports, 'mixed': ('1.0', licence)};
          final run = licences(ports);
          expect(run.exitCode, 0, reason: '$licence: $run');
        }
      });

      test('fails on a port without licence that was not reviewed, and on a port our build leaves out', () {
        for (final none in ['LicenseRef-vcpkg-null', 'NOASSERTION']) {
          final unknown = licences({..._ports, 'mystery': ('1.0', none)});
          expect(unknown.exitCode, 1, reason: '$unknown');
          expect(unknown.output, contains('mystery 1.0 gives no licence and was not reviewed'));
        }
        final cholmod = licences({..._ports, 'suitesparse-cholmod': ('5.3.0', 'LGPL-2.1-or-later')});
        expect(cholmod.exitCode, 1, reason: '$cholmod');
        expect(cholmod.output, contains('suitesparse-cholmod 5.3.0 is installed: it is left out of our build'));
      });

      test('fails when the table of THIRD-PARTY.md differs from the ports installed', () {
        final missing = licences(_ports, table: {..._ports}..remove('fmt'));
        expect(missing.exitCode, 1, reason: '$missing');
        expect(missing.output, contains('fmt 12.1.0 (MIT) is installed for linux-x64 but not in the table'));
        final version = licences(_ports, table: {..._ports, 'fmt': ('11.0.0', 'MIT')});
        expect(version.exitCode, 1, reason: '$version');
        expect(version.output, contains('fmt: the table says 11.0.0 under MIT, installed 12.1.0 under MIT'));
      });

      test('table writes the rows of both systems from the port lists of the jobs', () {
        String ports(String system, Map<String, (String, String)> list) => jsonEncode({
          'system': system,
          'triplet': 'x',
          'ports': {
            for (final entry in list.entries) entry.key: {'version': entry.value.$1, 'licence': entry.value.$2},
          },
        });
        final root = tree({
          'windows.json': ports('windows-x64', _ports),
          'linux.json': ports('linux-x64', {..._ports, 'openblas': ('0.3.33', 'BSD-3-Clause')}),
          'THIRD-PARTY.md': _table({}),
        });
        final run = colmap([
          'table',
          '--ports-json',
          p.join(root.path, 'windows.json'),
          '--ports-json',
          p.join(root.path, 'linux.json'),
          '--table',
          p.join(root.path, 'THIRD-PARTY.md'),
        ]);
        expect(run.exitCode, 0, reason: '$run');
        final text = File(p.join(root.path, 'THIRD-PARTY.md')).readAsStringSync();
        expect(text, contains('| `zlib` | 1.3.2#2 | Zlib | linux-x64, windows-x64 | `licenses/vcpkg/zlib.txt` |'));
        expect(text, contains('| `openblas` | 0.3.33 | BSD-3-Clause | linux-x64 |'));
        expect(
          text,
          contains('| `blas` | 2023-04-14#6 | LicenseRef-vcpkg-null | linux-x64, windows-x64 | none, a metapackage'),
        );
      });
    });

    group('check', () {
      ScriptRun check(Map<String, List<int>> files) {
        final root = Directory.systemTemp.createTempSync('immuch360_colmap_');
        folders.add(root);
        for (final entry in files.entries) {
          File(p.join(root.path, entry.key))
            ..createSync(recursive: true)
            ..writeAsBytesSync(entry.value);
        }
        return colmap(['check', '--dir', root.path]);
      }

      test('passes a program that imports Windows and the Visual C++ runtime only', () {
        final run = check({
          'colmap.exe': fakePe(imports: ['KERNEL32.dll', 'VCRUNTIME140.dll', 'VCOMP140.DLL']),
          'licenses/patches/0001-without-cholmod.patch': utf8.encode('cholmod_ CHOLMOD SiftGPU Usage:'),
        });
        expect(run.exitCode, 0, reason: '$run');
      });

      test('fails on a forbidden file name or import', () {
        for (final (files, message) in [
          ({'Qt6Core.dll': fakePe()}, 'Qt6Core.dll: a forbidden name'),
          ({'cholmod.dll': fakePe()}, 'cholmod.dll: a forbidden name'),
          ({'libgfortran-5.dll': fakePe()}, 'libgfortran-5.dll: a forbidden name'),
          (
            {
              'colmap.exe': fakePe(imports: ['KERNEL32.dll', 'gmp-10.dll']),
            },
            'colmap.exe: imports or needs gmp-10.dll',
          ),
          (
            {
              'colmap.exe': fakePe(delayImports: ['glew32.dll']),
            },
            'colmap.exe: imports or needs glew32.dll',
          ),
          (
            {
              'colmap.exe': fakePe(imports: ['OPENGL32.dll']),
            },
            'colmap.exe: imports or needs OPENGL32.dll',
          ),
        ]) {
          final run = check(files);
          expect(run.exitCode, 1, reason: '$run');
          expect(run.output, contains(message));
        }
      });

      test('fails on the strings of SiftGPU, LSD, CHOLMOD and the other parts left out', () {
        for (final (marker, what) in [
          ('SiftGPU Usage:', 'SiftGPU'),
          ('[SiftGPU Language]', 'SiftGPU'),
          ('LineSegmentDetection', 'LSD (AGPL 3)'),
          ('new_ntuple_list', 'LSD (AGPL 3)'),
          ('cholmod_super_numeric', 'CHOLMOD'),
          ('SuiteSparseQR', 'SPQR'),
          ('__gmpz_init', 'GMP'),
          ('_gfortran_st_write', 'libgfortran'),
        ]) {
          final program = [
            ...fakePe(imports: ['KERNEL32.dll']),
            ...utf8.encode('\u0000$marker\u0000'),
          ];
          final run = check({'colmap.exe': program});
          expect(run.exitCode, 1, reason: '$marker: $run');
          expect(run.output, contains('a string of $what'));
        }
        // The CPU path of COLMAP warns about SiftGPU by name: that alone is not the library
        final warning = [
          ...fakePe(imports: ['KERNEL32.dll']),
          ...utf8.encode('Darkness adaptivity only available for GLSL SiftGPU.'),
        ];
        final run = check({'colmap.exe': warning});
        expect(run.exitCode, 0, reason: '$run');
      });
    });

    group('help', () {
      Directory fixtures(Map<String, String> texts) =>
          tree({for (final entry in texts.entries) '${entry.key}.txt': entry.value});

      String helpOf(String command) => command == 'help'
          ? 'COLMAP 4.2.1 (Commit bd1fcf6 on 2026-09-29 without GPU support, boost hash maps)\nUsage:\n'
                '  colmap [command] [options]\n'
          : '  -h [ --help ]\n  --database_path arg\n  --$command.num_threads arg (=-1)\n';

      const commands = [
        'help',
        'feature_extractor',
        'exhaustive_matcher',
        'sequential_matcher',
        'mapper',
        'model_orientation_aligner',
        'model_analyzer',
      ];

      ScriptRun help(String fake, Directory fixtureDir, {List<String> extra = const []}) {
        final root = tree({'colmap.py': fake});
        return colmap(['help', '--colmap', p.join(root.path, 'colmap.py'), '--fixtures', fixtureDir.path, ...extra]);
      }

      test('passes when every help equals its fixture, log lines apart', () {
        final run = help(_fakeColmap(), fixtures({for (final command in commands) command: helpOf(command)}));
        expect(run.exitCode, 0, reason: '$run');
        expect(run.output, contains('the same as the fixtures'));
      });

      test('fails on an option that changed, with the difference', () {
        final run = help(
          _fakeColmap(extraOption: 'Mapper.new_option'),
          fixtures({for (final command in commands) command: helpOf(command)}),
        );
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('mapper: the help differs from mapper.txt'));
        expect(run.output, contains('+  --Mapper.new_option arg'));
      });

      test('fails when colmap help names another commit', () {
        final run = help(
          _fakeColmap(commit: '1234567'),
          fixtures({for (final command in commands) command: helpOf(command)}),
        );
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('commit bd1fcf6, without GPU support expected'));
      });

      test('--write writes the fixtures, --save keeps the texts', () {
        final out = tree({'keep': ''});
        final run = help(_fakeColmap(), out, extra: ['--write', '--save', p.join(out.path, 'saved')]);
        expect(run.exitCode, 0, reason: '$run');
        expect(File(p.join(out.path, 'mapper.txt')).readAsStringSync(), helpOf('mapper'));
        expect(File(p.join(out.path, 'saved', 'help.txt')).readAsStringSync(), helpOf('help'));
      });
    });

    group('pack (Windows)', () {
      /// The trees pack reads: the sources and the build of COLMAP (the licence texts it compares), the installed
      /// ports, the Visual C++ redistributable with its OpenMP folder, and a System32
      Map<String, Directory> trees({
        List<String> imports = const ['KERNEL32.dll', 'VCRUNTIME140.dll', 'VCOMP140.DLL'],
      }) {
        final ours = Directory(p.join(repositoryRoot, 'licenses', 'colmap'));
        String text(String name) => File(p.join(ours.path, name)).readAsStringSync();
        final source = tree({
          'COPYING.txt': text('COPYING.txt'),
          'src/thirdparty/VLFeat/LICENSE': text('VLFeat-LICENSE.txt'),
          'src/thirdparty/PoissonRecon/LICENSE': text('PoissonRecon-LICENSE.txt'),
        });
        final build = tree({
          '_deps/poselib-src/LICENSE': text('PoseLib-LICENSE.txt'),
          '_deps/faiss-src/LICENSE': text('faiss-LICENSE.txt'),
        });
        File(p.join(build.path, 'src', 'colmap', 'exe', 'colmap.exe'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fakePe(imports: imports));
        final installed = tree({
          for (final entry in _ports.entries) ...{
            'x64-windows-static-md-release/share/${entry.key}/vcpkg.spdx.json': _spdx(
              entry.key,
              entry.value.$1,
              entry.value.$2,
            ),
            if (entry.key != 'blas')
              'x64-windows-static-md-release/share/${entry.key}/copyright': 'Copyright ${entry.key}',
          },
        });
        final crt = tree({'keep': ''});
        File(p.join(crt.path, 'Microsoft.VC143.CRT', 'vcruntime140.dll'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fakePe(imports: ['KERNEL32.dll']));
        File(p.join(crt.path, 'Microsoft.VC143.OpenMP', 'vcomp140.dll'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(fakePe(imports: ['KERNEL32.dll']));
        final system = tree({'kernel32.dll': '', 'vcruntime140.dll': '', 'opengl32.dll': ''});
        return {'source': source, 'build': build, 'installed': installed, 'crt': crt, 'system': system};
      }

      ScriptRun pack(Map<String, Directory> dirs, Directory out) => colmap([
        'pack',
        '--system',
        'windows-x64',
        '--source',
        dirs['source']!.path,
        '--build',
        dirs['build']!.path,
        '--installed',
        dirs['installed']!.path,
        '--out',
        out.path,
        '--crt-dir',
        p.join(dirs['crt']!.path, 'Microsoft.VC143.CRT'),
        '--system-dir',
        dirs['system']!.path,
      ]);

      test('the archive holds the program, its runtime DLLs, the licences and the sums, the same bytes twice', () {
        final dirs = trees();
        final first = tree({'keep': ''});
        final run = pack(dirs, first);
        expect(run.exitCode, 0, reason: '$run');
        final zip = File(p.join(first.path, 'Immuch360-AI-colmap-4.2.1-imm1-windows-x64.zip'));
        final listed = Process.runSync(python!.first, [
          ...python!.skip(1),
          '-c',
          'import sys, zipfile; print("\\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))',
          zip.path,
        ]);
        final names = '${listed.stdout}'.trim().split(RegExp(r'\r?\n'));
        final unpacked = tree({'keep': ''});
        Process.runSync(python!.first, [...python!.skip(1), '-m', 'zipfile', '-e', zip.path, unpacked.path]);
        List<int> member(String name) => File(p.joinAll([unpacked.path, ...name.split('/')])).readAsBytesSync();
        expect(
          names,
          containsAll(<String>[
            'colmap.exe',
            'vcruntime140.dll',
            'vcomp140.dll',
            'BUILD-INFO.txt',
            'SHA256SUMS.txt',
            'licenses/COPYING.txt',
            'licenses/README.md',
            'licenses/THIRD-PARTY.md',
            'licenses/libf2c-Notice.txt',
            'licenses/patches/0001-without-cholmod.patch',
            'licenses/vcpkg/zlib.txt',
            'licenses/vcpkg/clapack.txt',
          ]),
        );
        expect(names, isNot(contains('licenses/vcpkg/blas.txt')));
        expect(names, orderedEquals([...names]..sort()));
        final sums = utf8.decode(member('SHA256SUMS.txt'));
        expect(sums, contains('${sha256.convert(member('colmap.exe'))}  colmap.exe'));
        expect(sums, contains('${sha256.convert(member('licenses/vcpkg/zlib.txt'))}  licenses/vcpkg/zlib.txt'));
        final info = utf8.decode(member('BUILD-INFO.txt'));
        expect(info, contains('bd1fcf654d2dd8fefa1466999c190a246f83f4b9'));
        expect(info, contains('Left out: the graphical interface (Qt), OpenGL and SiftGPU, CUDA, LSD, CGAL, CHOLMOD'));
        final digest = File('${zip.path}.sha256').readAsStringSync();
        expect(digest, '${sha256.convert(zip.readAsBytesSync())}  ${p.basename(zip.path)}\n');

        final second = tree({'keep': ''});
        expect(pack(dirs, second).exitCode, 0);
        expect(
          File(p.join(second.path, p.basename(zip.path))).readAsBytesSync(),
          zip.readAsBytesSync(),
          reason: 'sorted names and fixed dates: the same files give the same bytes',
        );
      });

      test('fails when a licence text differs from the sources built, and on a forbidden import', () {
        final dirs = trees();
        File(p.join(dirs['build']!.path, '_deps', 'faiss-src', 'LICENSE')).writeAsStringSync('Another licence');
        final changed = pack(dirs, tree({'keep': ''}));
        expect(changed.exitCode, 1, reason: '$changed');
        expect(changed.output, contains('licenses/colmap/faiss-LICENSE.txt differs from _deps/faiss-src/LICENSE'));

        final qt = pack(trees(imports: ['KERNEL32.dll', 'Qt6Core.dll']), tree({'keep': ''}));
        expect(qt.exitCode, 1, reason: '$qt');
        expect(qt.output, contains('imports Qt6Core.dll, found neither in the folder nor in Windows'));
        expect(qt.output, contains('colmap.exe: imports or needs Qt6Core.dll'));
      });
    });
  }, skip: skipCiScripts);
}
