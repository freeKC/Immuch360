// On a big screen, the item a linked phone sends from its relay (release 53): one file read over HTTP from the phone,
// with ranges, as a share the media bridge serves to the players and the image widgets (network_file_system.dart).
// Every request goes to the address the play link session talks to (RelayPlayTarget.origin), never to a host of a
// message, through a bare client (no proxy, cookie nor redirect), and carries the MAC of the lease's path under the
// session's K_relay (play_link_protocol.dart). Nothing of it is kept on the screen: the source lives in memory and goes
// with the item.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_protocol.dart';

HttpClient _bareClient() => HttpOverrides.runWithHttpOverrides(HttpClient.new, _NoOverrides());

class _NoOverrides extends HttpOverrides {}

/// The id of the in-memory source of the lease [lease]
String playRelaySourceId(String lease) => '${NetworkEntry.importSourcePrefix}relay-$lease';

/// Whether [sourceId] is the source in memory of an item a phone sends (its pages save, upload and convert nothing)
bool isPlayRelaySource(String sourceId) => sourceId.startsWith('${NetworkEntry.importSourcePrefix}relay-');

class RelayFileSystem implements NetworkFileSystem, NetworkAbortableReads {
  RelayFileSystem._(this.source, this._target, this._client, this._size);

  /// The relay of [target], checked with a HEAD (its size); throws a [NetworkFileSystemException] when the phone does
  /// not serve it. [name] is the phone's name, for the texts.
  static Future<RelayFileSystem> open(
    RelayPlayTarget target, {
    required String name,
    HttpClient Function()? createClient,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final origin = target.origin;
    if (origin == null) {
      throw const NetworkFileSystemException('No address to read the item from');
    }
    final client = (createClient ?? _bareClient)()
      ..connectionTimeout = timeout
      ..findProxy = ((_) => 'DIRECT')
      ..userAgent = 'Immuch360'
      ..autoUncompress = false;
    final source = NetworkSource(
      id: playRelaySourceId(target.lease),
      type: NetworkSourceType.phoneRelay,
      name: name,
      host: origin.host,
      port: target.port,
      rootPath: '/',
    );
    final fileSystem = RelayFileSystem._(source, target, client, target.size);
    try {
      fileSystem._size = await fileSystem._head(timeout);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
    return fileSystem;
  }

  @override
  final NetworkSource source;
  final RelayPlayTarget _target;
  final HttpClient _client;
  int? _size;
  bool _closed = false;

  /// The one file of this source
  String get path => '/${_target.name}';

  Uri get _url => Uri(scheme: 'http', host: _target.origin!.host, port: _target.port, path: _target.path);

  Future<HttpClientRequest> _request(String method, Duration timeout) async {
    if (_closed) {
      throw const NetworkFileSystemException('The item is no longer sent');
    }
    final HttpClientRequest request;
    try {
      request = await _client.openUrl(method, _url).timeout(timeout);
    } on TimeoutException {
      throw const NetworkFileSystemException('The phone does not answer');
    } on SocketException {
      throw const NetworkFileSystemException('The phone does not answer');
    }
    request
      ..followRedirects = false
      ..persistentConnection = true;
    request.headers.set(playRelayHeader, playRelayMac(_target.origin!.relayKey, _target.path));
    return request;
  }

  static NetworkFileSystemException _refused(int status) =>
      NetworkFileSystemException('The phone answered $status', isNotFound: status == HttpStatus.notFound);

  Future<int?> _head(Duration timeout) async {
    final HttpClientResponse response;
    try {
      response = await (await _request('HEAD', timeout)).close().timeout(timeout);
      await response.drain<void>();
    } on TimeoutException {
      throw const NetworkFileSystemException('The phone does not answer');
    } on SocketException {
      throw const NetworkFileSystemException('The phone does not answer');
    } on HttpException {
      throw const NetworkFileSystemException('The phone does not answer');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw _refused(response.statusCode);
    }
    return response.contentLength >= 0 ? response.contentLength : _target.size;
  }

  NetworkEntry get _entry => NetworkEntry(
    sourceId: source.id,
    path: path,
    isDirectory: false,
    size: _size,
    mimeType: _target.mime,
    title: _target.name,
  );

  @override
  Future<List<NetworkEntry>> list(String path) async => path == '/' ? [_entry] : const [];

  @override
  Future<NetworkEntry> stat(String path) async {
    if (path != this.path) {
      throw const NetworkFileSystemException('No such file', isNotFound: true);
    }
    return _entry;
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length, {Future<void>? abort}) async {
    if (path != this.path) {
      throw const NetworkFileSystemException('No such file', isNotFound: true);
    }
    final size = _size;
    if (length <= 0 || offset < 0 || (size != null && offset >= size)) {
      return Uint8List(0);
    }
    final request = await _request('GET', const Duration(seconds: 15));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-${offset + length - 1}');
    var aborted = false;
    unawaited(
      abort?.then((_) {
        aborted = true;
        request.abort(const NetworkReadAborted());
      }),
    );
    try {
      final response = await request.close();
      final status = response.statusCode;
      if (status != HttpStatus.partialContent && status != HttpStatus.ok) {
        await response.drain<void>();
        throw _refused(status);
      }
      // A whole file for a range: its bytes from the start, those before the offset dropped
      var skip = status == HttpStatus.ok ? offset : 0;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        var part = chunk;
        if (skip > 0) {
          if (part.length <= skip) {
            skip -= part.length;
            continue;
          }
          part = part.sublist(skip);
          skip = 0;
        }
        final room = length - bytes.length;
        bytes.add(part.length > room ? part.sublist(0, room) : part);
        if (bytes.length >= length) {
          break;
        }
      }
      return bytes.takeBytes();
    } catch (error) {
      if (aborted) {
        throw const NetworkReadAborted();
      }
      if (error is NetworkFileSystemException) {
        rethrow;
      }
      throw const NetworkFileSystemException('The phone stopped sending');
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
  }
}
