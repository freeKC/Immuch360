// Temporary switches for the measure of release 48 on a Samsung S24: a Plex film through the media bridge came at 4 to
// 8 Mbit/s where the phone read the file at 41. Two changes may each lift it, the Plex client in a worker isolate and
// the native player's position at 10 Hz; one profile build with the switches lets the phone measure each alone. Only a
// build made with --dart-define=IMMUCH_RATE_SWITCHES=true reads them, over adb, after a force stop of the app:
//
//   adb shell setprop debug.immuch.plex_worker 0     the Plex client on the UI isolate again (IOClient, as release 47)
//   adb shell setprop debug.immuch.position_ms 8     the position at every 8 ms tick again (Android, any build)
//
// Remove once the measure settled which change lifts the rate.

import 'dart:io';

import 'package:flutter/foundation.dart';

/// Whether this build reads the switches, see the top of the file
const rateSwitchesBuilt = bool.fromEnvironment('IMMUCH_RATE_SWITCHES');

/// Whether the Plex client runs in the worker isolate (IsolateHttpClient): always, but in a build with the switches on
/// an Android device where debug.immuch.plex_worker is 0
Future<bool> plexClientOffMainIsolate() async {
  if (!rateSwitchesBuilt || !Platform.isAndroid) {
    return true;
  }
  try {
    final result = await Process.run('getprop', const ['debug.immuch.plex_worker']);
    final onMain = '${result.stdout}'.trim() == '0';
    debugPrint('Immuch360 rate switch: the Plex client runs ${onMain ? 'on the UI isolate' : 'in the worker isolate'}');
    return !onMain;
  } catch (error) {
    debugPrint('Immuch360 rate switch unread ($error): the Plex client runs in the worker isolate');
    return true;
  }
}
