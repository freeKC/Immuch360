// A local HTTPS server for the tests of the AI components: it serves files with Range, cuts a connection in the
// middle, answers 404, redirects (also to http://), sends slowly, keeps silent, and records the headers of every
// request. Its
// certificates are made by openssl at test time in a temporary folder, so that no key is kept in the repository, as in
// tls_contract_test.dart; the tests that need it are skipped when openssl is not there.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/services/ai_immersive/ai_component_downloader.dart';
import 'package:path/path.dart' as p;

/// The openssl of Git for Windows, which the Windows machines of the project have when openssl is not on the PATH
const _gitForWindowsOpenssl = [
  r'C:\Program Files\Git\mingw64\bin\openssl.exe',
  r'C:\Program Files\Git\usr\bin\openssl.exe',
];

/// The extensions of the test authority, written here rather than taken from the system's openssl.cnf, which Git for
/// Windows' openssl does not find when a Windows process starts it
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

/// A test authority and the certificate of 127.0.0.1 it signed
class TestCertificates {
  TestCertificates._(this.folder);

  final Directory folder;
  String _openssl = 'openssl';

  String _path(String name) => p.join(folder.path, name);

  Future<bool> _run(List<String> arguments) async {
    try {
      final result = await Process.run(
        _openssl,
        arguments,
        workingDirectory: folder.path,
        environment: {'OPENSSL_CONF': _path('openssl.cnf')},
      );
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
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

  /// The certificates in [folder], or null when openssl cannot make them
  static Future<TestCertificates?> make(Directory folder) async {
    final certificates = TestCertificates._(folder);
    File(certificates._path('openssl.cnf')).writeAsStringSync(_opensslConfig);
    File(certificates._path('server.ext')).writeAsStringSync(
      'subjectAltName=IP:127.0.0.1,DNS:localhost\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n',
    );
    final run = certificates._run;
    final ok =
        await certificates._findOpenssl() &&
        await run([
          'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '2', //
          '-subj', '/CN=Immuch360 Test Authority',
          '-addext', 'basicConstraints=critical,CA:TRUE',
          '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
        ]) &&
        await run([
          'req',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          'server.key',
          '-out',
          'server.csr',
          '-subj',
          '/CN=127.0.0.1',
        ]) &&
        await run([
          'x509', '-req', '-in', 'server.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', //
          '-out', 'server.pem', '-days', '2', '-extfile', 'server.ext',
        ]);
    return ok ? certificates : null;
  }

  SecurityContext get serverContext => SecurityContext()
    ..useCertificateChain(_path('server.pem'))
    ..usePrivateKey(_path('server.key'));

  /// A context that trusts the test authority only, for the bare client of the downloader
  SecurityContext get clientContext =>
      SecurityContext(withTrustedRoots: false)..setTrustedCertificates(_path('ca.pem'));

  /// The bare client of the app, trusting the test authority
  HttpClient bareClient() => aiBareHttpClient(context: clientContext);
}

/// What the server saw of one request
class SeenRequest {
  SeenRequest(this.path, this.headers);

  final String path;

  /// Header names in lower case, with their values joined by ", "
  final Map<String, String> headers;

  String? get range => headers['range'];
}

/// How the server answers for a file
class ServedFile {
  ServedFile(this.bytes, {this.cutFirstAfter, this.chunk = 64 * 1024, this.pause, this.contentLength});

  final Uint8List bytes;

  /// The first answer stops after this many bytes, the connection closed under it
  int? cutFirstAfter;

  /// The size of each write, and the pause after each one (a slow server)
  final int chunk;
  final Duration? pause;

  /// A Content-Length that lies (a server that sends another file)
  final int? contentLength;
}

/// The server. Paths: `/files/NAME` (the file, with Range), `/redirect/NAME` (302 to `/files/NAME`, relative),
/// `/to-http/NAME` (302 to the plain http server), `/silent/NAME` (the request taken, never answered), anything else
/// 404.
class ComponentTestServer {
  ComponentTestServer._(this._server, this.plain) {
    _server.listen(_answer, onError: (Object _) {});
    plain.listen((request) {
      plainRequests.add(request.uri.path);
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
    }, onError: (Object _) {});
  }

  static Future<ComponentTestServer> start(TestCertificates certificates) async => ComponentTestServer._(
    await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, certificates.serverContext),
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
  );

  final HttpServer _server;

  /// A plain http server, which must never be reached
  final HttpServer plain;
  final files = <String, ServedFile>{};
  final requests = <SeenRequest>[];
  final plainRequests = <String>[];

  String get base => 'https://127.0.0.1:${_server.port}';
  String get plainBase => 'http://127.0.0.1:${plain.port}';

  /// The address of [name] under [folder] ("files", "redirect", "to-http", "silent", "missing")
  String url(String folder, String name) => '$base/$folder/$name';

  Future<void> _answer(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(', '));
    requests.add(SeenRequest(request.uri.path, headers));
    final parts = request.uri.pathSegments;
    final response = request.response;
    if (parts.length != 2) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final name = parts[1];
    switch (parts[0]) {
      case 'redirect':
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '../files/$name');
        await response.close();
        return;
      case 'to-http':
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, '$plainBase/files/$name');
        await response.close();
        return;
      case 'silent':
        // Held until the server closes
        return;
      case 'files':
        final file = files[name];
        if (file != null) {
          await _serve(request, file);
          return;
        }
    }
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }

  Future<void> _serve(HttpRequest request, ServedFile file) async {
    final response = request.response;
    final total = file.bytes.length;
    var start = 0;
    final range = RegExp(r'^bytes=(\d+)-$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null) {
      start = int.parse(range.group(1)!);
      if (start >= total) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${total - 1}/$total');
    }
    response.headers.contentType = ContentType.binary;
    response.contentLength = file.contentLength ?? total - start;
    final cut = file.cutFirstAfter;
    file.cutFirstAfter = null;
    if (cut != null) {
      // The headers, then part of the body, then the connection closed: the client sees the body end too soon
      final socket = await response.detachSocket();
      socket.add(file.bytes.sublist(start, start + cut));
      await socket.flush();
      socket.destroy();
      return;
    }
    try {
      for (var at = start; at < total; at += file.chunk) {
        response.add(file.bytes.sublist(at, at + file.chunk < total ? at + file.chunk : total));
        await response.flush();
        if (file.pause != null) {
          await Future<void>.delayed(file.pause!);
        }
      }
      await response.close();
    } on Object {
      // The client went away (a cancelled download)
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    await plain.close(force: true);
  }
}

