import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/network/upnp/dlna_file_system.dart';

/// A container or an item of the fake server; an item serves [bytes] at [file]
class _Object {
  _Object.folder(this.id, this.parent, this.title)
    : file = null,
      mime = '',
      bytes = null,
      upnpClass = 'object.container';

  _Object.file(this.id, this.parent, this.title, this.file, this.mime, this.bytes, {String? upnpClass})
    : upnpClass = upnpClass ?? (mime.startsWith('video/') ? 'object.item.videoItem' : 'object.item.imageItem.photo');

  final String id;
  final String parent;
  final String title;
  final String? file;
  final String mime;
  final Uint8List? bytes;
  final String upnpClass;
}

typedef _Request = ({String method, String path, Map<String, String> headers, String body});

/// A tiny DLNA media server: a device description, the Browse action of its ContentDirectory with paging, and the files
/// of its items with or without Range support
class _FakeDlnaServer {
  late HttpServer _server;

  int get port => _server.port;

  final List<_Object> objects = [];
  final List<_Request> requests = [];

  /// Ids the server no longer knows (UPnP error 701)
  final Set<String> unknownIds = {};

  /// The fault code for [unknownIds]
  int unknownIdError = 701;
  bool supportRanges = true;

  /// Leaves the size attribute out of the resources
  bool withoutSizes = false;

  /// Answers 406 to a read without the DLNA transfer mode header
  bool needsTransferMode = false;

  /// The host written in the resource URLs, null for the one the request came to
  String? resourceHost;

  /// Paths of files that answer 404
  final Set<String> goneFiles = {};

  /// Like minidlna: a range that ends past the end of the file gets a 416
  bool strictRangeEnd = false;

  /// Like Gerbera: a connection kept open by the client is dropped at its second request, without an answer
  bool dropsKeptConnections = false;
  final Set<int> _servedPorts = {};
  int droppedConnections = 0;

  int browseStatus = 200;
  String description = 'normal';

  /// 'huge': the Browse answers are 17 MiB of spaces; 'drip': one space every 100 ms, for 10 s
  String browseAnswer = 'normal';

  /// The Content-Range of the parts of files, instead of the right one
  String? contentRange;

  NetworkSource source({String rootPath = '/'}) => NetworkSource(
    id: 'dlna-1',
    type: NetworkSourceType.dlna,
    name: 'Media server',
    host: '127.0.0.1',
    port: port,
    share: '/rootDesc.xml?v=1',
    rootPath: rootPath,
  );

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  List<_Request> get browses => requests.where((r) => r.method == 'POST').toList();

  List<_Request> get gets => requests.where((r) => r.method == 'GET' && r.path.startsWith('/media/')).toList();

  /// (ObjectID, StartingIndex, RequestedCount) of each Browse
  List<(String, int, int)> get browsed => [
    for (final request in browses)
      (
        decodeXmlEntities(RegExp('<ObjectID>(.*?)</ObjectID>').firstMatch(request.body)!.group(1)!),
        int.parse(RegExp(r'<StartingIndex>(\d+)</StartingIndex>').firstMatch(request.body)!.group(1)!),
        int.parse(RegExp(r'<RequestedCount>(\d+)</RequestedCount>').firstMatch(request.body)!.group(1)!),
      ),
  ];

