// Whether someone can be in front of the computer: the session locked or the display turned off. The window is neither
// minimised nor hidden then, so the app's lifecycle does not say it; the Spatial 2.5D views close the webcam while
// nobody can be there, and open it again when the session comes back.
//
// - Windows and macOS: the runner tells it on the channel immuch360/session ("locked", "unlocked", "displayOff",
//   "displayOn"): windows/runner/flutter_window.cpp (WTS session notifications, GUID_CONSOLE_DISPLAY_STATE) and
//   macos/Runner/MainFlutterWindow.swift (com.apple.screenIsLocked and Unlocked, NSWorkspace screensDidSleep and
//   screensDidWake). A message sent before Dart listens waits in the channel's buffer (the newest one), which is right
//   since the last one tells the state.
// - Linux: D-Bus, read here. logind's Lock and Unlock signals of this session and its LockedHint (on the session's own
//   object path, asked to logind: its signals never come from the alias session/auto), and the desktop's screen saver
//   (org.freedesktop.ScreenSaver and org.gnome.ScreenSaver ActiveChanged, which also covers the display going off on
//   GNOME and KDE). A desktop without them leaves the webcam to the page's own rules (it still closes with the page and
//   when the window is minimised, though under Wayland, whose xdg-shell has no minimised state, GTK may never say it).

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

  /// One that listens to nothing until the test calls [listenLinux] or [handle]
  @visibleForTesting
  DesktopSessionPresence.forTesting() : _listening = true;

  static final instance = DesktopSessionPresence._();

  static const _logind = 'org.freedesktop.login1';
  static const _logindSession = 'org.freedesktop.login1.Session';

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
    DBusClient? system;
    DBusClient? session;
    try {
      system = DBusClient.system();
    } catch (error) {
      _log.info('no system bus: $error');
    }
    try {
      session = DBusClient.session();
    } catch (error) {
      _log.info('no session bus: $error');
    }
    await listenLinux(system: system, session: session);
  }

  /// The Linux signals on [system] (logind) and [session] (the screen saver); the buses of the tests in the tests
  @visibleForTesting
  Future<void> listenLinux({DBusClient? system, DBusClient? session}) async {
    if (system != null) {
      await _listenLogind(system);
    }
    if (session != null) {
      _listenScreenSaver(session);
    }
  }

  /// logind's Lock and Unlock signals and LockedHint. logind takes /org/freedesktop/login1/session/auto for the
  /// caller's session in method calls only: its signals come from the session's own path, asked here first.
  Future<void> _listenLogind(DBusClient system) async {
    try {
      final path = await logindSessionPath(system);
      if (path == null) {
        _log.info('logind: no session for this app, its lock is not followed');
        return;
      }
      for (final name in ['Lock', 'Unlock']) {
        _subscriptions.add(
          DBusSignalStream(
            system,
            sender: _logind,
            interface: _logindSession,
            name: name,
            path: path,
          ).listen((_) => handle(name == 'Lock' ? 'locked' : 'unlocked')),
        );
      }
      final object = DBusRemoteObject(system, name: _logind, path: path);
      _subscriptions.add(
        object.propertiesChanged.listen((signal) {
          final hint = signal.propertiesInterface == _logindSession ? signal.changedProperties['LockedHint'] : null;
          if (hint is DBusBoolean) {
            handle(hint.value ? 'locked' : 'unlocked');
          }
        }),
      );
      // A session locked already when the app starts
      final hint = await object.getProperty(_logindSession, 'LockedHint', signature: DBusSignature.boolean);
      if (hint is DBusBoolean && hint.value) {
        handle('locked');
      }
    } catch (error) {
      _log.info('logind lock signals not available: $error');
    }
  }

  /// The object path of this app's logind session: its own session ("auto": the caller's, or the user's graphical
  /// one), else the user's display session; null without one
  @visibleForTesting
  static Future<DBusObjectPath?> logindSessionPath(DBusClient system) async {
    final manager = DBusRemoteObject(system, name: _logind, path: DBusObjectPath('/org/freedesktop/login1'));
    try {
      final reply = await manager.callMethod('org.freedesktop.login1.Manager', 'GetSession', [
        const DBusString('auto'),
      ], replySignature: DBusSignature.objectPath);
      return reply.returnValues.first.asObjectPath();
    } catch (error) {
      _log.fine('logind GetSession(auto): $error');
    }
    try {
      final user = DBusRemoteObject(system, name: _logind, path: DBusObjectPath('/org/freedesktop/login1/user/self'));
      final display = await user.getProperty(
        'org.freedesktop.login1.User',
        'Display',
        signature: DBusSignature('(so)'),
      );
      final path = display.asStruct()[1].asObjectPath();
      return path.value == '/' ? null : path;
    } catch (error) {
      _log.fine('logind user Display: $error');
      return null;
    }
  }

  void _listenScreenSaver(DBusClient bus) {
    try {
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

  /// Stops listening (the tests)
  @visibleForTesting
  Future<void> cancel() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }
}
