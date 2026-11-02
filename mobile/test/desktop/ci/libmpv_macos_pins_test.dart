// The pins of the macOS libmpv build (.github/desktop/libmpv-macos/packages.lock.nix): FFmpeg, mpv, libplacebo,
// fast_float and the Vulkan headers at the commits of the Windows build (the defaults of immuch360-libmpv.yml and
// .github/desktop/libmpv/sources.lock), every archive pinned by its SHA-256, and the overlay script copying every file
// of the folder that the recipe reads. Then the FFmpeg options of the overlay (mk-pkg-ffmpeg-meson.build): the
// yuv4mpegpipe demuxer and the rawvideo decoder with which libmpv reads the y4m of the AV2 decoder, in a copy of the
// recipe's meson.build that differs from it by the lines that say Immuch360 only, and the overlay run on a recipe.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

final String _macosDir = p.join(ciScriptsDir, 'libmpv-macos');
final File _lock = File(p.join(_macosDir, 'packages.lock.nix'));
final File _windowsLock = File(p.join(ciScriptsDir, 'libmpv', 'sources.lock'));
final File _workflow = File(p.join(repositoryRoot, '.github', 'workflows', 'immuch360-libmpv.yml'));
final File _ffmpegMeson = File(p.join(_macosDir, 'mk-pkg-ffmpeg-meson.build'));
final String _overlay = p.join(_macosDir, 'apply_overlay.sh');

final Object _skip = !_lock.existsSync() || !_windowsLock.existsSync() || !_workflow.existsSync()
    ? 'no libmpv pins in $ciScriptsDir'
    : false;

/// The entries of packages.lock.nix: name, then version, url and sha256
Map<String, ({String version, String url, String sha256})> _macosEntries() {
  final entry = RegExp(
    r'^  ([\w-]+) = \{\s*version = "([^"]*)";\s*url = "([^"]*)";\s*sha256 = "([^"]*)";',
    multiLine: true,
  );
  return {
    for (final match in entry.allMatches(_lock.readAsStringSync()))
      match[1]!: (version: match[2]!, url: match[3]!, sha256: match[4]!),
  };
}

/// The commits of sources.lock by package
Map<String, String> _windowsCommits() => {
  for (final line in _windowsLock.readAsLinesSync())
    if (line.trim().isNotEmpty && !line.startsWith('#')) line.split(' ').first: line.split(' ')[1],
};

/// The default of the workflow variable [name] (FFMPEG_REF, MPV_REF)
String _workflowDefault(String name) {
  final match = RegExp(
    "^  $name: \\\$\\{\\{ inputs\\.[a-z_]+ \\|\\| '([0-9a-f]{40})' \\}\\}",
    multiLine: true,
  ).firstMatch(_workflow.readAsStringSync());
  if (match == null) {
    throw StateError('no default for $name in ${_workflow.path}');
  }
  return match[1]!;
}

