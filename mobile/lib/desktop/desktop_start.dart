// The start of Immuch360 Desktop, run by lib/main_desktop.dart once the Flutter binding exists and before the start
// the phones share (runImmich in main.dart).

import 'dart:async';

import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/desktop/window/single_instance.dart';
import 'package:immich_mobile/desktop/window/window_setup.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// [args] are the command line of the program: the files given to "Open with", or dropped on the program, opened once
/// a session is (see DesktopOpenFilesHandler), like those of the later starts and of the drops on the window
Future<void> startDesktop(List<String> args) async {
  DesktopOpenRequests.add(args);
  // On Linux the session bus is asked for a keyring while the rest of the app starts
  if (CurrentPlatform.isLinux) {
    LinuxSecretStorage.install();
  }
  listenForLaterStarts();
  // An AI component removed while it was loaded (a DLL on Windows) is deleted now, before anything loads it
  unawaited(AiComponentsService.freePendingAtStart(desktopAiComponentsFolder));
  setUpDesktopVideo();
  // The video player's native libraries on the licence page, from the texts the app carries (Windows and macOS)
  registerVideoLicenses();
  await setUpDesktopWindow();
}
