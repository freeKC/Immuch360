// A DLNA/UPnP media server (minidlna, Gerbera, Plex, Jellyfin, Emby, a NAS, a TV box) as a share: the folders are its
// ContentDirectory containers, listed with the SOAP Browse action, and the files the original resources of its photo
// and video items, read with Range requests (see http_range_reader.dart, shared with WebDAV). Paths are made of entry
// names built from the titles (see dlnaEntryName); the server only knows object ids, which this file system maps paths
// to as it lists. DLNA has no authentication.
//
// Rule for every share client of the app (SMB, WebDAV, DLNA, the phone share): no URL of a share, of a resource or of
// an album art ever crosses a pigeon call to Kotlin or Swift. The native players and viewers only get the
// http://127.0.0.1 URLs of the media bridge, which the quest network security config allows; the DLNA requests and
// the album art run in Dart, which reaches plain http addresses of the local network on every flavour.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/network/upnp/didl_lite.dart';
import 'package:immich_mobile/infrastructure/network/upnp/ssdp.dart';
import 'package:immich_mobile/infrastructure/network/upnp/upnp_description.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';
import 'package:logging/logging.dart';

final _log = Logger('DlnaFileSystem');

/// The body of a Browse of the direct children of [objectId], [count] objects from [start]
String browseRequestBody(String objectId, int start, int count, String serviceType) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
    '<u:Browse xmlns:u="${escapeXmlText(serviceType)}"><ObjectID>${escapeXmlText(objectId)}</ObjectID>'
    '<BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>$start</StartingIndex>'
    '<RequestedCount>$count</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>';

/// What a Browse answered: the objects of one page and the counts of the paging, or the UPnP error of a fault
class BrowseAnswer {
  const BrowseAnswer({this.objects, this.numberReturned = 0, this.totalMatches = 0, this.errorCode});

  /// Null when the answer has no Result
  final List<DidlObject>? objects;
  final int numberReturned;

  /// 0 when the server does not know (yet)
  final int totalMatches;

  /// The errorCode of a SOAP fault (701: no such object)
  final int? errorCode;
}

/// Reads the answer of a Browse: Envelope/Body/BrowseResponse/Result, whose text (entities decoded by the parser, or a
/// CDATA section) is the DIDL-Lite document of the page, its URLs resolved against [base]
BrowseAnswer parseBrowseResponse(String xml, Uri base) {
  final document = parseLiteXml(xml);
  final code = document.descendantsNamed('UPnPError').firstOrNull?.child('errorCode')?.text.trim();
  if (code != null) {
    return BrowseAnswer(errorCode: int.tryParse(code) ?? -1);
  }
  final response = document.descendantsNamed('BrowseResponse').firstOrNull;
  final result = response?.child('Result');
  if (response == null || result == null) {
    return const BrowseAnswer();
  }
  final objects = parseDidlLite(result.text, base: base);
  final returned = int.tryParse(response.child('NumberReturned')?.text.trim() ?? '');
  return BrowseAnswer(
    objects: objects,
    // A server that does not count: what the page holds
    numberReturned: returned ?? objects.length,
    totalMatches: int.tryParse(response.child('TotalMatches')?.text.trim() ?? '') ?? 0,
  );
}

/// A [NetworkFileSystem] over a DLNA media server, see [open]
class DlnaFileSystem implements NetworkFileSystem {
  DlnaFileSystem._(this.source, this._description, this._client, this._ownsClient, this._pageSize, this._browseTimeout);

