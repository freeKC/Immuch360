import 'dart:convert';
import 'dart:io';

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
      expect(read('usr/share/doc/immuch360/copyright'), contains('GNU AFFERO GENERAL PUBLIC LICENSE'));

      final nfpm = jsonDecode(File(p.join(out, 'nfpm.json')).readAsStringSync()) as Map<String, dynamic>;
      expect(
        [nfpm['name'], nfpm['version'], nfpm['prerelease'], nfpm['release']],
        ['immuch360', '3.3.0', 'rc.0', 'desktop.5'],
      );
      final overrides = nfpm['overrides'] as Map<String, dynamic>;
      expect(
        (overrides['deb'] as Map)['depends'],
        containsAll(['libmpv2 | libmpv1', 'libgtk-3-0t64 | libgtk-3-0', 'libc6 (>= 2.34)']),
      );
      expect((overrides['rpm'] as Map)['depends'], containsAll(['mpv-libs', 'gtk3', 'glibc >= 2.34']));
      final destinations = [for (final entry in nfpm['contents'] as List) (entry as Map)['dst']];
      expect(destinations, containsAll(['/opt/immuch360', '/usr/bin/immuch360']));
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
