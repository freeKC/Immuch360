// windows_sign.py, which signs the Windows files of a desktop release, run with a fake signtool: the signatures it
// "makes" are a marker at the end of the file, which its verify reports as signtool verify /pa /v does

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

/// signtool for the tests: sign appends the marker of APROGSYS to each file, after checking the options of a signature
/// through Artifact Signing; verify prints the certificate chain of the marker, or "No signature found"
const _fakeSigntool = r'''
import pathlib, sys
args = sys.argv[1:]
MARK = b'\nFAKE-SIGNATURE:'
ROOT = 'Microsoft Identity Verification Root Certificate Authority 2020'
if args[0] == 'sign':
    wanted = ('/fd', 'SHA256', '/tr', 'http://timestamp.acs.microsoft.com', '/td', '/dlib', '/dmdf')
    missing = [option for option in wanted if option not in args]
    if missing:
        print('SignTool Error: missing ' + ' '.join(missing))
        sys.exit(1)
    for name in args[args.index('/du') + 2:]:
        path = pathlib.Path(name)
        data = path.read_bytes()
        if MARK in data:
            data = data[:data.index(MARK)]
        path.write_bytes(data + MARK + b'APROGSYS')
        print('Successfully signed: ' + name)
    sys.exit(0)
name = args[-1]
data = pathlib.Path(name).read_bytes()
print('Verifying: ' + name)
if MARK not in data:
    print('SignTool Error: No signature found.')
    sys.exit(1)
signer = data[data.index(MARK) + len(MARK):].decode()
issuer = 'Microsoft ID Verified CS EOC CA 03' if signer == 'APROGSYS' else 'Microsoft Code Signing PCA 2011'
print('Signing Certificate Chain:')
print('    Issued to: ' + ROOT)
print('    Issued by: ' + ROOT)
print('        Issued to: ' + issuer)
print('        Issued by: ' + ROOT)
print('            Issued to: ' + signer)
print('            Issued by: ' + issuer)
print('')
print('The signature is timestamped: Thu Oct 22 17:00:00 2026')
print('Timestamp Verified by:')
print('    Issued to: Microsoft Public RSA Timestamping CA 2020')
print('')
print('Successfully verified: ' + name)
''';

/// A ZIP as windows_bundle.py makes it: one folder with the program (file version 3.3.0.28), two DLLs of the app, a
/// runtime DLL Microsoft signed, data/app.so, and BUILD-INFO.txt holding the note of windows_bundle.py about the
/// signature, its lines ended by \r\n or, with crcrlf, by the \r\r\n that a Windows run writes
const _makeZip = r'''
import struct, sys, zipfile
sys.path.insert(0, sys.argv[1])
from windows_bundle import UNSIGNED_NOTE
end = '\r\r\n' if sys.argv[3] == 'crcrlf' else '\r\n'
version = struct.pack('<IIII', 0xFEEF04BD, 0x00010000, 3 << 16 | 3, 28)
info = end.join(['Immuch360 Desktop', 'version: 3.3.0-rc.0-desktop.8', '', *UNSIGNED_NOTE, 'last line']) + end
files = [
    ('BUILD-INFO.txt', info.encode('utf-8')),
    ('data/app.so', b'not a PE file'),
    ('flutter_windows.dll', b'MZ flutter'),
    ('immuch360.exe', b'MZ' + bytes(64) + version + bytes(36)),
    ('plugins/libmpv-2.DLL', b'MZ libmpv'),
    ('vcruntime140.dll', b'MZ runtime\nFAKE-SIGNATURE:Microsoft Corporation'),
]
with zipfile.ZipFile(sys.argv[2], 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
    for name, data in files:
        archive.writestr(zipfile.ZipInfo('Immuch360 Desktop/' + name, (2026, 10, 22, 12, 30, 0)), data)
''';

