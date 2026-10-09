// libmpv for the videos of Immuch360 Desktop, loaded once by desktop_start.dart before the first page, so that the
// first video does not pay for it and a missing library shows in the log at start rather than as a black player.

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';

final _log = Logger('DesktopVideo');

bool _available = false;

/// Whether libmpv was loaded at start. Only Windows carries it so far (media_kit_libs_windows_video): Linux and macOS
/// get their libs packages in phase 4, and until then their players have no library to open.
bool get desktopVideoAvailable => _available;

/// For the tests of the pages on a computer, which have no libmpv: with a pool of fake players they play as if it
/// were loaded
@visibleForTesting
set desktopVideoAvailable(bool available) => _available = available;

void setUpDesktopVideo() {
  if (!CurrentPlatform.isWindows) {
    _log.info('No libmpv on this operating system yet: videos are not played');
    return;
  }
  try {
    // Finds libmpv-2.dll next to the executable, where the libs package's CMake puts it
    MediaKit.ensureInitialized();
    _available = true;
  } catch (error) {
    // The start goes on: photos and everything else work without the video library
    _log.severe('libmpv could not be loaded, videos will not play: $error');
  }
}
