import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';

/// How the test server writes its multistatus answers, after real servers
enum _XmlStyle {
  /// "D:" everywhere (many servers)
  upperPrefix,

  /// "d:" with ownCloud properties and a 404 propstat (Nextcloud, sabre/dav)
  lowerPrefix,

  /// A default namespace, no prefix (IIS, some NAS)
  defaultNamespace,

  /// "D:" for the structure and "lp1:" for the live properties (Apache mod_dav)
  apache,
}

typedef _Request = ({String method, String path, Map<String, String> headers, int? port});

/// A tiny WebDAV server over an in memory tree: PROPFIND with depth 0 and 1, GET with or without Range support
class _FakeWebDavServer {
  _FakeWebDavServer({this.basePath = '/dav'});

  static const username = 'alice';
  static const password = 'secret';

  final String basePath;

  _XmlStyle style = _XmlStyle.upperPrefix;
  bool supportRanges = true;
  bool digestOnly = false;
  bool absoluteHrefs = false;

  /// Like Apache, answers a folder asked without its trailing "/" with a redirect to it
  bool redirectFolders = false;

  /// Sends every request to another host
  bool redirectElsewhere = false;

  final Set<String> forbidden = {};
  final Set<String> folders = {'/'};
  final Map<String, Uint8List> files = {};
  final List<_Request> requests = [];

  /// Bytes of file bodies written so far
  int bytesSent = 0;

  static final modified = DateTime.utc(2026, 9, 30, 12, 34, 56);

  late HttpServer _server;

  int get port => _server.port;

  NetworkSource source({String share = '/dav', String rootPath = '/', String? user}) => NetworkSource(
    id: 'source-1',
    type: NetworkSourceType.webdav,
    name: 'Test share',
    host: '127.0.0.1',
    port: port,
    share: share,
    rootPath: rootPath,
    username: user ?? username,
  );

  void addFile(String path, Uint8List bytes) {
    files[path] = bytes;
    var parent = path.substring(0, path.lastIndexOf('/'));
    while (parent.isNotEmpty) {
      folders.add(parent);
      parent = parent.substring(0, parent.lastIndexOf('/'));
    }
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  List<_Request> get gets => requests.where((r) => r.method == 'GET').toList();

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    await request.drain<void>();
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(', '));
    requests.add((
      method: request.method,
      path: request.uri.path,
      headers: headers,
      port: request.connectionInfo?.remotePort,
    ));
    try {
      if (redirectElsewhere) {
        response.statusCode = HttpStatus.found;
        response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.2:$port${request.uri.path}');
        return;
      }
      final expected = 'Basic ${base64.encode(utf8.encode('$username:$password'))}';
      if (digestOnly || headers['authorization'] != expected) {
        response.statusCode = HttpStatus.unauthorized;
        response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          digestOnly ? 'Digest realm="test", nonce="abc", qop="auth"' : 'Basic realm="test"',
        );
        return;
      }

