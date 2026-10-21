// The secrets of Immuch360 Desktop on Linux: the session of the server's HTTP stack, the client certificate, the share
// passwords, the PIN code of the locked folder. flutter_secure_storage_linux keeps them in the keyring of the session
// through libsecret, whose calls it makes synchronously on the platform thread, the thread of the window. Without a
// secret service on the session bus (no GNOME Keyring or KWallet: a minimal window manager, a container, WSLg)
// libsecret fails at once with "Failed to unlock the keyring", which reached the app as an unhandled
// PlatformException at the first start; with a secret service that does not answer, each call held the window for
// the 25 seconds of the D-Bus timeout, twice per read (the plugin stores a control item before each lookup).
//
// So the session bus is asked once, in Dart, with short timeouts and without blocking anything, whether a secret
// service answers (SecretServiceProbe). When none does, or when the keyring refuses a call, the secrets of this
// session are kept in memory and D-Bus is not asked again until the app restarts; the settings say so ("This
// computer", session_secrets_notice.dart) and the Logs page holds the reason. The other isolates of the app (the sync
// of runInIsolateGentle reads the HTTP session) ask the store of the root isolate through a port, so that they see the
// same secrets and never call libsecret themselves.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer, RootIsolateToken;

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('LinuxSecretStorage');

/// What the session bus says of the Secret Service API (org.freedesktop.secrets), which GNOME Keyring and KWallet
/// provide and libsecret talks to
enum SecretServiceState {
  /// A secret service answered: the keyring is used
  answers,

  /// No session bus to ask
  noSessionBus,

  /// A session bus without a secret service, neither running nor startable by the bus
  noService,

  /// The session bus or its secret service did not answer in time: libsecret would wait for the D-Bus timeout
  silent,

  /// An address this check cannot reach, which libsecret may: the keyring is tried, its errors caught
  unknown,
}

@immutable
class SecretServiceAnswer {
  const SecretServiceAnswer(this.state, this.detail);

  final SecretServiceState state;

  /// What was found, in English, for the log
  final String detail;

  bool get keyringUsable => state == SecretServiceState.answers || state == SecretServiceState.unknown;

  @override
  String toString() => '${state.name}: $detail';
}

/// Asks the session bus whether a secret service answers, as libsecret would find it, without libsecret
abstract final class SecretServiceProbe {
  static const serviceName = 'org.freedesktop.secrets';
  static final servicePath = DBusObjectPath('/org/freedesktop/secrets');

  /// Errors of the bus meaning that no secret service is there or could be started
  static const _gone = {'org.freedesktop.DBus.Error.ServiceUnknown', 'org.freedesktop.DBus.Error.NameHasNoOwner'};

  /// Errors of the bus meaning that the secret service did not answer
  static const _silent = {'org.freedesktop.DBus.Error.NoReply', 'org.freedesktop.DBus.Error.TimedOut'};