/// The entries of a ZIP, their dates, and the contents of each file as Latin-1 text
const _readZip = r'''
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    entries = archive.infolist()
    print(json.dumps({'names': [entry.filename for entry in entries],
                      'dates': [list(entry.date_time) for entry in entries],
                      'files': {entry.filename: archive.read(entry).decode('latin-1') for entry in entries}}))
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

  ProcessResult runPython(List<String> arguments) => Process.runSync(python!.first, [...python!.skip(1), ...arguments]);

  /// A tools folder whose signing.json runs the fake signtool
  Directory tools() {
    final root = tree({'fake_signtool.py': _fakeSigntool});
    File(p.join(root.path, 'signing.json')).writeAsStringSync(
      jsonEncode({
        'signtool': [...python!, p.join(root.path, 'fake_signtool.py')],
        'dlib': p.join(root.path, 'Azure.CodeSigning.Dlib.dll'),
        'metadata': p.join(root.path, 'metadata.json'),
        'log': p.join(root.path, 'sign.log'),
      }),
    );
    return root;
  }

  String makeZip(Directory root, {String ends = 'crlf'}) {
    final zip = p.join(root.path, 'Immuch360-Desktop-test-windows-x64.zip');
    final run = runPython(['-c', _makeZip, ciScriptsDir, zip, ends]);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
    return zip;
  }

  Map<String, dynamic> readZip(String zip) {
    final run = runPython(['-c', _readZip, zip]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    return jsonDecode('${run.stdout}') as Map<String, dynamic>;
  }

  group('windows_sign.py', () {
    test('signs every .exe and .dll of the ZIP, keeps the runtime of Microsoft, and keeps the layout', () {
      final signing = tools();
      final root = tree({});
      final zip = makeZip(root, ends: 'crcrlf');
      final before = readZip(zip);
      final output = File(p.join(root.path, 'github-output.txt'))..writeAsStringSync('');

      final run = runCiScript(
        'windows_sign.py',
        [
          'bundle',
          '--tools',
          signing.path,
          '--zip',
          zip,
          '--work',
          p.join(root.path, 'work'),
          '--out',
          p.join(root.path, 'signed'),
          '--github-output',
        ],
        environment: {'GITHUB_OUTPUT': output.path},
      );
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('4 .exe and .dll files: 3 to sign, 1 signed already'));
      expect(run.output, contains('kept: vcruntime140.dll, signed by Microsoft Corporation'));

      final after = readZip(p.join(root.path, 'signed', 'Immuch360-Desktop-test-windows-x64.zip'));
      // The same entries in the same order, with their dates
      expect(after['names'], before['names']);
      expect(after['dates'], before['dates']);
      final files = after['files'] as Map<String, dynamic>;
      for (final name in ['immuch360.exe', 'flutter_windows.dll', 'plugins/libmpv-2.DLL']) {
        expect(files['Immuch360 Desktop/$name'], endsWith('FAKE-SIGNATURE:APROGSYS'), reason: name);
      }
      expect(files['Immuch360 Desktop/vcruntime140.dll'], endsWith('FAKE-SIGNATURE:Microsoft Corporation'));
      expect(files['Immuch360 Desktop/data/app.so'], 'not a PE file');

      // BUILD-INFO.txt says the build is signed, with the line ends it had
      final info = files['Immuch360 Desktop/BUILD-INFO.txt'] as String;
      expect(info, isNot(contains('not signed')));
      expect(info, contains('show APROGSYS as their publisher\r\r\n(file properties, Digital Signatures)'));
      expect(info, endsWith('last line\r\r\n'));

      final values = output.readAsStringSync();
      expect(values, contains('file_version=3.3.0.28'));
      expect(values, contains('folder='));
      expect(File(p.join(signing.path, 'sign.log')).readAsStringSync(), contains('Successfully signed'));
    });

    test('files: the archive of stable-diffusion.cpp, its programs and libraries signed at the top, the rest kept', () {
      final signing = tools();
      final root = tree({});
      final zip = p.join(root.path, 'Immuch360-AI-sdcpp-be48649-1-windows-x64.zip');
      const make = r'''
import sys, zipfile
files = [('BUILD-INFO.txt', b'lock be48649-1'), ('ggml-vulkan.dll', b'MZ vulkan'), ('licenses/THIRD-PARTY.md', b'MIT'),
         ('sd-cli.exe', b'MZ cli'), ('vcruntime140.dll', b'MZ rt\nFAKE-SIGNATURE:Microsoft Corporation')]
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as archive:
    for name, data in files:
        info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
        info.external_attr = (0o100755 if name.endswith('.exe') else 0o100644) << 16
        archive.writestr(info, data)
