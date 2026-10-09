// The TLS half of the desktop stack's contract: the certificates the user trusts in the app, in every client the app
// builds (the stack, every plain HttpClient through DesktopHttpOverrides, the desktop transfers of the vendored
// background_downloader), and the client certificate (mTLS) of NetworkApi.addCertificate, against TLS servers on
// 127.0.0.1. The certificates are made by openssl at test time in a temporary folder, so that no key is kept in the
// repository, as in the Plex TLS tests; the tests are skipped when openssl is not there.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
// The vendored downloader's own client, checked without starting its isolates and database
import 'package:background_downloader/src/desktop/desktop_downloader.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:web_socket/web_socket.dart';

const _password = 'test password';

/// The openssl of Git for Windows, which the Windows machines of the project have when openssl is not on the PATH
const _gitForWindowsOpenssl = [
  r'C:\Program Files\Git\mingw64\bin\openssl.exe',
  r'C:\Program Files\Git\usr\bin\openssl.exe',
];

/// The configuration openssl runs with: the extensions of a self signed certificate written here rather than taken
/// from the system's openssl.cnf, which Git for Windows' openssl does not find when a Windows process starts it
const _opensslConfig = '''
[req]
distinguished_name = dn
x509_extensions = v3_ca
[dn]
[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:true
''';

class _Certificates {
  _Certificates(this.folder);

  final Directory folder;
  String _openssl = 'openssl';

  String path(String name) => '${folder.path}/$name';
  Uint8List bytes(String name) => File(path(name)).readAsBytesSync();

  Future<ProcessResult?> _process(List<String> arguments) async {
    try {
      return await Process.run(
        _openssl,
        arguments,
        workingDirectory: folder.path,
        environment: {'OPENSSL_CONF': path('openssl.cnf')},
      );
    } on ProcessException {
      return null;
    }
  }

  Future<bool> _run(List<String> arguments) async => (await _process(arguments))?.exitCode == 0;

  Future<String?> _output(List<String> arguments) async {
    final result = await _process(arguments);
    return result?.exitCode == 0 ? result!.stdout as String : null;
  }

  Future<bool> _findOpenssl() async {
    if (await _run(['version'])) {
      return true;
    }
    for (final candidate in Platform.isWindows ? _gitForWindowsOpenssl : const <String>[]) {
      if (File(candidate).existsSync()) {
        _openssl = candidate;
        return _run(['version']);
      }
    }
    return false;
  }

  Future<bool> _leaf(String name, String subject, String extensions, {required String issuer}) async {
    File(path('$name.ext')).writeAsStringSync(extensions);
    return await _run([
          'req',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          '$name.key',
          '-out',
          '$name.csr',
          '-subj',
          subject,
        ]) &&
        await _run([
          'x509', '-req', '-in', '$name.csr', '-CA', '$issuer.pem', '-CAkey', '$issuer.key', '-CAcreateserial', //
          '-out', '$name.pem', '-days', '2', '-extfile', '$name.ext',
        ]);
  }

