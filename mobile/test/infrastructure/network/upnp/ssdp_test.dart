import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';
import 'package:immich_mobile/infrastructure/network/upnp/upnp_description.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _fixture(String name) => File('test/fixtures/upnp/$name').readAsBytesSync();

/// An answer to an M-SEARCH, CRLF line ends unless [lf]
String _answer({
  String location = 'http://192.168.1.10:8200/rootDesc.xml',
  String st = ssdpMediaServerTarget,
  String? usn = 'uuid:4d696e69-444c-164e-9d41-000000000001::urn:schemas-upnp-org:device:MediaServer:1',
  bool lf = false,
}) {
  final lines = [
    'HTTP/1.1 200 OK',
    'CACHE-CONTROL: max-age=1800',
    'ST: $st',
    if (usn != null) 'USN: $usn',
    'EXT:',
    'SERVER: Linux/6.1 DLNADOC/1.50 UPnP/1.0 MiniDLNA/1.3.3',
    if (location.isNotEmpty) 'LOCATION: $location',
    'Content-Length: 0',
    '',
    '',
  ];
  return lines.join(lf ? '\n' : '\r\n');
}

typedef _Sent = ({String text, String address, int port, Duration at});

/// A socket of the probe in memory: what it sent, with the time, and the answers the test gives it
class _FakeTransport implements SsdpTransport {
  _FakeTransport(this.now, {this.failsMulticast = false});

  final Duration Function() now;

  /// Like a socket of iOS without the multicast entitlement under dart:io: the first send to the group fails and
  /// closes it, and what is sent afterwards is lost
  final bool failsMulticast;
  final List<_Sent> sent = [];
  final _datagrams = StreamController<Datagram>();
  bool closed = false;
  bool dead = false;
  int lost = 0;

  @override
  Stream<Datagram> get datagrams => _datagrams.stream;

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    if (closed) {
      throw StateError('sent on a closed socket');
    }
    if (dead || (failsMulticast && address.address == ssdpMulticastAddress)) {
      lost++;
      if (!dead) {
        dead = true;
        unawaited(_datagrams.close());
      }
      return;
    }
    sent.add((text: ascii.decode(bytes), address: address.address, port: port, at: now()));
  }

  @override
  void close() {
    closed = true;
    if (!dead) {
      unawaited(_datagrams.close());
    }
  }

  /// Lost once the socket is closed, as on a real one
  void answer(String text, {String from = '192.168.1.10'}) {
    if (!closed && !dead) {
      _datagrams.add(Datagram(_bytes(text), InternetAddress(from), 1900));
    }
  }
}

/// The two sockets of the probe: the first one opened sends to the group, the second one sweeps
class _FakeSockets {
  _FakeSockets(this.now, {this.groupFailsMulticast = false});

  final Duration Function() now;
  final bool groupFailsMulticast;
  final List<_FakeTransport> opened = [];

  _FakeTransport open() {
    final transport = _FakeTransport(now, failsMulticast: opened.isEmpty && groupFailsMulticast);
    opened.add(transport);
    return transport;
  }

  _FakeTransport get group => opened[0];
  _FakeTransport get sweep => opened[1];

  List<_Sent> get sent => [for (final transport in opened) ...transport.sent];

  List<_Sent> get multicast => sent.where((s) => s.address == ssdpMulticastAddress).toList();

  List<_Sent> get unicast => sent.where((s) => s.address != ssdpMulticastAddress).toList();

  bool get closed => opened.every((transport) => transport.closed);

  /// An answer to the sweep, on its socket; [toGroup] for an answer to a request sent to the group
  void answer(String text, {String from = '192.168.1.10', bool toGroup = false}) =>
      (toGroup ? group : sweep).answer(text, from: from);
}

UpnpDevice _device(String name, String udn) => UpnpDevice(
  friendlyName: name,
  udn: udn,
  contentDirectoryControl: Uri.parse('http://192.168.1.10:8200/ctl/ContentDir'),
  contentDirectoryType: 'urn:schemas-upnp-org:service:ContentDirectory:1',
);