      final baseSegments = basePath.split('/').where((s) => s.isNotEmpty).toList();
      final segments = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.length < baseSegments.length ||
          !Iterable.generate(baseSegments.length).every((i) => segments[i] == baseSegments[i])) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final path = '/${segments.skip(baseSegments.length).join('/')}';
      if (forbidden.contains(path)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final isFolder = folders.contains(path);
      if (!isFolder && !files.containsKey(path)) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (isFolder && redirectFolders && !request.uri.path.endsWith('/')) {
        response.statusCode = HttpStatus.movedPermanently;
        response.headers.set(HttpHeaders.locationHeader, 'http://127.0.0.1:$port${request.uri.path}/');
        return;
      }

      switch (request.method) {
        case 'PROPFIND':
          final depth = headers['depth'] ?? 'infinity';
          final paths = [
            path,
            if (isFolder && depth == '1') ...{...folders, ...files.keys}.where((p) => p != '/' && _parentOf(p) == path),
          ];
          response.statusCode = 207;
          response.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          response.write(_multistatus(paths));
        case 'GET':
          if (isFolder) {
            response.statusCode = HttpStatus.methodNotAllowed;
            return;
          }
          await _get(request, response, files[path]!);
        default:
          response.statusCode = HttpStatus.methodNotAllowed;
      }
    } finally {
      try {
        await response.close();
      } catch (_) {
        // The client went away
      }
    }
  }

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash == 0 ? '/' : path.substring(0, slash);
  }

  Future<void> _get(HttpRequest request, HttpResponse response, Uint8List bytes) async {
    response.headers.set(HttpHeaders.contentTypeHeader, _typeOf(request.uri.path));
    final range = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (supportRanges && range != null) {
      final start = int.parse(range.group(1)!);
      final askedEnd = range.group(2)!.isEmpty ? bytes.length - 1 : int.parse(range.group(2)!);
      if (start >= bytes.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${bytes.length}');
        return;
      }
      final end = askedEnd < bytes.length ? askedEnd : bytes.length - 1;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/${bytes.length}');
      response.contentLength = end - start + 1;
      response.add(Uint8List.sublistView(bytes, start, end + 1));
      bytesSent += end - start + 1;
      return;
    }
    // The whole file, in parts, straight on the socket so that a client that stops the transfer stops the writes
    response
      ..statusCode = HttpStatus.ok
      ..contentLength = bytes.length
      ..persistentConnection = false;
    final socket = await response.detachSocket();
    const part = 64 * 1024;
    try {
      for (var offset = 0; offset < bytes.length; offset += part) {
        final end = offset + part < bytes.length ? offset + part : bytes.length;
        socket.add(Uint8List.sublistView(bytes, offset, end));
        await socket.flush();
        bytesSent += end - offset;
      }
      await socket.close();
    } catch (_) {
      // The client went away
      socket.destroy();
    }
  }

  String _typeOf(String path) => switch (path.split('.').last.toLowerCase()) {
    'jpg' => 'image/jpeg',
    'mp4' => 'video/mp4',
    _ => 'application/octet-stream',
  };

  String _href(String path, bool isFolder) {
    final segments = [...basePath.split('/'), ...path.split('/')].where((s) => s.isNotEmpty);
    final encoded = '/${segments.map(Uri.encodeComponent).join('/')}${isFolder && segments.isNotEmpty ? '/' : ''}';
    return absoluteHrefs ? 'http://127.0.0.1:$port$encoded' : encoded;
  }

  String _multistatus(List<String> paths) {
    final (root, s, p) = switch (style) {
      _XmlStyle.upperPrefix => ('<D:multistatus xmlns:D="DAV:">', 'D:', 'D:'),
      _XmlStyle.lowerPrefix => (
        '<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">',
        'd:',
        'd:',
      ),
      _XmlStyle.defaultNamespace => ('<multistatus xmlns="DAV:">', '', ''),
      _XmlStyle.apache => ('<D:multistatus xmlns:D="DAV:" xmlns:ns0="DAV:">', 'D:', 'lp1:'),
    };
    final out = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n$root\n');
    for (final path in paths) {
      final isFolder = folders.contains(path);
      final name = path == '/' ? '' : path.split('/').last;
      out
        ..write(style == _XmlStyle.apache ? '<${s}response xmlns:lp1="DAV:">' : '<${s}response>')
        ..write('<${s}href>${_escape(_href(path, isFolder))}</${s}href>')
        ..write('<${s}propstat><${s}prop>')
        ..write('<${s}displayname>${_escape(name)}</${s}displayname>')
        ..write(isFolder ? '<${p}resourcetype><${s}collection/></${p}resourcetype>' : '<${p}resourcetype/>')
        ..write('<${p}getlastmodified>${HttpDate.format(modified)}</${p}getlastmodified>');
      if (!isFolder) {
        out
          ..write('<${p}getcontentlength>${files[path]!.length}</${p}getcontentlength>')
          ..write('<${s}getcontenttype>${_typeOf(path)}</${s}getcontenttype>');
      }
      if (style == _XmlStyle.lowerPrefix) {
        // Properties of another namespace, one of them with a DAV name, to be left alone
        out.write('<oc:size>42</oc:size><oc:getcontentlength>999999</oc:getcontentlength>');
      }
      out.write('</${s}prop><${s}status>HTTP/1.1 200 OK</${s}status></${s}propstat>');
      if (style == _XmlStyle.lowerPrefix && isFolder) {
        out.write(
          '<${s}propstat><${s}prop><${s}getcontentlength/><${s}getcontenttype/></${s}prop>'
          '<${s}status>HTTP/1.1 404 Not Found</${s}status></${s}propstat>',
        );
      }
      out.write('</${s}response>\n');
    }
    out.write('</${root.substring(1, root.indexOf(' '))}>');
    return out.toString();
  }

  static String _escape(String text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

Uint8List _bytes(int length, {int seed = 0}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + seed + (i >> 8)) & 0xFF;
  }
  return bytes;
}

