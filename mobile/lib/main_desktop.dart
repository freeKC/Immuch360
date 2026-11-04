import 'package:immich_mobile/desktop/desktop_start.dart';
import 'package:immich_mobile/main.dart';

/// The entry point of Immuch360 Desktop on Windows, macOS and Linux, given to every desktop build and run with -t:
///   flutter run -d windows -t lib/main_desktop.dart
///   flutter build windows -t lib/main_desktop.dart
/// It sets up the window, then runs the start the phones use. The engine desktop_webview_window would start for the
/// title bar of the splat viewer's window (its arguments `web_view_title_bar <id>`) runs nothing of the app: the
/// patched copy never starts one (packages/desktop_webview_window/IMMUCH360-NOTE.md), this stays should a patch be
/// lost.
Future<void> main(List<String> args) async {
  if (isWebViewTitleBarEngine(args)) {
    return runEmptyEngine();
  }
  await runImmich(beforeStart: () => startDesktop(args));
}
