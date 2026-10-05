// A share reached over WebDAV (a NAS, Nextcloud, a computer running a WebDAV server) with nothing but plain HTTP:
// PROPFIND to list a folder and to stat an entry, GET with a Range header to read a part of a file (see
// http_range_reader.dart, shared with the DLNA client). No file is ever downloaded whole: a read asks for its bytes
// only, and stops the transfer once they arrived.
//
// Authentication is Basic, sent with every request. A server that only offers Digest is reported as an authentication
// failure for now. Redirects are followed on the same host only, so that the credentials never leave it.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';

/// A [NetworkFileSystem] over WebDAV, see [open]
class WebDavFileSystem implements NetworkFileSystem {
  WebDavFileSystem._(this.source, this._base, this._authorization, this._client, this._ownsClient);

  /// Connects to the WebDAV share of [source] and checks that its start folder (the root path of the source) answers
  /// a PROPFIND. Throws a [NetworkFileSystemException] when it does not.
  ///
  /// [client] is used instead of a client of its own, and is then left open by [close].
  static Future<WebDavFileSystem> open(NetworkSource source, String? password, {http.Client? client}) async {
    if (source.type != NetworkSourceType.webdav) {
      throw ArgumentError.value(source.type, 'source.type', 'Not a WebDAV source');
    }
    final fileSystem = WebDavFileSystem._(
      source,
      baseUriOf(source),
      _authorizationOf(source.username, password),
      client ?? _defaultClient(),
      client == null,
    );
    try {
      final root = await fileSystem._guard(() => fileSystem._stat(normalizePath(source.rootPath), folder: true));
      if (!root.isDirectory) {
        throw NetworkFileSystemException('${root.path} is not a folder');
      }
    } catch (_) {
      await fileSystem.close();
      rethrow;
    }
    return fileSystem;
  }

  @override
  final NetworkSource source;

  final Uri _base;
  final String? _authorization;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  /// The reads of the files, keyed by path
  late final _ranges = HttpRangeReader(send: _send, fail: _fail, isClosed: () => _closed);

  /// Longest wait for the answer of the server, then between two parts of a body
  static const answerTimeout = HttpRangeReader.answerTimeout;

  static const _maxRedirects = 5;

  /// Past this size, a multistatus answer is parsed in another isolate, away from the interface
  static const _isolateParseSize = 256 * 1024;

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>\n'
      '<D:propfind xmlns:D="DAV:"><D:prop>'
      '<D:displayname/><D:getcontentlength/><D:getlastmodified/><D:getcontenttype/><D:resourcetype/>'
      '</D:prop></D:propfind>';

  /// Whether the server honours range requests: null until a read tells, false when it answers them with the whole
  /// file (reads still work, but each one transfers the file from its start up to the bytes asked for)
  bool? get supportsRanges => _ranges.supportsRanges;

  @override
  Future<List<NetworkEntry>> list(String path) {
    final folder = normalizePath(path);
    return _guard(() async {
      final (resources, uri) = await _propfind(folder, depth: 1, folder: true);
      final requested = normalizePath(_percentDecode(uri.path));
      final paths = [for (final resource in resources) _resolveHref(resource.href, requested)];

      // The answer holds the folder itself, usually first, along with its content
      var self = paths.indexWhere((p) => _samePath(p, requested));
      if (self < 0) {
        // A server behind a proxy may answer with other hrefs than the URL asked: the folder is then the collection
        // all the other entries are inside of
        final parents = [
          for (var i = 0; i < resources.length; i++)
            if (resources[i].isCollection &&
                paths.indexed.every((other) => other.$1 == i || other.$2.startsWith(_asFolderPrefix(paths[i]))))
              i,
        ];
        self = parents.length == 1 ? parents.single : -1;
      }
      if (self >= 0 && !resources[self].isCollection) {
        throw NetworkFileSystemException('$folder is not a folder');
      }

      final seen = <String>{};
      final entries = <NetworkEntry>[];
      for (var i = 0; i < resources.length; i++) {
        if (i == self) {
          continue;
        }
        final name = _lastSegment(paths[i]);
        // Entries deeper than the folder, from a server that ignored the depth
        if (name.isEmpty || (self >= 0 && !_samePath(_parentOf(paths[i]), paths[self]))) {
          continue;
        }
        final entryPath = folder == '/' ? '/$name' : '$folder/$name';
        if (seen.add(entryPath)) {
          entries.add(_entryOf(entryPath, resources[i]));
        }
      }
      entries.sort(compareNetworkEntries);
      return entries;
    });
  }

