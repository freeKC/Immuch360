// .github/desktop/libsmb2/pack_sources.py: the archive of the sources of libsmb2 (LGPL) that every build carries as an
// asset and every release as a file, made from the pinned commits only and the same way each time.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

const _script = 'libsmb2/pack_sources.py';
const _libsmb2Commit = '0123456789abcdef0123456789abcdef01234567';
const _top = 'immuch360-libsmb2-sources';

final Object _skip = skipCiScripts != false
    ? skipCiScripts
    : !_runs('git', ['--version'])
    ? 'needs git'
    : false;

bool _runs(String command, List<String> arguments) {
  try {
    return Process.runSync(command, arguments).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

String _git(String dir, List<String> arguments) {
  final result = Process.runSync('git', [
    '-c',
    'user.name=Immuch360 test',
    '-c',
    'user.email=test@immuch360.invalid',
    '-c',
    'init.defaultBranch=main',
    '-c',
    'commit.gpgsign=false',
    '-c',
    'core.autocrlf=false',
    ...arguments,
  ], workingDirectory: dir);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
  }
  return '${result.stdout}'.trim();
}

int _octal(String digits) => int.parse(digits, radix: 8);

/// One file of a tar archive
class _Member {
  final int mode;
  final List<int> data;

  const _Member(this.mode, this.data);
}

/// The plain files of a .tar.gz by name, from the headers of the ustar and GNU formats (long names included)
Map<String, _Member> _untar(List<int> archive) {
  final bytes = gzip.decode(archive);
  final files = <String, _Member>{};
  String? longName;
  var offset = 0;
  while (offset + 512 <= bytes.length) {
    final header = bytes.sublist(offset, offset + 512);
    if (header.every((byte) => byte == 0)) {
      break;
    }
    String field(int start, int length) {
      final raw = header.sublist(start, start + length);
      final end = raw.indexOf(0);
      return utf8.decode(end < 0 ? raw : raw.sublist(0, end));
    }

    final size = int.parse(field(124, 12).trim(), radix: 8);
    final type = header[156];
    final data = bytes.sublist(offset + 512, offset + 512 + size);
    offset += 512 + (size + 511) ~/ 512 * 512;
    if (type == 0x4C) {
      longName = utf8.decode(data.takeWhile((byte) => byte != 0).toList());
      continue;
    }
    final name = longName ?? field(0, 100);
    longName = null;
    if (type == 0x30 || type == 0) {
      files[name] = _Member(int.parse(field(100, 8).trim(), radix: 8), data);
    }
  }
  return files;
}

void main() {
  late Directory root;
  late String scripts;
  late String commit;
  late File libsmb2;

  setUp(() {
    root = Directory.systemTemp.createTempSync('immuch360_libsmb2_');
    libsmb2 = File(p.join(root.path, 'libsmb2.tar.gz'))..writeAsBytesSync(utf8.encode('libsmb2 at a commit'));
    final sha256OfLibsmb2 = sha256.convert(libsmb2.readAsBytesSync()).toString();
    scripts = p.join(root.path, 'scripts');
    writeFiles(Directory(scripts), {
      'scripts/shared/_versions.sh':
          '# Pinned upstream versions\n'
          'export LIBSMB2_COMMIT="\${LIBSMB2_COMMIT:-$_libsmb2Commit}"\n'
          'export LIBSMB2_TARBALL_SHA256="\${LIBSMB2_TARBALL_SHA256:-$sha256OfLibsmb2}"\n',
      'scripts/build_libsmb2_linux.sh': '#!/usr/bin/env bash\necho build\n',
      'patches/libsmb2/shared/patch_one.py': 'print("patch")\n',
      // Kept as git stores it, carriage returns included, whatever the checkout settings of the machine
      'build.cmd': '@echo off\r\necho build\r\n',
    });
    _git(scripts, ['init', '-q']);
    _git(scripts, ['add', '.']);
    _git(scripts, ['update-index', '--chmod=+x', 'scripts/build_libsmb2_linux.sh']);
    _git(scripts, ['commit', '-q', '-m', 'scripts']);
    commit = _git(scripts, ['rev-parse', 'HEAD']);
  });

  tearDown(() => root.deleteSync(recursive: true));

  /// The archive of libsmb2 comes from [libsmb2Archive] (by default the right one), or from [libsmb2Url] and then the
  /// fallback when that is given. The fallback is never the fork's release on the network: a folder of the test,
  /// absent unless the test fills it.
  ScriptRun pack(
    String out, {
    String? libsmb2Archive,
    String? scriptsCommit,
    String? scriptsRepository,
    String? libsmb2Url,
    String? fallback,
  }) => runCiScript(_script, [
    out,
    '--scripts-repository',
    scriptsRepository ?? scripts,
    '--scripts-commit',
    scriptsCommit ?? commit,
    if (libsmb2Url == null) ...[
      '--libsmb2-archive',
      libsmb2Archive ?? libsmb2.path,
    ] else ...[
      '--libsmb2-url',
      libsmb2Url,
    ],
    '--fallback',
    fallback ?? p.join(root.path, 'no-fallback'),
  ]);

  test('the same commits give the same archive: the scripts as git stores them, libsmb2 in their cache, the Linux '
      'build and a README', () {
    final first = p.join(root.path, 'first', 'sources.tar.gz');
    final second = p.join(root.path, 'second', 'sources.tar.gz');
    final run = pack(first);
    expect(run.exitCode, 0, reason: '$run');
    expect(pack(second).exitCode, 0);
    expect(File(second).readAsBytesSync(), File(first).readAsBytesSync());

    final files = _untar(File(first).readAsBytesSync());
    final tree = '$_top/libsmb2-scripts-$commit';
    expect(files.keys.toSet(), {
      '$_top/README.txt',
      '$_top/build_linux.sh',
      '$tree/build.cmd',
      '$tree/patches/libsmb2/shared/patch_one.py',
      '$tree/scripts/build_libsmb2_linux.sh',
      '$tree/scripts/shared/_versions.sh',
      '$tree/sources/cache/libsmb2-$_libsmb2Commit.tar.gz',
    });
    expect(files['$tree/sources/cache/libsmb2-$_libsmb2Commit.tar.gz']!.data, libsmb2.readAsBytesSync());
    expect(utf8.decode(files['$tree/build.cmd']!.data), '@echo off\r\necho build\r\n');
    expect(files['$tree/scripts/build_libsmb2_linux.sh']!.mode, _octal('755'));
    expect(files['$tree/patches/libsmb2/shared/patch_one.py']!.mode, _octal('644'));
    expect(
      files['$_top/build_linux.sh']!.data,
      File(p.join(ciScriptsDir, 'libsmb2', 'build_linux.sh')).readAsBytesSync(),
    );
    expect(files['$_top/build_linux.sh']!.mode, _octal('755'));
    final readme = utf8.decode(files['$_top/README.txt']!.data);
    expect(readme, contains('libsmb2 at commit $_libsmb2Commit'));
    expect(readme, contains(commit));
    expect(readme, contains('ARCHS=x86_64 bash scripts/build_libsmb2_linux.sh'));
    expect(run.output, contains(sha256.convert(File(first).readAsBytesSync()).toString()));
  }, skip: _skip);

  test('an archive of libsmb2 that is not the one the scripts pin is refused', () {
    final other = File(p.join(root.path, 'other.tar.gz'))..writeAsBytesSync(utf8.encode('another libsmb2'));
    final out = p.join(root.path, 'out', 'sources.tar.gz');
    final run = pack(out, libsmb2Archive: other.path);
    expect(run.exitCode, 1, reason: '$run');
    expect(run.output, contains('the scripts pin'));
    expect(File(out).existsSync(), isFalse);
  }, skip: _skip);

  test('a commit the repository does not have is refused', () {
    final out = p.join(root.path, 'out', 'sources.tar.gz');
    final run = pack(out, scriptsCommit: 'f' * 40);
    expect(run.exitCode, 1, reason: '$run');
    expect(File(out).existsSync(), isFalse);
  }, skip: _skip);

  group('the fallback of the fork', () {
    late String fallback;
    late String upstream;
    late String upstreamLibsmb2;

    setUp(() {
      // The release of the fork for this commit of the scripts: a git bundle of them and the archive of libsmb2
      fallback = p.join(root.path, 'fallback');
      Directory(fallback).createSync();
      _git(scripts, ['bundle', 'create', '-q', p.join(fallback, 'libsmb2-scripts-$commit.bundle'), 'main']);
      libsmb2.copySync(p.join(fallback, 'libsmb2-$_libsmb2Commit.tar.gz'));
      // GitHub's archive endpoint, as a file of the test
      upstream = p.join(root.path, 'upstream', 'libsmb2-{commit}.tar.gz');
      upstreamLibsmb2 = p.join(root.path, 'upstream', 'libsmb2-$_libsmb2Commit.tar.gz');
      Directory(p.dirname(upstreamLibsmb2)).createSync();
    });

    test('each input comes from upstream while upstream gives it, from the fallback after it fails, and the archive '
        'is the same', () {
      final expected = p.join(root.path, 'expected.tar.gz');
      expect(pack(expected).exitCode, 0);

      libsmb2.copySync(upstreamLibsmb2);
      final fromUpstream = p.join(root.path, 'upstream.tar.gz');
      final first = pack(fromUpstream, libsmb2Url: upstream, fallback: fallback);
      expect(first.exitCode, 0, reason: '$first');
      expect(first.output, isNot(contains('fallback')));
      expect(File(fromUpstream).readAsBytesSync(), File(expected).readAsBytesSync());

      // The repository of the scripts is gone, and GitHub serves libsmb2 with other bytes
      File(upstreamLibsmb2).writeAsBytesSync(utf8.encode('libsmb2 at a commit, packed again'));
      final fromFallback = p.join(root.path, 'fallback.tar.gz');
      final second = pack(
        fromFallback,
        scriptsRepository: p.join(root.path, 'gone'),
        libsmb2Url: upstream,
        fallback: fallback,
      );
      expect(second.exitCode, 0, reason: '$second');
      expect(second.output, contains('the scripts from the fallback'));
      expect(second.output, contains('not the one the scripts pin'));
      expect(second.output, contains('the archive of libsmb2 from the fallback'));
      expect(File(fromFallback).readAsBytesSync(), File(expected).readAsBytesSync());
    }, skip: _skip);

    test('the fallback goes through the same checks: another libsmb2 or a bundle without the commit is refused', () {
      File(p.join(fallback, 'libsmb2-$_libsmb2Commit.tar.gz')).writeAsBytesSync(utf8.encode('another libsmb2'));
      final out = p.join(root.path, 'out', 'sources.tar.gz');
      final libsmb2Run = pack(out, libsmb2Url: upstream, fallback: fallback);
      expect(libsmb2Run.exitCode, 1, reason: '$libsmb2Run');
      expect(libsmb2Run.output, contains('no archive of libsmb2 with the SHA-256 the scripts pin'));
      expect(File(out).existsSync(), isFalse);

      // A later commit of the scripts, which the bundle of the fallback does not hold, under its name
      File(p.join(scripts, 'CHANGELOG.md')).writeAsStringSync('later\n');
      _git(scripts, ['add', '.']);
      _git(scripts, ['commit', '-q', '-m', 'later']);
      final later = _git(scripts, ['rev-parse', 'HEAD']);
      File(
        p.join(fallback, 'libsmb2-scripts-$commit.bundle'),
      ).renameSync(p.join(fallback, 'libsmb2-scripts-$later.bundle'));
      final scriptsRun = pack(
        out,
        scriptsRepository: p.join(root.path, 'gone'),
        scriptsCommit: later,
        fallback: fallback,
      );
      expect(scriptsRun.exitCode, 1, reason: '$scriptsRun');
      expect(scriptsRun.output, contains('the scripts from the fallback'));
      expect(File(out).existsSync(), isFalse);
    }, skip: _skip);
  });
}