void main() {
  group('ssdpSearchRequest', () {
    test('builds the multicast request, byte for byte', () {
      expect(
        ascii.decode(ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: 'Android/14')),
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
        'USER-AGENT: Android/14 UPnP/1.1 Immuch360/3.3\r\n'
        '\r\n',
      );
      expect(
        ascii.decode(ssdpSearchRequest(searchTarget: ssdpContentDirectoryTarget, osToken: 'iOS/18')),
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:service:ContentDirectory:1\r\n'
        'USER-AGENT: iOS/18 UPnP/1.1 Immuch360/3.3\r\n'
        '\r\n',
      );
    });

    test('builds the unicast request with the target as HOST', () {
      expect(
        ascii.decode(
          ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: 'Android/14', host: '192.168.1.10'),
        ),
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 192.168.1.10:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: urn:schemas-upnp-org:device:MediaServer:1\r\n'
        'USER-AGENT: Android/14 UPnP/1.1 Immuch360/3.3\r\n'
        '\r\n',
      );
    });

    test('names the system and its major version', () async {
      final token = await ssdpOsToken();
      expect(token, matches(RegExp(r'^[A-Za-z]+(/\d+)?$')));
    });
  });

  group('parseSsdpResponse', () {
    test('reads the answers of minidlna and Gerbera', () {
      final minidlna = parseSsdpResponse(_fixture('minidlna_ssdp_answer.txt'))!;
      expect(minidlna.location, Uri.parse('http://172.17.0.4:8200/rootDesc.xml'));
      expect(minidlna.searchTarget, ssdpMediaServerTarget);
      expect(minidlna.udn, 'uuid:4d696e69-444c-164e-9d41-b64674b87a0b');
      expect(minidlna.server, contains('MiniDLNA'));

      final gerbera = parseSsdpResponse(_fixture('gerbera_ssdp_answer.txt'))!;
      expect(gerbera.location, Uri.parse('http://172.17.0.5:49494/upnp/description.xml'));
      expect(gerbera.udn, 'uuid:96dea31c-d605-4ef0-aeb8-0af1c9fd4d26');
    });

    test('reads header names without case, and lines ending with LF only', () {
      final lower = parseSsdpResponse(
        _bytes(
          'http/1.1 200 ok\r\nst: urn:schemas-upnp-org:service:ContentDirectory:1\r\n'
          'location: http://nas.local:9000/desc.xml?x=1\r\nusn: uuid:abc\r\n\r\n',
        ),
      )!;
      expect(lower.searchTarget, ssdpContentDirectoryTarget);
      expect(lower.location, Uri.parse('http://nas.local:9000/desc.xml?x=1'), reason: 'a host name is accepted');
      expect(lower.udn, 'uuid:abc', reason: 'a USN without "::" is the UDN');

      final lf = parseSsdpResponse(_bytes(_answer(lf: true)))!;
      expect(lf.location, Uri.parse('http://192.168.1.10:8200/rootDesc.xml'));
      expect(lf.udn, 'uuid:4d696e69-444c-164e-9d41-000000000001');
    });

    test('leaves out other statuses, other targets, missing or odd locations, and addresses off the network', () {
      SsdpResponse? parse(String text) => parseSsdpResponse(_bytes(text));

      expect(parse(_answer().replaceFirst('200 OK', '404 Not Found')), isNull);
      expect(parse('NOTIFY * HTTP/1.1\r\nLOCATION: http://192.168.1.10/a.xml\r\nNT: upnp:rootdevice\r\n\r\n'), isNull);
      expect(parse(_answer(st: 'urn:schemas-upnp-org:device:InternetGatewayDevice:1')), isNull);
      expect(parse(_answer(location: '')), isNull);
      expect(parse(_answer(location: 'ftp://192.168.1.10/a.xml')), isNull);
      expect(parse(_answer(location: 'not a url at all')), isNull);
      expect(parse(_answer(location: 'http://8.8.8.8:8200/rootDesc.xml')), isNull, reason: 'a public address');
      expect(parse(_answer(location: 'http://[2001:db8::1]:8200/rootDesc.xml')), isNull, reason: 'IPv6');
      expect(parse('garbage'), isNull);

      for (final host in ['10.0.2.2', '172.16.0.1', '172.31.255.1', '192.168.0.1', '169.254.1.1', '127.0.0.1']) {
        expect(parse(_answer(location: 'http://$host:8200/rootDesc.xml')), isNotNull, reason: host);
      }
      expect(parse(_answer(location: 'http://172.32.0.1:8200/rootDesc.xml')), isNull);
      expect(parse(_answer(usn: 'urn:schemas-upnp-org:device:MediaServer:1'))!.udn, isNull);
      expect(parse(_answer(usn: null))!.udn, isNull);
    });
  });

  group('SsdpProbe', () {
    /// Runs the probe in fake time as [drive] says, with fake sockets and the descriptions of [devices] by location
    /// ([describe] instead when given, with the number of the request for that location from 1)
    ({_FakeSockets transport, List<DiscoveredServer> found, List<Uri> fetched}) run({
      required void Function(FakeAsync async, _FakeSockets transport, Completer<void> done) drive,
      Map<String, UpnpDevice?> devices = const {},
      UpnpDevice? Function(Uri location, int attempt)? describe,
      List<String>? hosts,
      Duration fetchTime = Duration.zero,
      bool groupFailsMulticast = false,
    }) {
      late _FakeSockets transport;
      final found = <DiscoveredServer>[];
      final fetched = <Uri>[];
      fakeAsync((async) {
        transport = _FakeSockets(() => async.elapsed, groupFailsMulticast: groupFailsMulticast);
        final done = Completer<void>();
        final probe = SsdpProbe(
          bind: () async => transport.open(),
          osToken: () async => 'Android/14',
          localAddresses: () async => ['192.168.1.20'],
          fetchDescription: (location, request) async {
            fetched.add(location);
            await Future<void>.delayed(fetchTime);
            if (describe != null) {
              return describe(location, fetched.where((uri) => uri == location).length);
            }
            return devices[location.toString()];
          },
        );
        probe(DiscoveryRequest(hosts: hosts, done: done.future)).listen(found.add);
        async.flushMicrotasks();
        drive(async, transport, done);
        if (!done.isCompleted) {
          done.complete();
        }
        async.flushMicrotasks();
      });
      return (transport: transport, found: found, fetched: fetched);
    }

    test('searches the group at once, again at 400 ms and 1.2 s, and sweeps the /24 from 100 ms', () {
      final (:transport, found: _, fetched: _) = run(drive: (async, _, _) => async.elapse(const Duration(seconds: 3)));

      final multicast = transport.multicast;
      expect(
        [for (final s in multicast) (s.at.inMilliseconds, s.port)],
        [(0, 1900), (0, 1900), (400, 1900), (1200, 1900)],
      );
      expect(multicast[0].text, contains('ST: $ssdpMediaServerTarget\r\n'));
      expect(multicast[1].text, contains('ST: $ssdpContentDirectoryTarget\r\n'));
      expect(multicast[2].text, multicast[0].text);
      expect(multicast[3].text, multicast[0].text);

      final unicast = transport.unicast;
      final hosts = unicast.map((s) => s.address).toSet();
      expect(hosts, hasLength(253));
      expect(hosts, isNot(contains('192.168.1.20')), reason: 'not this device');
      expect(hosts, containsAll(['192.168.1.1', '192.168.1.254']));
      expect(unicast, hasLength(2 * 253), reason: 'the UPnP 1.1 request and the multicast one to each host');
      final first = unicast.where((s) => s.address == '192.168.1.1').toList();
      expect(first[0].text, contains('HOST: 192.168.1.1:1900\r\n'));
      expect(first[1].text, contains('HOST: 239.255.255.250:1900\r\n'));
      expect(unicast.every((s) => s.port == 1900 && s.text.contains('ST: $ssdpMediaServerTarget')), isTrue);
      expect(unicast.first.at, const Duration(milliseconds: 100));
      // 32 datagrams every 20 ms
      final batches = <Duration, int>{};
      for (final s in unicast) {
        batches[s.at] = (batches[s.at] ?? 0) + 1;
      }
      expect(batches.values.every((count) => count <= 32), isTrue);
      expect(batches.keys.toList()[1] - batches.keys.first, const Duration(milliseconds: 20));
      expect(unicast.last.at, const Duration(milliseconds: 100 + 20 * (2 * 253 ~/ 32)));
      expect(transport.opened, hasLength(2));
      expect(transport.group.sent.every((s) => s.address == ssdpMulticastAddress), isTrue, reason: 'a socket each');
      expect(transport.sweep.sent, hasLength(2 * 253));
      expect(transport.closed, isTrue, reason: 'closed when the discovery ended');
    });

    test('sweeps and hears the answers when the group socket dies at its first send, as on iOS', () {
      final (:transport, :found, fetched: _) = run(
        groupFailsMulticast: true,
        devices: {'http://192.168.1.10:8200/rootDesc.xml': _device('Gerbera', 'uuid:gerbera')},
        drive: (async, transport, _) {
          async.elapse(const Duration(milliseconds: 300));
          transport.answer(_answer());
          async.elapse(const Duration(seconds: 2));
        },
      );

      expect(transport.group.dead, isTrue);
      expect(transport.group.lost, 4, reason: 'the two requests of the start and the two repeats');
      expect(transport.multicast, isEmpty);
      expect(transport.unicast, hasLength(2 * 253), reason: 'the sweep went on its own socket');
      expect(found.single.displayName, 'Gerbera');
      expect(transport.closed, isTrue);
    });

    test('sweeps the hosts of the discovery instead of the subnet', () {
      final (:transport, found: _, fetched: _) = run(
        hosts: ['10.0.0.5', 'nas.local', '10.0.0.6'],
        drive: (async, _, _) => async.elapse(const Duration(seconds: 1)),
      );

      expect(transport.unicast.map((s) => s.address).toSet(), {'10.0.0.5', '10.0.0.6'});
    });

    test('fetches each server once, whatever it answered for, and leaves out what has no ContentDirectory', () {
      const minidlna = 'http://192.168.1.10:8200/rootDesc.xml';
      const router = 'http://192.168.1.1:5000/rootDesc.xml';
      const jellyfin = 'http://192.168.1.12:8096/dlna/abc/description.xml?client=1';
      final (transport: _, :found, :fetched) = run(
        devices: {
          minidlna: _device(' Living room ', 'uuid:4d696e69-444c-164e-9d41-000000000001'),
          router: null,
          jellyfin: _device('', ''),
        },
        drive: (async, transport, _) {
          transport.answer(_answer(location: minidlna));
          transport.answer(
            _answer(
              location: minidlna,
              st: ssdpContentDirectoryTarget,
              usn: 'uuid:4D696E69-444C-164E-9D41-000000000001::urn:schemas-upnp-org:service:ContentDirectory:1',
            ),
          );
          async.elapse(const Duration(milliseconds: 500));
          transport.answer(_answer(location: minidlna));
          transport.answer(_answer(location: router, usn: 'uuid:router::urn:schemas-upnp-org:device:MediaServer:1'));
          transport.answer(_answer(location: jellyfin, usn: null), from: '192.168.1.12');
          transport.answer(_answer(location: jellyfin, usn: null), from: '192.168.1.12');
          transport.answer('HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nLOCATION: http://192.168.1.3/x.xml\r\n\r\n');
          async.elapse(const Duration(seconds: 2));
        },
      );

      expect(fetched.map((uri) => uri.toString()), [minidlna, router, jellyfin]);
      expect(found, hasLength(2));
      final server = found.first;
      expect(server.host, '192.168.1.10');
      expect(server.displayName, 'Living room');
      expect(server.type, NetworkSourceType.dlna);
      expect(server.port, 8200);
      expect(server.useTls, isFalse);
      expect(server.path, '/rootDesc.xml');
      expect(server.origin, DiscoveryOrigin.ssdp);
      expect(server.discoveryId, 'uuid:4d696e69-444c-164e-9d41-000000000001');
      expect(server.address, '192.168.1.10');

      final unnamed = found.last;
      expect(unnamed.displayName, '192.168.1.12', reason: 'no friendly name: the host');
      expect(unnamed.path, '/dlna/abc/description.xml?client=1');
      expect(unnamed.discoveryId, isNull);
    });

    test('takes the UDN of the answer when the description has none, and https from the location', () {
      const location = 'https://192.168.1.14:8920/desc.xml';
      final (transport: _, :found, fetched: _) = run(
        devices: {location: _device('Secure', '')},
        drive: (async, transport, _) {
          transport.answer(_answer(location: location, usn: 'uuid:from-usn::urn:x'));
          async.elapse(const Duration(seconds: 1));
        },
      );

      expect(found.single.useTls, isTrue);
      expect(found.single.port, 8920);
      expect(found.single.discoveryId, 'uuid:from-usn');
    });

    test('asks again for a description that could not be read, on a later answer, three times at most', () {
      const slow = 'http://192.168.1.10:8200/rootDesc.xml';
      const broken = 'http://192.168.1.11:8200/rootDesc.xml';
      final (transport: _, :found, :fetched) = run(
        describe: (location, attempt) {
          if (location.toString() == slow) {
            return attempt < 2 ? null : _device('Slow', 'uuid:slow');
          }
          if (attempt == 2) {
            throw const SocketException('Connection reset by peer');
          }
          return null;
        },
        drive: (async, transport, _) {
          for (var i = 0; i < 5; i++) {
            transport.answer(_answer(usn: 'uuid:slow::urn:schemas-upnp-org:device:MediaServer:1'));
            transport.answer(
              _answer(location: broken, usn: 'uuid:broken::urn:schemas-upnp-org:device:MediaServer:1'),
              from: '192.168.1.11',
            );
            async.elapse(const Duration(milliseconds: 300));
          }
        },
      );

      expect(found.map((s) => s.displayName), ['Slow']);
      expect(fetched.where((uri) => uri.toString() == slow), hasLength(2), reason: 'not again once read');
      expect(fetched.where((uri) => uri.toString() == broken), hasLength(3), reason: 'a failure, a throw, a failure');
    });

    test('sends nothing more and emits nothing once the discovery ended', () {
      final (:transport, :found, :fetched) = run(
        devices: {'http://192.168.1.10:8200/rootDesc.xml': _device('Late', 'uuid:late')},
        fetchTime: const Duration(seconds: 1),
        drive: (async, transport, done) {
          async.elapse(const Duration(milliseconds: 10));
          transport.answer(_answer());
          async.elapse(const Duration(milliseconds: 40));
          done.complete();
          async.flushMicrotasks();
          transport.answer(_answer(location: 'http://192.168.1.11:8200/rootDesc.xml', usn: 'uuid:other'));
          async.elapse(const Duration(seconds: 3));
        },
      );

      expect(transport.sent, hasLength(2), reason: 'the two requests of the start only');
      expect(transport.closed, isTrue);
      expect(fetched, hasLength(1), reason: 'the description asked for before the end');
      expect(found, isEmpty, reason: 'it came after the end');
    });

    test('ends at once when no socket can be opened', () async {
      final probe = SsdpProbe(
        bind: () async => throw const SocketException('no network'),
        osToken: () async => 'Android/14',
      );

      final found = await probe(DiscoveryRequest(done: Completer<void>().future)).toList();

      expect(found, isEmpty);
    });

    test('a real socket binds again on its port once a failed send closed it, and keeps receiving', () async {
      final transport = await bindSsdpTransport(address: InternetAddress.loopbackIPv4);
      addTearDown(transport.close);
      final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(receiver.close);
      final received = StreamIterator(
        receiver
            .where((event) => event == RawSocketEvent.read)
            .map((_) => receiver.receive())
            .where((datagram) => datagram != null)
            .cast<Datagram>(),
      );
      final answers = StreamIterator(transport.datagrams);
      final search = ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: 'Linux/6');

      transport.send(search, receiver.address, receiver.port);
      expect(await received.moveNext(), isTrue);
      final port = received.current.port;

      // Linux refuses a datagram to port 0, and dart:io closes the socket then, as iOS does on a send to the group
      transport.send(search, InternetAddress.loopbackIPv4, 0);
      await Future<void>.delayed(Duration.zero);
      // Sent once the new socket is bound
      transport.send(search, receiver.address, receiver.port);

      expect(await received.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(received.current.port, port, reason: 'the same port, for the answers to what was sent before');
      receiver.send(utf8.encode('HTTP/1.1 200 OK\r\n\r\n'), InternetAddress.loopbackIPv4, port);
      expect(await answers.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(ascii.decode(answers.current.data), startsWith('HTTP/1.1 200 OK'));
    });

    test('a real socket sends and closes without an error', () async {
      final transport = await bindSsdpTransport(address: InternetAddress.loopbackIPv4);
      final receiver = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(receiver.close);

      transport.send(
        ssdpSearchRequest(searchTarget: ssdpMediaServerTarget, osToken: 'Linux/6'),
        receiver.address,
        receiver.port,
      );
      final datagram = await receiver
          .where((event) => event == RawSocketEvent.read)
          .map((_) => receiver.receive())
          .first;

      expect(ascii.decode(datagram!.data), startsWith('M-SEARCH * HTTP/1.1\r\n'));
      transport.close();
    });
  });
}
