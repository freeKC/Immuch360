// Whether someone can be in front of the computer: the session locked or the display turned off. The window is neither
// minimised nor hidden then, so the app's lifecycle does not say it; the Spatial 2.5D views close the webcam while
// nobody can be there, and open it again when the session comes back.
//
// - Windows and macOS: the runner tells it on the channel immuch360/session ("locked", "unlocked", "displayOff",
//   "displayOn"): windows/runner/flutter_window.cpp (WTS session notifications, GUID_CONSOLE_DISPLAY_STATE) and
//   macos/Runner/MainFlutterWindow.swift (com.apple.screenIsLocked and Unlocked, NSWorkspace screensDidSleep and
//   screensDidWake). A message sent before Dart listens waits in the channel's buffer (the newest one), which is right
//   since the last one tells the state.
// - Linux: D-Bus, read here. logind's Lock and Unlock signals of this session and its LockedHint, and the desktop's
//   screen saver (org.freedesktop.ScreenSaver and org.gnome.ScreenSaver ActiveChanged, which also covers the display
//   going off on GNOME and KDE). A desktop without them leaves the webcam to the page's own rules (it still closes with
//   the page and when the window is minimised).

import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

final _log = Logger('SessionPresence');

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
  final _subscriptions = <StreamSubscription<DBusSignal>>[];

  /// True while the session is locked or the display is off; listening starts at the first read
  ValueListenable<bool> get away {
    listen();
    return _away;
  }

  /// Takes the system's messages from now on (once)
  void listen() {
    if (_listening || kIsWeb) {
      return;
    }
    if (Platform.isWindows || Platform.isMacOS) {
      _listening = true;
      sessionPresenceChannel.setMethodCallHandler((call) async {
        handle(call.method);
        return null;
      });
    } else if (Platform.isLinux) {
      _listening = true;
      unawaited(_listenLinux());
    }
  }

  Future<void> _listenLinux() async {
    try {
      final system = DBusClient.system();
      final session = DBusObjectPath('/org/freedesktop/login1/session/auto');
      for (final name in ['Lock', 'Unlock']) {
        _subscriptions.add(
          DBusSignalStream(
            system,
            interface: 'org.freedesktop.login1.Session',
            name: name,
            path: session,
          ).listen((_) => handle(name == 'Lock' ? 'locked' : 'unlocked')),
        );
      }
    } catch (error) {
      _log.info('logind lock signals not available: $error');
    }
    try {
      final bus = DBusClient.session();
      for (final (interface, path) in [
        ('org.freedesktop.ScreenSaver', '/org/freedesktop/ScreenSaver'),
        ('org.freedesktop.ScreenSaver', '/ScreenSaver'),
        ('org.gnome.ScreenSaver', '/org/gnome/ScreenSaver'),
      ]) {
        _subscriptions.add(
          DBusSignalStream(bus, interface: interface, name: 'ActiveChanged', path: DBusObjectPath(path)).listen((
            signal,
          ) {
            final value = signal.values.isEmpty ? null : signal.values.first;
            if (value is DBusBoolean) {
              handle(value.value ? 'displayOff' : 'displayOn');
            }
          }),
        );
      }
    } catch (error) {
      _log.info('screen saver signals not available: $error');
    }
  }

  /// One message of the system
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