  /// [environment]: the process's by default. [busTimeout] bounds each question to the bus, [answerTimeout] the
  /// ping of a running secret service and [activationTimeout] the ping that makes the bus start one (gnome-keyring
  /// started on demand). Never throws.
  static Future<SecretServiceAnswer> check({
    Map<String, String>? environment,
    Duration busTimeout = const Duration(seconds: 3),
    Duration answerTimeout = const Duration(seconds: 5),
    Duration activationTimeout = const Duration(seconds: 10),
  }) async {
    final (address, problem) = sessionBusAddress(environment ?? Platform.environment);
    if (address == null) {
      return problem!;
    }
    final client = DBusClient(address, introspectable: false);
    try {
      final bool running;
      try {
        running = await client.nameHasOwner(serviceName).timeout(busTimeout);
      } on TimeoutException {
        return SecretServiceAnswer(
          SecretServiceState.silent,
          'the session bus ($address) did not answer in ${busTimeout.inSeconds} s',
        );
      }
      if (!running) {
        final activatable = await client.listActivatableNames().timeout(busTimeout);
        if (!activatable.contains(serviceName)) {
          return const SecretServiceAnswer(
            SecretServiceState.noService,
            'no $serviceName on the session bus, neither running nor startable',
          );
        }
      }
      final timeout = running ? answerTimeout : activationTimeout;
      try {
        await client
            .callMethod(
              destination: serviceName,
              path: servicePath,
              interface: 'org.freedesktop.DBus.Peer',
              name: 'Ping',
              replySignature: DBusSignature.empty,
            )
            .timeout(timeout);
        return SecretServiceAnswer(
          SecretServiceState.answers,
          running ? '$serviceName answered' : '$serviceName was started by the session bus and answered',
        );
      } on TimeoutException {
        return SecretServiceAnswer(
          SecretServiceState.silent,
          '$serviceName ${running ? 'is there' : 'is startable'} but did not answer in ${timeout.inSeconds} s',
        );
      } on DBusMethodResponseException catch (error) {
        final name = error.errorName;
        if (_gone.contains(name) || name.startsWith('org.freedesktop.DBus.Error.Spawn.')) {
          return SecretServiceAnswer(SecretServiceState.noService, '$serviceName could not be reached: $name');
        }
        if (_silent.contains(name)) {
          return SecretServiceAnswer(SecretServiceState.silent, '$serviceName did not answer: $name');
        }
        // Any other error comes from the service itself, which is there
        return SecretServiceAnswer(SecretServiceState.answers, '$serviceName answered ($name)');
      }
    } on TimeoutException {
      return SecretServiceAnswer(
        SecretServiceState.silent,
        'the session bus ($address) did not answer in ${busTimeout.inSeconds} s',
      );
    } on SocketException catch (error) {
      return SecretServiceAnswer(
        SecretServiceState.noSessionBus,
        'the session bus ($address) cannot be reached: ${error.osError?.message ?? error.message}',
      );
    } catch (error) {
      return SecretServiceAnswer(SecretServiceState.noSessionBus, 'the session bus ($address) failed: $error');
    } finally {
      unawaited(client.close().timeout(const Duration(seconds: 1)).catchError((_) {}));
    }
  }

  /// The address of the session bus as libdbus and GDBus find it: DBUS_SESSION_BUS_ADDRESS (its first address), else
  /// the bus socket of XDG_RUNTIME_DIR. Where GDBus would then start a bus for the X display (dbus-launch), there is
  /// none here. Returns the address, or why there is none to ask.
  static (DBusAddress?, SecretServiceAnswer?) sessionBusAddress(Map<String, String> environment) {
    var text = environment['DBUS_SESSION_BUS_ADDRESS'] ?? '';
    if (text.trim().isEmpty) {
      final runtime = environment['XDG_RUNTIME_DIR'];
      final socket = runtime == null || runtime.isEmpty ? null : '$runtime/bus';
      if (socket == null || FileSystemEntity.typeSync(socket) != FileSystemEntityType.unixDomainSock) {
        return (
          null,
          const SecretServiceAnswer(
            SecretServiceState.noSessionBus,
            'DBUS_SESSION_BUS_ADDRESS is not set and XDG_RUNTIME_DIR holds no bus',
          ),
        );
      }
      text = 'unix:path=$socket';
    }
    final first = text
        .split(';')
        .map((address) => address.trim())
        .firstWhere((address) => address.isNotEmpty, orElse: () => '');
    final DBusAddress address;
    try {
      address = DBusAddress(first);
    } on FormatException catch (error) {
      return (
        null,
        SecretServiceAnswer(SecretServiceState.unknown, 'unreadable session bus address: ${error.message}'),
      );
    }
    switch (address.transport) {
      case 'unix':
        final path = address.properties['path'];
        if (path != null) {
          if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
            return (null, SecretServiceAnswer(SecretServiceState.noSessionBus, 'no session bus at $path'));
          }
          return (address, null);
        }
        if (address.properties['abstract'] != null) {
          return (address, null);
        }
      case 'tcp':
        if (address.properties['host'] != null) {
          return (address, null);
        }
      // What a session without D-Bus may set, on purpose
      case 'disabled':
        return (null, const SecretServiceAnswer(SecretServiceState.noSessionBus, 'the session bus is disabled'));
    }
    return (
      null,
      SecretServiceAnswer(SecretServiceState.unknown, 'a session bus address this check cannot use: $first'),
    );
  }
}

/// Why the secrets of this session are kept in memory only
@immutable
class SessionOnlySecrets {
  const SessionOnlySecrets({required this.keyringRefused, required this.detail});

  /// True when a keyring answered but refused a call (locked, its prompt dismissed); false when none answered
  final bool keyringRefused;

  /// The reason, in English, for the log
  final String detail;
}

