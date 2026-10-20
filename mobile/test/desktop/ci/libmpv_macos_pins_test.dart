// The pins of the macOS libmpv build (.github/desktop/libmpv-macos/packages.lock.nix): FFmpeg, mpv, libplacebo,
// fast_float and the Vulkan headers at the commits of the Windows build (the defaults of immuch360-libmpv.yml and
// .github/desktop/libmpv/sources.lock), every archive pinned by its SHA-256, and the overlay script copying every file
// of the folder that the recipe reads.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'ci_scripts.dart';

final String _macosDir = p.join(ciScriptsDir, 'libmpv-macos');
final File _lock = File(p.join(_macosDir, 'packages.lock.nix'));
final File _windowsLock = File(p.join(ciScriptsDir, 'libmpv', 'sources.lock'));
final File _workflow = File(p.join(repositoryRoot, '.github', 'workflows', 'immuch360-libmpv.yml'));

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

    test('the overlay script copies every .nix file and patch of the folder', () {
      final script = File(p.join(_macosDir, 'apply_overlay.sh')).readAsStringSync();
      final files = Directory(_macosDir)
          .listSync()
          .whereType<File>()
          .map((file) => p.basename(file.path))
          .where((name) => name.endsWith('.nix') || name.endsWith('.patch'));
      for (final name in files) {
        expect(script, contains('\$here/$name'), reason: '$name is not copied over the recipe');
      }
    });
  }, skip: _skip);
}
