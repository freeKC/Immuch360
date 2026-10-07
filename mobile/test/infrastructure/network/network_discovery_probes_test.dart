import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';
import 'package:immich_mobile/infrastructure/network/plex/gdm.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_discovery.dart';

/// A TCP server on 127.0.0.1 that answers each connection with [reply] once it received a whole NetBIOS message
/// (nothing when [reply] is null), and keeps what it received
class _FakeSmbServer {
  _FakeSmbServer._(this._server, this.reply) {
    _server.listen((socket) {
      final received = BytesBuilder(copy: false);
      socket.listen((data) {
        received.add(data);
        final bytes = received.toBytes();
        if (bytes.length >= 4) {
          final length = (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
          if (bytes.length >= 4 + length && requests.length < 100) {
            requests.add(bytes);
            final answer = reply;
            if (answer != null) {
              socket.add(answer);
            }
          }
        }
      }, onError: (Object _) {});
      sockets.add(socket);
    });
  }

  static Future<_FakeSmbServer> start(List<int>? reply) async =>
      _FakeSmbServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), reply);

  final ServerSocket _server;
  final List<int>? reply;
  final List<Uint8List> requests = [];
  final List<Socket> sockets = [];

  int get port => _server.port;

  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await _server.close();
  }

  /// A NetBIOS session message holding an SMB2 header with the status [status]
  static List<int> smb2Reply({int status = 0}) {
    final message = Uint8List(64 + 8);
    message.setRange(0, 4, [0xFE, 0x53, 0x4D, 0x42]);
    message[4] = 64;
    message.buffer.asByteData().setUint32(8, status, Endian.little);
    return [0, 0, 0, message.length, ...message];
  }
}

/// An HTTP server on 127.0.0.1 answering with [handler] once it completes, keeping the method and path of each request
class _FakeHttpServer {
  _FakeHttpServer._(this._server, FutureOr<void> Function(HttpRequest request) handler) {
    _server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      await handler(request);
      // The client may be gone by then
      request.response.close().ignore();
    });
  }

  static Future<_FakeHttpServer> start(FutureOr<void> Function(HttpRequest request) handler) async =>
      _FakeHttpServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), handler);

  final HttpServer _server;
  final List<String> requests = [];

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

/// A port of 127.0.0.1 where nothing listens
Future<int> _closedPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// Plain WebDAV: OPTIONS gets a DAV header
void _davHandler(HttpRequest request) {
  if (request.method == 'OPTIONS') {
    request.response.headers.set('DAV', '1, 2');
  } else {
    request.response.statusCode = HttpStatus.methodNotAllowed;
  }
}

/// WebDAV behind Basic authentication, like Apache or Synology: everything gets a 401
void _authHandler(HttpRequest request) {
  request.response.statusCode = HttpStatus.unauthorized;
  request.response.headers.set('WWW-Authenticate', 'Basic realm="WebDAV"');
}

/// A web server that is not a WebDAV server
void _webHandler(HttpRequest request) {
  request.response.headers.contentType = ContentType.html;
  request.response.write('<html></html>');
}

DiscoveryRequest _request({List<String>? hosts, Future<void>? done}) =>
    DiscoveryRequest(hosts: hosts, done: done ?? Completer<void>().future);

/// A discovery that already ended
Future<DiscoveryRequest> _endedRequest() async {
  final request = _request(done: Future<void>.value());
  await Future<void>.delayed(Duration.zero);
  return request;
}

/// A plain web server on "/" that ends the discovery as it answers the first request, and a WebDAV server under
/// remote.php: without the end of the discovery, a confirmation would go on to a PROPFIND and to the other path
void Function(HttpRequest request) _endingAtFirstRequest(Completer<void> done) => (request) {
  if (!done.isCompleted) {
    done.complete();
  }
  if (request.uri.path.startsWith('/remote.php/webdav')) {
    _davHandler(request);
  } else {
    _webHandler(request);
  }
};