/// flutter_secure_storage on Linux, in the root isolate: the keyring when a secret service answers, else the memory of
/// this session. [install] puts it in front of the plugin.
class LinuxSecretStorage extends FlutterSecureStoragePlatform {
  /// [keyring]: the plugin (its method channel). [probe]: [SecretServiceProbe.check] by default. [logReady]: whether
  /// the app's log service listens yet, whose Logs page shows the warnings; a warning made before waits for it.
  LinuxSecretStorage(this._keyring, {Future<SecretServiceAnswer> Function()? probe, bool Function()? logReady})
    : _probe = probe ?? SecretServiceProbe.check,
      _logReady = logReady ?? _logServiceReady;

  /// The name of the root isolate's port in IsolateNameServer, which the other isolates ask
  static const portName = 'immuch360_linux_secret_storage';

  final FlutterSecureStoragePlatform _keyring;
  final Future<SecretServiceAnswer> Function() _probe;
  final bool Function() _logReady;
  final Map<String, String> _memory = {};
  Future<bool>? _useKeyring;
  ReceivePort? _port;
  Timer? _logWait;
  final List<String> _pendingWarnings = [];

  /// Set once the secrets of this session are kept in memory, with the reason; the settings show it
  final sessionOnly = ValueNotifier<SessionOnlySecrets?>(null);

  /// The store of this isolate, when [install] put one in front of flutter_secure_storage here
  static LinuxSecretStorage? get installed => switch (FlutterSecureStoragePlatform.instance) {
    final LinuxSecretStorage storage => storage,
    _ => null,
  };

  /// Puts the store in front of flutter_secure_storage in this isolate, once: the root isolate keeps the secrets and
  /// asks the session bus at once, the other isolates ask the root isolate. Linux only (SecureStorageRepository).
  static void install() {
    final current = FlutterSecureStoragePlatform.instance;
    if (current is LinuxSecretStorage || current is LinuxSecretStorageClient) {
      return;
    }
    if (RootIsolateToken.instance != null) {
      final storage = LinuxSecretStorage(current);
      storage.serve(portName);
      unawaited(storage.keyringUsable());
      FlutterSecureStoragePlatform.instance = storage;
    } else {
      FlutterSecureStoragePlatform.instance = LinuxSecretStorageClient(local: () => LinuxSecretStorage(current));
    }
  }

  /// Whether the keyring is used: the session bus is asked at the first call only
  Future<bool> keyringUsable() => _useKeyring ??= _decide();

  Future<bool> _decide() async {
    SecretServiceAnswer answer;
    try {
      answer = await _probe();
    } catch (error) {
      answer = SecretServiceAnswer(SecretServiceState.unknown, 'the check failed: $error');
    }
    if (answer.keyringUsable) {
      _log.info('The secrets go to the keyring of the session ($answer)');
      return true;
    }
    _keepInMemory(keyringRefused: false, detail: answer.toString());
    return false;
  }

  void _keepInMemory({required bool keyringRefused, required String detail}) {
    _useKeyring = Future.value(false);
    if (sessionOnly.value != null) {
      return;
    }
    sessionOnly.value = SessionOnlySecrets(keyringRefused: keyringRefused, detail: detail);
    _warn(
      keyringRefused
          ? 'The keyring refused a secret ($detail): the secrets of this session are kept in memory only and are '
                'forgotten when the app closes'
          : 'No keyring answered ($detail): the secrets of this session are kept in memory only and are forgotten '
                'when the app closes; install gnome-keyring or KWallet to keep them',
    );
  }

  void _warn(String message) {
    if (_logReady()) {
      _log.warning(message);
      return;
    }
    // Before the log service of the app listens (the first reads come from Bootstrap.initDomain, before it), the
    // warning waits for it, so that the Logs page shows it
    _pendingWarnings.add(message);
    var tries = 0;
    _logWait ??= Timer.periodic(const Duration(milliseconds: 500), (timer) {
      tries++;
      if (!_logReady() && tries < 240) {
        return;
      }
      timer.cancel();
      _logWait = null;
      _pendingWarnings.forEach(_log.warning);
      _pendingWarnings.clear();
    });
  }

  static bool _logServiceReady() {
    try {
      LogService.I;
      return true;
    } on LoggerUnInitializedException {
      return false;
    }
  }

