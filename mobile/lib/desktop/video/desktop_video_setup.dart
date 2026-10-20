// libmpv for the videos of Immuch360 Desktop, loaded once by desktop_start.dart before the first page, so that the
// first video does not pay for it and a missing library shows in the log at start rather than as a black player.
//
// Where the library comes from: on Windows the project's own build, next to the executable
// (media_kit_libs_windows_video); on Linux the system's, libmpv.so.2 or libmpv.so.1, which the .deb and the .rpm
// depend on (libmpv2 or libmpv1, mpv-libs on Fedora: .github/desktop/desktop_installers.py) and which the vendored
// media_kit_video finds at run time too (its IMMUCH360-NOTE.md, patch 8); on macOS the project's own build again,
// Mpv.framework in the app's Frameworks folder (media_kit_libs_macos_video, .github/workflows/immuch360-libmpv.yml).
// The app ships no libmpv on Linux.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

final _log = Logger('DesktopVideo');

bool _available = false;

/// Whether libmpv was loaded at start: on Windows (media_kit_libs_windows_video, next to the executable), on Linux
/// (the system's libmpv.so.2 or libmpv.so.1) and on macOS (Mpv.framework in the app's Frameworks folder, the project's
/// own build of .github/workflows/immuch360-libmpv.yml), unless the library failed to load.
bool get desktopVideoAvailable => _available;

/// For the tests of the pages on a computer, which have no libmpv: with a pool of fake players they play as if it
/// were loaded
@visibleForTesting
set desktopVideoAvailable(bool available) => _available = available;

/// Whether this system's build has a libmpv to load: Windows and macOS bundle it, Linux uses the system's (see the
/// top of this file)
bool get desktopVideoLibraryExpected => CurrentPlatform.isWindows || CurrentPlatform.isLinux || CurrentPlatform.isMacOS;

/// Whether the app of this computer bundles libmpv: Windows and macOS. On macOS the 360°, 3D and raw players draw flat
/// with their reason, as renderer C is Windows only (PluginRenderer.supported).
bool get desktopVideoBundled => CurrentPlatform.isWindows || CurrentPlatform.isMacOS;

/// Loads libmpv: media_kit's NativeLibrary tries LIBMPV_LIBRARY_PATH, then libmpv-2.dll next to the executable on
/// Windows, Mpv.framework/Mpv on macOS (linked through media_kit_video and loaded with the app), or libmpv.so,
/// libmpv.so.2 and libmpv.so.1 on Linux. Replaced by the tests.
@visibleForTesting
void Function() loadLibmpv = MediaKit.ensureInitialized;

/// What the log says when libmpv does not load on this system
@visibleForTesting
String libmpvMissingHint() => CurrentPlatform.isLinux
    ? 'install the libmpv2 package (libmpv1 on Ubuntu 22.04, mpv-libs on Fedora), which the .deb and the .rpm of '
          'Immuch360 depend on'
    : CurrentPlatform.isMacOS
    ? 'Mpv.framework should be in the Frameworks folder of Immuch360.app'
    : 'libmpv-2.dll should be next to immuch360.exe';

void setUpDesktopVideo() {
  if (!desktopVideoLibraryExpected) {
    _log.info('No libmpv on this operating system yet: videos are not played');
    return;
  }
  try {
    loadLibmpv();
    _available = true;
    // The decoders of the GPU in use, read in the background now (0.1 to 0.4 s, more at the driver's first start), so
    // that the question of the first video does not wait for them (gpu_decoders.dart)
    unawaited(DesktopGpuDecoders.decoders());
  } catch (error) {
    // The start goes on: photos and everything else work without the video library
    _log.severe('libmpv could not be loaded, videos will not play ($error): ${libmpvMissingHint()}');
  }
}