  /// Reads the device description of [source], then lists its start folder (the root path of the source). Throws a
  /// [NetworkFileSystemException] when either fails. DLNA has no password: [password] is not used.
  ///
  /// [client] is used instead of a client of its own, and is then left open by [close]. [pageSize] is the number of
  /// objects asked for by each Browse, [browseTimeout] the longest time for one, its answer read.
  static Future<DlnaFileSystem> open(
    NetworkSource source,
    String? password, {
    http.Client? client,
    @visibleForTesting int pageSize = defaultPageSize,
    @visibleForTesting Duration browseTimeout = answerTimeout,
  }) async {
    if (source.type != NetworkSourceType.dlna) {
      throw ArgumentError.value(source.type, 'source.type', 'Not a DLNA source');
    }
    final fileSystem = DlnaFileSystem._(
      source,
      descriptionUriOf(source),
      client ?? _defaultClient(),
      client == null,
      pageSize,
      browseTimeout,
    );
    try {
      await fileSystem._guard(() async {
        await fileSystem._readDescription();
        final root = normalizePath(source.rootPath);
        fileSystem._openListing = (root, await fileSystem._rewalkOnce(() => fileSystem._browseFolder(root)));
      });
    } catch (_) {
      await fileSystem.close();
      rethrow;
    }
    return fileSystem;
  }

  @override
  final NetworkSource source;

  final Uri _description;
  final http.Client _client;
  final bool _ownsClient;
  final int _pageSize;
  final Duration _browseTimeout;
  bool _closed = false;

  late UpnpDevice _device;
  late Uri _control;

  /// The media server, as its description tells it
  UpnpDevice get device => _device;

  /// The objects behind the paths listed so far, the root as "0": kept while the connection lives, since the ids of
  /// a server only change with a rescan (see [_rewalkOnce])
  final Map<String, DidlObject> _objects = {'/': _rootObject};

  /// The entries of the paths listed so far, for [stat], with the sizes found by [stat] itself
  final Map<String, NetworkEntry> _entries = {};

  /// The listings of the folders, for looking a name up without asking the server again within [listingLifetime]
  final Map<String, ({List<NetworkEntry> entries, Duration at})> _listings = {};

  /// The listings under way, so that two callers wait for one Browse
  final Map<String, Future<List<NetworkEntry>>> _browsing = {};

  /// The listing [open] made of the start folder, handed to the first [list] of it: the browser lists that folder
  /// right after the connection opened
  (String, List<NetworkEntry>)? _openListing;

  final Stopwatch _clock = Stopwatch()..start();

  /// Set once the server refused a read with 400 or 406: some servers want the DLNA transfer mode header
  bool _sendsTransferMode = false;

  /// Cleared once a request failed on a connection the server had closed without telling: the servers built on
  /// libupnp (Gerbera, many NAS and TV boxes) close it after each answer, so that reusing it breaks the next request
  bool _keepsConnections = true;

  /// The files whose size neither the listing nor the server tells, so that it is asked for once
  final Set<String> _unknownSizes = {};

  /// The reads of the files, keyed by object id
  late final _ranges = HttpRangeReader(send: _send, fail: _fail, isClosed: () => _closed);

  static const defaultPageSize = 200;

  /// Objects listed in one container at most; a folder that holds more shows the first ones
  static const maxObjectsPerContainer = 20000;

  /// Longest wait for the answer of the server, then between two parts of a body; also the longest time for a whole
  /// Browse, its answer read
  static const answerTimeout = HttpRangeReader.answerTimeout;
  static const descriptionTimeout = Duration(seconds: 10);
  static const listingLifetime = Duration(seconds: 60);

  /// The user agent of every request: some servers pick what they serve by it (a DLNA client gets the files as they
  /// are)
  static const userAgent = '$upnpProductToken UPnP/1.0 DLNADOC/1.50';

  static const _maxRedirects = 5;

  /// Past this size, a Browse answer is parsed in another isolate, away from the interface
  static const _isolateParseSize = 256 * 1024;

  /// Largest Browse answer read: a page of [defaultPageSize] objects takes well under 1 MiB, even with long titles
  /// and many resources
  static const maxBrowseAnswerSize = 16 * 1024 * 1024;

  static const _maxDescriptionSize = 1024 * 1024;

  static const _rootObject = DidlObject(
    id: '0',
    parentId: '-1',
    isContainer: true,
    title: '',
    upnpClass: 'object.container',
  );