  @override
  Future<NetworkEntry> stat(String path) {
    final target = normalizePath(path);
    return _guard(() => _stat(target, folder: target == '/'));
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(length, 'length');
    final target = normalizePath(path);
    if (length == 0) {
      return Future.value(Uint8List(0));
    }
    return _guard(() => _ranges.read(_uriOf(target), target, offset, length));
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _ranges.close();
    if (_ownsClient) {
      _client.close();
    }
  }

  /// The base URL of the WebDAV share of [source]: https when it uses TLS, its host and port, and its share as path
  static Uri baseUriOf(NetworkSource source) {
    var host = source.host.trim();
    var port = source.port;
    // Lenient with an address typed as a URL
    final scheme = host.indexOf('://');
    if (scheme >= 0) {
      host = host.substring(scheme + 3);
    }
    final slash = host.indexOf('/');
    if (slash >= 0) {
      host = host.substring(0, slash);
    }
    // "nas:5006", "[fe80::1]" and "[fe80::1]:5006"
    final withPort =
        RegExp(r'^\[([^\]]*)\](?::(\d+))?$').firstMatch(host) ?? RegExp(r'^([^:]+):(\d+)$').firstMatch(host);
    if (withPort != null) {
      host = withPort.group(1)!;
      final typedPort = withPort.group(2);
      if (typedPort != null) {
        port ??= int.parse(typedPort);
      }
    }
    if (host.isEmpty) {
      throw const NetworkFileSystemException('No server address');
    }
    final segments = _segmentsOf(_percentDecode(source.share));
    try {
      return segments.isEmpty
          ? Uri(scheme: source.useTls ? 'https' : 'http', host: host, port: port, path: '/')
          : Uri(scheme: source.useTls ? 'https' : 'http', host: host, port: port, pathSegments: segments);
    } on FormatException catch (error) {
      throw NetworkFileSystemException('Invalid server address ${source.host}: ${error.message}');
    }
  }

  /// [path] absolute, "/" separated, without empty, "." and ".." segments, without a trailing "/" ("/" for the root)
  static String normalizePath(String path) => '/${_segmentsOf(path).join('/')}';

  static List<String> _segmentsOf(String path) {
    final segments = <String>[];
    for (final segment in path.split('/')) {
      if (segment.isEmpty || segment == '.') {
        continue;
      }
      if (segment == '..') {
        if (segments.isNotEmpty) {
          segments.removeLast();
        }
        continue;
      }
      segments.add(segment);
    }
    return segments;
  }

  static String? _authorizationOf(String username, String? password) {
    if (username.isEmpty && (password == null || password.isEmpty)) {
      return null;
    }
    return 'Basic ${base64.encode(utf8.encode('$username:${password ?? ''}'))}';
  }