  /// Everything the tests use; false when openssl cannot make it
  Future<bool> make() async {
    File(path('openssl.cnf')).writeAsStringSync(_opensslConfig);
    final ok =
        await _findOpenssl() &&
        await _run([
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', //
          '-subj', '/CN=Immuch360 Test Authority',
          '-addext', 'basicConstraints=critical,CA:TRUE',
          '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        ]) &&
        await _run(['x509', '-in', 'ca.pem', '-outform', 'der', '-out', 'ca.cer']) &&
        await _leaf(
          'server',
          '/CN=127.0.0.1',
          'subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n',
          issuer: 'ca',
        ) &&
        await _leaf(
          'client',
          '/CN=Immuch360 Test Client',
          'basicConstraints=CA:FALSE\nextendedKeyUsage=clientAuth\n',
          issuer: 'ca',
        ) &&
        await _run([
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'self.key', '-out', 'self.pem', '-days', '2', //
          '-subj', '/O=Immuch360 Self Signed', '-addext', 'subjectAltName=IP:127.0.0.1',
        ]) &&
        await _run([
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'elsewhere.key', '-out', 'elsewhere.pem', //
          '-days', '2', '-subj', '/CN=elsewhere.test', '-addext', 'subjectAltName=DNS:elsewhere.test',
        ]) &&
        // The PKCS #12 of OpenSSL 3 (AES-256, PBKDF2, SHA-256), and the one Windows and older tools export
        await _run([
          'pkcs12', '-export', '-in', 'client.pem', '-inkey', 'client.key', '-out', 'client.p12', //
          '-passout', 'pass:$_password',
        ]) &&
        await _run([
          'pkcs12', '-export', '-in', 'client.pem', '-inkey', 'client.key', '-out', 'client-3des.p12', //
          '-passout', 'pass:$_password', '-certpbe', 'PBE-SHA1-3DES', '-keypbe', 'PBE-SHA1-3DES', '-macalg', 'sha1',
        ]);
    return ok;
  }

  Future<String?> fingerprint(String name) async {
    final output = await _output(['x509', '-in', name, '-noout', '-fingerprint', '-sha256']);
    return output?.split('=').last.trim();
  }

  SecurityContext serverContext(String name, {bool trustClients = false}) {
    final context = SecurityContext()
      ..useCertificateChain(path('$name.pem'))
      ..usePrivateKey(path('$name.key'));
    if (trustClients) {
      context.setTrustedCertificates(path('ca.pem'));
    }
    return context;
  }
}

/// An HTTPS server answering the subject of the client certificate it received (or "none") and the cookie
class _TlsServer {
  _TlsServer._(this._server) {
    _server.listen((request) async {
      if (request.uri.path == '/socket') {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(request.certificate?.subject ?? 'none');
        await socket.close();
        return;
      }
      request.response.write(
        jsonEncode({'client': request.certificate?.subject ?? 'none', 'cookie': request.headers.value('cookie')}),
      );
      await request.response.close();
    }, onError: (Object _) {});
  }

  static Future<_TlsServer> start(SecurityContext context, {bool requestClientCertificate = false}) async =>
      _TlsServer._(
        await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          context,
          requestClientCertificate: requestClientCertificate,
        ),
      );

  final HttpServer _server;

  Uri get url => Uri.parse('https://127.0.0.1:${_server.port}/api/users/me');

  Future<void> close() => _server.close(force: true);
}

void main() {
  late Directory folder;
  late _Certificates certificates;
  var haveOpenssl = true;

  setUpAll(() async {
    folder = await Directory.systemTemp.createTemp('immuch360_tls_');
    certificates = _Certificates(folder);
    haveOpenssl = await certificates.make();
  });

  tearDownAll(() => folder.delete(recursive: true));

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TrustedCertificates trustedIn(String name) =>
      TrustedCertificates(folder: () async => Directory('${folder.path}/$name'));

  DesktopHttpStack makeStack(TrustedCertificates trusted, {bool global = false}) => DesktopHttpStack(
    secrets: const SecureStorageRepository(FlutterSecureStorage()),
    trustedCertificates: trusted,
    userAgent: () async => 'immich-unknown/9.9.9-test',
    global: global,
  );

  Future<Map<String, dynamic>> getJson(DesktopHttpStack stack, Uri url) async =>
      jsonDecode((await stack.client.get(url)).body) as Map<String, dynamic>;

  /// True, with the test marked skipped, when openssl could not make the certificates
  bool skipped() {
    if (!haveOpenssl) {
      markTestSkipped('openssl is not available to make the test certificates');
    }
    return !haveOpenssl;
  }

  group('trusted certificates', () {
    test(
      'a server of a private authority fails until the authority is trusted, and again once it is removed',
      () async {
        if (skipped()) {
          return;
        }
        final server = await _TlsServer.start(certificates.serverContext('server'));
        addTearDown(server.close);
        final trusted = trustedIn('private-authority');
        final stack = makeStack(trusted);
        await stack.init();

        await expectLater(stack.client.get(server.url), throwsA(isA<HandshakeException>()));

        final added = await trusted.add(certificates.bytes('ca.pem'));
        expect(added.single.subject, 'Immuch360 Test Authority');
        // The same stack and the same client object: only the connections under it are new
        expect((await stack.client.get(server.url)).statusCode, 200);

        await trusted.remove(added.single);
        await expectLater(stack.client.get(server.url), throwsA(isA<HandshakeException>()));
      },
    );

    test('every plain HttpClient of the app trusts them too, but not one that brings its own context', () async {
      if (skipped()) {
        return;
      }
      final server = await _TlsServer.start(certificates.serverContext('server'));
      addTearDown(server.close);
      final trusted = trustedIn('overrides');

      Future<int> fetch({SecurityContext? context}) => HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient(context: context);
        try {
          final response = await (await client.getUrl(server.url)).close();
          await response.drain<void>();
          return response.statusCode;
        } finally {
          client.close(force: true);
        }
      }, DesktopHttpOverrides(trusted));

      await expectLater(fetch(), throwsA(isA<HandshakeException>()));
      await trusted.add(certificates.bytes('ca.pem'));
      expect(await fetch(), 200);
      // The Tapo cameras check their certificates with a context of their own
      await expectLater(fetch(context: SecurityContext()), throwsA(isA<HandshakeException>()));
    });

    test('a self signed server certificate can be trusted itself, its host name still checked', () async {
      if (skipped()) {
        return;
      }
      final selfSigned = await _TlsServer.start(certificates.serverContext('self'));
      final elsewhere = await _TlsServer.start(certificates.serverContext('elsewhere'));
      addTearDown(selfSigned.close);
      addTearDown(elsewhere.close);
      final trusted = trustedIn('self-signed');
      final stack = makeStack(trusted);
      await stack.init();

      await trusted.add(certificates.bytes('self.pem'));
      expect((await stack.client.get(selfSigned.url)).statusCode, 200);
      expect(trusted.certificates.single.subject, 'Immuch360 Self Signed');

      // Trusted, but made for another name than the address: refused, nothing accepts a certificate unchecked
      await trusted.add(certificates.bytes('elsewhere.pem'));
      await expectLater(stack.client.get(elsewhere.url), throwsA(isA<HandshakeException>()));
    });

    test('PEM and DER files are read, a bundle gives each certificate, a file without one is refused', () async {
      if (skipped()) {
        return;
      }
      final der = readCertificates(certificates.bytes('ca.cer'));
      final pem = readCertificates(certificates.bytes('ca.pem'));
      expect(der.single, pem.single);
      expect(der.single.displayFingerprint, await certificates.fingerprint('ca.pem'));
      final notAfter = der.single.notAfter!;
      expect(notAfter.difference(DateTime.now().toUtc()).inHours, inInclusiveRange(46, 49));

      final bundle = [...certificates.bytes('ca.pem'), ...utf8.encode('\n'), ...certificates.bytes('self.pem')];
      expect(readCertificates(bundle).map((c) => c.subject), ['Immuch360 Test Authority', 'Immuch360 Self Signed']);

      final trusted = trustedIn('files');
      await expectLater(trusted.add(utf8.encode('no certificate here')), throwsA(isA<FormatException>()));
      await expectLater(trusted.add(certificates.bytes('client.key')), throwsA(isA<FormatException>()));
      expect(await trusted.add(bundle), hasLength(2));
      // Known already: nothing new
      expect(await trusted.add(certificates.bytes('ca.cer')), isEmpty);
    });

    test('the list is kept in its folder, one file per certificate, and read at the next start', () async {
      if (skipped()) {
        return;
      }
      final first = trustedIn('kept');
      var changes = 0;
      first.addListener(() => changes++);
      // Nothing saved yet: nothing to tell
      await first.load();
      expect(first.context, isNull);
      final added = await first.add(certificates.bytes('ca.pem'));
      expect(changes, 1);
      expect(first.context, isNotNull);
      expect(File('${folder.path}/kept/${added.single.fingerprint}.pem').existsSync(), isTrue);

      final next = trustedIn('kept');
      await next.load();
      expect(next.certificates, added);

      await next.remove(added.single);
      expect(Directory('${folder.path}/kept').listSync(), isEmpty);
    });
  });

  group('client certificate', () {
    for (final file in ['client.p12', 'client-3des.p12']) {
      test('$file: presented to a server that asks, kept between starts, gone once removed', () async {
        if (skipped()) {
          return;
        }
        final server = await _TlsServer.start(
          certificates.serverContext('server', trustClients: true),
          requestClientCertificate: true,
        );
        addTearDown(server.close);
        final trusted = trustedIn('mtls-$file');
        await trusted.add(certificates.bytes('ca.pem'));
        final stack = makeStack(trusted);
        await stack.init();

        expect((await getJson(stack, server.url))['client'], 'none');

        await stack.setClientCertificate(certificates.bytes(file), _password);
        expect(stack.hasClientCertificate, isTrue);
        expect((await getJson(stack, server.url))['client'], contains('Immuch360 Test Client'));

        // The next start reads it back
        final next = makeStack(trusted);
        await next.init();
        expect(next.hasClientCertificate, isTrue);
        expect((await getJson(next, server.url))['client'], contains('Immuch360 Test Client'));

        await next.removeClientCertificate();
        expect(next.hasClientCertificate, isFalse);
        expect((await getJson(next, server.url))['client'], 'none');
        final afterRemoval = makeStack(trusted);
        await afterRemoval.init();
        expect(afterRemoval.hasClientCertificate, isFalse);
      });
    }

    test('a wrong password is refused and the certificate in use stays', () async {
      if (skipped()) {
        return;
      }
      final stack = makeStack(trustedIn('password'));
      await stack.init();
      await stack.setClientCertificate(certificates.bytes('client.p12'), _password);
      await expectLater(
        stack.setClientCertificate(certificates.bytes('client-3des.p12'), 'wrong'),
        throwsA(isA<TlsException>()),
      );
      expect(stack.hasClientCertificate, isTrue);
      final next = makeStack(trustedIn('password'));
      await next.init();
      expect(next.hasClientCertificate, isTrue);
    });

    test('the websocket presents it too', () async {
      if (skipped()) {
        return;
      }
      final server = await _TlsServer.start(
        certificates.serverContext('server', trustClients: true),
        requestClientCertificate: true,
      );
      addTearDown(server.close);
      final trusted = trustedIn('websocket');
      await trusted.add(certificates.bytes('ca.pem'));
      final stack = makeStack(trusted);
      await stack.init();
      await stack.setClientCertificate(certificates.bytes('client.p12'), _password);

      final socket = await stack.createWebSocket(server.url.replace(scheme: 'wss', path: '/socket'));
      final first = await socket.events.first;
      expect(first, isA<TextDataReceived>().having((e) => e.text, 'text', contains('Immuch360 Test Client')));
    });
  });

  group('desktop transfers of the vendored background_downloader', () {
    test('the app\'s stack hands over its certificates and its session cookie', () async {
      if (skipped()) {
        return;
      }
      final server = await _TlsServer.start(
        certificates.serverContext('server', trustClients: true),
        requestClientCertificate: true,
      );
      addTearDown(server.close);
      final trusted = trustedIn('transfers');
      final stack = makeStack(trusted, global: true);
      // The app's stack sets what every client of the isolate uses: put back for the tests that follow
      addTearDown(() {
        HttpOverrides.global = null;
        configureDesktopTransfers();
      });
      await stack.init();
      await trusted.add(certificates.bytes('ca.pem'));
      await stack.setClientCertificate(certificates.bytes('client.p12'), _password);
      await stack.setRequestHeaders(const {}, ['https://127.0.0.1:${server.url.port}/api'], 'SESSION');

      final security = DesktopDownloader.transferSecurity!;
      expect(security.trustedCertificates, hasLength(1));
      expect(security.clientCertificate, isNotNull);
      final headers = DesktopDownloader.transferHeadersOf(server.url.toString());
      expect(headers['cookie'], contains('immich_access_token=SESSION'));
      expect(DesktopDownloader.transferHeadersOf('https://elsewhere.test/file'), isEmpty);

      // The client of the main isolate (head requests of the tasks) is rebuilt with them
      final main = jsonDecode((await DesktopDownloader.httpClient.get(server.url)).body) as Map<String, dynamic>;
      expect(main['client'], contains('Immuch360 Test Client'));
      expect(main['cookie'], contains('immich_access_token=SESSION'));

      // A task's isolate: what the main isolate sends with the task arguments, the cookie for the task's origin only
      final url = server.url.toString();
      final other = Uri.parse('https://localhost:${server.url.port}/api/users/me').toString();
      final seen = await Isolate.run(() async {
        DesktopDownloader.useTaskTransfer(security, url, headers);
        DesktopDownloader.setHttpClient(null, const {}, false);
        final client = DesktopDownloader.httpClient;
        final sameOrigin = jsonDecode((await client.get(Uri.parse(url))).body) as Map<String, dynamic>;
        final otherOrigin = jsonDecode((await client.get(Uri.parse(other))).body) as Map<String, dynamic>;
        return [sameOrigin['client'], sameOrigin['cookie'], otherOrigin['cookie']];
      });
      expect(seen[0], contains('Immuch360 Test Client'));
      expect(seen[1], contains('immich_access_token=SESSION'));
      expect(seen[2], isNull);
    });

    test('nothing configured: the plain client of the package, as before', () {
      expect(const DesktopTransferSecurity().createContext(), isNull);
    });
  });
}
