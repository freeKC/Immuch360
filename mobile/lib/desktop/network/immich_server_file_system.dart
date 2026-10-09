// The videos of the user's Immich server as a source of the app's media bridge (design 0.2 and 2.2), so that the
// desktop player reads them as it reads the shares: libmpv gets a bridge URL on 127.0.0.1, and the requests to the
// server are made here, by the app's HTTP stack (NetworkRepository.client: the session cookie, the custom headers,
// the client certificate and the certificates the user trusts, desktop_http_stack.dart). The session token and the
// server's address never reach libmpv, whose verbose log prints the request headers and every URL it opens.
//
// Read only, and only what the players ask for: the original of an asset and its transcoded stream, by range
// (HttpRangeReader, as WebDAV and DLNA). Nothing else of the server is reachable through the bridge.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';

class ImmichServerFileSystem implements NetworkFileSystem {
  /// [endpoint] gives the server's API address ("https://host/api") at each request, null when no server is set:
  /// the user may sign in to another server while the app runs. [client] gives the client the requests go through.
  ImmichServerFileSystem({required this._endpoint, required this._client});

  /// The bridge source id of the server: the bridge URLs of server videos are `/<token>/immich-server/assets/...`
  static const sourceId = 'immich-server';

  /// The paths served: the original and the transcoded stream of an asset, as the app's URLs name them
  /// (serverOriginalVideoUrl, serverTranscodedVideoUrl)
  static final _servedPath = RegExp(r'^/assets/[0-9A-Za-z-]{1,64}/(?:original|video/playback)$');

  final String? Function() _endpoint;
  final http.Client Function() _client;
  bool _closed = false;

  late final _ranges = HttpRangeReader(send: _send, fail: _fail, isClosed: () => _closed);

  @override
  final NetworkSource source = const NetworkSource(
    id: sourceId,
    // Plain HTTP with ranges, as WebDAV; the bridge reads only the id and the name
    type: NetworkSourceType.webdav,
    name: 'Immich server',
    host: sourceId,
  );

  /// The path of [url] for the bridge when it is a video of the server at [endpoint] that this file system serves
  /// (`/assets/<id>/original`), null otherwise
  static String? pathOf(String url, String? endpoint) {
    if (endpoint == null || endpoint.isEmpty) {
      return null;
    }
    final base = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    if (!url.startsWith('$base/')) {
      return null;
    }
    // An endpoint saved with a final slash gives URLs with two
    final path = '/${url.substring(base.length).replaceFirst(RegExp('^/+'), '')}';
    return _servedPath.hasMatch(path) ? path : null;
  }

  /// Whether [path] is one this file system serves
  static bool serves(String path) => _servedPath.hasMatch(path);

  Uri _uriOf(String path) {
    if (!serves(path)) {
      throw const NetworkFileSystemException('Only the videos of the server are read', isNotFound: true);
    }
    final endpoint = _endpoint();
    if (endpoint == null || endpoint.isEmpty) {
      throw const NetworkFileSystemException('No server is set', isAuthentication: true);
    }
    final base = endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
    return Uri.parse('$base$path');
  }

  @override
  Future<List<NetworkEntry>> list(String path) async => const [];

  @override
  Future<NetworkEntry> stat(String path) => _guard(() async {
    // One byte asked: the answer tells the size (Content-Range), the type and the date of the file, without a body
    final (response, _) = await _send('GET', _uriOf(path), headers: const {'range': 'bytes=0-0'});
    final headers = response.headers;
    final int? size;
    switch (response.statusCode) {
      case 206:
        size = int.tryParse(RegExp(r'/(\d+)\s*$').firstMatch(headers['content-range'] ?? '')?.group(1) ?? '');
      case 200:
        // The range was ignored: the length of the whole file
        size = response.contentLength;
      default:
        return _fail(response, path);
    }
    await discardHttpBody(response);
    if (size == null) {
      throw NetworkFileSystemException('The server did not tell the size of $path');
    }
    DateTime? modified;
    try {
      final lastModified = headers['last-modified'];
      modified = lastModified == null ? null : HttpDate.parse(lastModified);
    } on HttpException {
      modified = null;
    }
    return NetworkEntry(
      sourceId: sourceId,
      path: path,
      isDirectory: false,
      size: size,
      modified: modified,
      mimeType: headers['content-type'],
    );
  });

  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    return _guard(() => _ranges.read(_uriOf(path), path, offset, length));
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _ranges.close();
  }

  Future<(http.StreamedResponse, Uri)> _send(String method, Uri uri, {Map<String, String> headers = const {}}) async {
    if (_closed) {
      throw const NetworkFileSystemException('The server source is closed');
    }
    final abort = Completer<void>();
    final timer = Timer(HttpRangeReader.answerTimeout, () {
      if (!abort.isCompleted) {
        abort.complete();
      }
    });
    // The redirects of a proxy in front of the server are followed by the client, with its cookies
    final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)..headers.addAll(headers);
    try {
      return (await _client().send(request), uri);
    } finally {
      timer.cancel();
    }
  }

  /// The exception of an unexpected answer about [path]: its words never quote the address of the server
  Future<Never> _fail(http.StreamedResponse response, String path) async {
    final status = response.statusCode;
    await discardHttpBody(response);
    if (status == 401 || status == 403) {
      throw NetworkFileSystemException('The server refused to give $path', isAuthentication: true);
    }
    if (status == 404 || status == 410) {
      throw NetworkFileSystemException('$path was not found on the server', isNotFound: true);
    }
    throw NetworkFileSystemException('The server answered HTTP $status for $path');
  }

  /// Runs [action], with the errors of the network turned into [NetworkFileSystemException]. Their own texts are not
  /// kept: those of the HTTP clients quote the URL, and the server address may hold a user name and a password.
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NetworkFileSystemException {
      rethrow;
    } on http.RequestAbortedException {
      throw const NetworkFileSystemException('The server did not answer in time');
    } on TimeoutException {
      throw const NetworkFileSystemException('The server did not answer in time');
    } on TlsException {
      throw const NetworkFileSystemException('The secure connection to the server failed');
    } on SocketException catch (error) {
      throw NetworkFileSystemException('Cannot reach the server: ${error.osError?.message ?? 'no connection'}');
    } on http.ClientException {
      throw const NetworkFileSystemException('Cannot reach the server');
    } on IOException {
      throw const NetworkFileSystemException('Cannot reach the server');
    }
  }
}
