// The UDP 7359 discovery of Jellyfin and Emby with a fake socket, as gdm_test.dart: the broadcast and the sweep, the
// two questions, the container address in Address (bench of release 49, fact 2), answers that do not read, the
// confirmation at the source address; then the merge of a UDP find and a scan find of one server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_api.dart';
import 'package:immich_mobile/infrastructure/network/jellyfin/jellyfin_discovery.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/udp_transport.dart';

const _jellyfinId = '20c74532649049adbcb7a9ac5aba0149';
const _embyId = '1e72492f03c44ebdbcc65272d20b9669';

/// The answers of the bench: Jellyfin 10.10 in bridge mode (its container address), Emby without EndpointAddress
Uint8List _jellyfinAnswer({String address = 'http://172.17.0.3:8096'}) =>
    utf8.encode(jsonEncode({'Address': address, 'Id': _jellyfinId, 'Name': 'Box', 'EndpointAddress': null}));
Uint8List _embyAnswer() =>
    utf8.encode(jsonEncode({'Address': 'http://172.17.0.4:8096', 'Id': _embyId, 'Name': 'Emby box'}));

class _FakeTransport implements UdpTransport {
  _FakeTransport({required this.broadcast, this.failsBroadcast = false});

  final bool broadcast;
  final bool failsBroadcast;
  final List<(String question, String address, int port)> sent = [];
  final _datagrams = StreamController<Datagram>();
  bool closed = false;
  bool dead = false;

