// Whether someone can be in front of the computer, as Windows tells the app's window (windows/runner/flutter_window.cpp):
// the session locked (Win+L, or the lock that comes with the display's sleep) or the display turned off. The window is
// neither minimised nor hidden then, so the app's lifecycle says only "inactive"; the Spatial page closes the webcam
// while nobody can be there, and opens it again when the session comes back.
//
// The runner sends "locked", "unlocked", "displayOff" and "displayOn" on the channel immuch360/session; a message sent
// before Dart listens waits in the channel's buffer (the newest one), which is right since the last one tells the state.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The channel of the runner's session messages
const sessionPresenceChannel = MethodChannel('immuch360/session');

/// See the top of this file
class DesktopSessionPresence {
  DesktopSessionPresence._();

  static final instance = DesktopSessionPresence._();

  final _away = ValueNotifier<bool>(false);
  bool _listening = false;
  bool _locked = false;
  bool _displayOff = false;

  /// True while the session is locked or the display is off; listening starts at the first read
  ValueListenable<bool> get away {
    listen();
    return _away;
  }

  /// Takes the runner's messages from now on (once)
  void listen() {
    if (_listening || kIsWeb || !Platform.isWindows) {
      return;
    }
    _listening = true;
    sessionPresenceChannel.setMethodCallHandler((call) async {
      handle(call.method);
      return null;
    });
  }

  /// One message of the runner
  @visibleForTesting
  void handle(String message) {
    switch (message) {
      case 'locked':
        _locked = true;
      case 'unlocked':
        _locked = false;
      case 'displayOff':
        _displayOff = true;
      case 'displayOn':
        _displayOff = false;
      default:
        return;
    }
    _away.value = _locked || _displayOff;
  }
}