  Future<void> _handle(HttpRequest request) async {
    final port = request.connectionInfo!.remotePort;
    if (dropsKeptConnections && !_servedPorts.add(port)) {
      droppedConnections++;
      (await request.response.detachSocket(writeHeaders: false)).destroy();
      return;
    }
    final body = await utf8.decodeStream(request);
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name] = values.join(', '));
    requests.add((method: request.method, path: request.uri.toString(), headers: headers, body: body));
    final response = request.response;
    if (request.method == 'POST' && browseAnswer != 'normal') {
      await _answerWithoutEnd(response);
      return;
    }
    try {
      if (request.method == 'GET' && request.uri.path == '/rootDesc.xml') {
        _describe(response);
      } else if (request.method == 'POST' && request.uri.path == '/ctl/ContentDir') {
        _browse(body, response, request.requestedUri.host);
      } else if (request.method == 'GET' && request.uri.path.startsWith('/media/')) {
        await _serve(request, response);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } finally {
      await response.close();
    }
  }

  /// A Browse answer the client has to cut, see [browseAnswer]
  Future<void> _answerWithoutEnd(HttpResponse response) async {
    try {
      response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      if (browseAnswer == 'huge') {
        final block = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 0x20);
        for (var i = 0; i < 17; i++) {
          response.add(block);
          await response.flush();
        }
      } else {
        for (var i = 0; i < 100; i++) {
          response.write(' ');
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      await response.close();
    } catch (_) {
      // The client stopped reading
    }
  }

  void _describe(HttpResponse response) {
    if (description == 'missing') {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    final service = description == 'router'
        ? 'urn:schemas-upnp-org:service:WANIPConnection:1'
        : 'urn:schemas-upnp-org:service:ContentDirectory:1';
    response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    response.write(
      '<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>'
      '<deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><friendlyName>Test server</friendlyName>'
      '<UDN>uuid:test-server</UDN><serviceList><service><serviceType>$service</serviceType>'
      '<controlURL>/ctl/ContentDir</controlURL></service></serviceList></device></root>',
    );
  }

  void _browse(String body, HttpResponse response, String host) {
    if (browseStatus != 200) {
      response.statusCode = browseStatus;
      return;
    }
    final id = decodeXmlEntities(RegExp('<ObjectID>(.*?)</ObjectID>').firstMatch(body)!.group(1)!);
    final start = int.parse(RegExp(r'<StartingIndex>(\d+)</StartingIndex>').firstMatch(body)!.group(1)!);
    final count = int.parse(RegExp(r'<RequestedCount>(\d+)</RequestedCount>').firstMatch(body)!.group(1)!);
    response.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    if (unknownIds.contains(id) || (id != '0' && !objects.any((o) => o.id == id))) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault><faultcode>s:Client'
        '</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
        '<errorCode>$unknownIdError</errorCode><errorDescription>No such object</errorDescription></UPnPError></detail>'
        '</s:Fault></s:Body></s:Envelope>',
      );
      return;
    }
    final children = objects.where((o) => o.parent == id).toList();
    final page = children.skip(start).take(count).toList();
    final resourceHost = this.resourceHost ?? host;
    final didl = StringBuffer(
      '<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
      'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">',
    );
    for (final object in page) {
      if (object.file == null) {
        didl.write(
          '<container id="${object.id}" parentID="$id" restricted="1"><dc:title>${escapeXmlText(object.title)}'
          '</dc:title><upnp:class>${object.upnpClass}</upnp:class></container>',
        );
        continue;
      }
      final size = withoutSizes ? '' : ' size="${object.bytes!.length}"';
      final video = object.mime.startsWith('video/');
      didl.write(
        '<item id="${object.id}" parentID="$id" restricted="1"><dc:title>${escapeXmlText(object.title)}</dc:title>'
        '<upnp:class>${object.upnpClass}</upnp:class><dc:date>2024-09-08T13:30:36</dc:date>'
        '<res$size${video ? ' duration="0:00:03.000" resolution="1024x512"' : ' resolution="640x480"'} '
        'protocolInfo="http-get:*:${object.mime}:DLNA.ORG_OP=01;DLNA.ORG_CI=0">'
        'http://$resourceHost:$port${object.file}</res>'
        '<upnp:albumArtURI>http://$resourceHost:$port/art/${object.id}.jpg</upnp:albumArtURI></item>',
      );
    }
    didl.write('</DIDL-Lite>');
    response.write(
      '<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:BrowseResponse '
      'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result>${escapeXmlText(didl.toString())}</Result>'
      '<NumberReturned>${page.length}</NumberReturned><TotalMatches>${children.length}</TotalMatches>'
      '<UpdateID>1</UpdateID></u:BrowseResponse></s:Body></s:Envelope>',
    );
  }

  Future<void> _serve(HttpRequest request, HttpResponse response) async {
    final object = objects.where((o) => o.file == request.uri.path).firstOrNull;
    if (object == null || goneFiles.contains(request.uri.path)) {
      response.statusCode = HttpStatus.notFound;
      return;
    }
    if (needsTransferMode && request.headers.value('transferMode.dlna.org') == null) {
      response.statusCode = HttpStatus.notAcceptable;
      return;
    }
    final bytes = object.bytes!;
    response.headers.contentType = ContentType.parse(object.mime);
    final range = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (!supportRanges || range == null) {
      response.contentLength = bytes.length;
      response.add(bytes);
      return;
    }
    final start = int.parse(range.group(1)!);
    if (start >= bytes.length) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${bytes.length}');
      return;
    }
    final asked = range.group(2)!;
    if (strictRangeEnd && asked.isNotEmpty && int.parse(asked) >= bytes.length) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      return;
    }
    final end = asked.isEmpty ? bytes.length - 1 : [int.parse(asked), bytes.length - 1].reduce((a, b) => a < b ? a : b);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(HttpHeaders.contentRangeHeader, contentRange ?? 'bytes $start-$end/${bytes.length}');
    response.contentLength = end - start + 1;
    response.add(bytes.sublist(start, end + 1));
  }
}