''';
      expect(runPython(['-c', make, zip]).exitCode, 0);
      final before = readZip(zip);
      final output = File(p.join(root.path, 'github-output.txt'))..writeAsStringSync('');

      final run = runCiScript(
        'windows_sign.py',
        [
          'files',
          '--tools',
          signing.path,
          '--zip',
          zip,
          '--work',
          p.join(root.path, 'work'),
          '--out',
          p.join(root.path, 'signed'),
          '--github-output',
        ],
        environment: {'GITHUB_OUTPUT': output.path},
      );
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains('3 .exe and .dll files: 2 to sign, 1 signed already'));
      final signed = p.join(root.path, 'signed', 'Immuch360-AI-sdcpp-be48649-1-windows-x64.zip');
      final after = readZip(signed);
      expect(after['names'], before['names']);
      expect(after['dates'], before['dates']);
      final files = after['files'] as Map<String, dynamic>;
      expect(files['sd-cli.exe'], endsWith('FAKE-SIGNATURE:APROGSYS'));
      expect(files['ggml-vulkan.dll'], endsWith('FAKE-SIGNATURE:APROGSYS'));
      expect(files['vcruntime140.dll'], endsWith('FAKE-SIGNATURE:Microsoft Corporation'));
      expect(files['BUILD-INFO.txt'], 'lock be48649-1');
      expect(files['licenses/THIRD-PARTY.md'], 'MIT');
      final values = output.readAsStringSync();
      // The path resolved by the script: a Windows temporary folder may be given in its short form (RUNNER~1)
      expect(values, matches(RegExp(r'archive=.+[\\/]signed[\\/]Immuch360-AI-sdcpp-be48649-1-windows-x64\.zip')));
      expect(values, matches(RegExp(r'sha256=[0-9a-f]{64}')));

      // A path that leaves the archive, or an archive without a program, is refused before anything is signed
      final unsafe = p.join(root.path, 'unsafe.zip');
      expect(runPython(['-c', make.replaceFirst("('sd-cli.exe'", "('../sd-cli.exe'"), unsafe]).exitCode, 0);
      final refused = runCiScript('windows_sign.py', [
        'files',
        '--tools',
        signing.path,
        '--zip',
        unsafe,
        '--work',
        p.join(root.path, 'work2'),
        '--out',
        p.join(root.path, 'signed2'),
      ]);
      expect(refused.exitCode, 1, reason: '$refused');
      expect(refused.output, contains('unsafe path in the ZIP: ../sd-cli.exe'));
      final empty = p.join(root.path, 'empty.zip');
      expect(runPython(['-c', make.replaceAll('.exe', '.txt').replaceAll('.dll', '.txt'), empty]).exitCode, 0);
      final none = runCiScript('windows_sign.py', [
        'files',
        '--tools',
        signing.path,
        '--zip',
        empty,
        '--work',
        p.join(root.path, 'work3'),
        '--out',
        p.join(root.path, 'signed3'),
      ]);
      expect(none.exitCode, 1, reason: '$none');
      expect(none.output, contains('holds no .exe and no .dll'));
    });

    test('check passes the signed files and refuses a ZIP or an installer that APROGSYS did not sign', () {
      final signing = tools();
      final root = tree({});
      final zip = makeZip(root);
      final signed = runCiScript('windows_sign.py', [
        'bundle',
        '--tools',
        signing.path,
        '--zip',
        zip,
        '--work',
        p.join(root.path, 'work'),
        '--out',
        p.join(root.path, 'signed'),
      ]);
      expect(signed.exitCode, 0, reason: '$signed');
      final setup = File(p.join(root.path, 'setup.exe'))..writeAsStringSync('MZ setup');
      final signedZip = p.join(root.path, 'signed', p.basename(zip));
      final summary = File(p.join(root.path, 'summary.md'))..writeAsStringSync('');
      List<String> check(String zipPath) => ['check', '--tools', signing.path, '--zip', zipPath, '--setup', setup.path];

      // The installer is not signed yet
      final unsignedSetup = runCiScript('windows_sign.py', check(signedZip));
      expect(unsignedSetup.exitCode, 1, reason: '$unsignedSetup');
      expect(unsignedSetup.output, contains('installer: setup.exe: no valid signature'));

      final sign = runCiScript('windows_sign.py', ['sign', '--tools', signing.path, setup.path]);
      expect(sign.exitCode, 0, reason: '$sign');
      expect(sign.output, contains('setup.exe: signed by APROGSYS (issuer Microsoft ID Verified CS EOC CA 03)'));

      final good = runCiScript('windows_sign.py', check(signedZip), environment: {'GITHUB_STEP_SUMMARY': summary.path});
      expect(good.exitCode, 0, reason: '$good');
      expect(good.output, contains('ZIP: signed by Microsoft Corporation: vcruntime140.dll'));
      expect(summary.readAsStringSync(), contains('Every file is signed as it must be.'));

      final unsignedZip = runCiScript('windows_sign.py', check(zip));
      expect(unsignedZip.exitCode, 1, reason: '$unsignedZip');
      expect(
        unsignedZip.output,
        contains('ZIP: immuch360.exe: no valid signature, APROGSYS with a timestamp expected'),
      );
      expect(unsignedZip.output, contains('ZIP: flutter_windows.dll: no valid signature'));

      final verify = runCiScript('windows_sign.py', ['verify', '--tools', signing.path, setup.path, zip]);
      expect(verify.exitCode, 1, reason: '$verify');
    });

    test('refuses a BUILD-INFO.txt without the note of windows_bundle.py, and a ZIP of several folders', () {
      final signing = tools();
      final root = tree({});
      final zip = makeZip(root);
      final rewrite = runPython([
        '-c',
        r'''
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as old, zipfile.ZipFile(sys.argv[2], 'w') as new:
    for entry in old.infolist():
        data = old.read(entry)
        if entry.filename.endswith('BUILD-INFO.txt'):
            data = b'Immuch360 Desktop\r\n'
        new.writestr(entry, data)