  static http.Client _defaultClient() => IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15),
  );

  /// The URL of [path] (normalized), with a trailing "/" for a [folder]
  Uri _uriOf(String path, {bool folder = false}) {
    final segments = [..._base.pathSegments.where((s) => s.isNotEmpty), ..._segmentsOf(path)];
    if (segments.isEmpty) {
      return _base.replace(path: '/');
    }
    return _base.replace(pathSegments: folder ? [...segments, ''] : segments);
  }

  Future<NetworkEntry> _stat(String target, {bool folder = false}) async {
    final (resources, uri) = await _propfind(target, depth: 0, folder: folder);
    if (resources.isEmpty) {
      throw NetworkFileSystemException('$target was not found', isNotFound: true);
    }
    final requested = normalizePath(_percentDecode(uri.path));
    final resource = resources.firstWhere(
      (r) => _samePath(_resolveHref(r.href, requested), requested),
      orElse: () => resources.first,
    );
    return _entryOf(target, resource);
  }

  NetworkEntry _entryOf(String path, WebDavResource resource) => NetworkEntry(
    sourceId: source.id,
    path: path,
    isDirectory: resource.isCollection,
    size: resource.isCollection ? null : resource.contentLength,
    modified: resource.lastModified,
    mimeType: resource.isCollection ? null : resource.contentType,
  );

  /// The resources of a PROPFIND of [path], and the URL that answered (after the redirects)
  Future<(List<WebDavResource>, Uri)> _propfind(String path, {required int depth, bool folder = false}) async {
    final (response, uri) = await _send(
      'PROPFIND',
      _uriOf(path, folder: folder),
      headers: {'depth': '$depth', 'content-type': 'application/xml; charset=utf-8'},
      body: utf8.encode(_propfindBody),
    );
    if (response.statusCode != 207 && response.statusCode != 200) {
      return _fail(response, path, method: 'PROPFIND');
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(answerTimeout)) {
      body.add(chunk);
    }
    final xml = utf8.decode(body.takeBytes(), allowMalformed: true);
    final resources = xml.length > _isolateParseSize
        ? await Isolate.run(() => parseWebDavMultistatus(xml))
        : parseWebDavMultistatus(xml);
    if (resources == null) {
      throw NetworkFileSystemException('The server at ${_base.host} did not answer like a WebDAV server');
    }
    return (resources, uri);
  }

  /// Sends a request with the credentials, and follows the redirects that stay on the same host
  Future<(http.StreamedResponse, Uri)> _send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    var current = uri;
    for (var redirects = 0; ; redirects++) {
      if (_closed) {
        throw const NetworkFileSystemException('The share is closed');
      }
      final abort = Completer<void>();
      final timer = Timer(answerTimeout, () {
        if (!abort.isCompleted) {
          abort.complete();
        }
      });
      final request = http.AbortableRequest(method, current, abortTrigger: abort.future)
        ..followRedirects = false
        ..headers.addAll(headers);
      final authorization = _authorization;
      if (authorization != null) {
        request.headers['authorization'] = authorization;
      }
      if (body != null) {
        request.bodyBytes = body;
      }
      final http.StreamedResponse response;
      try {
        response = await _client.send(request);
      } finally {
        timer.cancel();
      }

      final location = response.headers['location'];
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode) || location == null) {
        return (response, current);
      }
      await discardHttpBody(response);
      if (redirects >= _maxRedirects) {
        throw NetworkFileSystemException('Too many redirects from ${uri.path}');
      }
      final Uri next;
      try {
        next = current.resolve(location);
      } on FormatException {
        throw NetworkFileSystemException('The server redirected to an invalid address: $location');
      }
      if (!_isSameHost(current, next)) {
        throw NetworkFileSystemException('The server redirected to another host (${next.host}), which is not followed');
      }
      current = next;
    }
  }

  /// Same host, and no step down from https to http, so that the credentials stay where the user sent them
  static bool _isSameHost(Uri from, Uri to) =>
      to.host.toLowerCase() == from.host.toLowerCase() &&
      (to.scheme == 'https' || (to.scheme == 'http' && from.scheme == 'http'));

  /// Throws the exception matching an unexpected answer of the server
  Future<Never> _fail(http.StreamedResponse response, String path, {String method = 'GET'}) async {
    final status = response.statusCode;
    final challenge = (response.headers['www-authenticate'] ?? '').toLowerCase();
    await discardHttpBody(response);
    if (status == 401) {
      if (challenge.contains('digest') && !challenge.contains('basic')) {
        throw const NetworkFileSystemException(
          'The server asks for Digest authentication, which is not supported yet',
          isAuthentication: true,
        );
      }
      throw NetworkFileSystemException(
        _authorization == null
            ? 'The server asks for a user name and a password'
            : 'The server refused the user name or the password',
        isAuthentication: true,
      );
    }
    if (status == 403) {
      throw NetworkFileSystemException('Access to $path is refused', isAuthentication: true);
    }
    if (status == 404 || status == 410) {
      throw NetworkFileSystemException('$path was not found', isNotFound: true);
    }
    if (method == 'PROPFIND' && (status == 405 || status == 501)) {
      throw NetworkFileSystemException('The server at ${_base.host} does not offer WebDAV at ${_base.path}');
    }
    throw NetworkFileSystemException('The server answered HTTP $status for $path');
  }

  /// Runs [action], with the errors of the network turned into [NetworkFileSystemException]
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on NetworkFileSystemException {
      rethrow;
    } on http.RequestAbortedException {
      throw NetworkFileSystemException('The server at ${_base.host} did not answer in time');
    } on TimeoutException {
      throw NetworkFileSystemException('The server at ${_base.host} did not answer in time');
    } on TlsException catch (error) {
      throw NetworkFileSystemException('The secure connection to ${_base.host} failed: ${error.message}');
    } on SocketException catch (error) {
      throw NetworkFileSystemException('Cannot reach ${_base.host}: ${error.osError?.message ?? error.message}');
    } on http.ClientException catch (error) {
      throw NetworkFileSystemException('Cannot reach ${_base.host}: ${error.message}');
    } on IOException catch (error) {
      throw NetworkFileSystemException('Cannot reach ${_base.host}: $error');
    }
  }

  /// The decoded path of an href, made absolute against [requested] (a folder) when it is relative
  static String _resolveHref(String href, String requested) {
    if (href.startsWith('/')) {
      return normalizePath(href);
    }
    return normalizePath('$requested/$href');
  }

  static bool _samePath(String a, String b) => a.toLowerCase() == b.toLowerCase();

  static String _asFolderPrefix(String path) => path == '/' ? '/' : '$path/';

  static String _lastSegment(String path) => path.substring(path.lastIndexOf('/') + 1);

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}

