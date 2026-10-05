import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/phone_share_server.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';
import 'package:immich_mobile/providers/network/phone_share.provider.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';

import 'fakes.dart';

const _installId = '0123456789abcdef';

class _FakeApi extends PhoneShareApi {
  final List<String> calls = [];

  @override
  Future<void> startKeepAlive(String title, String text, String stopLabel) async => calls.add('startKeepAlive');

  @override
  Future<void> updateKeepAlive(String text) async => calls.add('updateKeepAlive');

  @override
  Future<void> stopKeepAlive() async => calls.add('stopKeepAlive');

  @override
  Future<void> releaseTemporaryFiles() async => calls.add('releaseTemporaryFiles');

  @override
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) async => const [];

  @override
  Future<PhoneShareOpenedFile?> openFile(String assetId) async => null;
}

class _FakeServer implements PhoneShareServer {
  _FakeServer({required this.username, required this.password, required this.preferredPort, this.failure});

  final String username;
  final String password;

  @override
  final int preferredPort;

  final Exception? failure;
  final _activity = StreamController<PhoneShareActivity>.broadcast();
  bool started = false;
  bool stopped = false;
  int addressRefreshes = 0;

  @override
  DateTime? lastRequestAt;

  @override
  Stream<PhoneShareActivity> get activity => _activity.stream;

  void request(String client, String method, String path, DateTime at) {
    lastRequestAt = at;
    _activity.add(PhoneShareActivity(client: client, method: method, path: path, at: at));
  }

  @override
  int? get port => started && !stopped ? (preferredPort == 0 ? 40123 : preferredPort) : null;

  @override
  Future<int> start() async {
    if (failure != null) {
      throw failure!;
    }
    started = true;
    return port!;
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<void> refreshServedAddresses() async => addressRefreshes++;
}

/// The device of the tests: what the share started, announced and kept alive
class _Device {
  _Device(this.clock, {this.isIOS = false});

  final DateTime Function() clock;
  final bool isIOS;
  final api = _FakeApi();
  final servers = <_FakeServer>[];
  final announced = <({String name, int port, Map<String, String> attributes})>[];
  int announcementsStopped = 0;

  /// The indexes in [announced] of the announcements stopped, in order
  final stoppedAnnouncements = <int>[];

  /// When set, each announcement waits for its completer in [heldAnnouncements]
  bool holdAnnouncements = false;
  final heldAnnouncements = <Completer<void>>[];
  List<String> addresses = ['192.168.1.20'];
  final network = StreamController<void>.broadcast();
  final lifecycle = StreamController<AppLifecycleState>.broadcast();
  final events = <PhoneShareEvents?>[];
  Exception? serverFailure;

  _FakeServer get server => servers.last;

  void dispose() {
    unawaited(network.close());
    unawaited(lifecycle.close());
  }

