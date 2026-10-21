// lib/desktop/video/video_licenses.dart: the libraries of the video player on the licence page of Immuch360 Desktop,
// read from a licence folder laid out as the Windows bundle and the macOS app carry it.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:path/path.dart' as p;

/// The texts of the Windows folder; a checkout on Windows gives NOTICES.md CRLF line ends
const _windowsFolder = {
  'NOTICES.md': '# Notices: the native libraries of the video player\r\n\r\nlibmpv-2.dll: LGPL 3 or later.\r\n',
  'LGPL-3.0.txt': 'GNU LESSER GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n',
  'GPL-3.0.txt': 'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n',
  'Apache-2.0.txt': 'Apache License\nVersion 2.0, January 2004\n',
  'ANGLE-BSD-3-Clause.txt': 'Copyright 2018 The ANGLE Project Authors.\n',
  'libmpv/BUILDINFO.txt':
      'libmpv-2.dll for Windows x86_64, built for Immuch360 Desktop\nrun: https://example.invalid/1\n',
  'libmpv/ffmpeg/COPYING.LGPLv2.1': 'GNU LESSER GENERAL PUBLIC LICENSE\nVersion 2.1, February 1999\n',
  'libmpv/ffmpeg/LICENSE.md': 'FFmpeg is licensed under the GNU Lesser General Public License\n',
  'libmpv/mpv/Copyright': 'mpv is built with -Dgpl=false: LGPL 2.1 or later\n',
  'libmpv/spirv-cross/LICENSES/MIT.txt': 'MIT License\n',
  'libsmb2/NOTICE': 'libsmb2: an entry of its own\n',
};

/// The texts of the macOS resource bundle
const _macosFolder = {
  'NOTICES.md': '# Notices: the native libraries of the video player of Immuch360 Desktop on macOS\n',
  'LGPL-3.0.txt': 'GNU LESSER GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n',
  'GPL-3.0.txt': 'GNU GENERAL PUBLIC LICENSE\nVersion 3, 29 June 2007\n',
  'Apache-2.0.txt': 'Apache License\nVersion 2.0, January 2004\n',
  'libmpv/BUILDINFO-macos.txt':
      'libmpv for macOS (arm64 and x86_64, macOS 12 and later), built for Immuch360 Desktop\n',
  'libmpv/fribidi/COPYING': 'GNU LESSER GENERAL PUBLIC LICENSE\nVersion 2.1, February 1999\n',
  'libmpv/mbedtls/LICENSE': 'Apache License\nVersion 2.0, January 2004\n',
};

List<String> _paragraphs(LicenseEntry entry) => entry.paragraphs.map((paragraph) => paragraph.text).toList();

/// A folder whose listing fails, as one the user cannot read does
class _UnreadableDirectory extends Fake implements Directory {
  @override
  final String path;

  _UnreadableDirectory(this.path);

  @override
  bool existsSync() => true;

  @override
  List<FileSystemEntity> listSync({bool recursive = false, bool followLinks = true}) =>
      throw FileSystemException('Directory listing failed', path, const OSError('Permission denied', 13));
}

/// A file whose read fails, as one the user cannot read does
class _UnreadableFile extends Fake implements File {
  @override
  final String path;

  _UnreadableFile(this.path);

  @override
  bool existsSync() => true;

  @override
  Future<Uint8List> readAsBytes() async =>
      throw FileSystemException('Cannot open file', path, const OSError('Permission denied', 13));
}

/// The licence folder as written, but for [unreadable], a folder or a file of it that cannot be read
final class _Unreadable extends IOOverrides {
  final String unreadable;

  _Unreadable(this.unreadable);

  @override
  Directory createDirectory(String path) =>
      p.basename(path) == unreadable ? _UnreadableDirectory(path) : super.createDirectory(path);

  @override
  File createFile(String path) => p.basename(path) == unreadable ? _UnreadableFile(path) : super.createFile(path);
}

