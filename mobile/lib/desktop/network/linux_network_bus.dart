// What Immuch360 Desktop on Linux needs of the system bus for the local network: the changes of the network, which
// connectivity_plus reads from NetworkManager, and the mDNS announcements of "Sign in with your phone" and "Play from a
// phone", which bonsoir makes through Avahi.
//
// - Without NetworkManager (a minimal install, systemd-networkd, a container), or without a system bus at all,
//   connectivity_plus failed inside the onListen of its stream (connectivity_plus_linux.dart starts listening in an
//   async callback whose future nobody awaits), so the error escaped every onError of the app and reached the zone
//   as an unhandled D-Bus error at each pairing code (Linux trial of 26 Oct 2026). The bus is now asked first, once:
//   with NetworkManager the plugin is used, guarded; without it the addresses of the network interfaces are compared
//   every [LinuxNetworkChanges.pollEvery], which is what the pairing, the player and the shares listen for anyway.
// - Without Avahi the announcement fails (bonsoir_linux calls org.freedesktop.Avahi). The code, the QR code and the
//   typed address still work, but phones no longer list this computer under "Enter a code", nor find it to play a
//   film here. The pages say so (avahiUnansweredProvider) when the bus confirms that Avahi does not answer.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';

final _log = Logger('LinuxNetworkBus');

/// Asks the system bus whether a service answers, without the plugins that would fail outside our zone
abstract final class SystemBusProbe {
  static const networkManager = 'org.freedesktop.NetworkManager';
  static const avahi = 'org.freedesktop.Avahi';

  /// Whether [service] answers a ping on the system bus within [timeout]; the bus starts it when it can (D-Bus
  /// activation), as the plugin's first call would. Never throws: no bus, no service and no answer are all false.
  static Future<bool> answers(String service, {Duration timeout = const Duration(seconds: 4)}) async {
    DBusClient? client;
    try {
      client = DBusClient.system();
      await client
          .callMethod(
            destination: service,
            path: DBusObjectPath('/'),
            interface: 'org.freedesktop.DBus.Peer',
            name: 'Ping',
            replySignature: DBusSignature.empty,
          )
          .timeout(timeout);
      return true;
    } catch (error) {
      _log.info('$service does not answer on the system bus: ${_short(error)}');
      return false;
    } finally {
      unawaited(client?.close().then<void>((_) {}, onError: (Object _) {}));
    }
  }

  static String _short(Object error) => error is DBusMethodResponseException ? error.errorName : '${error.runtimeType}';
}

/// One event per change of the network of this computer, for as long as it is listened to (see the top of this file)
class LinuxNetworkChanges {
  LinuxNetworkChanges({
    Future<bool> Function()? networkManagerAnswers,
    Stream<void> Function()? connectivity,
    Future<Set<String>> Function()? addresses,
    this.pollEvery = const Duration(seconds: 15),
  }) : _networkManagerAnswers = networkManagerAnswers ?? (() => SystemBusProbe.answers(SystemBusProbe.networkManager)),
       _connectivity = connectivity ?? (() => Connectivity().onConnectivityChanged.map<void>((_) {})),
       _addresses = addresses ?? interfaceAddresses;

  final Future<bool> Function() _networkManagerAnswers;
  final Stream<void> Function() _connectivity;
  final Future<Set<String>> Function() _addresses;
  final Duration pollEvery;

  /// The answer of the bus, asked once for the life of the app: NetworkManager does not come and go
  Future<bool>? _withNetworkManager;

  /// The addresses of the network interfaces, by interface, loopback left out
  static Future<Set<String>> interfaceAddresses() async {
    final interfaces = await NetworkInterface.list(includeLoopback: false, includeLinkLocal: true);
    return {
      for (final interface in interfaces)
        for (final address in interface.addresses) '${interface.name} ${address.address}',
    };
  }

