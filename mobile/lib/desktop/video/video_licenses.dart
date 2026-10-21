// The libraries of the video player on the licence page of Immuch360 Desktop, Windows and macOS: libmpv (mpv, FFmpeg
// and the libraries built into them, LGPL version 3 or later as a whole), from the notices and licence texts the app
// already carries, with where their sources are. Flutter's licence page lists the Dart packages only.
//
// Windows: the licenses folder next to immuch360.exe (.github/desktop/windows_bundle.py): NOTICES.md and the LGPL,
// GPL, Apache and ANGLE texts of mobile/packages/media_kit_video/windows, and in licenses/libmpv the BUILDINFO.txt and
// the licence texts of each library of the fork's libmpv build. macOS: the licenses folder of the resource bundle of
// media_kit_libs_macos_video in the app, the same layout with BUILDINFO-macos.txt. Linux is not concerned: the app
// uses the system's libmpv and ships none. A build run from its build folder, before the bundle script, has no such
// folder and adds nothing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:path/path.dart' as p;

/// The libmpv releases of https://github.com/freeKC/Immuch360 the desktop builds take their libraries from, as pinned
/// by mobile/packages/media_kit_libs_windows_video/windows/CMakeLists.txt (IMMUCH360_LIBMPV_TAG) and
/// mobile/packages/media_kit_libs_macos_video/macos/media_kit_libs_macos_video/Package.swift (libmpvTag); a test keeps
/// them equal
const windowsLibmpvRelease = 'libmpv-windows-20261009-3';
const macosLibmpvRelease = 'libmpv-macos-20261020-9';

const _releases = 'https://github.com/freeKC/Immuch360/releases/tag';

/// The system whose layout the licence folder has
enum VideoLicenseSystem { windows, macos }

/// Adds the entries of the video libraries to the licence page, on Windows and macOS
void registerVideoLicenses() {
  final system = CurrentPlatform.isWindows
      ? VideoLicenseSystem.windows
      : CurrentPlatform.isMacOS
      ? VideoLicenseSystem.macos
      : null;
  if (system == null) {
    return;
  }
  final folder = videoLicensesFolder(system, Platform.resolvedExecutable);
  LicenseRegistry.addLicense(() => videoLicenseEntries(Directory(folder), system));
}

/// The licence folder of the app whose executable is [executable]
String videoLicensesFolder(VideoLicenseSystem system, String executable) => switch (system) {
  VideoLicenseSystem.windows => p.join(p.dirname(executable), 'licenses'),
  // Immuch360 Desktop.app/Contents/MacOS/Immuch360 Desktop
  VideoLicenseSystem.macos => p.join(
    p.dirname(p.dirname(executable)),
    'Resources',
    'media_kit_libs_macos_video_media_kit_libs_macos_video.bundle',
    'Contents',
    'Resources',
    'licenses',
  ),
};

/// The entries from [folder]: libmpv with its Source paragraph, its notice, its build information and the LGPL and
/// GPL texts, then one entry per library of licenses/libmpv with its own texts, and on Windows ANGLE and SwiftShader
Stream<LicenseEntry> videoLicenseEntries(Directory folder, VideoLicenseSystem system) async* {
  if (!folder.existsSync()) {
    return;
  }
  final windows = system == VideoLicenseSystem.windows;
  final libmpv = Directory(p.join(folder.path, 'libmpv'));
  final buildInfoName = windows ? 'BUILDINFO.txt' : 'BUILDINFO-macos.txt';
  final buildInfo = await _text(File(p.join(libmpv.path, buildInfoName)));
  final release = windows ? windowsLibmpvRelease : macosLibmpvRelease;
  final files = windows
      ? 'libmpv-2.dll, next to immuch360.exe'
      : 'the frameworks Mpv, Avcodec, Avfilter, Avformat, Avutil, Swresample, Swscale, Placebo and the others in '
            'Contents/Frameworks of the app';
  final where = windows
      ? 'the licenses folder of the app'
      : 'Contents/Resources/media_kit_libs_macos_video_media_kit_libs_macos_video.bundle/Contents/Resources/licenses '
            'in the app';

  // The fork's own build carries its build information; without it (media-kit's archive of 2024 on Windows, the
  // fallback of IMMUCH360_LIBMPV_FROM_CI) the notice itself says where the sources are
  final source = buildInfo != null
      ? 'Source: the corresponding source of libmpv and of every library built into it is the file '
            '$release-sources.tar.xz of the release $release of Immuch360, $_releases/$release, built by the run '
            'that $buildInfoName names. $buildInfoName, below, gives the commit or the archive of each library.'
      : 'Source: the notice below says where the sources of this build of libmpv are.';
  final intro =
      'libmpv, the library that plays the videos of Immuch360 Desktop: mpv, FFmpeg and the libraries built into them, '
      'in $files. Its notice, its build information and its licence texts follow, as $where holds them.';
  final libmpvText = [
    intro,
    source,
    ?await _text(File(p.join(folder.path, 'NOTICES.md'))),
    if (buildInfo != null) '$buildInfoName:\n\n$buildInfo',
    ?await _text(File(p.join(folder.path, 'LGPL-3.0.txt'))),
    ?await _text(File(p.join(folder.path, 'GPL-3.0.txt'))),
  ];
  yield LicenseEntryWithLineBreaks(const ['libmpv'], libmpvText.join('\n\n'));

  if (libmpv.existsSync()) {
    final libraries = libmpv.listSync().whereType<Directory>().toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final library in libraries) {
      final name = p.basename(library.path);
      final texts = library.listSync(recursive: true).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      final parts = [
        '$name, built into libmpv in Immuch360 Desktop. Its source is part of the one of libmpv: see the libmpv entry.',
        for (final text in texts)
          if (await _text(text) case final content?)
            '${p.posix.joinAll(p.split(p.relative(text.path, from: library.path)))}:\n\n$content',
      ];
      if (parts.length > 1) {
        yield LicenseEntryWithLineBreaks(['$name (libmpv)'], parts.join('\n\n'));
      }
    }
  }

  if (windows) {
    // The other libraries of the video player in the Windows folder, which NOTICES.md covers
    if (await _text(File(p.join(folder.path, 'ANGLE-BSD-3-Clause.txt'))) case final angle?) {
      yield LicenseEntryWithLineBreaks(const [
        'ANGLE',
      ], 'ANGLE (libEGL.dll, libGLESv2.dll), OpenGL ES over Direct3D 11 for the video player.\n\n$angle');
    }
    if (await _text(File(p.join(folder.path, 'Apache-2.0.txt'))) case final apache?) {
      yield LicenseEntryWithLineBreaks(const [
        'SwiftShader',
        'Vulkan-Loader',
      ], 'SwiftShader (vk_swiftshader.dll) and the Vulkan loader (vulkan-1.dll), shipped with ANGLE.\n\n$apache');
    }
  }
}

/// The text of [file] with LF line ends (a checkout on Windows gives CRLF, which the parser of the licence page would
/// keep inside its paragraphs), or null when there is no such file
Future<String?> _text(File file) async {
  if (!file.existsSync()) {
    return null;
  }
  return utf8.decode(await file.readAsBytes(), allowMalformed: true).replaceAll('\r\n', '\n').trimRight();
}
