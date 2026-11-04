// The start of Immuch360 Desktop, run by lib/main_desktop.dart once the Flutter binding exists and before the start
// the phones share (runImmich in main.dart).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec_licenses.dart';
import 'package:immich_mobile/desktop/ai/components/ai_components_folder.dart';
import 'package:immich_mobile/desktop/ai/creator/safe_writer.dart';
import 'package:immich_mobile/desktop/ai/creator/server_original_source.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:immich_mobile/desktop/splat/splat_window_licenses.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/video_licenses.dart';
import 'package:immich_mobile/desktop/window/single_instance.dart';
import 'package:immich_mobile/desktop/window/window_setup.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_components_service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// Whether [args] are those desktop_webview_window gives the engine of a title bar: `web_view_title_bar <id>`
bool isWebViewTitleBarEngine(List<String> args) => args.isNotEmpty && args.first == 'web_view_title_bar';

/// A second engine that runs nothing of the app: an empty view, no database, no window setup
void runEmptyEngine() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
}

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
  // The partial 3D photos a crash or a power cut left in the folders of the user, deleted while the app starts
  unawaited(cleanUpPartFilesAtStart());
  // The copies of the photos of the server a conversion left in the temporary folder, once an hour old
  unawaited(cleanUpAiCopiesAtStart());
  setUpDesktopVideo();
  // The video player's native libraries on the licence page, from the texts the app carries (Windows and macOS)
  registerVideoLicenses();
  // The Rust crates of the JPEG codec of the AI features, from the texts the library carries (the three systems)
  registerSbsCodecLicenses();
  // The WebView2 SDK and wil of the splat viewer's window (Windows)
  registerSplatWindowLicenses();
  await setUpDesktopWindow();
}
