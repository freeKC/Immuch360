// A small Plex Media Server on 127.0.0.1 for the tests of the Plex client: /identity, the sections, the folder view
// with its paging headers, the albums of a photo section, the parts with or without Range support, the photo
// transcoder, the account and the preferences. Every answer but /identity wants the test token in its header, as a
// real server does, and answers 401 in HTML otherwise. The values are the synthetic ones of test/fixtures/plex.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const plexTestToken = 'TEST-TOKEN-0000000000';
const plexTestHash = '0123456789abcdef0123456789abcdef';
const plexTestMachine = '0000000000000000000000000000000000000001';

/// One request the server received
typedef PlexTestRequest = ({String method, String path, String? query, Map<String, String> headers});

Map<String, Object?> plexFolder(String key, String title) => {'key': key, 'title': title};

Map<String, Object?> plexFile(
  int id,
  String file,
  int? size, {
  String container = 'mp4',
  bool thumb = true,
  int addedAt = 1600000000,
  int width = 1920,
  int height = 1080,
}) => {
  'ratingKey': '$id',
  'key': '/library/metadata/$id',
  'type': container == 'jpeg' ? 'photo' : 'movie',
  'title': 'Title $id',
  'addedAt': addedAt + id,
  'updatedAt': 1700000000,
  if (thumb) 'thumb': '/library/metadata/$id/thumb/1700000000',
  'Media': [
    {
      'id': id,
      'width': width,
      'height': height,
      'duration': 60000,
      'container': container,
      'Part': [
        {
          'id': id,
          'key': '/library/parts/$id/1700000000/file.$container',
          'file': file,
          'size': ?size,
          'container': container,
          'duration': 60000,
        },
      ],
    },
  ],
};

/// The bytes of part [id], [size] long: each byte tells its offset, so that a read shows where it came from
Uint8List plexPartBytes(int id, int size) => Uint8List.fromList([for (var i = 0; i < size; i++) (i * 7 + id) % 256]);

class FakePlexServer {
  FakePlexServer._(this._server) {
    _server.listen(_answer);
  }

  static Future<FakePlexServer> start() async =>
      FakePlexServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  int get port => _server.port;
  Uri get base => Uri.parse('http://127.0.0.1:$port');

  final List<PlexTestRequest> requests = [];

  String machineIdentifier = plexTestMachine;
  String token = plexTestToken;

  /// Answers 403 to everything but /identity, like a server to a user without the right to read
  bool forbidden = false;
  bool supportRanges = true;

  /// Waits this long before answering /identity
  Duration identityDelay = Duration.zero;

  /// Waits this long before answering some paths (without the query) or paths with their query
  final Map<String, Duration> delays = {};

  /// The elements of each listing, by its path and query; paged by the X-Plex-Container-* headers
  final Map<String, List<Map<String, Object?>>> listings = {
    '/library/sections/1/folder': [
      plexFolder('/library/sections/1/folder?parent=101', 'Holidays'),
      plexFile(11, '/data/movies/a.mp4', 1000),
      plexFolder('/library/sections/1/folder?parent=103', 'holidays'),
      plexFile(12, '/data/movies/b.jpg', 600, container: 'jpeg', width: 4000, height: 2000),
    ],
    '/library/sections/1/folder?parent=101': [
      plexFile(21, '/data/movies/Holidays/beach.mp4', 5000),
      plexFile(22, r'D:\Plex\Holidays\beach.mp4', null, thumb: false),
    ],
    '/library/sections/1/folder?parent=103': [plexFile(31, '/data/movies/holidays/c.mp4', 10)],
    '/library/sections/2/all': [
      plexFolder('/library/metadata/500/children', 'Summer'),
      plexFile(51, '/data/photos/loose.jpg', 300, container: 'jpeg'),
    ],
    '/library/metadata/500/children': [plexFile(52, '/data/photos/Summer/pano.jpg', 400, container: 'jpeg')],
  };

  /// Leaves totalSize out of the listings
  bool withTotals = true;

  /// Statuses forced for some paths (without the query) or paths with their query
  final Map<String, int> statuses = {'/library/sections/2/folder': 404};

  /// Where some paths redirect to
  final Map<String, String> redirects = {};

  /// The sizes of the parts, by part id
  final Map<int, int> partSizes = {11: 1000, 12: 600, 21: 5000, 22: 3000, 31: 10, 51: 300, 52: 400};