  /// The call on the keyring when it is used and does not fail, else on the memory of this session
  Future<T> _run<T>(Future<T> Function(FlutterSecureStoragePlatform keyring) onKeyring, T Function() inMemory) async {
    if (await keyringUsable()) {
      try {
        return await onKeyring(_keyring);
      } on PlatformException catch (error) {
        _keepInMemory(keyringRefused: true, detail: '${error.code}: ${error.message}');
      } on MissingPluginException catch (error) {
        _keepInMemory(keyringRefused: true, detail: 'no keyring plugin: ${error.message}');
      }
    }
    return inMemory();
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) =>
      _run((keyring) => keyring.read(key: key, options: options), () => _memory[key]);

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _run((keyring) => keyring.write(key: key, value: value, options: options), () => _memory[key] = value);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) =>
      _run((keyring) => keyring.containsKey(key: key, options: options), () => _memory.containsKey(key));

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _run((keyring) => keyring.delete(key: key, options: options), () => _memory.remove(key));

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) =>
      _run((keyring) => keyring.readAll(options: options), () => Map.of(_memory));

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      _run((keyring) => keyring.deleteAll(options: options), _memory.clear);

  /// Answers the other isolates (LinuxSecretStorageClient) on a port registered under [name]
  void serve(String name) {
    final port = _port = ReceivePort('LinuxSecretStorage');
    port.listen((message) => unawaited(_answer(message)));
    IsolateNameServer.removePortNameMapping(name);
    IsolateNameServer.registerPortWithName(port.sendPort, name);
  }

  Future<void> _answer(Object? message) async {
    if (message is! List || message.length != 5 || message[0] is! SendPort) {
      return;
    }
    final reply = message[0] as SendPort;
    try {
      final result = await dispatch(
        message[1] as String,
        message[2] as String?,
        message[3] as String?,
        _options(message[4]),
      );
      reply.send([true, result]);
    } catch (error) {
      reply.send([false, '$error']);
    }
  }

  static Map<String, String> _options(Object? options) =>
      options is Map ? options.map((key, value) => MapEntry('$key', '$value')) : const {};

  /// One call by its name, as the other isolates send it
  Future<Object?> dispatch(String method, String? key, String? value, Map<String, String> options) => switch (method) {
    'read' => read(key: key!, options: options),
    'write' => write(key: key!, value: value!, options: options),
    'containsKey' => containsKey(key: key!, options: options),
    'delete' => delete(key: key!, options: options),
    'readAll' => readAll(options: options),
    'deleteAll' => deleteAll(options: options),
    _ => Future.error(ArgumentError.value(method, 'method')),
  };

  /// Stops answering the other isolates and waiting for the log (the tests)
  void close() {
    _port?.close();
    _port = null;
    _logWait?.cancel();
    _logWait = null;
  }
}

/// flutter_secure_storage on Linux in an isolate other than the root one: each call goes to the root isolate's
/// [LinuxSecretStorage], which holds the keyring decision and the memory of the session. Without it (the root isolate
/// put none, as in a test), this isolate keeps a store of its own.
class LinuxSecretStorageClient extends FlutterSecureStoragePlatform {
  /// [root]: the root isolate's port, looked up in IsolateNameServer by default. [local]: the store of this isolate
  /// when there is no root one.
  LinuxSecretStorageClient({SendPort? Function()? root, required LinuxSecretStorage Function() local})
    : _lookUp = root ?? (() => IsolateNameServer.lookupPortByName(LinuxSecretStorage.portName)),
      _makeLocal = local;

  final SendPort? Function() _lookUp;
  final LinuxSecretStorage Function() _makeLocal;
  LinuxSecretStorage? _local;

  Future<Object?> _call(String method, {String? key, String? value, required Map<String, String> options}) async {
    final root = _lookUp();
    if (root == null) {
      return (_local ??= _makeLocal()).dispatch(method, key, value, options);
    }
    final reply = ReceivePort('LinuxSecretStorageClient');
    try {
      root.send([reply.sendPort, method, key, value, options]);
      final answer = await reply.first as List<Object?>;
      if (answer[0] == true) {
        return answer[1];
      }
      throw PlatformException(code: 'LinuxSecretStorage', message: answer[1] as String?);
    } finally {
      reply.close();
    }
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async =>
      await _call('read', key: key, options: options) as String?;

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) =>
      _call('write', key: key, value: value, options: options);

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async =>
      await _call('containsKey', key: key, options: options) == true;

  @override
  Future<void> delete({required String key, required Map<String, String> options}) =>
      _call('delete', key: key, options: options);

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async =>
      LinuxSecretStorage._options(await _call('readAll', options: options));

  @override
  Future<void> deleteAll({required Map<String, String> options}) => _call('deleteAll', options: options);
}
