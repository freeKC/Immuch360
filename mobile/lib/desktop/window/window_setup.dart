// The window of Immuch360 Desktop, set up before the first frame: its title and its smallest size, below which the
// tablet layouts the app uses on a computer would overflow.

import 'dart:ui';

import 'package:window_manager/window_manager.dart';

const desktopWindowTitle = 'Immuch360 Desktop';

const desktopMinimumWindowSize = Size(960, 600);

/// Needs the Flutter binding
Future<void> setUpDesktopWindow() async {
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(title: desktopWindowTitle, minimumSize: desktopMinimumWindowSize),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