void main() {
  group('macOS libmpv pins', () {
    late Map<String, ({String version, String url, String sha256})> entries;

    setUpAll(() => entries = _macosEntries());

    test('every archive is pinned by the SHA-256 of what is downloaded', () {
      expect(entries, isNotEmpty);
      for (final MapEntry(key: name, value: entry) in entries.entries) {
        if (name == 'fftools-ffi') {
          // A Nix hash, for the encoders flavor only, which is not built
          continue;
        }
        expect(entry.sha256, matches(RegExp(r'^[0-9a-f]{64}$')), reason: name);
        expect(entry.url, startsWith('https://'), reason: name);
      }
    });

    test('FFmpeg and mpv at the commits the Windows build defaults to', () {
      expect(entries['ffmpeg']!.url, contains(_workflowDefault('FFMPEG_REF')));
      expect(entries['mpv']!.url, contains(_workflowDefault('MPV_REF')));
    });

    test('libplacebo, fast_float and the Vulkan headers at the commits of sources.lock', () {
      final windows = _windowsCommits();
      expect(entries['libplacebo']!.url, contains(windows['libplacebo']));
      expect(entries['fast_float']!.url, contains(windows['fast_float']));
      expect(entries['vulkan-headers']!.url, contains(windows['vulkan-header']));
      for (final name in ['ffmpeg', 'mpv', 'libplacebo', 'fast_float', 'vulkan-headers']) {
        final commit = RegExp(r'/archive/([0-9a-f]{40})\.tar\.gz$').firstMatch(entries[name]!.url)?[1];
        expect(commit, isNotNull, reason: '$name: an archive of a full commit');
        expect(commit, startsWith(entries[name]!.version), reason: '$name: its version is the start of its commit');
      }
    });

    test('the overlay script copies every .nix file, patch and meson.build of the folder', () {
      final script = File(_overlay).readAsStringSync();
      final files = Directory(_macosDir)
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where((name) => name.endsWith('.nix') || name.endsWith('.patch') || name.endsWith('.build'));
      expect(files, contains('mk-pkg-ffmpeg-meson.build'));
      for (final name in files) {
        expect(script, contains('\$here/$name'), reason: '$name is not copied over the recipe');
      }
    });
  }, skip: _skip);

  group('FFmpeg of the macOS libmpv', () {
    test('the default video flavor reads the y4m of the AV2 decoder over HTTP: yuv4mpegpipe and rawvideo', () {
      final meson = _ffmpegMeson.readAsStringSync();
      expect(
        _mesonList(meson, 'video_default_options'),
        containsAll(['--enable-demuxer=yuv4mpegpipe', '--enable-decoder=rawvideo']),
      );
      // The protocols are in the audio list, which the default flavor builds into the video variant too
      expect(
        _mesonList(meson, 'audio_default_options'),
        containsAll(['--enable-protocol=http', '--enable-protocol=tcp']),
      );
      expect(
        meson,
        contains(
          "if flavor == 'default'\n    options += audio_default_options\n    if variant == 'video'\n"
          '        options += video_default_options\n',
        ),
      );
    });

    test('nothing GPL or nonfree in the default flavor', () {
      final meson = _ffmpegMeson.readAsStringSync();
      for (final list in [
        'common_options',
        'audio_common_options',
        'video_common_options',
        'audio_default_options',
        'video_default_options',
      ]) {
        expect(
          _mesonList(meson, list),
          isNot(anyOf(contains('--enable-gpl'), contains('--enable-nonfree'))),
          reason: list,
        );
      }
    });

    test("the copy is the recipe's meson.build and the lines that say Immuch360, checked by its SHA-256", () {
      final copy = _ffmpegMeson.readAsStringSync().replaceAll('\r\n', '\n');
      final pin = RegExp(
        r'^ffmpeg_meson_sha256=([0-9a-f]{64})$',
        multiLine: true,
      ).firstMatch(File(_overlay).readAsStringSync());
      expect(pin, isNotNull, reason: 'apply_overlay.sh checks the SHA-256 of the meson.build it replaces');
      expect(sha256.convert(utf8.encode(_recipeMeson(copy))).toString(), pin![1]);
      final added = [
        for (final line in copy.split('\n').where((line) => line.contains('Immuch360')))
          if (RegExp(r"^\s+'([^']+)',").firstMatch(line) case final option?) option[1],
      ];
      expect(added, unorderedEquals(['--enable-decoder=rawvideo', '--enable-demuxer=yuv4mpegpipe']));
    });
  }, skip: _ffmpegMeson.existsSync() || _lock.existsSync() ? false : 'no libmpv overlay in $ciScriptsDir');

  group('the overlay over a recipe', () {
    late Directory recipe;
    late String copy;

    setUp(() {
      copy = _ffmpegMeson.readAsStringSync().replaceAll('\r\n', '\n');
      const minVersion = "min_version   = '-mmacosx-version-min=10.9'\n";
      recipe = fixtureTree({
        for (final file in [
          'packages.lock.nix',
          'nix/packages/mk-pkg-ffmpeg/default.nix',
          'nix/packages/mk-pkg-mpv/default.nix',
          'nix/packages/mk-out-libs/default.nix',
          'nix/packages/mk-pkg-libpng/default.nix',
          'patches/README',
        ])
          file: '# the recipe\'s\n',
        'nix/packages/mk-pkg-ffmpeg/meson.build': _recipeMeson(copy),
        'cross-files/macos-arm64.ini': minVersion,
        'cross-files/macos-amd64.ini': minVersion,
      });
    });
    tearDown(() => recipe.deleteSync(recursive: true));

    File recipeFile(String path) => File(p.joinAll([recipe.path, ...path.split('/')]));

    test('puts the FFmpeg options over the meson.build it was made from', () {
      final run = Process.runSync('bash', [_overlay, recipe.path]);
      expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
      expect(recipeFile('nix/packages/mk-pkg-ffmpeg/meson.build').readAsStringSync(), copy);
      expect(recipeFile('packages.lock.nix').readAsStringSync(), _lock.readAsStringSync());
      expect(recipeFile('cross-files/macos-arm64.ini').readAsStringSync(), contains('-mmacosx-version-min=12.0'));
    });

    test('refuses a recipe whose FFmpeg meson.build is not the one the copy was made from', () {
      final meson = recipeFile('nix/packages/mk-pkg-ffmpeg/meson.build');
      final changed = '${meson.readAsStringSync()}# a newer recipe\n';
      meson.writeAsStringSync(changed);
      final run = Process.runSync('bash', [_overlay, recipe.path]);
      expect(run.exitCode, isNot(0));
      expect('${run.stdout}${run.stderr}', contains('mk-pkg-ffmpeg/meson.build'));
      expect(meson.readAsStringSync(), changed);
    });
  }, skip: _skipOverlay);
}

/// The overlay runs on the runners of the workflow (Linux and macOS); on Windows "bash" may be WSL's launcher
final Object _skipOverlay = Platform.isWindows
    ? 'apply_overlay.sh runs on Linux and macOS'
    : !_ffmpegMeson.existsSync() && !_lock.existsSync()
    ? 'no libmpv overlay in $ciScriptsDir'
    : false;

/// The quoted options of the list [name] of a meson.build
List<String> _mesonList(String meson, String name) {
  final list = RegExp('^$name = \\[\n(.*?)^\\]', multiLine: true, dotAll: true).firstMatch(meson);
  if (list == null) {
    throw StateError('no list $name in ${_ffmpegMeson.path}');
  }
  return [
    for (final line in list[1]!.split('\n'))
      if (RegExp(r"^\s+'([^']+)',").firstMatch(line) case final option?) option[1]!,
  ];
}

/// The recipe's own meson.build as the copy holds it: the copy without its lines that say Immuch360
String _recipeMeson(String copy) => copy.split('\n').where((line) => !line.contains('Immuch360')).join('\n');
