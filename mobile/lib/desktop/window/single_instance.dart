import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/platform/desktop_view_intent_api.dart';

/// The channel by which the Windows runner hands over the command line of a second start of the app, a file opened
/// with it while it runs (windows/runner/main.cpp): one copy of the app runs per user, with one database
const singleInstanceChannel = MethodChannel('immuch360/instance');

/// Takes the files of later starts as the files of the first one, see DesktopViewIntentHostApi.addLaunchPaths;
/// [onFiles] is told once they are queued
void listenForLaterStarts({void Function()? onFiles}) {
  singleInstanceChannel.setMethodCallHandler((call) async {
    if (call.method != 'openFiles' || call.arguments is! List) {
      return;
    }
    DesktopViewIntentHostApi.addLaunchPaths((call.arguments as List).whereType<String>());
    onFiles?.call();
  });
}
