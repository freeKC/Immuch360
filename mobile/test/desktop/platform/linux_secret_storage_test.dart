// The secrets of Immuch360 Desktop on Linux without a keyring that answers (lib/desktop/platform/
// linux_secret_storage.dart): the session bus asked once, on a real D-Bus server of the dbus package in a temporary
// folder, a bus that does not answer and a secret service that does not answer bounded by short timeouts; the store
// that keeps the secrets in memory for the session and never calls the plugin again once the keyring is missing or
// refused; the other isolates served by the root one.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:dbus/dbus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/platform/linux_secret_storage.dart';
import 'package:logging/logging.dart';

/// The plugin as the store sees it: a map, its calls counted, an error on demand
class _FakeKeyring extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  final calls = <String>[];
  PlatformException? failure;

  Future<T> _call<T>(String name, T Function() body) async {
    calls.add(name);
    final error = failure;
    if (error != null) {
      throw error;
    }
    return body();
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) => _call('read', () => values[key]);

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _call('write', () => values[key] = value);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _call('containsKey', () => values.containsKey(key));

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _call('delete', () => values.remove(key));

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) => _call('readAll', () => Map.of(values));

  @override
  Future<void> deleteAll({required Map<String, String> options}) => _call('deleteAll', values.clear);
}

const _noService = SecretServiceAnswer(SecretServiceState.noService, 'no org.freedesktop.secrets');
const _answers = SecretServiceAnswer(SecretServiceState.answers, 'org.freedesktop.secrets answered');
final _unlockFailure = PlatformException(code: 'Libsecret error', message: 'Failed to unlock the keyring');

/// A secret service that took its name on the bus, then holds its isolate, so that it never answers
Future<void> _silentService((String, SendPort) message) async {
  final (address, ready) = message;
  final client = DBusClient(DBusAddress(address));
  await client.requestName(SecretServiceProbe.serviceName);
  ready.send(true);
  sleep(const Duration(seconds: 3));
  await client.close();
}

/// The D-Bus servers of these tests listen on Unix sockets, which the Windows job of the CI does not have
final _unixSockets = Platform.isWindows ? 'D-Bus on a Unix socket' : null;

