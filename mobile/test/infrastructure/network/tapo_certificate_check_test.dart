// The scan takes a host answering on the RTSP port for a Tapo camera only when it shows the certificate of one on 443:
// "TPRI" in its subject or its issuer. The check refuses the TLS handshake as soon as the certificate is seen, so the
// host never receives a byte of the application. The certificates are made with openssl at test time, in a temporary
// folder: no key is kept in the repository.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/network_discovery.service.dart';
import 'package:immich_mobile/infrastructure/network/network_discovery_probes.dart';

/// A self-signed certificate and its key for [subject], null when openssl is not there
Future<SecurityContext?> _context(Directory folder, String name, String subject) async {
  final key = '${folder.path}/$name.key';
  final certificate = '${folder.path}/$name.pem';
  final ProcessResult result;
  try {
    result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      key,
      '-out',
      certificate,
      '-days',
      '2',
      '-subj',
      subject,
    ]);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return SecurityContext()
    ..useCertificateChain(certificate)
    ..usePrivateKey(key);
}

/// A TLS server on 127.0.0.1 with [context], counting the handshakes that ended and the bytes received after one
class _TlsServer {
  _TlsServer._(this._server, SecurityContext context) {
    _server.listen((socket) async {
      try {
        final secure = await SecureSocket.secureServer(socket, context);
        handshakes++;
        secure.listen((data) => applicationBytes += data.length, onError: (Object _) {}, onDone: secure.destroy);
      } catch (_) {
        refusedHandshakes++;
      }
    });
  }

  static Future<_TlsServer> start(SecurityContext context) async =>
      _TlsServer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), context);

  final ServerSocket _server;
  int handshakes = 0;
  int refusedHandshakes = 0;
  int applicationBytes = 0;

  int get port => _server.port;

  Future<void> close() => _server.close();
}

void main() {
  const confirmer = ServerConfirmer(httpTimeout: Duration(seconds: 2));
  late Directory folder;
  SecurityContext? tapo;
  SecurityContext? other;

  setUpAll(() async {
    folder = await Directory.systemTemp.createTemp('immuch360-tapo-tls');
    tapo = await _context(folder, 'tapo', '/CN=TPRI-DEVICE');
    other = await _context(folder, 'other', '/CN=nas.example.com/O=Example');
  });

  tearDownAll(() async {
    await folder.delete(recursive: true);
  });

  test('a host showing the certificate of a Tapo camera is one, and gets no byte of the application', () async {
    final context = tapo;
    if (context == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    final server = await _TlsServer.start(context);
    addTearDown(server.close);

    expect(await confirmer.isTapoCamera('127.0.0.1', port: server.port), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(server.handshakes, 0, reason: 'the handshake is refused once the certificate is seen');
    expect(server.applicationBytes, 0);
    expect(server.refusedHandshakes, 1);
  });

  test('a host showing another certificate is no camera', () async {
    final context = other;
    if (context == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    final server = await _TlsServer.start(context);
    addTearDown(server.close);

    expect(await confirmer.isTapoCamera('127.0.0.1', port: server.port), isFalse);
    expect(server.handshakes, 0);
  });

  test('a host that does not answer TLS, or nothing at all, is no camera', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(silent.close);
    final held = <Socket>[];
    silent.listen(held.add);
    addTearDown(() {
      for (final socket in held) {
        socket.destroy();
      }
    });
    const quick = ServerConfirmer(httpTimeout: Duration(milliseconds: 300));

    final watch = Stopwatch()..start();
    expect(await quick.isTapoCamera('127.0.0.1', port: silent.port), isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)), reason: 'the handshake has a time limit');

    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    expect(await quick.isTapoCamera('127.0.0.1', port: port), isFalse);
  });

  test('checks nothing once the discovery ended', () async {
    final request = DiscoveryRequest(done: Future<void>.value());
    await Future<void>.delayed(Duration.zero);

    expect(await confirmer.isTapoCamera('127.0.0.1', port: 1, request: request), isFalse);
  });
}