/// A confirmer whose Tapo certificate check says [isTapo], and remembers the hosts and ports it was asked about
class _TapoConfirmer extends ServerConfirmer {
  _TapoConfirmer({required this.isTapo}) : super(httpTimeout: const Duration(seconds: 1));

  final bool isTapo;
  final List<String> checked = [];

  @override
  Future<bool> isTapoCamera(String host, {int port = 443, DiscoveryRequest? request}) async {
    checked.add('$host:$port');
    return isTapo;
  }
}

/// Waits until [condition] holds, 5 seconds at most
Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 5)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  const confirmer = ServerConfirmer(smbTimeout: Duration(milliseconds: 500), httpTimeout: Duration(seconds: 1));

  group('ScanPort.parse', () {
    test('reads port:type[:tls] entries separated by commas', () {
      expect(ScanPort.parse('1445:smb,1880:webdav'), const [
        ScanPort(1445, NetworkSourceType.smb),
        ScanPort(1880, NetworkSourceType.webdav),
      ]);
      expect(ScanPort.parse(' 8443:WebDAV:TLS , 139:SMB '), const [
        ScanPort(8443, NetworkSourceType.webdav, useTls: true),
        ScanPort(139, NetworkSourceType.smb),
      ]);
    });

    test('leaves out what does not read', () {
      expect(ScanPort.parse(''), isEmpty);
      expect(ScanPort.parse('1445'), isEmpty);
      expect(ScanPort.parse('1445:ftp'), isEmpty);
      expect(ScanPort.parse('0:smb,70000:smb,x:smb'), isEmpty);
      expect(ScanPort.parse('1880:webdav:ssl,1880:webdav:tls:x'), isEmpty);
      expect(ScanPort.parse('1445:smb:tls'), const [ScanPort(1445, NetworkSourceType.smb)], reason: 'no TLS for SMB');
      expect(ScanPort.parse(',,1445:smb,'), const [ScanPort(1445, NetworkSourceType.smb)]);
    });

    test('is empty without IMMUCH_SCAN_PORTS', () {
      expect(ScanPort.fromEnvironment(), isEmpty);
    });
  });

  group('SMB2 NEGOTIATE', () {
    test('builds a NetBIOS session message holding an SMB2 NEGOTIATE with the five dialects', () {
      final packet = ServerConfirmer.smb2NegotiateRequest();
      final data = ByteData.sublistView(packet);

      expect(packet[0], 0, reason: 'session message');
      final length = (packet[1] << 16) | (packet[2] << 8) | packet[3];
      expect(packet.length, 4 + length);
      expect(packet.sublist(4, 8), [0xFE, 0x53, 0x4D, 0x42]);
      expect(data.getUint16(4 + 4, Endian.little), 64, reason: 'header StructureSize');
      expect(data.getUint16(4 + 12, Endian.little), 0, reason: 'command NEGOTIATE');
      const body = 4 + 64;
      expect(data.getUint16(body, Endian.little), 36, reason: 'NEGOTIATE StructureSize');
      expect(data.getUint16(body + 2, Endian.little), 5, reason: 'DialectCount');
      expect(
        [for (var i = 0; i < 5; i++) data.getUint16(body + 36 + 2 * i, Endian.little)],
        [0x0202, 0x0210, 0x0300, 0x0302, 0x0311],
      );
      final contextOffset = data.getUint32(body + 28, Endian.little);
      expect(contextOffset % 8, 0);
      expect(data.getUint16(body + 32, Endian.little), 1, reason: 'one negotiate context');
      expect(data.getUint16(4 + contextOffset, Endian.little), 1, reason: 'preauthentication integrity');
      final contextLength = data.getUint16(4 + contextOffset + 2, Endian.little);
      expect(4 + contextOffset + 8 + contextLength, packet.length);
    });

    test('tells an SMB2 reply from anything else', () {
      expect(ServerConfirmer.isSmb2Reply(_FakeSmbServer.smb2Reply()), isTrue);
      expect(ServerConfirmer.isSmb2Reply([0, 0, 0, 4, 0xFE, 0x53, 0x4D, 0x42]), isTrue);
      expect(ServerConfirmer.isSmb2Reply([0, 0, 0, 4, 0xFF, 0x53, 0x4D, 0x42]), isFalse, reason: 'SMB1');
      expect(ServerConfirmer.isSmb2Reply('HTTP/1.1 400 Bad Request'.codeUnits), isFalse);
      expect(ServerConfirmer.isSmb2Reply([0, 0, 0, 4, 0xFE, 0x53]), isFalse);
    });

    test('confirms a server that answers in SMB2, even with an error status', () async {
      for (final reply in [_FakeSmbServer.smb2Reply(), _FakeSmbServer.smb2Reply(status: 0xC000000D)]) {
        final server = await _FakeSmbServer.start(reply);
        addTearDown(server.close);

        expect(await confirmer.isSmb('127.0.0.1', server.port), isTrue);
        expect(server.requests.single.sublist(4, 8), [0xFE, 0x53, 0x4D, 0x42]);
      }
    });

    test('does not confirm a server that answers something else, nothing, or does not listen', () async {
      final http = await _FakeSmbServer.start('HTTP/1.1 400 Bad Request\r\n\r\n'.codeUnits);
      addTearDown(http.close);
      final silent = await _FakeSmbServer.start(null);
      addTearDown(silent.close);

      expect(await confirmer.isSmb('127.0.0.1', http.port), isFalse);
      final watch = Stopwatch()..start();
      expect(await confirmer.isSmb('127.0.0.1', silent.port), isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)), reason: 'gives up at its timeout');
      expect(await confirmer.isSmb('127.0.0.1', await _closedPort()), isFalse);
    });

    test('gives up when the discovery ends, and sends nothing once it ended', () async {
      final silent = await _FakeSmbServer.start(null);
      addTearDown(silent.close);
      const patient = ServerConfirmer(smbTimeout: Duration(seconds: 10));
      final done = Completer<void>();

      final verdict = patient.isSmb('127.0.0.1', silent.port, request: _request(done: done.future));
      await _until(() => silent.requests.isNotEmpty);
      final watch = Stopwatch()..start();
      done.complete();

      expect(await verdict, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'not the timeout of the NEGOTIATE');

      final smb = await _FakeSmbServer.start(_FakeSmbServer.smb2Reply());
      addTearDown(smb.close);
      expect(await confirmer.isSmb('127.0.0.1', smb.port, request: await _endedRequest()), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(smb.sockets, isEmpty, reason: 'no connection');
    });
  });

  group('WebDAV confirmation', () {
    test('confirms a server whose OPTIONS answer has a DAV header', () async {
      final server = await _FakeHttpServer.start(_davHandler);
      addTearDown(server.close);

      expect(await confirmer.webDavPath('127.0.0.1', server.port, useTls: false), '/');
      expect(server.requests, ['OPTIONS /']);
    });

    test('confirms a server that answers PROPFIND with a 401 and a WWW-Authenticate header', () async {
      final server = await _FakeHttpServer.start(_authHandler);
      addTearDown(server.close);

      expect(await confirmer.webDavPath('127.0.0.1', server.port, useTls: false), '/');
      expect(server.requests, ['OPTIONS /', 'PROPFIND /']);
    });

    test('confirms a server that answers PROPFIND with a multistatus', () async {
      final server = await _FakeHttpServer.start((request) {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
        }
      });
      addTearDown(server.close);

      expect(await confirmer.webDavPath('127.0.0.1', server.port, useTls: false), '/');
    });

    test('does not confirm a plain web server, nor a 401 without WWW-Authenticate', () async {
      final web = await _FakeHttpServer.start(_webHandler);
      addTearDown(web.close);
      final bare401 = await _FakeHttpServer.start((request) => request.response.statusCode = HttpStatus.unauthorized);
      addTearDown(bare401.close);

      expect(await confirmer.webDavPath('127.0.0.1', web.port, useTls: false), isNull);
      expect(await confirmer.webDavPath('127.0.0.1', bare401.port, useTls: false), isNull);
    });

    test('tries the next path on a web server, and gives up at once when nothing answers', () async {
      final server = await _FakeHttpServer.start((request) {
        if (request.uri.path.startsWith('/remote.php/webdav')) {
          _authHandler(request);
        } else {
          _webHandler(request);
        }
      });
      addTearDown(server.close);

      expect(
        await confirmer.webDavPath('127.0.0.1', server.port, useTls: false, paths: const ['/', '/remote.php/webdav']),
        '/remote.php/webdav',
      );
      expect(
        await confirmer.webDavPath('127.0.0.1', await _closedPort(), useTls: false, paths: const ['/', '/other']),
        isNull,
      );
    });

    test('does not confirm a plain HTTP server asked over TLS', () async {
      final server = await _FakeHttpServer.start(_davHandler);
      addTearDown(server.close);

      expect(await confirmer.webDavPath('127.0.0.1', server.port, useTls: true), isNull);
    });

    test('sends no other request once the discovery ended', () async {
      final done = Completer<void>();
      final server = await _FakeHttpServer.start(_endingAtFirstRequest(done));
      addTearDown(server.close);

      final path = await confirmer.webDavPath(
        '127.0.0.1',
        server.port,
        useTls: false,
        paths: const ['/', '/remote.php/webdav'],
        request: _request(done: done.future),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(path, isNull);
      expect(server.requests, ['OPTIONS /'], reason: 'no PROPFIND, no other path');

      final dav = await _FakeHttpServer.start(_davHandler);
      addTearDown(dav.close);
      expect(await confirmer.webDavPath('127.0.0.1', dav.port, useTls: false, request: await _endedRequest()), isNull);
      expect(dav.requests, isEmpty, reason: 'nothing is sent once the discovery ended');
    });

    test('drops the request under way when the discovery ends, without waiting for its timeout', () async {
      final answer = Completer<void>();
      addTearDown(() {
        if (!answer.isCompleted) {
          answer.complete();
        }
      });
      final server = await _FakeHttpServer.start((_) => answer.future);
      addTearDown(server.close);
      const patient = ServerConfirmer(httpTimeout: Duration(seconds: 10));
      final done = Completer<void>();

      final path = patient.webDavPath(
        '127.0.0.1',
        server.port,
        useTls: false,
        paths: const ['/', '/remote.php/webdav'],
        request: _request(done: done.future),
      );
      await _until(() => server.requests.isNotEmpty);
      final watch = Stopwatch()..start();
      done.complete();

      expect(await path, isNull);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'the client is closed with the discovery');
      answer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.requests, ['OPTIONS /']);
    });
  });

  group('SubnetScanProbe', () {
    test('finds and confirms the SMB and WebDAV servers of the hosts given, and leaves the others out', () async {
      final smb = await _FakeSmbServer.start(_FakeSmbServer.smb2Reply());
      addTearDown(smb.close);
      final notSmb = await _FakeSmbServer.start('nope'.codeUnits);
      addTearDown(notSmb.close);
      final dav = await _FakeHttpServer.start(_authHandler);
      addTearDown(dav.close);
      final web = await _FakeHttpServer.start(_webHandler);
      addTearDown(web.close);
      final closed = await _closedPort();

      final probe = SubnetScanProbe(
        confirmer: confirmer,
        ports: [
          ScanPort(notSmb.port, NetworkSourceType.smb),
          ScanPort(web.port, NetworkSourceType.webdav),
          ScanPort(closed, NetworkSourceType.webdav),
        ],
        extraPorts: [ScanPort(smb.port, NetworkSourceType.smb), ScanPort(dav.port, NetworkSourceType.webdav)],
        localAddresses: () async => fail('the hosts are given'),
        reverseLookup: (address) async => address == '127.0.0.1' ? 'localhost' : null,
      );

      final found = await probe(_request(hosts: ['127.0.0.1'])).toList();

      expect(found, hasLength(2));
      final smbFound = found.firstWhere((s) => s.type == NetworkSourceType.smb);
      expect(smbFound.host, '127.0.0.1');
      expect(smbFound.port, smb.port);
      expect(smbFound.displayName, 'localhost');
      expect(smbFound.origin, DiscoveryOrigin.scan);
      final davFound = found.firstWhere((s) => s.type == NetworkSourceType.webdav);
      expect(davFound.port, dav.port);
      expect(davFound.useTls, isFalse);
      expect(davFound.path, '');
      expect(smb.requests, hasLength(1), reason: 'the NEGOTIATE goes on the connection of the scan');
    });

    test('scans the /24 of the local address, the other ports on the hosts that answered only', () async {
      final tried = <String>[];
      final probe = SubnetScanProbe(
        confirmer: confirmer,
        connect: (host, port, timeout) async {
          tried.add('$host:$port');
          if (host == '192.168.1.7') {
            throw const SocketException('refused', osError: OSError('Connection refused', 111));
          }
          throw const SocketException('Connection timed out');
        },
        localAddresses: () async => ['192.168.1.5'],
        reverseLookup: (_) async => null,
      );

      expect(await probe(_request()).toList(), isEmpty);

      final hosts = tried.map((t) => t.split(':').first).toSet();
      expect(hosts, hasLength(253));
      expect(hosts, isNot(contains('192.168.1.5')), reason: 'not this device');
      expect(hosts, containsAll(['192.168.1.1', '192.168.1.254']));
      for (final host in hosts) {
        expect(tried, containsAll(['$host:445', '$host:80']));
      }
      final others = tried.where((t) => !t.endsWith(':445') && !t.endsWith(':80')).toList();
      expect(others.map((t) => t.split(':').first).toSet(), {'192.168.1.7'});
      expect(others, hasLength(6), reason: 'the five WebDAV ports and RTSP');
    });

    test('stops once the discovery ended', () async {
      final done = Completer<void>();
      var tried = 0;
      final probe = SubnetScanProbe(
        confirmer: confirmer,
        maxInFlight: 4,
        maxBurst: 4,
        connect: (host, port, timeout) async {
          tried++;
          if (tried == 8 && !done.isCompleted) {
            done.complete();
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw const SocketException('Connection timed out');
        },
        localAddresses: () async => ['10.0.2.15'],
      );

      await probe(_request(done: done.future)).toList();

      expect(tried, lessThan(20));
    });

    test('drops the confirmations under way once the discovery ended: no other request, no reverse lookup', () async {
      final done = Completer<void>();
      final server = await _FakeHttpServer.start(_endingAtFirstRequest(done));
      addTearDown(server.close);
      final looked = <String>[];
      final probe = SubnetScanProbe(
        confirmer: confirmer,
        ports: const [],
        extraPorts: [ScanPort(server.port, NetworkSourceType.webdav)],
        localAddresses: () async => fail('the hosts are given'),
        reverseLookup: (address) async {
          looked.add(address);
          return 'localhost';
        },
      );

      final found = await probe(_request(hosts: ['127.0.0.1'], done: done.future)).toList();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(found, isEmpty);
      expect(server.requests, ['OPTIONS /'], reason: 'the WebDAV under remote.php is not tried');
      expect(looked, isEmpty);
    });

    test('tries the other ports of the hosts that answered within the discovery, on two subnets and extra ports', () {
      for (final extraPorts in [
        const <ScanPort>[],
        const [ScanPort(1445, NetworkSourceType.smb)],
      ]) {
        fakeAsync((async) {
          const alive = {'192.168.1.254', '10.0.0.254', '192.168.1.2'};
          final tried = <String, Duration>{};
          final timeouts = <Duration>{};
          final probe = SubnetScanProbe(
            confirmer: confirmer,
            extraPorts: extraPorts,
            connect: (host, port, timeout) async {
              tried['$host:$port'] = async.elapsed;
              timeouts.add(timeout);
              if (alive.contains(host)) {
                await Future<void>.delayed(const Duration(milliseconds: 5));
                throw const SocketException('refused', osError: OSError('Connection refused', 111));
              }
              // A host that does not exist: the whole timeout
              await Future<void>.delayed(timeout);
              throw const SocketException('Connection timed out');
            },
            localAddresses: () async => ['192.168.1.5', '10.0.0.7'],
            reverseLookup: (_) async => null,
          );
          final service = NetworkDiscoveryService(probes: [probe.call]);
          Duration? endedAt;
          service.discover().listen(null, onDone: () => endedAt = async.elapsed);

          async.elapse(NetworkDiscoveryService.defaultTimeout + const Duration(seconds: 1));

          expect(endedAt, isNotNull);
          expect(endedAt, lessThan(NetworkDiscoveryService.defaultTimeout), reason: 'the scan ended by itself');
          final firstPorts = [445, 80, ...extraPorts.map((port) => port.port)];
          for (final subnet in ['192.168.1', '10.0.0']) {
            for (var i = 1; i < 255; i++) {
              if ('$subnet.$i' == '192.168.1.5' || '$subnet.$i' == '10.0.0.7') {
                continue;
              }
              for (final port in firstPorts) {
                expect(tried, contains('$subnet.$i:$port'));
              }
            }
          }
          for (final host in alive) {
            for (final port in [5005, 5006, 443, 8080, 8443, 554]) {
              expect(tried, contains('$host:$port'));
            }
          }
          expect(tried.length, 506 * firstPorts.length + alive.length * 6, reason: 'nothing else, nothing twice');
          expect(timeouts.every((timeout) => timeout >= const Duration(milliseconds: 250)), isTrue);
        });
      }
    });

    test('a host answering on the RTSP port with the certificate of a Tapo camera is a camera on 443', () async {
      final rtsp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(rtsp.close);
      rtsp.listen((socket) => socket.destroy());
      final tapo = _TapoConfirmer(isTapo: true);
      final probe = SubnetScanProbe(
        confirmer: tapo,
        ports: [ScanPort(rtsp.port, NetworkSourceType.tapo)],
        localAddresses: () async => fail('the hosts are given'),
        reverseLookup: (address) async => null,
      );

      final found = await probe(_request(hosts: ['127.0.0.1'])).toList();

      final camera = found.single;
      expect(camera.type, NetworkSourceType.tapo);
      expect(camera.host, '127.0.0.1');
      expect(camera.port, 443, reason: 'where a camera is reached, as TDP finds it');
      expect(camera.useTls, isTrue);
      expect(camera.displayName, '127.0.0.1', reason: 'no English text made outside the pages');
      expect(camera.origin, DiscoveryOrigin.scan);
      expect(tapo.checked, ['127.0.0.1:443']);
    });

    test('a host answering on the RTSP port without the certificate of a Tapo camera is nothing', () async {
      final rtsp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(rtsp.close);
      rtsp.listen((socket) => socket.destroy());
      final probe = SubnetScanProbe(
        confirmer: _TapoConfirmer(isTapo: false),
        ports: [ScanPort(rtsp.port, NetworkSourceType.tapo)],
        localAddresses: () async => fail('the hosts are given'),
        reverseLookup: (address) async => null,
      );

      expect(await probe(_request(hosts: ['127.0.0.1'])).toList(), isEmpty);
    });

    test('tries RTSP last, for the Tapo cameras, and never takes it from IMMUCH_SCAN_PORTS', () {
      expect(ScanPort.defaults.last, const ScanPort(554, NetworkSourceType.tapo));
      expect(ScanPort.defaults.where((port) => port.type == NetworkSourceType.tapo), hasLength(1));
      expect(ScanPort.parse('554:tapo'), isEmpty);
    });

    test('sizes the connections at once and their timeout to the scan budget', () {
      const probe = SubnetScanProbe(confirmer: confirmer);
      expect(probe.plan(10), (64, const Duration(milliseconds: 400)));
      final (oneSubnet, oneTimeout) = probe.plan(506);
      expect((506 / oneSubnet).ceil() * oneTimeout.inMilliseconds, lessThanOrEqualTo(3000));
      final (twoSubnets, twoTimeout) = probe.plan(1012);
      expect(twoSubnets, inInclusiveRange(65, 128));
      expect((1012 / twoSubnets).ceil() * twoTimeout.inMilliseconds, lessThanOrEqualTo(3000));
      expect(probe.plan(5000), (128, const Duration(milliseconds: 250)), reason: 'no shorter than the minimum');
    });

    test('lists the hosts of a /24 but this one', () {
      final hosts = SubnetScanProbe.subnetHostsOf('10.0.2.15');
      expect(hosts, hasLength(253));
      expect(hosts.first, '10.0.2.1');
      expect(hosts, contains('10.0.2.2'));
      expect(hosts, isNot(contains('10.0.2.15')));
      expect(hosts.last, '10.0.2.254');
      expect(SubnetScanProbe.subnetHostsOf('fe80::1'), isEmpty);
    });

    test('scans the private addresses of the Wi-Fi and Ethernet interfaces only', () {
      InternetAddress ip(String text) => InternetAddress(text);
      expect(
        SubnetScanProbe.lanAddressesOf([
          ('lo', ip('127.0.0.1')),
          ('wlan0', ip('169.254.3.4')),
          ('rmnet_data0', ip('10.120.4.5')),
          ('tun0', ip('10.8.0.2')),
          ('wlan0', ip('100.64.1.2')),
          ('wlan0', ip('192.168.1.23')),
          ('eth0', ip('192.168.1.24')),
          ('eth0', ip('10.0.2.15')),
          ('eth1', ip('172.16.5.5')),
        ]),
        ['192.168.1.23', '10.0.2.15'],
      );
      // Hotspot, Wi-Fi Direct and tethering left out, the main Wi-Fi interface first
      expect(
        SubnetScanProbe.lanAddressesOf([
          ('ap0', ip('192.168.43.1')),
          ('swlan0', ip('192.168.44.1')),
          ('p2p-wlan0-0', ip('192.168.49.1')),
          ('rndis0', ip('192.168.42.129')),
          ('bt-pan', ip('192.168.45.1')),
          ('ncm0', ip('192.168.46.1')),
          ('bridge100', ip('172.20.10.1')),
          ('usb0', ip('10.10.10.2')),
          ('wlan1', ip('10.20.0.1')),
          ('wlan0', ip('192.168.1.23')),
        ]),
        ['192.168.1.23', '10.20.0.1'],
      );
    });
  });

  group('MdnsProbe', () {
    MdnsService service(String type, {String host = '192.168.1.20', int port = 445, Map<String, String>? txt}) =>
        MdnsService(name: 'Living room NAS', type: type, host: host, port: port, attributes: txt ?? const {});

    test('turns SMB and WebDAV announcements into servers', () async {
      const probe = MdnsProbe(confirmer: confirmer);

      final smb = (await probe.serverOf(service('_smb._tcp', host: 'nas.local.')))!;
      expect(smb.type, NetworkSourceType.smb);
      expect(smb.host, 'nas.local');
      expect(smb.displayName, 'Living room NAS');
      expect(smb.origin, DiscoveryOrigin.mdns);

      final dav = (await probe.serverOf(service('_webdav._tcp', port: 5005, txt: {'path': 'dav/photos/'})))!;
      expect(dav.type, NetworkSourceType.webdav);
      expect(dav.useTls, isFalse);
      expect(dav.path, '/dav/photos');

      final davs = (await probe.serverOf(service('_webdavs._tcp', port: 5006, txt: {'root': '/'})))!;
      expect(davs.useTls, isTrue);
      expect(davs.path, '');

      expect(await probe.serverOf(service('_ipp._tcp', port: 631)), isNull);
    });

    test('tells a phone sharing its gallery by its TXT record, and leaves the own share of this device out', () async {
      final probe = MdnsProbe(confirmer: confirmer, ownPhoneShareId: () => 'own0000000000000');
      MdnsService phone(String id) => MdnsService(
        name: 'Immuch360 on Pixel',
        type: '_webdav._tcp',
        host: '192.168.1.42',
        port: 8360,
        attributes: {'path': '/', 'u': 'phone1234', 'app': 'immuch360', 'id': id, 'v': '1'},
      );

      final found = (await probe.serverOf(phone('a1b2c3d4e5f60718')))!;
      expect(found.isPhoneShare, isTrue);
      expect(found.type, NetworkSourceType.webdav);
      expect(found.displayName, 'Immuch360 on Pixel');
      expect(found.username, 'phone1234');
      expect(found.discoveryId, 'a1b2c3d4e5f60718');
      expect(found.port, 8360);
      expect(found.path, '');

      expect(await probe.serverOf(phone('own0000000000000')), isNull, reason: 'this phone');

      final plain = (await probe.serverOf(service('_webdav._tcp', port: 5005, txt: {'u': 'admin', 'id': 'x'})))!;
      expect(plain.isPhoneShare, isFalse);
      expect(plain.username, isNull, reason: 'only a phone share announces its user name');
      expect(plain.discoveryId, isNull);
    });

    test('reads the id of its own phone share from the store, none without a store', () {
      expect(storedPhoneShareId(), isNull);
    });

    test('keeps a web server announced over _http._tcp only when it speaks WebDAV', () async {
      final dav = await _FakeHttpServer.start(_davHandler);
      addTearDown(dav.close);
      final web = await _FakeHttpServer.start(_webHandler);
      addTearDown(web.close);
      const probe = MdnsProbe(confirmer: confirmer);

      final found = await probe.serverOf(service('_http._tcp', host: '127.0.0.1', port: dav.port));
      expect(found?.type, NetworkSourceType.webdav);
      expect(found?.port, dav.port);
      expect(await probe.serverOf(service('_http._tcp', host: '127.0.0.1', port: web.port)), isNull);
    });

    test('confirms nothing and looks nothing up once the discovery ended', () async {
      final done = Completer<void>();
      // A WebDAV server that ends the discovery as it answers
      final dav = await _FakeHttpServer.start((request) {
        if (!done.isCompleted) {
          done.complete();
        }
        _davHandler(request);
      });
      addTearDown(dav.close);
      final looked = <String>[];
      final probe = MdnsProbe(
        confirmer: confirmer,
        lookup: (host) async {
          looked.add(host);
          return '192.168.1.20';
        },
      );
      final request = _request(done: done.future);

      expect(
        await probe.serverOf(
          service('_http._tcp', host: '127.0.0.1', port: dav.port),
          request: request,
        ),
        isNull,
      );
      expect(dav.requests, ['OPTIONS /']);
      expect(await probe.serverOf(service('_smb._tcp', host: 'nas.local'), request: request), isNull);
      expect(looked, isEmpty);
    });

    test('browses every service type and ends when the browsers end, even failing ones', () async {
      final browsed = <String>[];
      final probe = MdnsProbe(
        confirmer: confirmer,
        lookup: (host) async => host == 'nas.local' ? '192.168.1.20' : null,
        browse: (type, until) {
          browsed.add(type);
          return switch (type) {
            '_smb._tcp' => Stream.value(service(type, host: 'nas.local')),
            '_webdav._tcp' => throw StateError('no mDNS'),
            '_https._tcp' => Stream.error(StateError('denied')),
            _ => const Stream.empty(),
          };
        },
      );

      final found = await probe(_request()).toList();

      expect(browsed, MdnsProbe.serviceTypes);
      expect(found.single.host, 'nas.local');
      expect(found.single.address, '192.168.1.20');
    });

    test('bonsoir without its platform side ends without an error', () async {
      final services = await bonsoirBrowse('_smb._tcp', Future<void>.delayed(const Duration(seconds: 5))).toList();
      expect(services, isEmpty);
    });
  });

  test('the discovery of the app runs mDNS, the scan, SSDP, GDM and TDP', () {
    final probes = networkDiscoveryProbes(extraPorts: const []);

    expect(probes, hasLength(5));
    expect(probes[2], const SsdpProbe().call);
    expect(probes[3], const GdmProbe().call);
    expect(probes[4], const TapoDiscoveryProbe().call);
  });
}
