import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/gdm.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';

const _hash = '0123456789abcdef0123456789abcdef';
const _machine = '0000000000000000000000000000000000000001';

Uint8List _fixture(String name) => File('test/fixtures/plex/$name').readAsBytesSync();

/// A socket that records what is sent, and answers like a server would
class _FakeTransport implements UdpTransport {
  _FakeTransport({required this.broadcast, this.failsGroup = false});

  final bool broadcast;

  /// Like a socket of iOS without the multicast entitlement: the first broadcast or group send closes it
  final bool failsGroup;
  final List<(String address, int port)> sent = [];
  final _datagrams = StreamController<Datagram>();
  bool closed = false;
  bool dead = false;

  /// What a host answers when the request reaches it
  Map<String, Uint8List> answers = {};

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    if (closed || dead) {
      return;
    }
    final isGroup = address.address.endsWith('.255') || address.address == gdmMulticastAddress;
    if (failsGroup && isGroup) {
      dead = true;
      unawaited(_datagrams.close());
      return;
    }
    expect(ascii.decode(bytes), 'M-SEARCH * HTTP/1.1\r\n\r\n');
    sent.add((address.address, port));
    final answer = answers[address.address];
    if (answer != null) {
      scheduleMicrotask(() => answerFrom(address.address, answer));
    }
  }

  void answerFrom(String host, Uint8List data) {
    if (!_datagrams.isClosed) {
      _datagrams.add(Datagram(data, InternetAddress(host), gdmPort));
    }
  }

  @override
  void close() {
    closed = true;
    if (!dead) {
      unawaited(_datagrams.close());
    }
  }
}

void main() {
  group('parseGdmAnswer', () {
    test('reads the answer of a media server, with its line ends as sent', () {
      final answer = parseGdmAnswer(_fixture('gdm_answer.txt'));
      expect(answer?.name, 'Test Plex');
      expect(answer?.hash, _hash);
      expect(answer?.machineIdentifier, _machine);
      expect(answer?.port, 32400);
      expect(answer?.version, '1.42.1.10060-4e8b05daf');
    });

    test('reads LF only and CRLF only answers', () {
      final text = ascii.decode(_fixture('gdm_answer.txt'));
      final lf = text.replaceAll('\r\n', '\n');
      final crlf = lf.replaceAll('\n', '\r\n');
      expect(parseGdmAnswer(ascii.encode(lf))?.hash, _hash);
      expect(parseGdmAnswer(ascii.encode(crlf))?.hash, _hash);
    });

    test('leaves out players and answers that miss what pairing needs', () {
      expect(parseGdmAnswer(_fixture('gdm_player_answer.txt')), isNull);
      final text = ascii.decode(_fixture('gdm_answer.txt'));
      for (final broken in [
        text.replaceFirst('200 OK', '404 Not Found'),
        text.replaceFirst('Host: $_hash.plex.direct', 'Host: example.com'),
        text.replaceFirst('Resource-Identifier: $_machine\n', ''),
        text.replaceFirst('Port: 32400', 'Port: 70000'),
        text.replaceFirst('Port: 32400', 'Port: x'),
        'garbage',
      ]) {
        expect(parseGdmAnswer(ascii.encode(broken)), isNull, reason: broken);
      }
    });
  });

  group('GdmProbe', () {
    late List<_FakeTransport> opened;

    GdmProbe probe({bool groupFails = false, Map<String, Uint8List> sweepAnswers = const {}}) => GdmProbe(
      bind: ({InternetAddress? address, bool broadcast = false}) async {
        final transport = _FakeTransport(broadcast: broadcast, failsGroup: groupFails && opened.isEmpty)
          ..answers = opened.isEmpty ? {} : sweepAnswers;
        opened.add(transport);
        return transport;
      },
      localAddresses: () async => ['192.168.1.5'],
      repeatAt: const [Duration(milliseconds: 20)],
      sweepAt: Duration.zero,
      sweepInterval: Duration.zero,
    );

    setUp(() => opened = []);

    // On a fake clock: the sweep paces itself with timers, which a loaded machine would not run in time on a real one
    List<DiscoveredServer> run(GdmProbe gdm, {List<String>? hosts, void Function()? meanwhile}) => fakeAsync((async) {
      final done = Completer<void>();
      final found = <DiscoveredServer>[];
      final subscription = gdm(DiscoveryRequest(hosts: hosts, done: done.future)).listen(found.add);
      async.elapse(const Duration(milliseconds: 50));
      meanwhile?.call();
      async.elapse(const Duration(seconds: 2));
      done.complete();
      unawaited(subscription.cancel());
      async.flushMicrotasks();
      return found;
    });

    test('sends to the broadcasts and the group from one socket allowed to broadcast, and sweeps from another', () {
      run(probe());
      expect(opened, hasLength(2));
      expect(opened[0].broadcast, isTrue);
      expect(opened[1].broadcast, isFalse);
      final group = {for (final s in opened[0].sent) s.$1};
      expect(group, {'255.255.255.255', '192.168.1.255', gdmMulticastAddress});
      expect(opened[0].sent.every((s) => s.$2 == gdmPort), isTrue);
      final swept = {for (final s in opened[1].sent) s.$1};
      expect(swept, hasLength(253), reason: 'the /24 without this device');
      expect(swept, isNot(contains('192.168.1.5')));
      expect(opened.every((t) => t.closed || t.dead), isTrue, reason: 'both sockets closed once the discovery ended');
    });

    test('finds a server once, by the address its answer came from', () {
      final found = run(
        probe(sweepAnswers: {'192.168.1.20': _fixture('gdm_answer.txt')}),
        meanwhile: () => opened[0].answerFrom('192.168.1.20', _fixture('gdm_answer.txt')),
      );
      expect(found, hasLength(1));
      final server = found.single;
      expect(server.type, NetworkSourceType.plex);
      expect((server.host, server.port, server.useTls), ('192.168.1.20', 32400, true));
      expect(server.origin, DiscoveryOrigin.gdm);
      expect(server.displayName, 'Test Plex');
      expect(server.discoveryId, _machine);
      expect(server.plexHash, _hash);
      expect(server.version, '1.42.1.10060-4e8b05daf');
    });

    test('keeps the sweep going when the broadcast socket fails, as on iOS', () {
      final found = run(probe(groupFails: true, sweepAnswers: {'192.168.1.20': _fixture('gdm_answer.txt')}));
      expect(opened[0].dead, isTrue);
      expect(found.single.host, '192.168.1.20');
    });

    test('ignores answers from outside the local network, and players', () {
      final found = run(
        probe(),
        meanwhile: () {
          opened[1].answerFrom('203.0.113.7', _fixture('gdm_answer.txt'));
          opened[1].answerFrom('192.168.1.30', _fixture('gdm_player_answer.txt'));
        },
      );
      expect(found, isEmpty);
    });

    test('sweeps the hosts of the request instead of the subnet', () {
      final found = run(probe(sweepAnswers: {'10.0.0.9': _fixture('gdm_answer.txt')}), hosts: ['10.0.0.9']);
      expect({for (final s in opened[1].sent) s.$1}, {'10.0.0.9'});
      expect(found.single.host, '10.0.0.9');
    });
  });
}
