// The start of Immuch360 Desktop, run by lib/main_desktop.dart once the Flutter binding exists and before the start
// the phones share (runImmich in main.dart).

import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/desktop/window/single_instance.dart';
import 'package:immich_mobile/desktop/window/window_setup.dart';

/// [args] are the command line of the program: the files given to "Open with", or dropped on the program, opened once
/// a session is (see DesktopOpenFilesHandler), like those of the later starts and of the drops on the window
Future<void> startDesktop(List<String> args) async {
  DesktopOpenRequests.add(args);
  listenForLaterStarts();
  setUpDesktopVideo();
  // The video player's native libraries on the licence page, from the texts the app carries (Windows and macOS)
  registerVideoLicenses();
  await setUpDesktopWindow();
}
