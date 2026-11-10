// A Plex Media Server inside the app for the lab tests of Download (lab_plex_download_test.dart): one movie library
// holding one film, served from memory with Range and download=1, at a set pace so that a copy lasts long enough to
// be paused and to run while the app is in the background. Loopback only, plain HTTP, the lab token in a header. Never
// a real server.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const labPlexToken = 'LAB-PLEX-TOKEN-000000';
const labPlexHash = 'feedfacefeedfacefeedfacefeedface';
const labPlexMachine = 'lab0000000000000000000000000000000000001';

/// The film of the lab library: its path in the app, and its part on the server
const labPlexFilmPath = '/Films/Lab Film (2026).mkv';
const labPlexPartKey = '/library/parts/7/1700000000/file.mkv';

/// The bytes of the film, each telling its offset
Uint8List labPlexFilmBytes(int size) => Uint8List.fromList([for (var i = 0; i < size; i++) (i * 31 + 7) % 251]);

class LabPlexServer {
  LabPlexServer._(this._server, this.film, this.chunk, this.pause) {
    _server.listen((request) => unawaited(_answer(request)));
  }

  /// Serves a film of [size] bytes in chunks of [chunk] bytes, [pause] between two
  static Future<LabPlexServer> start({
    int size = 24 * 1024 * 1024,
    int chunk = 64 * 1024,
    Duration pause = const Duration(milliseconds: 15),
  }) async =>
      LabPlexServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), labPlexFilmBytes(size), chunk, pause);

  final HttpServer _server;
  final Uint8List film;
  final int chunk;
  final Duration pause;

  /// The Range header (or "none") and the query of each request of the part
  final List<({String range, String query, bool token})> partRequests = [];

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);

  Future<void> _answer(HttpRequest request) async {
    final response = request.response;
    final uri = request.uri;
    try {
      if (uri.path == '/identity') {
        return await _json(response, {
          'MediaContainer': {'size': 0, 'claimed': true, 'machineIdentifier': labPlexMachine, 'version': '1.42.1'},
        });
      }
      if (request.headers.value('x-plex-token') != labPlexToken) {
        response.statusCode = 401;
        return await response.close();
      }
      switch (uri.path) {
        case '/library/sections':
          return await _json(response, {
            'MediaContainer': {
              'size': 1,
              'Directory': [
                {'key': '1', 'title': 'Films', 'type': 'movie'},
              ],
            },
          });
        case '/library/sections/1/folder':
          return await _json(response, {
            'MediaContainer': {
              'size': 1,
              'offset': 0,
              'totalSize': 1,
              'Metadata': [
                {
                  'ratingKey': '7',
                  'key': '/library/metadata/7',
                  'type': 'movie',
                  'title': 'Lab Film',
                  'year': 2026,
                  'addedAt': 1700000000,
                  'Media': [
                    {
                      'id': 7,
                      'duration': 60000,
                      'container': 'mkv',
                      'Part': [
                        {
                          'id': 7,
                          'key': labPlexPartKey,
                          'file': '/data/films/Lab Film (2026).mkv',
                          'size': film.length,
                          'container': 'mkv',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          });
        case labPlexPartKey:
          return await _part(request);
      }
      response.statusCode = 404;
      await response.close();
    } catch (_) {
      // The app went away (a pause aborts the request)
    }
  }

  Future<void> _part(HttpRequest request) async {
    final response = request.response;
    final asked = request.headers.value('range');
    partRequests.add((
      range: asked ?? 'none',
      query: request.uri.query,
      token: request.uri.query.toLowerCase().contains('token'),
    ));
    final match = RegExp(r'bytes=(\d+)-').firstMatch(asked ?? '');
    final start = match == null ? 0 : int.parse(match.group(1)!);
    if (start >= film.length) {
      response.statusCode = 416;
      response.headers.set('content-range', 'bytes */${film.length}');
      return response.close();
    }
    response.headers.contentType = ContentType('video', 'x-matroska');
    response.headers.set('accept-ranges', 'bytes');
    if (match != null) {
      response.statusCode = 206;
      response.headers.set('content-range', 'bytes $start-${film.length - 1}/${film.length}');
    }
    response.contentLength = film.length - start;
    for (var offset = start; offset < film.length; offset += chunk) {
      response.add(Uint8List.sublistView(film, offset, min(offset + chunk, film.length)));
      await response.flush();
      await Future<void>.delayed(pause);
    }
    await response.close();
  }

  Future<void> _json(HttpResponse response, Object body) async {
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
