// The pinned client of the Plex servers against a TLS server on 127.0.0.1, with certificates made by openssl at test
// time in a temporary folder (no key is kept in the repository): a test authority, and leaves for the plex.direct
// names of the test hash and of another one. The client trusts the test authority only, as the app trusts the system
// roots only. Skipped when openssl is not there.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_direct.dart';

const _hash = '0123456789abcdef0123456789abcdef';
const _other = 'fedcba9876543210fedcba9876543210';

class _Certificates {
  const _Certificates(this.folder);

  final Directory folder;
  String get ca => '${folder.path}/ca.pem';

  Future<bool> _run(List<String> arguments) async {
    try {
      final result = await Process.run('openssl', arguments, workingDirectory: folder.path);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// The test authority; false when openssl cannot make it
  Future<bool> makeAuthority() => _run([
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', //
    '-subj', '/CN=Immuch360 Test Authority',
    '-addext', 'basicConstraints=critical,CA:TRUE',
    '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
  ]);

  /// A leaf of the test authority for [subject] and the DNS name [san], as [name].pem and [name].key
  Future<bool> makeLeaf(String name, String subject, String san) async {
    File('${folder.path}/$name.ext').writeAsStringSync(
      'subjectAltName=DNS:$san\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\n',
    );
    return await _run([
          'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', '$name.key', '-out', '$name.csr', //
          '-subj', subject,
        ]) &&
        await _run([
          'x509', '-req', '-in', '$name.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', //
          '-out', '$name.pem', '-days', '2', '-extfile', '$name.ext',
        ]);
  }

  SecurityContext server(String name) => SecurityContext()
    ..useCertificateChain('${folder.path}/$name.pem')
    ..usePrivateKey('${folder.path}/$name.key');

  /// What the client trusts: the test authority only
  SecurityContext get client => SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca);
}

/// An HTTPS server on 127.0.0.1 answering /identity, counting the requests it received
class _PlexLikeServer {
  _PlexLikeServer._(this._server) {
    _server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'MediaContainer': {'machineIdentifier': 'm'},
        }),
      );
      await request.response.close();
    }, onError: (Object _) {});
  }

  static Future<_PlexLikeServer> start(SecurityContext context) async =>
      _PlexLikeServer._(await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context));

  final HttpServer _server;
  int requests = 0;

  int get port => _server.port;

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory folder;
  _Certificates? certificates;

  setUpAll(() async {
    folder = await Directory.systemTemp.createTemp('immuch360-plex-tls');
    final made = _Certificates(folder);
    final ok =
        await made.makeAuthority() &&
        await made.makeLeaf('plex', '/CN=*.$_hash.plex.direct', '*.$_hash.plex.direct') &&
        await made.makeLeaf('other', '/CN=*.$_other.plex.direct', '*.$_other.plex.direct') &&
        // Valid for the exact name, but not the wildcard subject Plex issues
        await made.makeLeaf('exact', '/CN=127-0-0-1.$_hash.plex.direct', '127-0-0-1.$_hash.plex.direct') &&
        await made.makeLeaf('nas', '/CN=nas.example.com', 'nas.example.com');
    certificates = ok ? made : null;
  });

  tearDownAll(() => folder.delete(recursive: true));

  Future<Object?> get(HttpClient client, int port) async {
    try {
      final request = await client.getUrl(Uri.parse('https://127-0-0-1.$_hash.plex.direct:$port/identity'));
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } catch (error) {
      return error;
    }
  }

  test('talks to the server holding the certificate of the hash', () async {
    final made = certificates;
    if (made == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    final server = await _PlexLikeServer.start(made.server('plex'));
    addTearDown(server.close);
    final client = pinnedPlexHttpClient(_hash, context: made.client);
    addTearDown(() => client.close(force: true));

    expect(await get(client, server.port), 200);
    expect(server.requests, 1);
  });

  test('refuses before any request a server with the certificate of another hash, or of the name only', () async {
    final made = certificates;
    if (made == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    for (final name in ['other', 'exact', 'nas']) {
      final server = await _PlexLikeServer.start(made.server(name));
      final client = pinnedPlexHttpClient(_hash, context: made.client);
      expect(await get(client, server.port), isA<HandshakeException>(), reason: name);
      expect(server.requests, 0, reason: '$name: no HTTP byte before the certificate is checked');
      client.close(force: true);
      await server.close();
    }
  });

  test('refuses a certificate of an authority the client does not trust', () async {
    final made = certificates;
    if (made == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    final server = await _PlexLikeServer.start(made.server('plex'));
    addTearDown(server.close);
    final client = pinnedPlexHttpClient(_hash, context: SecurityContext(withTrustedRoots: false));
    addTearDown(() => client.close(force: true));

    expect(await get(client, server.port), isA<HandshakeException>());
    expect(server.requests, 0);
  });

  test('probePlexHash reads the hash of a certificate and sends nothing', () async {
    final made = certificates;
    if (made == null) {
      markTestSkipped('openssl is not available');
      return;
    }
    for (final (name, expected) in [('plex', _hash), ('other', _other), ('nas', null)]) {
      final listener = await SecureServerSocket.bind(InternetAddress.loopbackIPv4, 0, made.server(name));
      var handshakes = 0;
      var received = 0;
      final subscription = listener.listen((socket) {
        handshakes++;
        socket.listen((data) => received += data.length, onError: (Object _) {}, onDone: socket.destroy);
      }, onError: (Object _) {});
      final hash = await probePlexHash(InternetAddress.loopbackIPv4, listener.port, context: made.client);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(hash, expected, reason: name);
      expect(handshakes, 0, reason: '$name: the handshake is refused once the certificate is seen');
      expect(received, 0);
      await subscription.cancel();
      await listener.close();
    }
  });

  test('probePlexHash finds nothing on a server that speaks no TLS', () async {
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => plain.close(force: true));
    plain.listen((request) => request.response.close());
    expect(await probePlexHash(InternetAddress.loopbackIPv4, plain.port, timeout: const Duration(seconds: 3)), isNull);
  });
}