  /// The URL of the device description of [source]: http or https after its TLS setting, its host and port, and its
  /// share as the path with its query
  static Uri descriptionUriOf(NetworkSource source) {
    var host = source.host.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (host.isEmpty) {
      throw const NetworkFileSystemException('No server address');
    }
    var share = source.share.trim();
    if (!share.startsWith('/')) {
      share = '/$share';
    }
    final question = share.indexOf('?');
    try {
      return Uri(
        scheme: source.useTls ? 'https' : 'http',
        host: host,
        port: source.port,
        path: question < 0 ? share : share.substring(0, question),
        query: question < 0 ? null : share.substring(question + 1),
      );
    } on FormatException catch (error) {
      throw NetworkFileSystemException('Invalid server address ${source.host}: ${error.message}');
    }
  }

  /// [path] absolute, "/" separated, as for WebDAV
  static String normalizePath(String path) => WebDavFileSystem.normalizePath(path);

  static http.Client _defaultClient() => IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15),
  );

  @override
  Future<List<NetworkEntry>> list(String path) {
    final folder = normalizePath(path);
    final opened = _openListing;
    if (opened != null) {
      _openListing = null;
      if (opened.$1 == folder) {
        return Future.value(opened.$2);
      }
    }
    return _guard(() => _rewalkOnce(() => _browseFolder(folder)));
  }

  @override
  Future<NetworkEntry> stat(String path) {
    final target = normalizePath(path);
    if (target == '/') {
      return Future.value(NetworkEntry(sourceId: source.id, path: '/', isDirectory: true));
    }
    return _guard(
      () => _rewalkOnce(() async {
        var entry = _entries[target];
        if (entry == null) {
          await _listingOf(_parentOf(target));
          entry = _entries[target];
        }
        if (entry == null) {
          throw NetworkFileSystemException('$target was not found', isNotFound: true);
        }
        if (entry.isDirectory || entry.size != null) {
          return entry;
        }
        final original = _objects[target]?.original;
        if (original == null) {
          return entry;
        }
        await _fileSize(target, _reachable(original.url), original);
        // Still without a size when the server does not tell it: the bridge then streams the file without ranges
        return _entries[target] ?? entry;
      }),
    );
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int asked) {
    RangeError.checkNotNegative(offset, 'offset');
    RangeError.checkNotNegative(asked, 'length');
    final target = normalizePath(path);
    if (asked == 0) {
      return Future.value(Uint8List(0));
    }
    return _guard(
      () => _rewalkOnce(() async {
        final object = await _resolve(target);
        final original = object.original;
        if (object.isContainer || original == null) {
          throw NetworkFileSystemException('$target is not a file');
        }
        final url = _reachable(original.url);
        // minidlna refuses a range that ends past the end of the file (416) instead of giving what there is
        final size = await _fileSize(target, url, original);
        if (size != null && offset >= size) {
          return Uint8List(0);
        }
        final length = size == null ? asked : min(asked, size - offset);
        try {
          return await _ranges.read(url, object.id, offset, length, headers: _transferHeaders(original));
        } on _HttpStatus catch (error) {
          if ((error.status == 400 || error.status == 406) && !_sendsTransferMode) {
            _sendsTransferMode = true;
            _log.info('${_description.host} wants the DLNA transfer mode header');
            try {
              return await _ranges.read(url, object.id, offset, length, headers: _transferHeaders(original));
            } on _HttpStatus catch (again) {
              throw _readError(again.status, target);
            }
          }
          throw _readError(error.status, target);
        }
      }),
    );
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

  Future<void> _readDescription() async {
    final (response, uri) = await _send('GET', _description).timeout(descriptionTimeout);
    final status = response.statusCode;
    if (status != 200) {
      await discardHttpBody(response);
      if (status == 401 || status == 403) {
        throw const NetworkFileSystemException(
          'The media server asks for a password, which DLNA has not',
          isAuthentication: true,
        );
      }
      throw NetworkFileSystemException('The server at ${_description.host} answered HTTP $status for ${uri.path}');
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(descriptionTimeout)) {
      body.add(chunk);
      if (body.length > _maxDescriptionSize) {
        throw NetworkFileSystemException('${_description.host} is not a DLNA media server');
      }
    }
    final device = parseUpnpDescription(utf8.decode(body.takeBytes(), allowMalformed: true), uri);
    if (device == null) {
      throw NetworkFileSystemException('${_description.host} is not a DLNA media server');
    }
    _device = device;
    _control = _reachable(device.contentDirectoryControl);
  }

  /// The object at [path], from the listing of its parent when it was not met yet
  Future<DidlObject> _resolve(String path) async {
    final known = _objects[path];
    if (known != null) {
      return known;
    }
    await _listingOf(_parentOf(path));
    final found = _objects[path];
    if (found == null) {
      throw NetworkFileSystemException('$path was not found', isNotFound: true);
    }
    return found;
  }

  /// The listing of [folder] made within [listingLifetime], else a new one
  Future<List<NetworkEntry>> _listingOf(String folder) async {
    final listing = _listings[folder];
    if (listing != null && _clock.elapsed - listing.at < listingLifetime) {
      return listing.entries;
    }
    return _browseFolder(folder);
  }

  /// Browses every page of [folder] and records its entries
  Future<List<NetworkEntry>> _browseFolder(String folder) {
    final running = _browsing[folder];
    if (running != null) {
      return running;
    }
    late final Future<List<NetworkEntry>> browsing;
    browsing = () async {
      try {
        final container = await _resolve(folder);
        if (!container.isContainer) {
          throw NetworkFileSystemException('$folder is not a folder');
        }
        final objects = await _browseAll(container.id, folder);
        final entries = <NetworkEntry>[];
        for (final (:object, :name) in dlnaEntryNames(objects.where((o) => o.isMedia))) {
          final path = folder == '/' ? '/$name' : '$folder/$name';
          final entry = _entryOf(path, object);
          _objects[path] = object;
          // A size found by stat stays, unless the server tells another one now
          final known = _entries[path];
          _entries[path] =
              known != null && entry.size == null && known.size != null && known.isDirectory == entry.isDirectory
              ? _withSize(entry, known.size!)
              : entry;
          entries.add(_entries[path]!);
        }
        entries.sort(compareNetworkEntries);
        final listed = List<NetworkEntry>.unmodifiable(entries);
        _listings[folder] = (entries: listed, at: _clock.elapsed);
        return listed;
      } finally {
        // The next listing of the folder asks the server again
        if (identical(_browsing[folder], browsing)) {
          // Its callers have it, errors included
          _browsing.remove(folder)?.ignore();
        }
      }
    }();
    _browsing[folder] = browsing;
    return browsing;
  }

  /// Every page of the direct children of [objectId], [maxObjectsPerContainer] objects at most
  Future<List<DidlObject>> _browseAll(String objectId, String path) async {
    final objects = <DidlObject>[];
    var start = 0;
    while (true) {
      final page = await _browse(objectId, start, path);
      objects.addAll(page.objects!);
      final returned = page.numberReturned;
      if (returned <= 0) {
        break;
      }
      start += returned;
      final total = page.totalMatches;
      final more = total == 0 ? returned == _pageSize : start < total;
      if (!more) {
        break;
      }
      if (start >= maxObjectsPerContainer) {
        _log.warning('$path holds more than $maxObjectsPerContainer objects; the first ones only are listed');
        break;
      }
    }
    return objects;
  }

  Future<BrowseAnswer> _browse(String objectId, int start, String path) async {
    final sent = Stopwatch()..start();
    final (response, _) = await _send(
      'POST',
      _control,
      headers: {
        'content-type': 'text/xml; charset="utf-8"',
        'soapaction': '"${_device.contentDirectoryType}#Browse"',
        'accept-encoding': 'identity',
      },
      body: utf8.encode(browseRequestBody(objectId, start, _pageSize, _device.contentDirectoryType)),
    );
    final status = response.statusCode;
    if (status == 401 || status == 403) {
      await discardHttpBody(response);
      throw const NetworkFileSystemException(
        'The media server asks for a password, which DLNA has not',
        isAuthentication: true,
      );
    }
    if (status != 200 && status != 500) {
      await discardHttpBody(response);
      throw NetworkFileSystemException('The media server answered HTTP $status for $path');
    }
    final xml = utf8.decode(await _browseBody(response, sent, path), allowMalformed: true);
    final base = _control;
    final answer = xml.length > _isolateParseSize
        ? await Isolate.run(() => parseBrowseResponse(xml, base))
        : parseBrowseResponse(xml, base);
    final code = answer.errorCode;
    // 701 is "no such object". Gerbera answers 501 for an id it does not know: any fault on a folder but the root may
    // come from an id that a rescan changed, which a new walk from the root finds out.
    if (code == 701 || (code != null && objectId != _rootObject.id)) {
      throw _NoSuchObject(path, upnpError: code);
    }
    if (code != null) {
      throw NetworkFileSystemException('The media server refused to list $path (UPnP error $code)');
    }
    if (status == 500) {
      throw NetworkFileSystemException('The media server answered HTTP 500 for $path');
    }
    if (answer.objects == null) {
      throw NetworkFileSystemException('The server at ${_description.host} did not answer like a DLNA media server');
    }
    return answer;
  }

  /// The body of the answer to a Browse sent [sent] ago: a server that sends an endless one, however slowly, is cut
  /// at [maxBrowseAnswerSize] bytes or once the Browse took [_browseTimeout]
  Future<Uint8List> _browseBody(http.StreamedResponse response, Stopwatch sent, String path) async {
    final body = BytesBuilder(copy: false);
    final chunks = StreamIterator(response.stream);
    try {
      while (true) {
        final left = _browseTimeout - sent.elapsed;
        if (left <= Duration.zero) {
          throw TimeoutException('The answer to the Browse of $path took too long', _browseTimeout);
        }
        if (!await chunks.moveNext().timeout(left)) {
          return body.takeBytes();
        }
        body.add(chunks.current);
        if (body.length > maxBrowseAnswerSize) {
          throw NetworkFileSystemException(
            'The media server answered more than ${maxBrowseAnswerSize ~/ (1024 * 1024)} MiB for $path',
          );
        }
      }
    } finally {
      // Stops the transfer that was cut; nothing to wait for once the body ended
      chunks.cancel().ignore();
    }
  }

  NetworkEntry _entryOf(String path, DidlObject object) {
    if (object.isContainer) {
      return NetworkEntry(sourceId: source.id, path: path, isDirectory: true, modified: object.date);
    }
    final original = object.original;
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: original?.size,
      modified: object.date,
      mimeType: original?.mimeType,
      thumbnailUrl: _thumbnailOf(object)?.toString(),
      width: original?.width,
      height: original?.height,
      durationMs: original?.durationMs,
    );
  }

  static NetworkEntry _withSize(NetworkEntry entry, int size) => NetworkEntry(
    sourceId: entry.sourceId,
    path: entry.path,
    isDirectory: entry.isDirectory,
    size: size,
    modified: entry.modified,
    mimeType: entry.mimeType,
    thumbnailUrl: entry.thumbnailUrl,
    width: entry.width,
    height: entry.height,
    durationMs: entry.durationMs,
  );

  Uri? _thumbnailOf(DidlObject object) {
    final url = object.thumbnailUrl;
    if (url == null) {
      return null;
    }
    try {
      return _reachable(url);
    } on NetworkFileSystemException {
      return null;
    }
  }

  /// [url] of a resource as this device can reach it. A server in a container (Jellyfin in Docker) or reached through
  /// a translated address (the Android emulator reaching the computer as 10.0.2.2) gives its own private address in
  /// its URLs: on the port of its description, the host of the description is used instead. A resource on a public
  /// address is refused, the app staying on the local network.
  Uri _reachable(Uri url) {
    final host = _description.host;
    if (url.host.toLowerCase() == host.toLowerCase()) {
      return url;
    }
    final address = InternetAddress.tryParse(url.host);
    if (address == null) {
      return url;
    }
    if (!isLocalNetworkAddress(address)) {
      throw NetworkFileSystemException('The media server points to ${url.host}, outside the local network');
    }
    return url.port == _description.port ? url.replace(host: host) : url;
  }

  Map<String, String> _transferHeaders(DidlResource resource) => _sendsTransferMode
      ? {'transferMode.dlna.org': resource.mimeType.startsWith('video/') ? 'Streaming' : 'Interactive'}
      : const {};

  /// The size of the file at [path] (at [url] on the server): the one of its listing, else the one [_sizeOf] finds,
  /// kept with its entry
  Future<int?> _fileSize(String path, Uri url, DidlResource original) async {
    final entry = _entries[path];
    final known = entry?.size;
    if (known != null) {
      return known;
    }
    if (_unknownSizes.contains(path)) {
      return null;
    }
    final size = await _sizeOf(url, original, path);
    if (size == null) {
      _unknownSizes.add(path);
    } else if (entry != null) {
      _entries[path] = _withSize(entry, size);
    }
    return size;
  }

  /// The size of the file at [url] by a request for its first byte: the total of the Content-Range of a 206, or the
  /// length of a 200 (the whole file, dropped at once); null when neither tells
  Future<int?> _sizeOf(Uri url, DidlResource original, String path) async {
    final (response, _) = await _send(
      'GET',
      url,
      headers: {..._transferHeaders(original), 'range': 'bytes=0-0', 'accept-encoding': 'identity'},
    );
    final status = response.statusCode;
    if ((status == 400 || status == 406) && !_sendsTransferMode) {
      await discardHttpBody(response);
      _sendsTransferMode = true;
      _log.info('${_description.host} wants the DLNA transfer mode header');
      return _sizeOf(url, original, path);
    }
    final size = switch (status) {
      206 => int.tryParse(RegExp(r'/\s*(\d+)\s*$').firstMatch(response.headers['content-range'] ?? '')?.group(1) ?? ''),
      200 => response.contentLength,
      _ => null,
    };
    if ((status == 200 || status == 206) && (response.contentLength ?? 2) > 1) {
      // The whole file (minidlna answers "bytes=0-0" with all of it): only the headers were wanted
      try {
        await response.stream.listen(null).cancel();
      } catch (_) {
        // Nothing to do with a failure to stop a transfer nobody reads
      }
    } else {
      await discardHttpBody(response);
    }
    if (status == 404 || status == 410) {
      throw _NoSuchObject(path);
    }
    return size;
  }

  /// Sends a request, and follows the redirects that stay on the local network (see [_reachable])
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
      final response = await _sendOnce(method, current, headers, body);
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
      current = _reachable(next);
    }
  }

  /// Sends one request, once more on a new connection when the one it went on had been closed by the server
  Future<http.StreamedResponse> _sendOnce(String method, Uri uri, Map<String, String> headers, List<int>? body) async {
    while (true) {
      final keepAlive = _keepsConnections;
      final abort = Completer<void>();
      final timer = Timer(answerTimeout, () {
        if (!abort.isCompleted) {
          abort.complete();
        }
      });
      final request = http.AbortableRequest(method, uri, abortTrigger: abort.future)
        ..followRedirects = false
        ..persistentConnection = keepAlive
        ..headers['user-agent'] = userAgent
        ..headers.addAll(headers);
      if (body != null) {
        request.bodyBytes = body;
      }
      try {
        return await _client.send(request);
      } on Exception catch (error) {
        // Every request asks for the same thing again: a Browse changes nothing on the server
        if (!keepAlive || _closed || !_isLostConnection(error)) {
          rethrow;
        }
        _keepsConnections = false;
        _log.info('${uri.host} closed a connection kept for the next request ($error): one connection per request now');
      } finally {
        timer.cancel();
      }
    }
  }

  static bool _isLostConnection(Exception error) =>
      error is SocketException ||
      error is HttpException ||
      (error is http.ClientException && error is! http.RequestAbortedException);

  /// Thrown for the unexpected answers of the reads, which [readRange] tells apart (400 and 406 get a second try)
  Future<Never> _fail(http.StreamedResponse response, String key) async {
    await discardHttpBody(response);
    throw _HttpStatus(response.statusCode);
  }

  /// The exception of a read the server refused with [status]
  Exception _readError(int status, String path) => switch (status) {
    401 || 403 => const NetworkFileSystemException(
      'The media server asks for a password, which DLNA has not',
      isAuthentication: true,
    ),
    // The ids and the URLs of a server change with a rescan: the tree is walked again
    404 || 410 => _NoSuchObject(path),
    _ => NetworkFileSystemException('The media server answered HTTP $status for $path'),
  };

  /// Runs [action], and once more after forgetting every object id when the server no longer knows one (a rescan
  /// gives new ids); a second miss is a path that is not there any more
  Future<T> _rewalkOnce<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on _NoSuchObject catch (error) {
      _log.info('${_description.host} no longer knows ${error.path}: walking the tree again from the root');
      _objects
        ..clear()
        ..['/'] = _rootObject;
      _entries.clear();
      _unknownSizes.clear();
      _listings.clear();
      _openListing = null;
      try {
        return await action();
      } on _NoSuchObject catch (again) {
        throw again.toException();
      }
    }
  }

  /// Runs [action], with the errors of the network turned into [NetworkFileSystemException]
  Future<T> _guard<T>(Future<T> Function() action) async {
    final host = _description.host;
    try {
      return await action();
    } on NetworkFileSystemException {
      rethrow;
    } on _NoSuchObject catch (error) {
      throw error.toException();
    } on _HttpStatus catch (error) {
      throw NetworkFileSystemException('The media server answered HTTP ${error.status}');
    } on FormatException {
      // A number or an address of an answer that does not read
      throw NetworkFileSystemException('The server at $host did not answer like a DLNA media server');
    } on http.RequestAbortedException {
      throw NetworkFileSystemException('The server at $host did not answer in time');
    } on TimeoutException {
      throw NetworkFileSystemException('The server at $host did not answer in time');
    } on TlsException catch (error) {
      throw NetworkFileSystemException('The secure connection to $host failed: ${error.message}');
    } on SocketException catch (error) {
      throw NetworkFileSystemException('Cannot reach $host: ${error.osError?.message ?? error.message}');
    } on http.ClientException catch (error) {
      throw NetworkFileSystemException('Cannot reach $host: ${error.message}');
    } on IOException catch (error) {
      throw NetworkFileSystemException('Cannot reach $host: $error');
    }
  }

  static String _parentOf(String path) {
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '/' : path.substring(0, slash);
  }
}

/// The server does not know an object id (UPnP error 701, or another fault on a folder) or a resource URL any more
class _NoSuchObject implements Exception {
  const _NoSuchObject(this.path, {this.upnpError});

  final String path;

  /// The UPnP error of the fault, null for a resource URL that is gone
  final int? upnpError;

  /// What is left once a new walk from the root did not help
  NetworkFileSystemException toException() {
    final code = upnpError;
    return code == null || code == 701
        ? NetworkFileSystemException('$path was not found', isNotFound: true)
        : NetworkFileSystemException('The media server refused to list $path (UPnP error $code)');
  }

  @override
  String toString() => 'No such object: $path';
}

/// An unexpected status of a read
class _HttpStatus implements Exception {
  const _HttpStatus(this.status);

  final int status;

  @override
  String toString() => 'HTTP $status';
}