  Stream<void> stream() {
    var cancelled = false;
    var polling = false;
    StreamSubscription<void>? plugin;
    // The zone the plugin is listened to and cancelled in: its errors, at the start and at the stop (it opens and
    // closes its D-Bus client in callbacks nobody awaits), end in this zone's handler, never in the app's
    Zone? pluginZone;
    Timer? poll;
    // Closed by its listener, when it cancels
    // ignore: close_sinks
    late final StreamController<void> controller;

    Future<void> startPolling() async {
      if (cancelled || polling) {
        return;
      }
      polling = true;
      var last = await _safeAddresses();
      if (cancelled) {
        return;
      }
      poll = Timer.periodic(pollEvery, (_) async {
        final now = await _safeAddresses();
        if (!cancelled && !setEquals(now, last)) {
          last = now;
          controller.add(null);
        }
      });
    }

    void stopPlugin() {
      pluginZone?.run(() => unawaited(plugin?.cancel().then<void>((_) {}, onError: (Object _) {})));
      plugin = null;
    }

    controller = StreamController<void>(
      onListen: () async {
        bool withNetworkManager;
        try {
          withNetworkManager = await (_withNetworkManager ??= _networkManagerAnswers());
        } catch (_) {
          withNetworkManager = false;
        }
        if (cancelled) {
          return;
        }
        if (!withNetworkManager) {
          _log.info('No NetworkManager: the network is checked every ${pollEvery.inSeconds} s');
          await startPolling();
          return;
        }
        runZonedGuarded(
          () {
            pluginZone = Zone.current;
            plugin = _connectivity().listen(
              controller.add,
              onError: (Object error) => _log.info('Network changes: ${error.runtimeType}'),
            );
          },
          (error, _) {
            if (cancelled) {
              _log.fine('Network changes: the plugin did not stop cleanly: ${error.runtimeType}');
              return;
            }
            _log.info('NetworkManager stopped answering (${error.runtimeType}): the network is polled');
            stopPlugin();
            unawaited(startPolling());
          },
        );
      },
      onCancel: () {
        cancelled = true;
        poll?.cancel();
        poll = null;
        stopPlugin();
      },
    );
    return controller.stream;
  }

  Future<Set<String>> _safeAddresses() async {
    try {
      return await _addresses();
    } catch (error) {
      _log.fine('No network interfaces: ${error.runtimeType}');
      return const {};
    }
  }
}

final _linuxNetworkChanges = LinuxNetworkChanges();

/// The changes of the network the pairing, the player and the shares listen to: connectivity_plus, and on Linux the
/// guarded reading of the top of this file
Stream<void> deviceNetworkChanges() =>
    CurrentPlatform.isLinux ? _linuxNetworkChanges.stream() : Connectivity().onConnectivityChanged.map<void>((_) {});

/// Whether the last mDNS announcement of this computer failed because Avahi does not answer on the system bus (Linux
/// only; false elsewhere, and once an announcement succeeds)
final avahiUnansweredProvider = NotifierProvider<AvahiUnansweredNotifier, bool>(AvahiUnansweredNotifier.new);

class AvahiUnansweredNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool unanswered) => state = unanswered;
}

/// [advertise], and on Linux whether it failed for want of Avahi, told to [note] (avahiUnansweredProvider):
/// [avahiAnswers] is asked only after a failure. Rethrows the error of [advertise].
Future<Future<void> Function()> advertiseNotingAvahi(
  Future<Future<void> Function()> Function() advertise,
  void Function(bool unanswered) note, {
  bool? linux,
  Future<bool> Function()? avahiAnswers,
}) async {
  final onLinux = linux ?? CurrentPlatform.isLinux;
  try {
    final stop = await advertise();
    if (onLinux) {
      note(false);
    }
    return stop;
  } catch (_) {
    if (onLinux) {
      final answers = await (avahiAnswers ?? () => SystemBusProbe.answers(SystemBusProbe.avahi))();
      note(!answers);
    }
    rethrow;
  }
}