''',
        zip,
        p.join(root.path, 'note.zip'),
      ]);
      expect(rewrite.exitCode, 0, reason: '${rewrite.stderr}');
      List<String> bundle(String name) => [
        'bundle',
        '--tools',
        signing.path,
        '--zip',
        p.join(root.path, name),
        '--work',
        p.join(root.path, 'work'),
        '--out',
        p.join(root.path, 'signed'),
      ];
      final note = runCiScript('windows_sign.py', bundle('note.zip'));
      expect(note.exitCode, 1, reason: '$note');
      expect(note.output, contains('does not say that the build is not signed'));
      // Found before anything is signed
      expect(note.output, isNot(contains('Successfully signed')));

      const addFolder = '''
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a') as archive:
    archive.writestr('other/readme.txt', b'')
''';
      final folders = runPython(['-c', addFolder, zip]);
      expect(folders.exitCode, 0, reason: '${folders.stderr}');
      final two = runCiScript('windows_sign.py', bundle(p.basename(zip)));
      expect(two.exitCode, 1, reason: '$two');
      expect(two.output, contains('does not hold one folder'));
    });

    test('takes signtool and the signing client only with the SHA-256 of their packages', () {
      final root = tree({'packages/microsoft.windows.sdk.buildtools.10.0.26100.4188.nupkg': 'not the package'});
      final run = runCiScript('windows_sign.py', [
        'tools',
        '--dir',
        p.join(root.path, 'tools'),
        '--packages',
        p.join(root.path, 'packages'),
      ]);
      expect(run.exitCode, 1, reason: '$run');
      expect(run.output, contains('microsoft.windows.sdk.buildtools.10.0.26100.4188.nupkg: SHA-256'));
      expect(File(p.join(root.path, 'tools', 'signing.json')).existsSync(), isFalse);

      final missing = runCiScript('windows_sign.py', [
        'tools',
        '--dir',
        p.join(root.path, 'tools'),
        '--packages',
        p.join(root.path, 'nothing'),
      ]);
      expect(missing.exitCode, 1, reason: '$missing');
      expect(missing.output, contains('no microsoft.windows.sdk.buildtools.10.0.26100.4188.nupkg'));
    });

    test('the installer is signed by Inno Setup through windows_sign.py sign, given its tools folder', () {
      final signing = tools();
      final root = tree({
        'list.json': jsonEncode({
          'photos': {'jpg': 'JPEG photo'},
          'videos': {'mp4': 'MPEG-4 video'},
        }),
        'bundle/immuch360.exe': 'MZ',
      });
      List<String> command(String toolsFolder) => [
        '--associations',
        p.join(root.path, 'list.json'),
        'windows',
        '--bundle',
        p.join(root.path, 'bundle'),
        '--label',
        '3.3.0-rc.0-desktop.8',
        '--file-version',
        '3.3.0.28',
        '--out',
        p.join(root.path, 'out'),
        '--iscc',
        'ISCC.exe',
        '--sign-with',
        toolsFolder,
        '--dry-run',
      ];
      final run = runCiScript('desktop_installers.py', command(signing.path));
      expect(run.exitCode, 0, reason: '$run');
      expect(run.output, contains(r'/Simmuch360sign=$q'));
      expect(run.output, contains(r'windows_sign.py$q sign --tools $q'));
      // The options before the script
      expect(run.output, contains(r'$q $f /DSignToolName=immuch360sign '));
      expect(run.output.indexOf('/DSignToolName'), lessThan(run.output.lastIndexOf('immuch360.iss')));

      final none = runCiScript('desktop_installers.py', command(root.path));
      expect(none.exitCode, 1, reason: '$none');
      expect(none.output, contains('has no signing.json'));
    });
  }, skip: skipCiScripts);
}
