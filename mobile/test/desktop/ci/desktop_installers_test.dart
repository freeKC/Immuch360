import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

/// An Info.plist with one key of its own, which writing the document types must keep
const _plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Immuch360 Desktop</string>
</dict>
</plist>
''';

/// A list of file types as .github/desktop/file-associations.json has it: two photos and two videos, one raw camera
/// format of each kind
String _list({Map<String, String>? photos, Map<String, String>? videos}) => jsonEncode({
  'photos': photos ?? {'jpg': 'JPEG photo', 'insp': 'Insta360 360° photo'},
  'videos': videos ?? {'mp4': 'MPEG-4 video', 'osv': 'DJI 360° video'},
});

/// The archive of the sources of libsmb2 in the bundle, an asset of the app that mise //mobile:codegen packs
const _libsmb2Sources = 'data/flutter_assets/packages/dart_smb2/libsmb2/Immuch360-libsmb2-sources.tar.gz';

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

  group('desktop_installers.py', () {
    ScriptRun installers(Directory root, List<String> command) =>
        runCiScript('desktop_installers.py', ['--associations', p.join(root.path, 'list.json'), ...command]);

    test('the list of the repository has its Linux and macOS types, and Info.plist declares it', () {
      final run = runCiScript('desktop_installers.py', ['check']);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('Info.plist declares them'));
    });

    test('Info.plist gets the list as types the app views, never as their default app, the raw ones imported', () {
      final root = tree({'list.json': _list(), 'Info.plist': _plist});
      final plist = p.join(root.path, 'Info.plist');
      var run = installers(root, ['check', '--plist', plist]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('CFBundleDocumentTypes differs'));

      run = installers(root, ['macos', '--write', '--plist', plist]);
      expect(run.exitCode, 0, reason: '$run');
      final text = File(plist).readAsStringSync();
      expect(text, contains('<string>public.jpeg</string>'));
      expect(text, contains('<string>public.mpeg-4</string>'));
      expect(text, contains('<string>com.aprogsys.immuch360.insp</string>'));
      expect(text, contains('<string>com.aprogsys.immuch360.osv</string>'));
      expect(text, contains('<string>Viewer</string>'));
      expect('<string>Alternate</string>'.allMatches(text), hasLength(4));
      expect(text, isNot(contains('<string>Owner</string>')));
      expect(text, isNot(contains('<string>Default</string>')));
      // Only the two raw formats are imported, each with its extension
      expect('<key>UTTypeIdentifier</key>'.allMatches(text), hasLength(2));
      expect(text, contains('<string>osv</string>'));
      expect(text, contains('<string>Immuch360 Desktop</string>'));

      run = installers(root, ['check', '--plist', plist]);
      expect(run.exitCode, 0, reason: '$run');
    });

    test('refuses an extension without its types, a dash as punctuation, a duplicate or an extension with its dot', () {
      for (final (list, message) in [
        (_list(photos: {'jpg': 'JPEG photo', 'bmp': 'Bitmap'}), 'bmp: no Linux MIME type'),
        (_list(photos: {'jpg': 'JPEG photo \u2013 the classic'}), 'a dash used as punctuation'),
        (_list(videos: {'jpg': 'JPEG video'}), 'jpg is listed twice'),
        (_list(photos: {'.jpg': 'JPEG photo'}), 'is not an extension in lower case'),
        (_list(photos: {'JPG': 'JPEG photo'}), 'is not an extension in lower case'),
        (_list(photos: {'jpg': ''}), 'needs a one line description'),
      ]) {
        final root = tree({'list.json': list, 'Info.plist': _plist});
        final run = installers(root, ['check', '--plist', p.join(root.path, 'Info.plist')]);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains(message));
      }
    });

    test('the Windows registry entries offer the app in "Open with" and never name the default program', () {
      final root = tree({'list.json': _list()});
      final out = p.join(root.path, 'associations.iss');
      final run = installers(root, ['inno', '--out', out]);
      expect(run.exitCode, 0, reason: '$run');
      final bytes = File(out).readAsBytesSync();
      // UTF-8 with its byte order mark, so that Inno Setup reads the degree sign
      expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
      final text = utf8.decode(bytes.skip(3).toList());
      for (final extension in ['jpg', 'insp', 'mp4', 'osv']) {
        final progId = 'Immuch360.$extension';
        expect(
          text,
          contains(
            'Subkey: "Software\\Classes\\.$extension\\OpenWithProgids"; ValueType: string; ValueName: "$progId"; '
            'ValueData: ""; Flags: uninsdeletevalue',
          ),
        );
        expect(
          text,
          contains(
            'Subkey: "Software\\Classes\\$progId\\shell\\open\\command"; ValueType: string; '
            'ValueData: """{app}\\immuch360.exe"" ""%1"""',
          ),
        );
        expect(text, contains('SupportedTypes"; ValueType: string; ValueName: ".$extension"'));
        expect(text, contains('FileAssociations"; ValueType: string; ValueName: ".$extension"; ValueData: "$progId"'));
      }
      expect(text, contains('ValueData: "Insta360 360° photo"'));
      // The default value of an extension key names its default program: no entry writes a value there
      expect(RegExp(r'Subkey: "Software\\Classes\\\.[0-9a-z]+"; ValueType').allMatches(text), isEmpty);
      expect(text, contains('Subkey: "Software\\RegisteredApplications"'));
    });

    test('the Windows installer is compiled from the folder of the ZIP, with the label and the file version', () {
      final root = tree({'list.json': _list(), 'bundle/immuch360.exe': 'MZ'});
      List<String> command({String fileVersion = '3.3.0.23', String bundle = 'bundle'}) => [
        'windows',
        '--bundle',
        p.join(root.path, bundle),
        '--label',
        '3.3.0-rc.0-desktop.5',
        '--file-version',
        fileVersion,
        '--out',
        p.join(root.path, 'out'),
        '--iscc',
        'ISCC.exe',
        '--dry-run',
      ];
      final run = installers(root, command());
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('/DSourceDir='));
      expect(run.output, contains('/DAppLabel=3.3.0-rc.0-desktop.5'));
      expect(run.output, contains('/DFileVersion=3.3.0.23'));
      expect(run.output, contains('/FImmuch360-Desktop-3.3.0-rc.0-desktop.5-windows-x64-setup'));
      expect(run.output, contains('immuch360.iss'));
      expect(File(p.join(root.path, 'out', 'immuch360-associations.iss')).existsSync(), isTrue);

      expect(installers(root, command(fileVersion: '3.3.0')).output, contains('is not A.B.C.D'));
      expect(installers(root, command(bundle: 'nothing')).output, contains('has no immuch360.exe'));
    });

    test('the Linux packages: the bundle under /opt, the launcher, the desktop entry, the MIME types, nFPM', () {
      final root = tree({
        'list.json': _list(),
        'bundle/immuch360': 'ELF',
        'bundle/data/icudtl.dat': 'data',
        'bundle/lib/libapp.so': 'ELF',
        // Built by jni for Android: it needs the libjvm.so of a Java runtime, so the packages leave it out
        'bundle/lib/libdartjni.so': 'ELF',
        // dart_smb2's library (LGPL-2.1-or-later): its notice and licence go into the packages, and the archive of
        // its sources is an asset of the app
        'bundle/lib/libsmb2.so': 'ELF',
        'bundle/$_libsmb2Sources': 'the sources of libsmb2',
      });
      final out = p.join(root.path, 'out');
      final run = installers(root, [
        'linux',
        '--bundle',
        p.join(root.path, 'bundle'),
        '--label',
        '3.3.0-rc.0-desktop.5',
        '--out',
        out,
        '--stage-only',
      ]);
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('package version 3.3.0~rc.0-desktop.5'));
      final stage = p.join(out, 'stage');
      String read(String path) => File(p.joinAll([stage, ...path.split('/')])).readAsStringSync();

      final desktop = read('usr/share/applications/com.aprogsys.immuch360.desktop');
      expect(desktop, contains('MimeType=image/jpeg;image/x-insta360-insp;video/mp4;video/x-dji-osv;\n'));
      expect(desktop, contains('Exec=immuch360 %F\n'));
      expect(desktop, contains('Icon=com.aprogsys.immuch360\n'));

      final mime = read('usr/share/mime/packages/com.aprogsys.immuch360.xml');
      expect(mime, contains('<mime-type type="image/x-insta360-insp">'));
      expect(mime, contains('<glob pattern="*.osv"/>'));
      expect(mime, contains('<sub-class-of type="video/mp4"/>'));
      expect(mime, isNot(contains('*.jpg')));

      final launcher = read('usr/bin/immuch360');
      expect(launcher, contains('echo "Immuch360 Desktop 3.3.0-rc.0-desktop.5"'));
      expect(launcher, contains('exec /opt/immuch360/immuch360 "\$@"'));
      if (!Platform.isWindows) {
        expect(File(p.join(stage, 'usr', 'bin', 'immuch360')).statSync().mode & 0x49, 0x49, reason: 'executable');
      }
      expect(read('opt/immuch360/lib/libapp.so'), 'ELF');
      expect(File(p.join(stage, 'opt', 'immuch360', 'lib', 'libdartjni.so')).existsSync(), isFalse);
      expect(run.output, contains('left out: lib/libdartjni.so'));
      expect(
        File(p.join(stage, 'usr/share/icons/hicolor/256x256/apps/com.aprogsys.immuch360.png')).existsSync(),
        isTrue,
      );
      final copyright = read('usr/share/doc/immuch360/copyright');
      expect(copyright, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
      expect(copyright, contains('/opt/immuch360/lib/libsmb2.so, the library of the SMB shares'));
      expect(copyright, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      expect(read('usr/share/licenses/immuch360/libsmb2/NOTICE'), contains('595d128b4d11a88a335eee961689a157e4f76cd3'));
      expect(read('opt/immuch360/$_libsmb2Sources'), 'the sources of libsmb2');

      final nfpm = jsonDecode(File(p.join(out, 'nfpm.json')).readAsStringSync()) as Map<String, dynamic>;
      expect(
        [nfpm['name'], nfpm['version'], nfpm['prerelease'], nfpm['release']],
        ['immuch360', '3.3.0', 'rc.0', 'desktop.5'],
      );
      final overrides = nfpm['overrides'] as Map<String, dynamic>;
      expect(
        (overrides['deb'] as Map)['depends'],
        containsAll(['libmpv2 | libmpv1', 'libgtk-3-0t64 | libgtk-3-0', 'libc6 (>= 2.34)', 'xdg-user-dirs']),
      );
      expect((overrides['rpm'] as Map)['depends'], containsAll(['mpv-libs', 'gtk3', 'glibc >= 2.34', 'xdg-user-dirs']));
      final destinations = [for (final entry in nfpm['contents'] as List) (entry as Map)['dst']];
      expect(
        destinations,
        containsAll([
          '/opt/immuch360',
          '/usr/bin/immuch360',
          '/usr/share/licenses/immuch360/libsmb2/LICENCE-LGPL-2.1.txt',
        ]),
      );
    });

    group('the AppImage', () {
      // A lock as appimage.lock.json has it, its tools and the source of the runtime faked by files of a few bytes
      String sha(String text) => sha256.convert(utf8.encode(text)).toString();
      Map<String, String> lock({String runtimeSource = 'the source of the runtime'}) => {
        'lock.json': jsonEncode({
          'appimagetool': {'url': 'https://example.org/appimagetool', 'sha256': sha('tool'), 'file': 'appimagetool'},
          'runtime': {'url': 'https://example.org/runtime', 'sha256': sha('runtime'), 'file': 'runtime-x86_64'},
          'sources': [
            {'url': 'https://example.org/src.tar.gz', 'sha256': sha(runtimeSource), 'file': 'runtime-src.tar.gz'},
          ],
        }),
        'tools/appimagetool': 'tool',
        'tools/runtime-x86_64': 'runtime',
        'tools/runtime-src.tar.gz': 'the source of the runtime',
      };
      Map<String, String> bundle() => {
        'list.json': _list(),
        'bundle/immuch360': 'ELF',
        'bundle/data/icudtl.dat': 'data',
        'bundle/lib/libapp.so': 'ELF',
        'bundle/lib/libdartjni.so': 'ELF',
        'bundle/lib/libsmb2.so': 'ELF',
        'bundle/$_libsmb2Sources': 'the sources of libsmb2',
      };
      ScriptRun appdir(Directory root) => installers(root, [
        'appimage',
        '--bundle',
        p.join(root.path, 'bundle'),
        '--label',
        '3.4.7-desktop.32',
        '--out',
        p.join(root.path, 'out'),
        '--tools',
        p.join(root.path, 'tools'),
        '--lock',
        p.join(root.path, 'lock.json'),
        '--appdir-only',
      ]);

      test(
        'the AppDir: the bundle, the AppRun that checks the libraries, the entry, the licences, the runtime source',
        () {
          final root = tree({...bundle(), ...lock()});
          final run = appdir(root);
          expect(run.exitCode, 0, reason: '$run');
          final dir = p.join(root.path, 'out', 'AppDir');
          String read(String path) => File(p.joinAll([dir, ...path.split('/')])).readAsStringSync();
          expect(read('immuch360/lib/libapp.so'), 'ELF');
          expect(File(p.join(dir, 'immuch360', 'lib', 'libdartjni.so')).existsSync(), isFalse);
          expect(read('immuch360/$_libsmb2Sources'), 'the sources of libsmb2');
          final apprun = read('AppRun');
          expect(apprun, contains("label='3.4.7-desktop.32'"));
          expect(apprun, contains('glibc 2.35 or later'));
          expect(apprun, isNot(contains('@LABEL@')));
          expect(apprun, isNot(contains('@GLIBC@')));
          expect(File(p.join(dir, 'AppRun')).statSync().mode & 0x49, 0x49, reason: 'executable');
          expect(File(p.join(dir, 'fallback', 'xdg-user-dir')).statSync().mode & 0x49, 0x49, reason: 'executable');
          final entry = read('com.aprogsys.immuch360.desktop');
          expect(entry, isNot(contains('TryExec=')));
          expect(entry, contains('X-AppImage-Version=3.4.7-desktop.32\n'));
          expect(entry, contains('PrefersNonDefaultGPU=true\n'));
          expect(read('usr/share/applications/com.aprogsys.immuch360.desktop'), entry);
          expect(Link(p.join(dir, '.DirIcon')).targetSync(), 'com.aprogsys.immuch360.png');
          expect(File(p.join(dir, 'com.aprogsys.immuch360.png')).existsSync(), isTrue);
          final metainfo = read('usr/share/metainfo/com.aprogsys.immuch360.metainfo.xml');
          expect(metainfo, contains('<release version="3.4.7" date="'));
          expect(metainfo, contains('<launchable type="desktop-id">com.aprogsys.immuch360.desktop</launchable>'));
          expect(read('usr/share/doc/immuch360/copyright'), contains('GNU LESSER GENERAL PUBLIC LICENSE'));
          expect(read('usr/share/licenses/immuch360/libsmb2/NOTICE'), isNotEmpty);
          const runtime = 'usr/share/doc/immuch360/appimage-runtime';
          expect(read('$runtime/runtime-src.tar.gz'), 'the source of the runtime');
          expect(read('$runtime/RUNTIME-NOTICE.txt'), contains('libfuse 3.15.0'));
          expect(read('$runtime/LICENCE-LGPL-2.1.txt'), contains('GNU LESSER GENERAL PUBLIC LICENSE'));
          // The AppRun answers its version before it looks for any library
          final version = Process.runSync('sh', [p.join(dir, 'AppRun'), '--version']);
          expect(version.stdout, 'Immuch360 Desktop 3.4.7-desktop.32\n');
        },
        skip: Platform.isWindows ? 'the AppImage is made on Linux (symbolic links, sh)' : false,
      );

      test('the AppRun names libmpv1 on Ubuntu 22.04 and the systems made on it, libmpv2 or mpv elsewhere', () {
        final root = tree({...bundle(), ...lock()});
        final run = appdir(root);
        expect(run.exitCode, 0, reason: '$run');
        final dir = p.join(root.path, 'out', 'AppDir');
        final apprun = File(p.join(dir, 'AppRun')).readAsStringSync();
        const check = 'if [ "\${1:-}" = "--immuch360-check" ]; then';
        expect(apprun, contains(check));
        expect(apprun, contains('/etc/os-release'));
        // The os-release of each system as it ships it (the fields the AppRun reads), and the advice for a missing
        // libmpv printed by a copy of the AppRun that reads that file and stops before any library is looked for
        const systems = {
          'ubuntu-22.04':
              'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n',
          'linuxmint-21':
              'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="21"\nVERSION_CODENAME=vanessa\nUBUNTU_CODENAME=jammy\n',
          'pop-22.04':
              'ID=pop\nID_LIKE="ubuntu debian"\nVERSION_ID="22.04"\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n',
          'zorin-17': 'ID=zorin\nID_LIKE=ubuntu\nVERSION_ID="17"\nVERSION_CODENAME=jammy\nUBUNTU_CODENAME=jammy\n',
          'elementary-7':
              'ID=elementary\nID_LIKE=ubuntu\nVERSION_ID="7"\nVERSION_CODENAME=horus\nUBUNTU_CODENAME=jammy\n',
          'ubuntu-24.04':
              'ID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n',
          'linuxmint-22':
              'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble\n',
          'debian-12': 'ID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n',
          'arch': 'ID=arch\n',
        };
        String advice(String system) {
          final release = File(p.join(root.path, 'os-release-$system'))..writeAsStringSync(systems[system]!);
          final copy = File(p.join(dir, 'AppRun-$system'))
            ..writeAsStringSync(
              apprun
                  .replaceAll('/etc/os-release', release.path)
                  .replaceFirst(check, 'if [ "\${1:-}" = "--advice" ]; then advice libmpv.so.2; exit 0; fi\n$check'),
            );
          final out = Process.runSync('sh', [copy.path, '--advice']);
          expect(out.exitCode, 0, reason: '$system: ${out.stderr}');
          return out.stdout as String;
        }

        for (final system in ['ubuntu-22.04', 'linuxmint-21', 'pop-22.04', 'zorin-17', 'elementary-7']) {
          expect(advice(system), contains('sudo apt install libmpv1\n'), reason: system);
        }
        for (final system in ['ubuntu-24.04', 'linuxmint-22', 'debian-12']) {
          expect(advice(system), contains('sudo apt install libmpv2\n'), reason: system);
        }
        expect(advice('arch'), contains('sudo pacman -S --needed mpv\n'));
      }, skip: Platform.isLinux ? false : 'the AppRun runs on Linux (its loader)');

      test('refuses a source of the runtime that is not the one the lock pins', () {
        final root = tree({...bundle(), ...lock(runtimeSource: 'another source')});
        final run = appdir(root);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('is not the file the lock pins'));
      }, skip: Platform.isWindows ? 'the AppImage is made on Linux' : false);

      test('refuses a lock without the source of the runtime or with an address that is not https', () {
        final root = tree({
          ...bundle(),
          ...lock(),
          'lock.json': jsonEncode({
            'appimagetool': {'url': 'http://example.org/t', 'sha256': sha('tool'), 'file': 'appimagetool'},
            'runtime': {'url': 'https://example.org/r', 'sha256': sha('runtime'), 'file': 'runtime-x86_64'},
            'sources': <Object>[],
          }),
        });
        final run = appdir(root);
        expect(run.exitCode, 1, reason: '$run');
        expect(run.output, contains('needs an https address'));
      });
    });

    test('refuses a bundle with lib/libsmb2.so whose assets lack the archive of its sources', () {
      final root = tree({
        'list.json': _list(),
        'bundle/immuch360': 'ELF',
        'bundle/data/icudtl.dat': 'data',
        'bundle/lib/libsmb2.so': 'ELF',
      });
      final run = installers(root, [
        'linux',
        '--bundle',
        p.join(root.path, 'bundle'),
        '--label',
        '3.3.0-rc.0-23',
        '--out',
        p.join(root.path, 'out'),
        '--stage-only',
      ]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('the corresponding source of libsmb2 must travel with lib/libsmb2.so'));
      expect(run.output, contains(_libsmb2Sources));
      expect(File(p.join(root.path, 'out', 'nfpm.json')).existsSync(), isFalse);
    });

    test('refuses a folder that is not the bundle of flutter build linux', () {
      final root = tree({'list.json': _list(), 'bundle/immuch360': 'ELF'});
      final run = installers(root, [
        'linux',
        '--bundle',
        p.join(root.path, 'bundle'),
        '--label',
        '3.3.0-rc.0-23',
        '--out',
        p.join(root.path, 'out'),
        '--stage-only',
      ]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('is not the bundle of flutter build linux'));
    });

    test('package versions put a pre-release before its release, and a label must be one of desktop_version.py', () {
      Map<String, String> versions(String label) {
        final run = runCiScript('desktop_installers.py', ['versions', '--label', label]);
        expect(run.exitCode, 0, reason: '$run');
        return {
          for (final line in const LineSplitter().convert(run.output))
            if (line.contains('=')) line.split('=').first: line.split('=').last,
        };
      }

      expect(versions('3.3.0-rc.0-desktop.5')['deb'], '3.3.0~rc.0-desktop.5');
      expect(versions('3.3.0-rc.0-23')['rpm'], '3.3.0~rc.0-23');
      expect(versions('3.3.0-rc.0-23-d7103a7')['deb'], '3.3.0~rc.0-23.d7103a7');
      expect(versions('3.4.0-7'), containsPair('deb', '3.4.0-7'));
      for (final label in [r'3.3.0;id-1', '3.3.0-rc.0', '3.3.0-rc.0-desktop', 'v3.3.0-rc.0-23']) {
        expect(runCiScript('desktop_installers.py', ['versions', '--label', label]).exitCode, 1, reason: label);
      }
    });
  }, skip: skipCiScripts);
}
