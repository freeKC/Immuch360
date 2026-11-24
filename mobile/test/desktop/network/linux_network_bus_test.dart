// The local network of Immuch360 Desktop on Linux without NetworkManager or Avahi: the changes of the network are
// polled from the interfaces instead of failing outside the app's zone, and a failed announcement says whether Avahi
// is the reason (linux_network_bus.dart)

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/linux_network_bus.dart';

const _poll = Duration(milliseconds: 20);

/// A plugin stream that fails as connectivity_plus does without NetworkManager: in an async onListen nobody awaits
/// ([atStart]), and in an async onCancel that closes its D-Bus client
Stream<void> _failingPlugin({bool atStart = true}) {
  // Never closed: the plugin's stream lives as long as the app
  // ignore: close_sinks
  final controller = StreamController<void>.broadcast(
    onListen: () async {
      await Future<void>.delayed(Duration.zero);
      if (atStart) {
        throw StateError('org.freedesktop.DBus.Error.ServiceUnknown');
      }
    },
    onCancel: () async {
      await Future<void>.delayed(Duration.zero);
      throw StateError('the D-Bus client did not close');
    },
  );
  return controller.stream;
}

void main() {
  group('LinuxNetworkChanges', () {
    test('without NetworkManager: an event when the addresses change, none while they stay', () async {
      var addresses = {'eth0 192.168.1.20'};
      var asked = 0;
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async => false,
        connectivity: () => fail('the plugin is not used without NetworkManager'),
        addresses: () async {
          asked++;
          return addresses;
        },
        pollEvery: _poll,
      );
      var events = 0;
      final subscription = changes.stream().listen((_) => events++);
      await Future<void>.delayed(_poll * 4);
      expect(events, 0);
      expect(asked, greaterThan(1));
      addresses = {'eth0 192.168.1.20', 'wlan0 10.0.0.7'};
      await Future<void>.delayed(_poll * 4);
      expect(events, 1);
      await subscription.cancel();
      final after = asked;
      await Future<void>.delayed(_poll * 4);
      expect(asked, after, reason: 'no polling once nobody listens');
    });

    test('with NetworkManager: the events of the plugin, and the bus asked once for the life of the app', () async {
      var probes = 0;
      final plugin = StreamController<void>.broadcast();
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async {
          probes++;
          return true;
        },
        connectivity: () => plugin.stream,
        addresses: () async => fail('no polling with NetworkManager'),
        pollEvery: _poll,
      );
      var events = 0;
      final first = changes.stream().listen((_) => events++);
      await Future<void>.delayed(_poll);
      plugin.add(null);
      await Future<void>.delayed(_poll);
      expect(events, 1);
      await first.cancel();
      final second = changes.stream().listen((_) => events++);
      await Future<void>.delayed(_poll);
      plugin.add(null);
      await Future<void>.delayed(_poll);
      expect(events, 2);
      expect(probes, 1);
      await second.cancel();
      await plugin.close();
    });

    test('a plugin error outside its stream is caught, and the addresses are polled instead', () async {
      var addresses = {'eth0 192.168.1.20'};
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async => true,
        connectivity: _failingPlugin,
        addresses: () async => addresses,
        pollEvery: _poll,
      );
      var events = 0;
      // An uncaught error would fail this test: it is the D-Bus error of the Linux trial of 26 Oct 2026
      final subscription = changes.stream().listen((_) => events++);
      await Future<void>.delayed(_poll * 3);
      addresses = {'eth0 192.168.1.21'};
      await Future<void>.delayed(_poll * 4);
      expect(events, 1);
      await subscription.cancel();
    });

    test('two streams share the plugin: its failure after the first one left turns the second to polling', () async {
      var addresses = {'eth0 192.168.1.20'};
      final failure = Completer<void>();
      var listens = 0;
      // Never closed: the plugin's stream lives as long as the app
      // ignore: close_sinks
      final plugin = StreamController<void>.broadcast(
        onListen: () async {
          listens++;
          await failure.future;
          throw StateError('org.freedesktop.NetworkManager went away');
        },
      );
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async => true,
        connectivity: () => plugin.stream,
        addresses: () async => addresses,
        pollEvery: _poll,
      );
      var first = 0;
      var second = 0;
      final pairing = changes.stream().listen((_) => first++);
      await Future<void>.delayed(_poll);
      final player = changes.stream().listen((_) => second++);
      await Future<void>.delayed(_poll);
      plugin.add(null);
      await Future<void>.delayed(_poll);
      expect((first, second, listens), (1, 1, 1), reason: 'one subscription to the plugin for both');

      // The pairing panel closes, then NetworkManager goes away
      await pairing.cancel();
      failure.complete();
      await Future<void>.delayed(_poll * 3);
      addresses = {'eth0 192.168.1.21'};
      await Future<void>.delayed(_poll * 4);
      expect(second, 2, reason: 'the player polls the addresses instead');
      await player.cancel();
    });

    test('a plugin error when it stops is caught too', () async {
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async => true,
        connectivity: () => _failingPlugin(atStart: false),
        addresses: () async => fail('no polling while the plugin works'),
        pollEvery: _poll,
      );
      final subscription = changes.stream().listen((_) {});
      await Future<void>.delayed(_poll);
      await subscription.cancel();
      await Future<void>.delayed(_poll * 2);
    });

    test('interfaces that cannot be read count as none, without an error', () async {
      var fails = true;
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () async => false,
        addresses: () async {
          if (fails) {
            throw StateError('no interfaces');
          }
          return {'eth0 192.168.1.20'};
        },
        pollEvery: _poll,
      );
      var events = 0;
      final subscription = changes.stream().listen((_) => events++, onError: (Object error) => fail('$error'));
      await Future<void>.delayed(_poll * 3);
      fails = false;
      await Future<void>.delayed(_poll * 4);
      expect(events, 1);
      await subscription.cancel();
    });

    test('a cancel before the bus answered starts nothing', () async {
      final answer = Completer<bool>();
      var asked = 0;
      final changes = LinuxNetworkChanges(
        networkManagerAnswers: () => answer.future,
        connectivity: () => fail('not listened to after a cancel'),
        addresses: () async {
          asked++;
          return const {};
        },
        pollEvery: _poll,
      );
      final subscription = changes.stream().listen((_) {});
      await subscription.cancel();
      answer.complete(false);
      await Future<void>.delayed(_poll * 3);
      expect(asked, 0);
    });
  });

  group('advertiseNotingAvahi', () {
    Future<void> stop() async {}

    test('an announcement made clears the note on Linux', () async {
      final notes = <bool>[];
      final result = await advertiseNotingAvahi(
        () async => stop,
        notes.add,
        linux: true,
        avahiAnswers: () async => fail('not asked after a success'),
      );
      expect(result, same(stop));
      expect(notes, [false]);
    });

    test('a failure while Avahi does not answer is noted, and the error still reaches the caller', () async {
      final notes = <bool>[];
      await expectLater(
        advertiseNotingAvahi(
          () async => throw StateError('org.freedesktop.DBus.Error.ServiceUnknown'),
          notes.add,
          linux: true,
          avahiAnswers: () async => false,
        ),
        throwsStateError,
      );
      expect(notes, [true]);
    });

    test('a failure while Avahi answers is not blamed on it', () async {
      final notes = <bool>[];
      await expectLater(
        advertiseNotingAvahi(
          () async => throw TimeoutException('slow'),
          notes.add,
          linux: true,
          avahiAnswers: () async => true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(notes, [false]);
    });

    test('other systems note nothing and never ask the bus', () async {
      final notes = <bool>[];
      await expectLater(
        advertiseNotingAvahi(
          () async => throw StateError('bonsoir'),
          notes.add,
          linux: false,
          avahiAnswers: () async => fail('no system bus off Linux'),
        ),
        throwsStateError,
      );
      expect(notes, isEmpty);
    });
  });

  test(
    'SystemBusProbe: a service that does not exist is false, never an error, with or without a system bus',
    () async {
      expect(await SystemBusProbe.answers('org.immuch360.NoSuchService', timeout: const Duration(seconds: 3)), isFalse);
    },
  );
}