  PhoneShareEnvironment get environment => PhoneShareEnvironment(
    api: api,
    createServer: ({required username, required password, required preferredPort}) {
      final server = _FakeServer(
        username: username,
        password: password,
        preferredPort: preferredPort,
        failure: serverFailure,
      );
      servers.add(server);
      return server;
    },
    advertise: (name, port, attributes) async {
      final index = announced.length;
      announced.add((name: name, port: port, attributes: attributes));
      if (holdAnnouncements) {
        final held = Completer<void>();
        heldAnnouncements.add(held);
        await held.future;
      }
      return () async {
        announcementsStopped++;
        stoppedAnnouncements.add(index);
      };
    },
    localAddresses: () async => addresses,
    networkChanges: () => network.stream,
    lifecycle: () => lifecycle.stream,
    deviceName: () async => 'Pixel 9',
    installId: () async => _installId,
    setUpEvents: events.add,
    isIOS: isIOS,
    clock: clock,
  );
}

void main() {
  late FakeSecureStorage secureStorage;

  setUp(() => secureStorage = FakeSecureStorage());

  ProviderContainer containerFor(_Device device) {
    return ProviderContainer(
      overrides: [
        phoneShareEnvironmentProvider.overrideWithValue(device.environment),
        secureStorageServiceProvider.overrideWithValue(secureStorage),
      ],
    );
  }

  /// Runs [body] in fake time, with a device whose clock follows it
  void inFakeTime(
    void Function(FakeAsync async, _Device device, ProviderContainer container) body, {
    bool isIOS = false,
  }) {
    fakeAsync((async) {
      final start = DateTime.utc(2026, 10, 5, 8);
      final device = _Device(() => start.add(async.elapsed), isIOS: isIOS);
      final container = containerFor(device);
      body(async, device, container);
      container.dispose();
      device.dispose();
      async.flushMicrotasks();
    });
  }

  group('start', () {
    test('serves with new credentials, announces the share and keeps it alive', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        expect(container.read(phoneShareProvider).status, PhoneShareStatus.starting);
        async.flushMicrotasks();

        final state = container.read(phoneShareProvider);
        expect(state.status, PhoneShareStatus.on);
        expect(state.port, PhoneShareServer.defaultPort);
        expect(state.urls, ['http://192.168.1.20:8360']);
        expect(state.serviceName, 'Immuch360 on Pixel 9');
        expect(state.username, matches(RegExp(r'^phone\d{4}$')));
        expect(state.password, matches(RegExp(r'^[a-km-z2-9]{8}$')));
        expect(state.displayedPassword, '${state.password!.substring(0, 4)} ${state.password!.substring(4)}');

        expect(secureStorage.values[phoneShareUsernameKey], state.username);
        expect(secureStorage.values[phoneSharePasswordKey], state.password);
        expect(device.server.username, state.username);
        expect(device.server.password, state.password);
        expect(device.announced.single.name, 'Immuch360 on Pixel 9');
        expect(device.announced.single.port, 8360);
        expect(device.announced.single.attributes, {
          'path': '/',
          'u': state.username,
          'app': 'immuch360',
          'id': _installId,
          'v': '1',
        });
        // The copies a killed session left go first
        expect(device.api.calls, ['releaseTemporaryFiles', 'startKeepAlive']);
        expect(device.events.single, isNotNull);
      });
    });

