// The session presence of the computers (lib/desktop/window/session_presence.dart): the messages of the runners, and on
// Linux logind on a bus of the test. A fake logind answers GetSession("auto") with the session's own path and emits its
// Lock and Unlock signals and LockedHint there, as the real one does (it takes the alias session/auto for method calls
// only), so a listener on the alias would hear nothing.

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/session_presence.dart';

const _logind = 'org.freedesktop.login1';
const _session = 'org.freedesktop.login1.Session';
final _sessionPath = DBusObjectPath('/org/freedesktop/login1/session/_32');

class _Manager extends DBusObject {
  _Manager({required this.hasSession}) : super(DBusObjectPath('/org/freedesktop/login1'));

  /// The app runs inside a session: GetSession("auto") answers, else logind's error for a process outside any
  final bool hasSession;
  final asked = <String>[];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == 'org.freedesktop.login1.Manager' && methodCall.name == 'GetSession') {
      asked.add(methodCall.values.first.asString());
      return hasSession
          ? DBusMethodSuccessResponse([_sessionPath])
          : DBusMethodErrorResponse('org.freedesktop.login1.NoSessionForPID', [const DBusString('no session')]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

class _User extends DBusObject {
  _User() : super(DBusObjectPath('/org/freedesktop/login1/user/self'));

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == 'org.freedesktop.login1.User' && name == 'Display') {
      return DBusGetPropertyResponse(DBusStruct([const DBusString('_32'), _sessionPath]));
    }
    return DBusMethodErrorResponse.unknownProperty();
  }
}

class _Session extends DBusObject {
  _Session({this.locked = false}) : super(_sessionPath);

  bool locked;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface == _session && name == 'LockedHint') {
      return DBusGetPropertyResponse(DBusBoolean(locked));
    }
    return DBusMethodErrorResponse.unknownProperty();
  }

  Future<void> lock(bool value) => emitSignal(_session, value ? 'Lock' : 'Unlock');

  Future<void> hint(bool value) async {
    locked = value;
    await emitPropertiesChanged(_session, changedProperties: {'LockedHint': DBusBoolean(value)});
  }
}

/// Lets the bus carry what was sent
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('the messages of the runners', () {
    test('away while locked or while the display is off', () {
      final presence = DesktopSessionPresence.forTesting();
      expect(presence.away.value, isFalse);
      presence.handle('locked');
      expect(presence.away.value, isTrue);
      presence.handle('displayOff');
      presence.handle('unlocked');
      expect(presence.away.value, isTrue, reason: 'the display is still off');
      presence.handle('displayOn');
      expect(presence.away.value, isFalse);
      presence.handle('something else');
      expect(presence.away.value, isFalse);
    });
  });

  group('Linux: logind', () {
    late DBusServer server;
    late DBusClient logind;
    late DBusClient app;
    late _Session session;
    late DesktopSessionPresence presence;

    Future<_Manager> start({bool hasSession = true, bool locked = false}) async {
      server = DBusServer();
      final address = await server.listenAddress(DBusAddress.unix(dir: Directory.systemTemp));
      logind = DBusClient(address);
      app = DBusClient(address);
      final manager = _Manager(hasSession: hasSession);
      session = _Session(locked: locked);
      await logind.requestName(_logind);
      await logind.registerObject(manager);
      await logind.registerObject(_User());
      await logind.registerObject(session);
      presence = DesktopSessionPresence.forTesting();
      await presence.listenLinux(system: app);
      await _settle();
      return manager;
    }

    tearDown(() async {
      await presence.cancel();
      await app.close();
      await logind.close();
      await server.close();
    });

    test('its path is asked with "auto", and Lock and Unlock on it are followed', () async {
      final manager = await start();
      expect(manager.asked, ['auto']);
      expect(await DesktopSessionPresence.logindSessionPath(app), _sessionPath);
      expect(presence.away.value, isFalse);
      await session.lock(true);
      await _settle();
      expect(presence.away.value, isTrue, reason: 'Lock comes from the session path, never from session/auto');
      await session.lock(false);
      await _settle();
      expect(presence.away.value, isFalse);
    });

    test('LockedHint, changed and at the start', () async {
      await start(locked: true);
      expect(presence.away.value, isTrue, reason: 'locked already when the app listens');
      await session.hint(false);
      await _settle();
      expect(presence.away.value, isFalse);
      await session.hint(true);
      await _settle();
      expect(presence.away.value, isTrue);
    });

    test('outside any session: the user display session', () async {
      await start(hasSession: false);
      expect(await DesktopSessionPresence.logindSessionPath(app), _sessionPath);
      await session.lock(true);
      await _settle();
      expect(presence.away.value, isTrue);
    });
  }, skip: Platform.isWindows ? 'no Unix socket for the bus of the test' : null);
}
