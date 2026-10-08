// The start of Immuch360 Desktop, run by lib/main_desktop.dart once the Flutter binding exists and before the start
// the phones share (runImmich in main.dart).

import 'package:immich_mobile/desktop/platform/desktop_view_intent_api.dart';
import 'package:immich_mobile/desktop/window/single_instance.dart';
import 'package:immich_mobile/desktop/window/window_setup.dart';

/// [args] are the command line of the program: the files given to "Open with", handed over as Android hands over
/// its view intents, like those of the later starts the runner passes on
Future<void> startDesktop(List<String> args) async {
  DesktopViewIntentHostApi.addLaunchPaths(args.where((arg) => !arg.startsWith('-')));
  listenForLaterStarts();
  await setUpDesktopWindow();
}