    test('keeps the credentials from one session to the next', () {
      secureStorage.values[phoneShareUsernameKey] = 'phone0042';
      secureStorage.values[phoneSharePasswordKey] = 'abcd2345';
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        expect(container.read(phoneShareProvider).username, 'phone0042');
        expect(container.read(phoneShareProvider).password, 'abcd2345');
        expect(device.server.password, 'abcd2345');
      });
    });

    test('shows why the server did not start, and stops nothing else', () {
      inFakeTime((async, device, container) {
        device.serverFailure = const SocketException('No port');
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        final state = container.read(phoneShareProvider);
        expect(state.status, PhoneShareStatus.error);
        expect(state.error, contains('No port'));
        expect(state.isEnabled, isFalse);
        expect(device.announced, isEmpty);
        expect(device.api.calls, isNot(contains('startKeepAlive')));

        device.serverFailure = null;
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();
        expect(container.read(phoneShareProvider).status, PhoneShareStatus.on);
      });
    });

    for (final newerFirst in [false, true]) {
      test('a start overtaken while it announces undoes what it made only '
          '(${newerFirst ? 'the newer' : 'the older'} announcement done first)', () {
        inFakeTime((async, device, container) {
          final notifier = container.read(phoneShareProvider.notifier);
          device.holdAnnouncements = true;
          unawaited(notifier.start());
          async.flushMicrotasks();
          unawaited(notifier.stop());
          async.flushMicrotasks();
          unawaited(notifier.start());
          async.flushMicrotasks();
          expect(device.servers, hasLength(2));
          expect(device.heldAnnouncements, hasLength(2));

          for (final index in newerFirst ? [1, 0] : [0, 1]) {
            device.heldAnnouncements[index].complete();
            async.flushMicrotasks();
          }

          expect(container.read(phoneShareProvider).status, PhoneShareStatus.on);
          expect(device.servers.first.stopped, isTrue);
          expect(device.server.stopped, isFalse);
          expect(device.stoppedAnnouncements, [0]);
          expect(device.api.calls.where((call) => call == 'startKeepAlive'), hasLength(1));
          expect(device.api.calls, isNot(contains('stopKeepAlive')));

          // What runs is the newer start, and the switch stops all of it
          unawaited(notifier.stop());
          async.flushMicrotasks();
          expect(device.server.stopped, isTrue);
          expect(device.stoppedAnnouncements, [0, 1]);
          expect(device.api.calls.last, 'releaseTemporaryFiles');
        });
      });
    }
  });

  group('stop', () {
    test('the switch stops the server, the announcement and the keep-alive, and deletes the copies', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();
        unawaited(container.read(phoneShareProvider.notifier).stop());
        async.flushMicrotasks();

        final state = container.read(phoneShareProvider);
        expect(state.status, PhoneShareStatus.off);
        expect(state.stoppedIdle, isFalse);
        expect(device.server.stopped, isTrue);
        expect(device.announcementsStopped, 1);
        expect(device.api.calls, ['releaseTemporaryFiles', 'startKeepAlive', 'stopKeepAlive', 'releaseTemporaryFiles']);
        expect(device.events.last, isNull);
      });
    });

    test('stops after an hour without a request', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 30));
        device.server.request('192.168.1.30', 'GET', '/Albums/Camera/VID.mp4', device.clock());
        async.elapse(const Duration(minutes: 59));
        expect(container.read(phoneShareProvider).status, PhoneShareStatus.on);

        async.elapse(const Duration(minutes: 2));
        final state = container.read(phoneShareProvider);
        expect(state.status, PhoneShareStatus.off);
        expect(state.stoppedIdle, isTrue);
        expect(device.server.stopped, isTrue);
        expect(device.api.calls, contains('releaseTemporaryFiles'));
      });
    });

    test('the Stop action of the notification stops the share', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        device.events.last!.stopRequested();
        async.flushMicrotasks();

        expect(container.read(phoneShareProvider).status, PhoneShareStatus.off);
        expect(device.server.stopped, isTrue);
      });
    });

    test('closing the app stops the share', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        device.lifecycle.add(AppLifecycleState.detached);
        async.flushMicrotasks();

        expect(container.read(phoneShareProvider).status, PhoneShareStatus.off);
      });
    });
  });

  group('background', () {
    test('iOS pauses the share in the background and resumes it in front, on the same port', () {
      inFakeTime(isIOS: true, (async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();
        final first = device.server;

        device.lifecycle.add(AppLifecycleState.inactive);
        async.flushMicrotasks();
        expect(container.read(phoneShareProvider).status, PhoneShareStatus.on);

        device.lifecycle.add(AppLifecycleState.hidden);
        device.lifecycle.add(AppLifecycleState.paused);
        async.flushMicrotasks();
        expect(container.read(phoneShareProvider).status, PhoneShareStatus.paused);
        expect(container.read(phoneShareProvider).isEnabled, isTrue);
        expect(first.stopped, isTrue);
        expect(device.announcementsStopped, 1);
        // iOS may end the app in the background: the copies do not wait for a stop
        expect(device.api.calls, ['releaseTemporaryFiles', 'startKeepAlive', 'stopKeepAlive', 'releaseTemporaryFiles']);

        // Paused for two hours: no idle stop meanwhile, nor right after
        async.elapse(const Duration(hours: 2));
        device.lifecycle.add(AppLifecycleState.resumed);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));

        final state = container.read(phoneShareProvider);
        expect(state.status, PhoneShareStatus.on);
        expect(device.servers, hasLength(2));
        expect(device.server.preferredPort, 8360);
        expect(device.server.password, first.password);
        expect(device.announced, hasLength(2));
        expect(device.api.calls, [
          'releaseTemporaryFiles',
          'startKeepAlive',
          'stopKeepAlive',
          'releaseTemporaryFiles',
          'startKeepAlive',
        ]);
      });
    });

    test('Android keeps sharing in the background', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        device.lifecycle.add(AppLifecycleState.hidden);
        device.lifecycle.add(AppLifecycleState.paused);
        async.flushMicrotasks();

        expect(container.read(phoneShareProvider).status, PhoneShareStatus.on);
        expect(device.server.stopped, isFalse);
      });
    });
  });

  group('while on', () {
    test('counts the devices of the last minute and tells the last file read', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        device.server.request('192.168.1.30', 'PROPFIND', '/Albums', device.clock());
        device.server.request('192.168.1.31', 'GET', '/Albums/Camera/IMG_0001.jpg', device.clock());
        device.server.request('192.168.1.30', 'GET', '/360/VID_0002.mp4', device.clock());
        async.flushMicrotasks();

        var state = container.read(phoneShareProvider);
        expect(state.clients, 2);
        expect(state.lastFile, 'VID_0002.mp4');

        async.elapse(const Duration(minutes: 2));
        state = container.read(phoneShareProvider);
        expect(state.clients, 0);
        expect(state.lastFile, 'VID_0002.mp4');
      });
    });

    test('follows the addresses when the network changes, and keeps serving without one', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();

        device.addresses = ['192.168.43.1'];
        device.network.add(null);
        async.flushMicrotasks();
        expect(container.read(phoneShareProvider).urls, ['http://192.168.43.1:8360']);
        expect(device.api.calls, ['releaseTemporaryFiles', 'startKeepAlive', 'updateKeepAlive']);
        // The server listens on the new address at once, not at its next check
        expect(device.server.addressRefreshes, 1);

        device.addresses = [];
        device.network.add(null);
        async.flushMicrotasks();
        final state = container.read(phoneShareProvider);
        expect(state.urls, isEmpty);
        expect(state.status, PhoneShareStatus.on);
        expect(device.server.stopped, isFalse);
      });
    });

    test('a new password is kept and the server starts again with it', () {
      inFakeTime((async, device, container) {
        unawaited(container.read(phoneShareProvider.notifier).start());
        async.flushMicrotasks();
        final before = container.read(phoneShareProvider).password;

        unawaited(container.read(phoneShareProvider.notifier).newPassword());
        async.flushMicrotasks();

        final state = container.read(phoneShareProvider);
        expect(state.password, isNot(before));
        expect(state.status, PhoneShareStatus.on);
        expect(secureStorage.values[phoneSharePasswordKey], state.password);
        expect(device.servers, hasLength(2));
        expect(device.servers.first.stopped, isTrue);
        expect(device.server.password, state.password);
        expect(device.server.username, device.servers.first.username);
      });
    });
  });

  group('helpers', () {
    test('passwords use the 32 symbols that do not read alike, in groups of four', () {
      for (var i = 0; i < 50; i++) {
        expect(newPhoneSharePassword(), matches(RegExp(r'^[abcdefghijkmnpqrstuvwxyz23456789]{8}$')));
      }
      expect(formatPhoneSharePassword('k7m3x9p2'), 'k7m3 x9p2');
      expect(newPhoneShareUsername(), matches(RegExp(r'^phone\d{4}$')));
    });

    test('the announced name fits a DNS-SD instance name', () {
      expect(phoneShareServiceName('Galaxy S24'), 'Immuch360 on Galaxy S24');
      expect(phoneShareServiceName('  '), 'Immuch360 on phone');
      expect(phoneShareServiceName('Line\nbreak.'), 'Immuch360 on Line break');
      final long = phoneShareServiceName('é' * 60);
      expect(long.startsWith('Immuch360 on é'), isTrue);
      expect(utf8.encode(long).length, lessThanOrEqualTo(63));
    });

    test('the addresses put the Wi-Fi first, then the hotspot, and leave out mobile data and VPNs', () {
      final addresses = phoneShareAddressesOf([
        ('rmnet_data0', InternetAddress('10.120.4.7')),
        ('ap0', InternetAddress('192.168.43.1')),
        ('tun0', InternetAddress('10.8.0.2')),
        ('lo', InternetAddress('127.0.0.1')),
        ('wlan0', InternetAddress('192.168.1.20')),
        ('wlan1', InternetAddress('10.0.0.4')),
        ('eth0', InternetAddress('8.8.4.4')),
        ('bridge100', InternetAddress('172.20.10.1')),
      ]);

      expect(addresses, ['192.168.1.20', '10.0.0.4', '192.168.43.1', '172.20.10.1']);
    });

    test('the install id is made once and kept in the store', () async {
      final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
      final store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
      addTearDown(() async {
        await store.dispose();
        await db.close();
      });

      final id = await phoneShareInstallId(store);

      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(store.tryGet(StoreKey.phoneShareId), id);
      expect(await phoneShareInstallId(store), id);
    });
  });
}