void main() {
  group('WebDavFileSystem against a test server', () {
    late _FakeWebDavServer server;
    final opened = <WebDavFileSystem>[];

    final video = _bytes(300000, seed: 1);
    final photo = _bytes(5000, seed: 2);

    Future<WebDavFileSystem> open({
      String share = '/dav',
      String rootPath = '/',
      String? password = 'secret',
      String? user,
    }) async {
      final fileSystem = await WebDavFileSystem.open(
        server.source(share: share, rootPath: rootPath, user: user),
        password,
      );
      opened.add(fileSystem);
      return fileSystem;
    }

    setUp(() async {
      server = _FakeWebDavServer();
      server
        ..addFile('/Photos/b.jpg', photo)
        ..addFile('/Photos/A clip.mp4', video)
        ..addFile('/Photos/Été & co #1.jpg', photo)
        ..addFile('/Photos/zeta/inside.jpg', photo)
        ..addFile('/Photos/Alpha/deeper/far.jpg', photo)
        ..addFile('/top.mp4', video);
      server.folders.add('/Photos/empty');
      await server.start();
    });

    tearDown(() async {
      for (final fileSystem in opened) {
        await fileSystem.close();
      }
      opened.clear();
      await server.close();
    });

    test('opens with Basic authentication and checks the root with PROPFIND', () async {
      final fileSystem = await open();
      expect(fileSystem.source.id, 'source-1');
      final request = server.requests.single;
      expect(request.method, 'PROPFIND');
      expect(request.path, '/dav/');
      expect(request.headers['depth'], '0');
      expect(request.headers['authorization'], 'Basic ${base64.encode(utf8.encode('alice:secret'))}');
    });

    test('opens at the root path of the source', () async {
      await open(rootPath: 'Photos/zeta');
      expect(server.requests.single.path, '/dav/Photos/zeta/');
    });

    test('a wrong password is an authentication failure', () async {
      await expectLater(
        open(password: 'wrong'),
        throwsA(
          isA<NetworkFileSystemException>()
              .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
              .having((e) => e.message, 'message', contains('refused')),
        ),
      );
    });

    test('no credentials on a server that wants some is an authentication failure', () async {
      await expectLater(
        open(password: null, user: ''),
        throwsA(
          isA<NetworkFileSystemException>()
              .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
              .having((e) => e.message, 'message', contains('asks for a user name')),
        ),
      );
      expect(server.requests.single.headers.containsKey('authorization'), isFalse);
    });

    test('a server that only offers Digest is reported as an authentication failure', () async {
      server.digestOnly = true;
      await expectLater(
        open(),
        throwsA(
          isA<NetworkFileSystemException>()
              .having((e) => e.isAuthentication, 'isAuthentication', isTrue)
              .having((e) => e.message, 'message', contains('Digest')),
        ),
      );
    });

    test('a missing root path is not found', () async {
      await expectLater(
        open(rootPath: '/Nope'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('a wrong share path is not found', () async {
      await expectLater(
        open(share: '/other'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('a forbidden folder is an authentication failure', () async {
      server.forbidden.add('/Photos');
      final fileSystem = await open();
      await expectLater(
        fileSystem.list('/Photos'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );
    });

    test('an unreachable server is a NetworkFileSystemException', () async {
      final port = server.port;
      await server.close();
      await expectLater(
        WebDavFileSystem.open(
          NetworkSource(id: 'x', type: NetworkSourceType.webdav, name: 'x', host: '127.0.0.1', port: port),
          null,
        ),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('127.0.0.1'))),
      );
      // tearDown closes it again
      server = _FakeWebDavServer();
      await server.start();
    });

    for (final style in _XmlStyle.values) {
      for (final absolute in [false, true]) {
        test('lists a folder, ${style.name}${absolute ? ', absolute hrefs' : ''}', () async {
          server
            ..style = style
            ..absoluteHrefs = absolute;
          final fileSystem = await open();
          final entries = await fileSystem.list('/Photos');

          expect(server.requests.last.headers['depth'], '1');
          expect(server.requests.last.path, '/dav/Photos/');
          // Folders first, then files, by name without case; the folder itself and deeper entries left out
          expect(entries.map((e) => e.path), [
            '/Photos/Alpha',
            '/Photos/empty',
            '/Photos/zeta',
            '/Photos/A clip.mp4',
            '/Photos/b.jpg',
            '/Photos/Été & co #1.jpg',
          ]);
          expect(entries.map((e) => e.isDirectory), [true, true, true, false, false, false]);
          expect(entries.every((e) => e.sourceId == 'source-1'), isTrue);

          final clip = entries[3];
          expect(clip.name, 'A clip.mp4');
          expect(clip.size, video.length);
          expect(clip.mimeType, 'video/mp4');
          expect(clip.modified, _FakeWebDavServer.modified);
          expect(clip.isVideo, isTrue);

          final folder = entries.first;
          expect(folder.size, isNull);
          expect(folder.mimeType, isNull);
          expect(folder.modified, _FakeWebDavServer.modified);

          expect(entries.last.size, photo.length);
          expect(entries.last.isImage, isTrue);
        });
      }
    }

    test('lists the root and an empty folder', () async {
      final fileSystem = await open();
      final root = await fileSystem.list('/');
      expect(root.map((e) => e.path), ['/Photos', '/top.mp4']);
      expect(await fileSystem.list('Photos/empty/'), isEmpty);
      expect(server.requests.last.path, '/dav/Photos/empty/');
    });

    test('lists a share without a base path', () async {
      await server.close();
      server = _FakeWebDavServer(basePath: '');
      server.addFile('/one.jpg', photo);
      await server.start();
      final fileSystem = await open(share: '');
      expect(server.requests.single.path, '/');
      expect((await fileSystem.list('/')).map((e) => e.path), ['/one.jpg']);
    });

    test('listing a missing folder is not found', () async {
      final fileSystem = await open();
      await expectLater(
        fileSystem.list('/Photos/missing'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('stats a file and a folder, following a redirect on the same host', () async {
      server.redirectFolders = true;
      final fileSystem = await open();

      final file = await fileSystem.stat('/Photos/Été & co #1.jpg');
      expect(server.requests.last.headers['depth'], '0');
      expect(file.path, '/Photos/Été & co #1.jpg');
      expect(file.name, 'Été & co #1.jpg');
      expect(file.isDirectory, isFalse);
      expect(file.size, photo.length);
      expect(file.mimeType, 'image/jpeg');
      expect(file.modified, _FakeWebDavServer.modified);

      final folder = await fileSystem.stat('/Photos/zeta');
      expect(folder.path, '/Photos/zeta');
      expect(folder.isDirectory, isTrue);
      expect(server.requests.reversed.take(2).map((r) => r.path), ['/dav/Photos/zeta/', '/dav/Photos/zeta']);
    });

    test('does not follow a redirect to another host', () async {
      final fileSystem = await open();
      server.redirectElsewhere = true;
      await expectLater(
        fileSystem.stat('/top.mp4'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('another host'))),
      );
    });

    test('stat of a missing file is not found', () async {
      final fileSystem = await open();
      await expectLater(
        fileSystem.stat('/nothing.jpg'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('reads ranges with Range requests', () async {
      final fileSystem = await open();
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 0, 100), video.sublist(0, 100));
      expect(server.gets.last.headers['range'], 'bytes=0-99');
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 123456, 70000), video.sublist(123456, 193456));
      // The end of the file: fewer bytes, then none
      expect(
        await fileSystem.readRange('/Photos/A clip.mp4', video.length - 100, 1000),
        video.sublist(video.length - 100),
      );
      expect(await fileSystem.readRange('/Photos/A clip.mp4', video.length, 10), isEmpty);
      expect(await fileSystem.readRange('/Photos/A clip.mp4', video.length + 5000, 10), isEmpty);
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 10, 0), isEmpty);
      expect(fileSystem.supportsRanges, isTrue);
      expect(server.bytesSent, 100 + 70000 + 100);
      // One connection for all, kept alive between the requests
      expect(server.requests.map((r) => r.port).toSet(), hasLength(1));
    });

    test('reading a missing file is not found', () async {
      final fileSystem = await open();
      await expectLater(
        fileSystem.readRange('/Photos/gone.mp4', 0, 10),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('reads ranges from a server that ignores them, and remembers it', () async {
      server.supportRanges = false;
      final fileSystem = await open();
      expect(fileSystem.supportsRanges, isNull);
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 1000, 500), video.sublist(1000, 1500));
      expect(fileSystem.supportsRanges, isFalse);
      expect(
        await fileSystem.readRange('/Photos/A clip.mp4', video.length - 10, 100),
        video.sublist(video.length - 10),
      );
      expect(await fileSystem.readRange('/Photos/b.jpg', 0, 100000), photo);
      expect(await fileSystem.readRange('/Photos/b.jpg', photo.length + 10, 10), isEmpty);
    });

    test('a file that fits in the bytes asked for does not tell whether ranges are ignored', () async {
      server.supportRanges = false;
      final fileSystem = await open();
      expect(await fileSystem.readRange('/Photos/b.jpg', 0, photo.length), photo);
      expect(fileSystem.supportsRanges, isNull);
    });

    test('on a server that ignores ranges, reads one after the other share one transfer', () async {
      server.supportRanges = false;
      final fileSystem = await open();
      const chunk = 16 * 1024;
      final read = BytesBuilder();
      for (var offset = 0; offset < video.length; offset += chunk) {
        read.add(await fileSystem.readRange('/Photos/A clip.mp4', offset, chunk));
      }
      expect(read.takeBytes(), video);
      expect(server.gets, hasLength(1));

      // Going back needs a new transfer, going forward does not
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 10, 20), video.sublist(10, 30));
      expect(await fileSystem.readRange('/Photos/A clip.mp4', 5000, 20), video.sublist(5000, 5020));
      expect(server.gets, hasLength(2));
    });

    test('stops the transfer of a server that ignores ranges once the bytes asked for arrived', () async {
      final big = _bytes(48 * 1024 * 1024, seed: 3);
      server
        ..supportRanges = false
        ..addFile('/big.mp4', big);
      final fileSystem = await open();
      expect(await fileSystem.readRange('/big.mp4', 0, 1000), big.sublist(0, 1000));
      // Closing drops the transfer left open for a next read
      await fileSystem.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(server.bytesSent, lessThan(big.length ~/ 2));
    });

    test('a closed share refuses to work', () async {
      final fileSystem = await open();
      await fileSystem.close();
      await expectLater(fileSystem.list('/'), throwsA(isA<NetworkFileSystemException>()));
    });

    test('leaves a client it was given open', () async {
      final client = http.Client();
      addTearDown(client.close);
      final fileSystem = await WebDavFileSystem.open(server.source(), 'secret', client: client);
      await fileSystem.close();
      final response = await client.get(Uri.parse('http://127.0.0.1:${server.port}/dav/top.mp4'));
      expect(response.statusCode, HttpStatus.unauthorized);
    });
  });

  group('WebDavFileSystem.normalizePath', () {
    test('makes paths absolute without empty, "." and ".." segments', () {
      expect(WebDavFileSystem.normalizePath(''), '/');
      expect(WebDavFileSystem.normalizePath('/'), '/');
      expect(WebDavFileSystem.normalizePath('a/b/'), '/a/b');
      expect(WebDavFileSystem.normalizePath('//a/./b/../c'), '/a/c');
      expect(WebDavFileSystem.normalizePath('/../..'), '/');
    });
  });

  group('WebDavFileSystem.baseUriOf', () {
    NetworkSource source(String host, {int? port, String share = '', bool useTls = false}) => NetworkSource(
      id: 'id',
      type: NetworkSourceType.webdav,
      name: 'name',
      host: host,
      port: port,
      share: share,
      useTls: useTls,
    );

    test('builds the base URL from the source', () {
      expect(WebDavFileSystem.baseUriOf(source('nas')).toString(), 'http://nas/');
      expect(
        WebDavFileSystem.baseUriOf(
          source('nas', port: 8443, share: 'remote.php/dav/files/alice%40example.com/', useTls: true),
        ).toString(),
        'https://nas:8443/remote.php/dav/files/alice@example.com',
      );
      expect(WebDavFileSystem.baseUriOf(source('nas', share: '/My Files')).toString(), 'http://nas/My%20Files');
    });

    test('is lenient with an address typed as a URL', () {
      expect(WebDavFileSystem.baseUriOf(source(' http://nas.local:5005/ ')).toString(), 'http://nas.local:5005/');
      expect(WebDavFileSystem.baseUriOf(source('[fe80::1]:8080')).toString(), 'http://[fe80::1]:8080/');
      expect(WebDavFileSystem.baseUriOf(source('nas:5005', port: 80)).port, 80);
    });

    test('refuses an empty address', () {
      expect(() => WebDavFileSystem.baseUriOf(source('  ')), throwsA(isA<NetworkFileSystemException>()));
    });
  });

  group('parseWebDavMultistatus', () {
    test('reads a default namespace, comments, CDATA, entities and failed statuses', () {
      const xml = '''\uFEFF<?xml version="1.0" encoding="utf-8"?>
<!-- generated -->
<!DOCTYPE multistatus [ <!ENTITY test "x"> ]>
<multistatus xmlns="DAV:">
  <response>
    <href>http://nas.local/dav/My%20Photos/</href>
    <propstat>
      <prop><resourcetype><collection/></resourcetype><displayname><![CDATA[My <Photos>]]></displayname></prop>
      <status>HTTP/1.1 200 OK</status>
    </propstat>
    <propstat><prop><getcontentlength/></prop><status>HTTP/1.1 404 Not Found</status></propstat>
  </response>
  <response>
    <href>/dav/My%20Photos/Tom%20&amp;%20Jerry%E2%80%99s.jpg</href>
    <propstat>
      <prop>
        <getcontentlength> 1234 </getcontentlength>
        <getlastmodified>Wed, 30 Sep 2026 12:00:00 GMT</getlastmodified>
        <getcontenttype>image/jpeg</getcontenttype>
        <resourcetype/>
        <x:getcontentlength xmlns:x="http://example.com/ns">999</x:getcontentlength>
      </prop>
      <status>HTTP/1.1 200 OK</status>
    </propstat>
  </response>
  <response><href>/dav/gone.jpg</href><status>HTTP/1.1 404 Not Found</status></response>
</multistatus>''';
      final resources = parseWebDavMultistatus(xml)!;
      expect(resources, hasLength(2));
      expect(resources[0].href, '/dav/My Photos/');
      expect(resources[0].isCollection, isTrue);
      expect(resources[0].displayName, 'My <Photos>');
      expect(resources[0].contentLength, isNull);
      expect(resources[1].href, '/dav/My Photos/Tom & Jerry’s.jpg');
      expect(resources[1].isCollection, isFalse);
      expect(resources[1].contentLength, 1234);
      expect(resources[1].lastModified, DateTime.utc(2026, 9, 30, 12));
      expect(resources[1].contentType, 'image/jpeg');
    });

    test('reads any prefix bound to DAV:, and Microsoft iscollection', () {
      const xml =
          '<a:multistatus xmlns:a="DAV:" xmlns:b="urn:uuid:c2f41010-65b3-11d1-a29f-00aa00c14882/">'
          '<a:response><a:href>/f%25older/</a:href><a:propstat><a:status>HTTP/1.1 200 OK</a:status>'
          '<a:prop><a:iscollection b:dt="boolean">1</a:iscollection><a:resourcetype/></a:prop>'
          '</a:propstat></a:response></a:multistatus>';
      final resources = parseWebDavMultistatus(xml)!;
      expect(resources.single.href, '/f%older/');
      expect(resources.single.isCollection, isTrue);
    });

    test('is null for an answer that is not a multistatus', () {
      expect(parseWebDavMultistatus('<html><body>Hello</body></html>'), isNull);
      expect(parseWebDavMultistatus(''), isNull);
    });
  });

  group(
    'WebDavFileSystem against the WebDAV test server of this machine',
    () {
      const source = NetworkSource(
        id: 'local-webdav',
        type: NetworkSourceType.webdav,
        name: 'Local WebDAV',
        host: 'localhost',
        port: 1880,
        username: 'tester',
      );
      WebDavFileSystem? fileSystem;

      setUpAll(() async {
        fileSystem = await WebDavFileSystem.open(source, 'testpass');
      });

      tearDownAll(() async {
        await fileSystem?.close();
      });

      test('lists the root, with the "sub" folder first', () async {
        final entries = await fileSystem!.list('/');
        final sub = entries.firstWhere((e) => e.name == 'sub');
        expect(sub.isDirectory, isTrue);
        expect(sub.path, '/sub');
        expect(entries.first.isDirectory, isTrue);
        expect(entries.where((e) => e.name == 'mono-video.mp4').single.isVideo, isTrue);
        expect(entries.any((e) => e.path == '/'), isFalse);
        await fileSystem!.list(sub.path);
      });

      test('reads the first and the last 100 bytes of mono-video.mp4', () async {
        final first = await fileSystem!.readRange('/mono-video.mp4', 0, 100);
        expect(first, hasLength(100));
        expect(ascii.decode(first.sublist(4, 8)), 'ftyp');

        final size = (await fileSystem!.stat('/mono-video.mp4')).size!;
        final last = await fileSystem!.readRange('/mono-video.mp4', size - 100, 100);
        expect(last, hasLength(100));
        // The same bytes as a plain suffix range request
        final client = http.Client();
        try {
          final response = await client.get(
            Uri.parse('http://localhost:1880/mono-video.mp4'),
            headers: {'authorization': 'Basic ${base64.encode(utf8.encode('tester:testpass'))}', 'range': 'bytes=-100'},
          );
          expect(response.statusCode, HttpStatus.partialContent);
          expect(last, response.bodyBytes);
        } finally {
          client.close();
        }
        expect(await fileSystem!.readRange('/mono-video.mp4', size - 10, 100), hasLength(10));
        expect(await fileSystem!.readRange('/mono-video.mp4', size, 100), isEmpty);
        expect(fileSystem!.supportsRanges, isTrue);
      });

      test('stats a jpg', () async {
        final entries = await fileSystem!.list('/');
        final jpg = entries.firstWhere((e) => e.extension == 'jpg');
        final stat = await fileSystem!.stat(jpg.path);
        expect(stat.isDirectory, isFalse);
        expect(stat.isImage, isTrue);
        expect(stat.size, jpg.size);
        expect(stat.size, greaterThan(0));
        expect(stat.mimeType, 'image/jpeg');
        expect(stat.modified, isNotNull);
      });

      test('stats the "sub" folder asked without its trailing slash', () async {
        final sub = await fileSystem!.stat('/sub');
        expect(sub.isDirectory, isTrue);
      });

      test('a wrong password is an authentication failure', () async {
        await expectLater(
          WebDavFileSystem.open(source, 'wrong'),
          throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
        );
      });
    },
    skip: Platform.environment['IMMUCH_NET_TESTS'] == '1'
        ? false
        : 'Set IMMUCH_NET_TESTS=1 to run against the test servers of the development machine',
  );
}
