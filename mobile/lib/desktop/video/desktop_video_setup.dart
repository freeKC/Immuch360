// libmpv for the videos of Immuch360 Desktop, loaded once by desktop_start.dart before the first page, so that the
// first video does not pay for it and a missing library shows in the log at start rather than as a black player.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

final _log = Logger('DesktopVideo');

bool _available = false;

/// Whether libmpv was loaded at start. Windows carries it in media_kit_libs_windows_video, macOS in
/// media_kit_libs_macos_video (Mpv.framework and its libraries in the app's Frameworks folder, the project's own build
/// of .github/workflows/immuch360-libmpv.yml); Linux gets its libs package later, and until then its players have no
/// library to open.
bool get desktopVideoAvailable => _available;

/// For the tests of the pages on a computer, which have no libmpv: with a pool of fake players they play as if it
/// were loaded
@visibleForTesting
set desktopVideoAvailable(bool available) => _available = available;

/// Whether the app of this computer bundles libmpv: Windows and macOS. On macOS the 360°, 3D and raw players draw flat
/// with their reason, as renderer C is Windows only (PluginRenderer.supported).
bool get desktopVideoBundled => CurrentPlatform.isWindows || CurrentPlatform.isMacOS;

void setUpDesktopVideo() {
  if (!desktopVideoBundled) {
    _log.info('No libmpv on this operating system yet: videos are not played');
    return;
  }
  try {
    // Finds libmpv-2.dll next to the executable on Windows, where the libs package's CMake puts it, and
    // Mpv.framework/Mpv on macOS, which the app links through media_kit_video and loads with the app
    MediaKit.ensureInitialized();
    _available = true;
    // The decoders of the GPU in use, read in the background now (0.1 to 0.4 s, more at the driver's first start), so
    // that the question of the first video does not wait for them (gpu_decoders.dart)
    unawaited(DesktopGpuDecoders.decoders());
  } catch (error) {
    // The start goes on: photos and everything else work without the video library
    _log.severe('libmpv could not be loaded, videos will not play: $error');
  }
}