/// A component of the tests, for [bytes] served as [assetName]
AiComponent testComponent(
  String assetName,
  List<int> installed, {
  required String sha256,
  AiCompression compression = AiCompression.none,
  int? downloadSize,
  List<String> officialUrls = const [],
  String id = 'test-component',
  String installPath = 'models/test/test.bin',
  List<AiComponentPart> parts = const [],
  String releaseTag = aiComponentsReleaseTag,
}) => AiComponent(
  id: id,
  version: '1',
  kind: AiComponentKind.model,
  platforms: AiPlatform.values.toSet(),
  assetName: assetName,
  installPath: installPath,
  size: installed.length,
  sha256: sha256,
  compression: compression,
  downloadSize: downloadSize,
  licence: 'Apache-2.0',
  licenceUrl: 'https://www.apache.org/licenses/LICENSE-2.0',
  officialUrls: officialUrls,
  parts: parts,
  releaseTag: releaseTag,
);

/// [bytes] cut into parts of [size] bytes named ASSET.001, ASSET.002, ..., as the publication script cuts them; their
/// bytes by asset name, to serve
({List<AiComponentPart> parts, Map<String, List<int>> served}) cutInParts(
  String assetName,
  List<int> bytes,
  int size,
  String Function(List<int> bytes) sha256Of,
) {
  final parts = <AiComponentPart>[];
  final served = <String, List<int>>{};
  for (var start = 0, index = 1; start < bytes.length; start += size, index++) {
    final piece = bytes.sublist(start, start + size < bytes.length ? start + size : bytes.length);
    final name = '$assetName.${'$index'.padLeft(3, '0')}';
    parts.add(AiComponentPart(assetName: name, size: piece.length, sha256: sha256Of(piece)));
    served[name] = piece;
  }
  return (parts: parts, served: served);
}