  /// What a host answers to each question it gets: Jellyfin to its own, Emby to its own
  Map<String, Map<String, Uint8List>> answers = {};

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    if (closed || dead) {
      return;
    }
    if (failsBroadcast && address.address.endsWith('.255')) {
      dead = true;
      unawaited(_datagrams.close());
      return;
    }
    final question = ascii.decode(bytes);
    sent.add((question, address.address, port));
    final answer = answers[address.address]?[question];
    if (answer != null) {
      scheduleMicrotask(() => answerFrom(address.address, answer));
    }
  }

  void answerFrom(String host, Uint8List data) {
    if (!_datagrams.isClosed) {
      _datagrams.add(Datagram(data, InternetAddress(host), jellyfinDiscoveryPort));
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
  test('the answers of both products, and what is not one', () {
    final jellyfin = parseJellyfinDiscoveryAnswer(_jellyfinAnswer())!;
    expect((jellyfin.id, jellyfin.port, jellyfin.useTls, jellyfin.name), (_jellyfinId, 8096, false, 'Box'));
    expect(parseJellyfinDiscoveryAnswer(_embyAnswer())!.id, _embyId);
    for (final broken in ['who is JellyfinServer?', '{"Id": "x"}', '[]', '{"Address": "http://a:1"}', '\u0000ÿ']) {
      expect(parseJellyfinDiscoveryAnswer(utf8.encode(broken)), isNull, reason: broken);
    }
  });

  group('JellyfinDiscoveryProbe', () {
    late List<_FakeTransport> opened;
    late List<Uri> confirmed;

    /// The servers that answer /System/Info/Public, by base URL
    late Map<String, JellyfinPublicInfo> servers;

    JellyfinDiscoveryProbe probe({bool broadcastFails = false, Map<String, Map<String, Uint8List>> sweep = const {}}) =>
        JellyfinDiscoveryProbe(
          bind: ({InternetAddress? address, bool broadcast = false}) async {
            final transport = _FakeTransport(broadcast: broadcast, failsBroadcast: broadcastFails && opened.isEmpty)
              ..answers = opened.isEmpty ? {} : sweep;
            opened.add(transport);
            return transport;
          },
          localAddresses: () async => ['192.168.1.5'],
          confirm: (base, {timeout = Duration.zero, until}) async {
            confirmed.add(base);
            return servers['$base'];
          },
          repeatAt: const [Duration(milliseconds: 20)],
          sweepAt: Duration.zero,
          sweepInterval: Duration.zero,
        );

    setUp(() {
      opened = [];
      confirmed = [];
      servers = {
        'http://192.168.1.20:8096': const JellyfinPublicInfo(
          id: _jellyfinId,
          product: JellyfinProduct.jellyfin,
          serverName: 'Living room',
          version: '10.10.7',
        ),
        'http://192.168.1.21:8096': const JellyfinPublicInfo(
          id: _embyId,
          product: JellyfinProduct.emby,
          version: '4.10.2.0',
        ),
      };
    });

    List<DiscoveredServer> run(JellyfinDiscoveryProbe probe, {List<String>? hosts, void Function()? meanwhile}) =>
        fakeAsync((async) {
          final done = Completer<void>();
          final found = <DiscoveredServer>[];
          final subscription = probe(DiscoveryRequest(hosts: hosts, done: done.future)).listen(found.add);
          async.elapse(const Duration(milliseconds: 50));
          meanwhile?.call();
          async.elapse(const Duration(seconds: 2));
          done.complete();
          unawaited(subscription.cancel());
          async.flushMicrotasks();
          return found;
        });

    test('asks both questions by broadcast from one socket, and of every host of the /24 from another', () {
      run(probe());
      expect(opened, hasLength(2));
      expect(opened[0].broadcast, isTrue);
      expect({for (final s in opened[0].sent) s.$2}, {'255.255.255.255', '192.168.1.255'});
      expect({for (final s in opened[0].sent) s.$1}, {'who is JellyfinServer?', 'who is EmbyServer?'});
      expect(opened[0].sent.every((s) => s.$3 == 7359), isTrue);
      final swept = {for (final s in opened[1].sent) s.$2};
      expect(swept, hasLength(253));
      expect(swept, isNot(contains('192.168.1.5')));
      expect(opened[1].sent.where((s) => s.$2 == '192.168.1.20').map((s) => s.$1), [
        'who is JellyfinServer?',
        'who is EmbyServer?',
      ]);
      expect(opened.every((t) => t.closed || t.dead), isTrue);
    });

    test('the host is the source of the answer, the port that of Address, confirmed at that address', () {
      final found = run(
        probe(
          sweep: {
            '192.168.1.20': {'who is JellyfinServer?': _jellyfinAnswer()},
            '192.168.1.21': {'who is EmbyServer?': _embyAnswer()},
          },
        ),
        meanwhile: () => opened[0].answerFrom('192.168.1.20', _jellyfinAnswer()),
      );
      expect(found, hasLength(2), reason: 'the broadcast and the sweep answers of Jellyfin are one');
      final jellyfin = found.firstWhere((s) => s.discoveryId == _jellyfinId);
      expect((jellyfin.host, jellyfin.port, jellyfin.useTls), ('192.168.1.20', 8096, false));
      expect(jellyfin.type, NetworkSourceType.jellyfin);
      expect(jellyfin.origin, DiscoveryOrigin.jellyfin);
      expect(jellyfin.displayName, 'Living room');
      expect(jellyfin.version, '10.10.7');
      expect(jellyfin.isEmby, isFalse);
      final emby = found.firstWhere((s) => s.discoveryId == _embyId);
      expect(emby.isEmby, isTrue);
      expect(emby.displayName, 'Emby box', reason: 'its answer named it, its public information did not');
      expect(confirmed.map((u) => u.host), everyElement(startsWith('192.168.1.')));
      expect(confirmed.map((u) => u.host), isNot(contains('172.17.0.3')));
    });

    test('an answer that does not confirm at its address, or tells another id, is not listed', () {
      servers.clear();
      servers['http://192.168.1.20:8096'] = const JellyfinPublicInfo(
        id: '0123456789abcdef0123456789abcdef',
        product: JellyfinProduct.jellyfin,
        version: '12.4.0',
      );
      final found = run(
        probe(
          sweep: {
            '192.168.1.20': {'who is JellyfinServer?': _jellyfinAnswer()},
            '192.168.1.22': {'who is JellyfinServer?': _jellyfinAnswer(address: 'http://172.17.0.9:18010')},
          },
        ),
      );
      expect(found, isEmpty);
    });

    test('keeps the sweep when the broadcast socket fails, as on iOS; ignores answers from outside', () {
      final found = run(
        probe(
          broadcastFails: true,
          sweep: {
            '192.168.1.20': {'who is JellyfinServer?': _jellyfinAnswer()},
          },
        ),
        meanwhile: () => opened[1].answerFrom('203.0.113.7', _jellyfinAnswer()),
      );
      expect(opened[0].dead, isTrue);
      expect(found.single.host, '192.168.1.20');
    });
  });

  test('a UDP find and a scan find of one server are one, whatever their ports', () {
    const info = JellyfinPublicInfo(id: _jellyfinId, product: JellyfinProduct.jellyfin, version: '12.4.0');
    final udp = jellyfinDiscovered(
      info,
      host: '192.168.1.20',
      port: 8096,
      useTls: false,
      origin: DiscoveryOrigin.jellyfin,
    );
    final scan = jellyfinDiscovered(info, host: '192.168.1.20', port: 8920, useTls: true, origin: DiscoveryOrigin.scan);
    expect(udp.mergeKey, scan.mergeKey);
    final merged = udp.mergedWith(scan);
    expect((merged.port, merged.version, merged.product), (8096, '12.4.0', 'jellyfin'));
  });

  test('the scan tries 8096 and 8920 with TLS for Jellyfin and Emby', () {
    expect(
      ScanPort.defaults,
      containsAll([
        const ScanPort(8096, NetworkSourceType.jellyfin),
        const ScanPort(8920, NetworkSourceType.jellyfin, useTls: true),
      ]),
    );
  });

  test('a server of either product is confirmed by its public information, anything else is not', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        request.uri.path == '/System/Info/Public'
            ? jsonEncode({'Id': _embyId, 'Version': '4.10.2.0', 'ServerName': 'Box', 'LocalAddresses': []})
            : '{}',
      );
      await request.response.close();
    });
    final info = await const ServerConfirmer().jellyfinAt(Uri.parse('http://127.0.0.1:${server.port}'));
    expect(info?.product, JellyfinProduct.emby);
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(await const ServerConfirmer().jellyfinAt(Uri.parse('http://127.0.0.1:$port')), isNull);
  });
}