/// One entry of a WebDAV multistatus answer
class WebDavResource {
  const WebDavResource({
    required this.href,
    required this.isCollection,
    this.displayName,
    this.contentLength,
    this.lastModified,
    this.contentType,
  });

  /// The path of the href, percent decoded (relative when the server gave it so, without scheme and host)
  final String href;
  final bool isCollection;
  final String? displayName;
  final int? contentLength;
  final DateTime? lastModified;
  final String? contentType;
}

const _davNamespace = 'DAV:';

/// The resources of a WebDAV multistatus document, null when [xml] is not one.
///
/// Elements of the DAV: namespace are recognised whatever their prefix ("D:", "d:", "lp1:", a default namespace), as
/// well as elements without a namespace from servers that do not declare it. Only the properties of a propstat with a
/// successful status are read, and the responses with a failed status are left out.
List<WebDavResource>? parseWebDavMultistatus(String xml) {
  final multistatus = parseLiteXml(xml).davChild('multistatus');
  if (multistatus == null) {
    return null;
  }
  final resources = <WebDavResource>[];
  for (final response in multistatus.davChildren('response')) {
    final href = response.davChild('href')?.text.trim();
    if (href == null || href.isEmpty) {
      continue;
    }
    final status = response.davChild('status');
    if (status != null && !_isSuccessStatus(status.text)) {
      continue;
    }
    var isCollection = false;
    String? displayName;
    int? contentLength;
    DateTime? lastModified;
    String? contentType;
    for (final propstat in response.davChildren('propstat')) {
      final propstatStatus = propstat.davChild('status');
      if (propstatStatus != null && !_isSuccessStatus(propstatStatus.text)) {
        continue;
      }
      for (final prop in propstat.davChildren('prop')) {
        for (final property in prop.children) {
          if (!property.isDav) {
            continue;
          }
          final value = property.text.trim();
          switch (property.name) {
            case 'resourcetype':
              isCollection = isCollection || property.davChild('collection') != null;
            case 'iscollection':
              // Older Microsoft servers
              isCollection = isCollection || value == '1' || value.toLowerCase() == 'true';
            case 'displayname':
              displayName = value.isEmpty ? null : value;
            case 'getcontentlength':
              contentLength = int.tryParse(value);
            case 'getlastmodified':
              lastModified = _parseHttpDate(value);
            case 'getcontenttype':
              contentType = value.isEmpty ? null : value;
          }
        }
      }
    }
    resources.add(
      WebDavResource(
        href: _hrefPath(href),
        isCollection: isCollection,
        displayName: displayName,
        contentLength: contentLength,
        lastModified: lastModified,
        contentType: contentType,
      ),
    );
  }
  return resources;
}

/// "HTTP/1.1 200 OK" and the like; a status that cannot be read counts as a success
bool _isSuccessStatus(String status) {
  final match = RegExp(r'\b(\d{3})\b').firstMatch(status);
  if (match == null) {
    return true;
  }
  final code = int.parse(match.group(1)!);
  return code >= 200 && code < 300;
}

DateTime? _parseHttpDate(String value) {
  if (value.isEmpty) {
    return null;
  }
  try {
    return HttpDate.parse(value);
  } on Exception {
    return DateTime.tryParse(value);
  }
}

/// The percent decoded path of an href, without the scheme and host of an absolute URL
String _hrefPath(String href) {
  var path = href;
  final scheme = path.indexOf('://');
  if (scheme >= 0) {
    final slash = path.indexOf('/', scheme + 3);
    path = slash < 0 ? '/' : path.substring(slash);
  }
  return _percentDecode(path);
}

final _percentRun = RegExp('(?:%[0-9a-fA-F]{2})+');

/// Decodes the %XX escapes as UTF-8, leaving anything else as it is (a "%" not followed by two hex digits, characters
/// a server did not escape)
String _percentDecode(String text) {
  if (!text.contains('%')) {
    return text;
  }
  return text.replaceAllMapped(_percentRun, (match) {
    final run = match[0]!;
    final bytes = [for (var i = 0; i < run.length; i += 3) int.parse(run.substring(i + 1, i + 3), radix: 16)];
    return utf8.decode(bytes, allowMalformed: true);
  });
}

/// The elements of the DAV: namespace, whatever their prefix, and those without a namespace from servers that do not
/// declare it
extension _DavElement on LiteXmlElement {
  bool get isDav => namespace == _davNamespace || namespace == null;

  Iterable<LiteXmlElement> davChildren(String name) => children.where((c) => c.name == name && c.isDav);

  LiteXmlElement? davChild(String name) => davChildren(name).firstOrNull;
}