  /// The pictures of the photo transcoder, by thumb path
  final Map<String, Uint8List> thumbnails = {
    '/library/metadata/21/thumb/1700000000': Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]),
  };

  Object? account = jsonDecode(File('test/fixtures/plex/account.json').readAsStringSync());
  Object? prefs = jsonDecode(File('test/fixtures/plex/prefs.json').readAsStringSync());

  Future<void> close() => _server.close(force: true);

  Future<void> _answer(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach((name, values) => headers[name.toLowerCase()] = values.join(','));
    final uri = request.uri;
    requests.add((method: request.method, path: uri.path, query: uri.hasQuery ? uri.query : null, headers: headers));
    final response = request.response;
    final full = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
    try {
      final delay = delays[full] ?? delays[uri.path];
      if (delay != null) {
        await Future<void>.delayed(delay);
      }
      if (uri.path == '/identity') {
        if (identityDelay > Duration.zero) {
          await Future<void>.delayed(identityDelay);
        }
        return await _json(response, {
          'MediaContainer': {
            'size': 0,
            'apiVersion': '1.1.0',
            'claimed': true,
            'machineIdentifier': machineIdentifier,
            'version': '1.42.1.10060-4e8b05daf',
          },
        });
      }
      if (headers['x-plex-token'] != token) {
        response.statusCode = 401;
        response.headers.contentType = ContentType.html;
        response.write('<html><head><title>Unauthorized</title></head><body><h1>401 Unauthorized</h1></body></html>');
        return await response.close();
      }
      if (forbidden) {
        response.statusCode = 403;
        return await response.close();
      }
      final redirect = redirects[full] ?? redirects[uri.path];
      if (redirect != null) {
        return await response.redirect(Uri.parse(redirect), status: 302);
      }
      final status = statuses[full] ?? statuses[uri.path];
      if (status != null) {
        response.statusCode = status;
        response.headers.contentType = ContentType.html;
        response.write('<html><body>$status</body></html>');
        return await response.close();
      }
      switch (uri.path) {
        case '/library/sections':
          return await _json(response, jsonDecode(File('test/fixtures/plex/sections.json').readAsStringSync()));
        case '/':
          return await _json(response, jsonDecode(File('test/fixtures/plex/server_root.json').readAsStringSync()));
        case '/myplex/account':
          return await _json(response, account);
        case '/:/prefs':
          return await _json(response, prefs);
        case '/photo/:/transcode':
          final picture = thumbnails[uri.queryParameters['url']];
          if (picture == null) {
            response.statusCode = 404;
            return await response.close();
          }
          response.headers.contentType = ContentType('image', 'jpeg');
          response.add(picture);
          return await response.close();
      }
      final part = RegExp(r'^/library/parts/(\d+)/').firstMatch(uri.path);
      if (part != null) {
        return await _part(request, int.parse(part.group(1)!));
      }
      final listing = listings[full];
      if (listing == null) {
        // A key the server does not know: an empty listing, as Plex answers a parent id it no longer has
        return await _json(response, {
          'MediaContainer': {'size': 0, 'offset': 0, if (withTotals) 'totalSize': 0},
        });
      }
      final start = int.tryParse(headers['x-plex-container-start'] ?? '') ?? 0;
      final size = int.tryParse(headers['x-plex-container-size'] ?? '') ?? listing.length;
      final page = listing.skip(start).take(size).toList();
      return await _json(response, {
        'MediaContainer': {
          'size': page.length,
          'offset': start,
          if (withTotals) 'totalSize': listing.length,
          'Metadata': page,
        },
      });
    } catch (_) {
      // The client went away
    }
  }

  Future<void> _json(HttpResponse response, Object? body) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _part(HttpRequest request, int id) async {
    final response = request.response;
    final size = partSizes[id];
    if (size == null) {
      response.statusCode = 404;
      return response.close();
    }
    final bytes = plexPartBytes(id, size);
    final range = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value('range') ?? '');
    response.headers.contentType = ContentType('video', 'mp4');
    if (range == null || !supportRanges) {
      response.contentLength = size;
      response.add(bytes);
      return response.close();
    }
    final start = int.parse(range.group(1)!);
    final end = range.group(2)!.isEmpty ? size - 1 : int.parse(range.group(2)!);
    if (start >= size) {
      response.statusCode = 416;
      response.headers.set('content-range', 'bytes */$size');
      return response.close();
    }
    final last = min(end, size - 1);
    response.statusCode = 206;
    response.headers.set('accept-ranges', 'bytes');
    response.headers.set('content-range', 'bytes $start-$last/$size');
    response.contentLength = last - start + 1;
    response.add(bytes.sublist(start, last + 1));
    return response.close();
  }
}