void main() {
  late Directory root;
  late Directory licenses;

  setUp(() {
    root = Directory.systemTemp.createTempSync('immuch360_video_licenses_');
    licenses = Directory(p.join(root.path, 'licenses'));
  });

  tearDown(() => root.deleteSync(recursive: true));

  void write(Map<String, String> files) {
    for (final MapEntry(key: path, value: text) in files.entries) {
      File(p.joinAll([licenses.path, ...path.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    }
  }

  test('Windows: libmpv with its Source, its notice, its build and its licences, then each library, ANGLE and '
      'SwiftShader', () async {
    write(_windowsFolder);
    final entries = await videoLicenseEntries(licenses, VideoLicenseSystem.windows).toList();

    expect(entries.map((entry) => entry.packages.join(', ')), [
      'libmpv',
      'ffmpeg (libmpv)',
      'mpv (libmpv)',
      'spirv-cross (libmpv)',
      'ANGLE',
      'SwiftShader, Vulkan-Loader',
    ]);
    final libmpv = _paragraphs(entries.first);
    expect(libmpv.first, contains('libmpv-2.dll'));
    expect(libmpv[1], startsWith('Source: '));
    expect(libmpv[1], contains('$windowsLibmpvRelease-sources.tar.xz'));
    expect(libmpv[1], contains('https://github.com/freeKC/Immuch360/releases/tag/$windowsLibmpvRelease'));
    expect(libmpv, contains('# Notices: the native libraries of the video player'));
    expect(libmpv, contains('BUILDINFO.txt:'));
    expect(libmpv, contains('GNU LESSER GENERAL PUBLIC LICENSE Version 3, 29 June 2007'));
    expect(libmpv, contains('GNU GENERAL PUBLIC LICENSE Version 3, 29 June 2007'));

    final ffmpeg = _paragraphs(entries[1]);
    expect(ffmpeg.first, contains('see the libmpv entry'));
    expect(ffmpeg, containsAllInOrder(['COPYING.LGPLv2.1:', 'LICENSE.md:']));
    expect(_paragraphs(entries[3]), contains('LICENSES/MIT.txt:'));
    expect(_paragraphs(entries[4]).last, 'Copyright 2018 The ANGLE Project Authors.');

    final all = entries.expand(_paragraphs).toList();
    expect(all.where((text) => text.contains('\r')), isEmpty);
    expect(all.where((text) => text.contains('libsmb2')), isEmpty, reason: 'libsmb2 has its own entry');
  });

  test('macOS: the layout of the resource bundle, its BUILDINFO-macos.txt and the macOS release', () async {
    write(_macosFolder);
    final entries = await videoLicenseEntries(licenses, VideoLicenseSystem.macos).toList();

    expect(entries.map((entry) => entry.packages.join(', ')), ['libmpv', 'fribidi (libmpv)', 'mbedtls (libmpv)']);
    final libmpv = _paragraphs(entries.first);
    expect(libmpv.first, contains('Mpv'));
    expect(libmpv[1], contains('https://github.com/freeKC/Immuch360/releases/tag/$macosLibmpvRelease'));
    expect(libmpv[1], contains('BUILDINFO-macos.txt'));
    expect(libmpv, contains('BUILDINFO-macos.txt:'));
    expect(_paragraphs(entries[1]), contains('GNU LESSER GENERAL PUBLIC LICENSE Version 2.1, February 1999'));
  });

  test(
    'Windows with media-kit\'s libmpv of 2024: no build information, the notice says where the sources are',
    () async {
      write({
        for (final MapEntry(:key, :value) in _windowsFolder.entries)
          if (!key.startsWith('libmpv/')) key: value,
      });
      final entries = await videoLicenseEntries(licenses, VideoLicenseSystem.windows).toList();

      expect(entries.map((entry) => entry.packages.first), ['libmpv', 'ANGLE', 'SwiftShader']);
      final libmpv = _paragraphs(entries.first);
      expect(libmpv[1], 'Source: the notice below says where the sources of this build of libmpv are.');
      expect(libmpv.join('\n'), isNot(contains(windowsLibmpvRelease)));
    },
  );

  test('a folder or a file that cannot be read ends the entries there, those already read stay, and the page does '
      'not fail', () async {
    write(_windowsFolder);
    final logs = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logs.add(message);
    final List<LicenseEntry> listed;
    final List<LicenseEntry> read;
    try {
      // The libraries of licenses/libmpv cannot be listed: the libmpv entry, read before, stays
      listed = await IOOverrides.runWithIOOverrides(
        () => videoLicenseEntries(licenses, VideoLicenseSystem.windows).toList(),
        _Unreadable('libmpv'),
      );
      // NOTICES.md cannot be read: nothing was read before it
      read = await IOOverrides.runWithIOOverrides(
        () => videoLicenseEntries(licenses, VideoLicenseSystem.windows).toList(),
        _Unreadable('NOTICES.md'),
      );
    } finally {
      debugPrint = original;
    }

    expect(listed.map((entry) => entry.packages.first), ['libmpv']);
    expect(_paragraphs(listed.single), contains('BUILDINFO.txt:'));
    expect(read, isEmpty);
    expect(logs, hasLength(2));
    expect(logs.first, contains('Directory listing failed'));
    expect(logs.last, contains('Cannot open file'));
  });

  test('no licence folder, as in a build run from its build folder: no entry', () async {
    expect(await videoLicenseEntries(licenses, VideoLicenseSystem.windows).toList(), isEmpty);
    expect(await videoLicenseEntries(licenses, VideoLicenseSystem.macos).toList(), isEmpty);
  });

  test('the licence folder of the running app', () {
    final windowsApp = p.join(root.path, 'Immuch360 Desktop');
    expect(
      videoLicensesFolder(VideoLicenseSystem.windows, p.join(windowsApp, 'immuch360.exe')),
      p.join(windowsApp, 'licenses'),
    );
    final macosApp = p.join(root.path, 'Immuch360 Desktop.app');
    expect(
      videoLicensesFolder(VideoLicenseSystem.macos, p.join(macosApp, 'Contents', 'MacOS', 'Immuch360 Desktop')),
      p.join(
        macosApp,
        'Contents',
        'Resources',
        'media_kit_libs_macos_video_media_kit_libs_macos_video.bundle',
        'Contents',
        'Resources',
        'licenses',
      ),
    );
  });

  test('the releases named are those the builds download', () {
    final cmake = File('packages/media_kit_libs_windows_video/windows/CMakeLists.txt').readAsStringSync();
    final swift = File(
      'packages/media_kit_libs_macos_video/macos/media_kit_libs_macos_video/Package.swift',
    ).readAsStringSync();

    expect(RegExp(r'set\(IMMUCH360_LIBMPV_TAG "([^"]+)"\)').firstMatch(cmake)?.group(1), windowsLibmpvRelease);
    expect(RegExp(r'let libmpvTag = "([^"]+)"').firstMatch(swift)?.group(1), macosLibmpvRelease);
  });
}