void main() {
  late Directory folder;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('linux_secret_storage_test');
  });

  tearDown(() {
    folder.deleteSync(recursive: true);
  });

  group('SecretServiceProbe.sessionBusAddress', () {
    test('no bus: neither DBUS_SESSION_BUS_ADDRESS nor a bus in XDG_RUNTIME_DIR', () {
      final (address, answer) = SecretServiceProbe.sessionBusAddress({'XDG_RUNTIME_DIR': folder.path});
      expect(address, isNull);
      expect(answer!.state, SecretServiceState.noSessionBus);
      expect(SecretServiceProbe.sessionBusAddress(const {}).$2!.state, SecretServiceState.noSessionBus);
    });

    test('no bus: the socket of the address is not there, as in the video smoke of the CI', () {
      final (address, answer) = SecretServiceProbe.sessionBusAddress({
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=${folder.path}/no-session-bus',
      });
      expect(address, isNull);
      expect(answer!.state, SecretServiceState.noSessionBus);
      expect(answer.keyringUsable, isFalse);
      expect(
        SecretServiceProbe.sessionBusAddress({'DBUS_SESSION_BUS_ADDRESS': 'disabled:'}).$2!.state,
        SecretServiceState.noSessionBus,
      );
    });

    test('the first address of a list; abstract and TCP addresses are asked', () {
      final socket = File('${folder.path}/bus')..createSync();
      final (address, _) = SecretServiceProbe.sessionBusAddress({
        'DBUS_SESSION_BUS_ADDRESS': 'unix:path=${socket.path},guid=0123;unix:abstract=/tmp/other',
      });
      expect(address!.properties['path'], socket.path);
      expect(
        SecretServiceProbe.sessionBusAddress({'DBUS_SESSION_BUS_ADDRESS': 'unix:abstract=/tmp/dbus-x'}).$1,
        isNotNull,
      );
      expect(
        SecretServiceProbe.sessionBusAddress({'DBUS_SESSION_BUS_ADDRESS': 'tcp:host=localhost,port=1'}).$1,
        isNotNull,
      );
    });

    test('an address this check cannot use leaves the keyring to libsecret', () {
      final (address, answer) = SecretServiceProbe.sessionBusAddress({'DBUS_SESSION_BUS_ADDRESS': 'launchd:env=X'});
      expect(address, isNull);
      expect(answer!.state, SecretServiceState.unknown);
      expect(answer.keyringUsable, isTrue);
    });
  });

  group('SecretServiceProbe.check on a D-Bus server', () {
    late DBusServer server;
    late String address;

    setUp(() async {
      server = DBusServer();
      address = (await server.listenAddress(DBusAddress.unix(path: '${folder.path}/bus'))).value;
    });

    tearDown(() async {
      await server.close();
    });

    test('a session bus without a secret service', () async {
      final answer = await SecretServiceProbe.check(environment: {'DBUS_SESSION_BUS_ADDRESS': address});
      expect(answer.state, SecretServiceState.noService, reason: '$answer');
      expect(answer.keyringUsable, isFalse);
    });

    test('a secret service that answers', () async {
      final service = DBusClient(DBusAddress(address));
      addTearDown(service.close);
      await service.requestName(SecretServiceProbe.serviceName);
      final answer = await SecretServiceProbe.check(environment: {'DBUS_SESSION_BUS_ADDRESS': address});
      expect(answer.state, SecretServiceState.answers, reason: '$answer');
      expect(answer.keyringUsable, isTrue);
    });

    test('a secret service that does not answer: the wait ends with the timeout, not the 25 s of D-Bus', () async {
      final ready = ReceivePort();
      addTearDown(ready.close);
      final isolate = await Isolate.spawn(_silentService, (address, ready.sendPort));
      addTearDown(() => isolate.kill(priority: Isolate.immediate));
      await ready.first;
      final watch = Stopwatch()..start();
      final answer = await SecretServiceProbe.check(
        environment: {'DBUS_SESSION_BUS_ADDRESS': address},
        answerTimeout: const Duration(milliseconds: 500),
      );
      expect(answer.state, SecretServiceState.silent, reason: '$answer');
      expect(answer.keyringUsable, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  }, skip: _unixSockets);

  test('a session bus that does not answer: the wait ends with the timeout', () async {
    final socket = await ServerSocket.bind(InternetAddress('${folder.path}/bus', type: InternetAddressType.unix), 0);
    final connections = <Socket>[];
    socket.listen(connections.add);
    addTearDown(() async {
      for (final connection in connections) {
        connection.destroy();
      }
      await socket.close();
    });
    final watch = Stopwatch()..start();
    final answer = await SecretServiceProbe.check(
      environment: {'DBUS_SESSION_BUS_ADDRESS': 'unix:path=${folder.path}/bus'},
      busTimeout: const Duration(milliseconds: 300),
    );
    expect(answer.state, SecretServiceState.silent, reason: '$answer');
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  }, skip: _unixSockets);

  group('LinuxSecretStorage', () {
    late _FakeKeyring keyring;
    late List<LogRecord> warnings;
    late StreamSubscription<LogRecord> logs;

    setUp(() {
      keyring = _FakeKeyring();
      warnings = [];
      Logger.root.level = Level.ALL;
      logs = Logger.root.onRecord.where((record) => record.level >= Level.WARNING).listen(warnings.add);
    });

    tearDown(() async {
      await logs.cancel();
    });

    LinuxSecretStorage storageWith(SecretServiceAnswer answer, {void Function()? onProbe}) {
      final storage = LinuxSecretStorage(
        keyring,
        probe: () async {
          onProbe?.call();
          return answer;
        },
        logReady: () => true,
      );
      addTearDown(storage.close);
      return storage;
    }

    test('without a secret service: the memory of the session, the session bus asked once, a warning', () async {
      var probes = 0;
      final storage = storageWith(_noService, onProbe: () => probes++);
      await Future.wait([
        storage.write(key: 'token', value: 'secret', options: const {}),
        storage.read(key: 'other', options: const {}),
        storage.containsKey(key: 'token', options: const {}),
      ]);
      expect(await storage.read(key: 'token', options: const {}), 'secret');
      expect(await storage.containsKey(key: 'token', options: const {}), isTrue);
      expect(await storage.readAll(options: const {}), {'token': 'secret'});
      await storage.delete(key: 'token', options: const {});
      expect(await storage.read(key: 'token', options: const {}), isNull);
      await storage.write(key: 'pin', value: '1234', options: const {});
      await storage.deleteAll(options: const {});
      expect(await storage.readAll(options: const {}), isEmpty);

      expect(probes, 1);
      expect(keyring.calls, isEmpty);
      expect(storage.sessionOnly.value!.keyringRefused, isFalse);
      expect(storage.sessionOnly.value!.detail, contains('no org.freedesktop.secrets'));
      expect(warnings, hasLength(1));
      expect(warnings.single.loggerName, 'LinuxSecretStorage');
      expect(warnings.single.message, contains('install gnome-keyring or KWallet'));
    });

    test('with a secret service that answers: the keyring, as before', () async {
      final storage = storageWith(_answers);
      await storage.write(key: 'token', value: 'secret', options: const {});
      expect(await storage.read(key: 'token', options: const {}), 'secret');
      expect(keyring.values, {'token': 'secret'});
      expect(keyring.calls, ['write', 'read']);
      expect(storage.sessionOnly.value, isNull);
      expect(warnings, isEmpty);
    });

    test(
      'a keyring that refuses a call: the memory of the session from then on, the plugin never called again',
      () async {
        final storage = storageWith(_answers);
        keyring.failure = _unlockFailure;
        expect(await storage.read(key: 'token', options: const {}), isNull);
        await storage.write(key: 'token', value: 'secret', options: const {});
        expect(await storage.read(key: 'token', options: const {}), 'secret');
        expect(keyring.calls, ['read']);
        expect(storage.sessionOnly.value!.keyringRefused, isTrue);
        expect(storage.sessionOnly.value!.detail, contains('Failed to unlock the keyring'));
        expect(warnings, hasLength(1));
      },
    );

    test('a check that fails leaves the keyring to libsecret', () async {
      final storage = LinuxSecretStorage(keyring, probe: () async => throw StateError('broken'), logReady: () => true);
      addTearDown(storage.close);
      await storage.write(key: 'token', value: 'secret', options: const {});
      expect(keyring.calls, ['write']);
      expect(storage.sessionOnly.value, isNull);
    });

    test('a warning made before the log service listens waits for it', () async {
      var ready = false;
      final storage = LinuxSecretStorage(keyring, probe: () async => _noService, logReady: () => ready);
      addTearDown(storage.close);
      await storage.read(key: 'token', options: const {});
      expect(storage.sessionOnly.value, isNotNull);
      expect(warnings, isEmpty);
      ready = true;
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(warnings, hasLength(1));
    });
  });

  group('the other isolates', () {
    tearDown(() {
      IsolateNameServer.removePortNameMapping(LinuxSecretStorage.portName);
    });

    test('ask the root isolate: the same secrets, the plugin never called from them', () async {
      final keyring = _FakeKeyring();
      final root = LinuxSecretStorage(keyring, probe: () async => _noService, logReady: () => true);
      addTearDown(root.close);
      root.serve(LinuxSecretStorage.portName);
      await root.write(key: 'session', value: 'cookies', options: const {});

      final seen = await Isolate.run(() async {
        final client = LinuxSecretStorageClient(local: () => throw StateError('the root isolate serves this isolate'));
        final session = await client.read(key: 'session', options: const {});
        await client.write(key: 'share', value: 'password', options: const {});
        final all = await client.readAll(options: const {});
        final contains = await client.containsKey(key: 'share', options: const {});
        await client.delete(key: 'session', options: const {});
        return (session, all, contains);
      });

      expect(seen.$1, 'cookies');
      expect(seen.$2, {'session': 'cookies', 'share': 'password'});
      expect(seen.$3, isTrue);
      expect(await root.readAll(options: const {}), {'share': 'password'});
      expect(keyring.calls, isEmpty);
    });

    test('keep a store of their own when the root isolate has none', () async {
      final value = await Isolate.run(() async {
        final client = LinuxSecretStorageClient(
          root: () => null,
          local: () => LinuxSecretStorage(_FakeKeyring(), probe: () async => _noService, logReady: () => true),
        );
        await client.write(key: 'token', value: 'secret', options: const {});
        return client.read(key: 'token', options: const {});
      });
      expect(value, 'secret');
    });
  });
}