Uint8List _bytes(int length, int seed) => Uint8List.fromList(List.generate(length, (i) => (i * 7 + seed) % 251));

void main() {
  late _FakeDlnaServer server;
  final pano = _bytes(300000, 1);
  final photo = _bytes(5000, 2);
  final clip = _bytes(20000, 3);

  setUp(() async {
    server = _FakeDlnaServer();
    await server.start();
    server.objects.addAll([
      _Object.file('10', '0', 'pano_360', '/media/10.mp4', 'video/mp4', pano),
      _Object.folder(r'64$1', '0', 'Trips'),
      _Object.file('11', '0', 'photo', '/media/11.jpg', 'image/jpeg', photo),
      _Object.folder('20', '0', 'Patterns'),
      _Object.file('12', '0', 'song', '/media/12.mp3', 'audio/mpeg', clip, upnpClass: 'object.item.audioItem'),
      _Object.file('13', '0', 'photo', '/media/13.jpg', 'image/jpeg', photo),
      _Object.file(r'64$1$1', r'64$1', 'clip', '/media/21.mp4', 'video/mp4', clip),
      _Object.folder(r'64$1$2', r'64$1', '2024 / summer'),
      _Object.file(r'64$1$2$1', r'64$1$2', 'beach', '/media/31.jpg', 'image/jpeg', photo),
    ]);
  });

  tearDown(() => server.close());

  Future<DlnaFileSystem> open({String rootPath = '/'}) async {
    final fileSystem = await DlnaFileSystem.open(server.source(rootPath: rootPath), null, pageSize: 2);
    addTearDown(fileSystem.close);
    return fileSystem;
  }

  group('DlnaFileSystem.open', () {
    test('reads the description and lists the start folder, every page of it', () async {
      final fileSystem = await open();

      expect(fileSystem.device.friendlyName, 'Test server');
      expect(fileSystem.device.udn, 'uuid:test-server');
      expect(server.requests.first.path, '/rootDesc.xml?v=1');
      expect(server.browsed, [('0', 0, 2), ('0', 2, 2), ('0', 4, 2)]);
      final browse = server.browses.first;
      expect(browse.headers['content-type'], 'text/xml; charset="utf-8"');
      expect(browse.headers['soapaction'], '"urn:schemas-upnp-org:service:ContentDirectory:1#Browse"');
      expect(browse.headers['user-agent'], 'Immuch360/3.3 UPnP/1.0 DLNADOC/1.50');
      expect(browse.body, browseRequestBody('0', 0, 2, 'urn:schemas-upnp-org:service:ContentDirectory:1'));
      expect(
        browse.body,
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Browse '
        'xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>0</ObjectID>'
        '<BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>0</StartingIndex>'
        '<RequestedCount>2</RequestedCount><SortCriteria>'
        '</SortCriteria></u:Browse></s:Body></s:Envelope>',
      );
    });

    test('refuses another type of source', () async {
      await expectLater(
        DlnaFileSystem.open(const NetworkSource(id: 'x', type: NetworkSourceType.webdav, name: 'x', host: 'h'), null),
        throwsArgumentError,
      );
    });

    test(
      'tells a server without description, a device that is no media server, and a share that cannot be reached',
      () async {
        server.description = 'missing';
        await expectLater(
          DlnaFileSystem.open(server.source(), null),
          throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('HTTP 404'))),
        );

        server.description = 'router';
        await expectLater(
          DlnaFileSystem.open(server.source(), null),
          throwsA(
            isA<NetworkFileSystemException>().having(
              (e) => e.message,
              'message',
              '127.0.0.1 is not a DLNA media server',
            ),
          ),
        );

        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();
        await expectLater(
          DlnaFileSystem.open(server.source().copyWith(port: port), null),
          throwsA(
            isA<NetworkFileSystemException>().having((e) => e.message, 'message', startsWith('Cannot reach 127.0.0.1')),
          ),
        );
      },
    );

    test('tells a server that wants a password, and a start folder that does not exist', () async {
      server.browseStatus = 401;
      await expectLater(
        DlnaFileSystem.open(server.source(), null),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'isAuthentication', isTrue)),
      );

      server.browseStatus = 200;
      await expectLater(
        DlnaFileSystem.open(server.source(rootPath: '/Nowhere'), null),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('builds the description URL of a source', () {
      expect(
        DlnaFileSystem.descriptionUriOf(server.source().copyWith(port: 8200)),
        Uri.parse('http://127.0.0.1:8200/rootDesc.xml?v=1'),
      );
      expect(
        DlnaFileSystem.descriptionUriOf(
          const NetworkSource(
            id: 'x',
            type: NetworkSourceType.dlna,
            name: 'x',
            host: ' [fe80::1] ',
            share: 'desc.xml',
            useTls: true,
          ),
        ),
        Uri.parse('https://[fe80::1]/desc.xml'),
      );
      expect(
        () => DlnaFileSystem.descriptionUriOf(
          const NetworkSource(id: 'x', type: NetworkSourceType.dlna, name: 'x', host: ' '),
        ),
        throwsA(isA<NetworkFileSystemException>()),
      );
    });
  });

  group('DlnaFileSystem.list', () {
    test('gives the folders, photos and videos of a folder, named after their titles, sorted', () async {
      final fileSystem = await open();
      final browses = server.browses.length;

      final entries = await fileSystem.list('/');

      expect(server.browses, hasLength(browses), reason: 'the listing made by open serves the first list');
      expect(
        [for (final entry in entries) entry.path],
        ['/Patterns', '/Trips', '/pano_360.mp4', '/photo (2).jpg', '/photo.jpg'],
      );
      final video = entries[2];
      expect(video.isDirectory, isFalse);
      expect(video.isVideo, isTrue);
      expect(video.size, pano.length);
      expect(video.mimeType, 'video/mp4');
      expect(video.modified, DateTime(2024, 9, 8, 13, 30, 36));
      expect(video.durationMs, 3000);
      expect(video.width, 1024);
      expect(video.height, 512);
      expect(video.thumbnailUrl, 'http://127.0.0.1:${server.port}/art/10.jpg');
      expect(entries.first.isDirectory, isTrue);

      await fileSystem.list('/');
      expect(server.browses.length, greaterThan(browses), reason: 'a list asks the server again');
    });

    test('goes down into folders by name, titles with a slash included', () async {
      final fileSystem = await open();

      final trips = await fileSystem.list('/Trips/');
      expect([for (final entry in trips) entry.path], ['/Trips/2024 _ summer', '/Trips/clip.mp4']);

      final summer = await fileSystem.list('/Trips/2024 _ summer');
      expect(summer.single.path, '/Trips/2024 _ summer/beach.jpg');
      expect(server.browsed.map((b) => b.$1).toSet(), {'0', r'64$1', r'64$1$2'});
    });

    test('finds a deep folder from a fresh connection by listing its parents', () async {
      final fileSystem = await open(rootPath: '/Trips/2024 _ summer');

      expect(server.browsed.map((b) => b.$1).toList(), ['0', '0', '0', r'64$1', r'64$1$2']);
      expect((await fileSystem.list('/Trips/2024 _ summer')).single.name, 'beach.jpg');
    });

    test('tells a missing folder and a file listed as a folder', () async {
      final fileSystem = await open();

      await expectLater(
        fileSystem.list('/Nowhere'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
      await expectLater(
        fileSystem.list('/photo.jpg'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', '/photo.jpg is not a folder')),
      );
    });

    test('walks the tree again from the root once the server forgot the ids of a rescan', () async {
      final fileSystem = await open();
      await fileSystem.list('/Trips');

      // A rescan: new ids for the same folders and files
      server.objects
        ..removeWhere((o) => o.parent == r'64$1' || o.id == r'64$1')
        ..addAll([
          _Object.folder('99', '0', 'Trips'),
          _Object.file('98', '99', 'clip', '/media/98.mp4', 'video/mp4', clip),
        ]);
      server.unknownIds.add(r'64$1');

      final trips = await fileSystem.list('/Trips');

      expect(trips.single.path, '/Trips/clip.mp4');
      expect(server.browsed.map((b) => b.$1).toList().sublist(server.browsed.length - 5), [
        r'64$1',
        '0',
        '0',
        '0',
        '99',
      ]);
      final bytes = await fileSystem.readRange('/Trips/clip.mp4', 0, 10);
      expect(bytes, clip.sublist(0, 10));
      expect(server.gets.last.path, '/media/98.mp4');
    });

    test('walks again after a fault other than 701 on a folder, as Gerbera answers 501 for an id it lost', () async {
      final fileSystem = await open();
      await fileSystem.list('/Trips');
      server.unknownIdError = 501;
      server.objects.removeWhere((o) => o.id == r'64$1' || o.parent == r'64$1');
      server.unknownIds.add(r'64$1');

      await expectLater(
        fileSystem.list('/Trips'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('tells the UPnP error of a fault on the root', () async {
      final fileSystem = await open();
      // The listing made by open
      await fileSystem.list('/');
      server.unknownIdError = 720;
      server.unknownIds.add('0');

      await expectLater(
        fileSystem.list('/'),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (e) => e.message,
            'message',
            'The media server refused to list / (UPnP error 720)',
          ),
        ),
      );
    });
  });

  group('DlnaFileSystem.stat', () {
    test('gives the root, folders and files from the listings', () async {
      final fileSystem = await open();

      expect((await fileSystem.stat('/')).isDirectory, isTrue);
      expect((await fileSystem.stat('/Trips')).isDirectory, isTrue);
      final file = await fileSystem.stat('/Trips/clip.mp4');
      expect(file.size, clip.length);
      expect(file.mimeType, 'video/mp4');
      await expectLater(
        fileSystem.stat('/Trips/nothing.mp4'),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('asks for the first byte when the server does not tell the size', () async {
      server.withoutSizes = true;
      final fileSystem = await open();
      expect((await fileSystem.list('/')).firstWhere((e) => e.name == 'photo.jpg').size, isNull);

      final stat = await fileSystem.stat('/photo.jpg');

      expect(stat.size, photo.length);
      expect(server.gets.single.headers['range'], 'bytes=0-0');
      await fileSystem.stat('/photo.jpg');
      expect(server.gets, hasLength(1), reason: 'the size found is kept');
    });

    test('takes the length of the whole file from a server that ignores ranges, without reading it', () async {
      server
        ..withoutSizes = true
        ..supportRanges = false;
      final fileSystem = await open();

      expect((await fileSystem.stat('/pano_360.mp4')).size, pano.length);
    });
  });

  group('DlnaFileSystem.readRange', () {
    test('reads parts of a file with ranges, and nothing past its end', () async {
      final fileSystem = await open();

      expect(await fileSystem.readRange('/pano_360.mp4', 1000, 64), pano.sublist(1000, 1064));
      expect(server.gets.last.headers['range'], 'bytes=1000-1063');
      expect(server.gets.last.headers['user-agent'], 'Immuch360/3.3 UPnP/1.0 DLNADOC/1.50');
      expect(await fileSystem.readRange('/pano_360.mp4', pano.length - 10, 64), pano.sublist(pano.length - 10));
      expect(await fileSystem.readRange('/pano_360.mp4', pano.length + 10, 64), isEmpty);
      expect(await fileSystem.readRange('/pano_360.mp4', 0, 0), isEmpty);
    });

    test('reads from a server that ignores ranges', () async {
      server.supportRanges = false;
      final fileSystem = await open();

      expect(await fileSystem.readRange('/pano_360.mp4', 0, 100), pano.sublist(0, 100));
      expect(await fileSystem.readRange('/pano_360.mp4', 200000, 100), pano.sublist(200000, 200100));
    });

    test('tries again with the DLNA transfer mode after a 406, and keeps sending it', () async {
      server.needsTransferMode = true;
      final fileSystem = await open();

      expect(await fileSystem.readRange('/pano_360.mp4', 0, 10), pano.sublist(0, 10));
      expect(server.gets.map((r) => r.headers['transfermode.dlna.org']).toList(), [null, 'Streaming']);
      expect(await fileSystem.readRange('/photo.jpg', 0, 10), photo.sublist(0, 10));
      expect(server.gets.last.headers['transfermode.dlna.org'], 'Interactive');
      expect(server.gets, hasLength(3));
    });

    test('reads a file the server moved after a rescan, from a new walk', () async {
      final fileSystem = await open();
      await fileSystem.readRange('/photo.jpg', 0, 10);
      server.goneFiles.add('/media/11.jpg');
      final index = server.objects.indexWhere((o) => o.id == '11');
      server.objects[index] = _Object.file('11', '0', 'photo', '/media/111.jpg', 'image/jpeg', photo);

      expect(await fileSystem.readRange('/photo.jpg', 5, 10), photo.sublist(5, 15));
      expect(server.gets.last.path, '/media/111.jpg');

      server.goneFiles.add('/media/111.jpg');
      await expectLater(
        fileSystem.readRange('/photo.jpg', 0, 10),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('reaches the resources a server gives under its private address on the port of its description', () async {
      server.resourceHost = '172.17.0.2';
      final fileSystem = await open();
      final entries = await fileSystem.list('/');

      expect(await fileSystem.readRange('/photo.jpg', 0, 10), photo.sublist(0, 10));
      expect(
        entries.firstWhere((e) => e.name == 'photo.jpg').thumbnailUrl,
        'http://127.0.0.1:${server.port}/art/11.jpg',
      );
    });

    test('refuses a resource on a public address, and drops its album art', () async {
      server.resourceHost = '8.8.8.8';
      final fileSystem = await open();
      final entries = await fileSystem.list('/');

      expect(entries.firstWhere((e) => e.name == 'photo.jpg').thumbnailUrl, isNull);
      await expectLater(
        fileSystem.readRange('/photo.jpg', 0, 10),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (e) => e.message,
            'message',
            'The media server points to 8.8.8.8, outside the local network',
          ),
        ),
      );
      expect(server.gets, isEmpty);
    });

    test('asks no byte past the end, which minidlna refuses', () async {
      server.strictRangeEnd = true;
      final fileSystem = await open();

      expect(await fileSystem.readRange('/photo.jpg', 0, 64 * 1024), photo);
      expect(server.gets.last.headers['range'], 'bytes=0-${photo.length - 1}');
      expect(await fileSystem.readRange('/photo.jpg', photo.length - 10, 64), photo.sublist(photo.length - 10));
      expect(await fileSystem.readRange('/photo.jpg', photo.length, 64), isEmpty);
      expect(server.gets, hasLength(2), reason: 'nothing asked past the end');
    });

    test('learns the size of a file the listing does not tell before reading its end', () async {
      server
        ..strictRangeEnd = true
        ..withoutSizes = true;
      final fileSystem = await open();

      expect(await fileSystem.readRange('/photo.jpg', 100, 64 * 1024), photo.sublist(100));
      expect(server.gets.map((r) => r.headers['range']).toList(), ['bytes=0-0', 'bytes=100-${photo.length - 1}']);
    });

    test('tells a folder read as a file', () async {
      final fileSystem = await open();

      await expectLater(fileSystem.readRange('/Trips', 0, 10), throwsA(isA<NetworkFileSystemException>()));
    });
  });

  test('opens a new connection for each request once the server dropped one it kept open, as Gerbera does', () async {
    server.dropsKeptConnections = true;
    final fileSystem = await open();

    expect((await fileSystem.list('/Trips/2024 _ summer')).single.name, 'beach.jpg');
    expect(await fileSystem.readRange('/Trips/clip.mp4', 0, 10), clip.sublist(0, 10));
    expect(await fileSystem.readRange('/Trips/clip.mp4', 10, 10), clip.sublist(10, 20));
    expect(server.droppedConnections, 1, reason: 'one request failed, then each went on a connection of its own');
  });

  group('DlnaFileSystem, answers that do not read', () {
    test('stops reading a Browse answer past 16 MiB', () async {
      final fileSystem = await open();
      server.browseAnswer = 'huge';

      await expectLater(
        fileSystem.list('/Trips'),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (e) => e.message,
            'message',
            'The media server answered more than 16 MiB for /Trips',
          ),
        ),
      );
    });

    test('gives up on a Browse answer that takes too long, however short its pauses', () async {
      final fileSystem = await DlnaFileSystem.open(
        server.source(),
        null,
        pageSize: 2,
        browseTimeout: const Duration(seconds: 1),
      );
      addTearDown(fileSystem.close);
      server.browseAnswer = 'drip';
      final clock = Stopwatch()..start();

      await expectLater(
        fileSystem.list('/Trips'),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (e) => e.message,
            'message',
            'The server at 127.0.0.1 did not answer in time',
          ),
        ),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)), reason: 'its answer comes for 10 s');
    });

    test('tells an answer with a number too long to read as not one of a media server', () async {
      final fileSystem = await open();
      server.contentRange = 'bytes 99999999999999999999999-9/20000';

      await expectLater(
        fileSystem.readRange('/Trips/clip.mp4', 0, 10),
        throwsA(
          isA<NetworkFileSystemException>().having(
            (e) => e.message,
            'message',
            'The server at 127.0.0.1 did not answer like a DLNA media server',
          ),
        ),
      );
    });
  });

  test('close ends the use of the connection', () async {
    final fileSystem = await DlnaFileSystem.open(server.source(), null);

    await fileSystem.close();
    await fileSystem.close();

    await expectLater(
      fileSystem.list('/Trips'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.message, 'message', 'The share is closed')),
    );
  });
}
