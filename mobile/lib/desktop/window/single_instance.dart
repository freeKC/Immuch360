import 'package:flutter/services.dart';
import 'package:immich_mobile/desktop/files/open_files.dart';

/// The channel by which the runner of the app hands over files to open while it runs: the command line of a second
/// start of the app, a file opened with it ("Open with", windows/runner/main.cpp and the Linux and macOS runners), and
/// the files dropped on its window. One copy of the app runs per user, with one database.
const singleInstanceChannel = MethodChannel('immuch360/instance');

/// Takes the files of later starts and of drops as the files of the first start: a batch each (see
/// DesktopOpenRequests). [onFiles] is told once they are queued.
void listenForLaterStarts({void Function()? onFiles}) {
  singleInstanceChannel.setMethodCallHandler((call) async {
    if (call.method != 'openFiles' || call.arguments is! List) {
      return;
    }
    DesktopOpenRequests.add((call.arguments as List).whereType<String>());
    onFiles?.call();
  });
}
