import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/m2ts.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';

import 'm2ts_fixtures.dart';

const _minChunk = LocalMediaBridge.defaultMinChunkSize;
const _maxChunk = LocalMediaBridge.defaultMaxChunkSize;
const _mib = 1024 * 1024;

// The sizes of the reads of a body of [length] bytes: the first chunk, then twice as many each time up to the largest
List<int> _chunksOf(int length) {
  final sizes = <int>[];
  var size = _minChunk;
  for (var done = 0; done < length; done += sizes.last) {
    sizes.add(size < length - done ? size : length - done);
    size = size * 2 < _maxChunk ? size * 2 : _maxChunk;
  }
  return sizes;
}

final _modified = DateTime.utc(2024, 6, 1, 12);

// Bytes that differ from one offset to the next, so that a misplaced range shows
Uint8List _bytes(int length, {int seed = 0}) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + seed + (i >> 8)) & 0xff));

// The byte at [offset] of a virtual file, too big to hold in memory
int _virtualByte(int offset) => offset % 251;

final _virtualPattern = Uint8List.fromList(List.generate(251, (i) => i));

// The bytes of a virtual file from [start] to [end], quickly
Uint8List _virtualBytes(int start, int end) {
  final bytes = Uint8List(end > start ? end - start : 0);
  var at = 0;
  while (at < bytes.length) {
    final phase = _virtualByte(start + at);
    final count = (251 - phase) < bytes.length - at ? 251 - phase : bytes.length - at;
    bytes.setRange(at, at + count, _virtualPattern, phase);
    at += count;
  }
  return bytes;
}

final _playlistBytes = Uint8List.fromList(ascii.encode('#EXTM3U\n#EXT-X-VERSION:7\n'));

// Generated media held in memory, telling what the bridge asked of it
class _MemoryMedia implements GeneratedMedia {
  final files = <String, GeneratedFile>{};
  final asked = <String>[];

  @override
  GeneratedFile? file(String name) {
    asked.add(name);
    return files[name];
  }
}

// Generated media that takes the posts to "events", as the splat viewer's session does
class _SinkMedia extends _MemoryMedia implements GeneratedMediaSink {
  final posts = <(String, String)>[];

  @override
  bool received(String name, Uint8List body) {
    if (name != 'events') {
      return false;
    }
    posts.add((name, utf8.decode(body)));
    return true;
  }
}

// A share held in memory, counting what the bridge asks of it
class _MemoryShare implements NetworkFileSystem {
  _MemoryShare(String id) : source = NetworkSource(id: id, type: NetworkSourceType.smb, name: 'Share $id', host: 'nas');

  @override
  final NetworkSource source;

  final files = <String, Uint8List>{};
  final directories = <String>{'/'};

  // Files whose byte i is _virtualByte(i), by size
  final virtualFiles = <String, int>{};

  // Files whose stat does not give a size
  final unknownSize = <String>{};

  // The content types the stat gives, by path
  final mimeTypes = <String, String>{};

  // What stat throws, by path
  final statErrors = <String, Exception>{};

  // Reads of a file from this offset on fail
  final failReadsFrom = <String, int>{};

  Duration readDelay = Duration.zero;

  // The share brings this many bytes per second, null for at once
  int? bytesPerSecond;

  // Called before each read, may hold it
  Future<void> Function(String path)? beforeRead;

  int statCount = 0;
  final reads = <({String path, int offset, int length})>[];

  int readsOf(String path) => reads.where((read) => read.path == path).length;

  int bytesAskedOf(String path) => reads.where((read) => read.path == path).fold(0, (sum, read) => sum + read.length);

  @override
  Future<List<NetworkEntry>> list(String path) async => [
    for (final file in files.keys) NetworkEntry(sourceId: source.id, path: file, isDirectory: false),
  ];

  @override
  Future<NetworkEntry> stat(String path) async {
    statCount++;
    final error = statErrors[path];
    if (error != null) {
      throw error;
    }
    if (directories.contains(path)) {
      return NetworkEntry(sourceId: source.id, path: path, isDirectory: true);
    }
    final size = files[path]?.length ?? virtualFiles[path];
    if (size == null) {
      throw const NetworkFileSystemException('No such file', isNotFound: true);
    }
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: unknownSize.contains(path) ? null : size,
      modified: _modified,
      mimeType: mimeTypes[path],
    );
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    reads.add((path: path, offset: offset, length: length));
    await beforeRead?.call(path);
    if (readDelay > Duration.zero) {
      await Future<void>.delayed(readDelay);
    }
    final rate = bytesPerSecond;
    if (rate != null) {
      await Future<void>.delayed(Duration(microseconds: length * Duration.microsecondsPerSecond ~/ rate));
    }
    final failFrom = failReadsFrom[path];
    if (failFrom != null && offset + length > failFrom) {
      throw const NetworkFileSystemException('The connection dropped');
    }
    final virtualSize = virtualFiles[path];
    if (virtualSize != null) {
      final end = (offset + length).clamp(0, virtualSize);
      return _virtualBytes(offset, end);
    }
    final bytes = files[path];
    if (bytes == null) {
      throw const NetworkFileSystemException('No such file', isNotFound: true);
    }
    final start = offset.clamp(0, bytes.length);
    final end = (offset + length).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, start, end);
  }

  @override
  Future<void> close() async {}
}

// Against the test servers of the development machine only
final _netTests = Platform.environment['IMMUCH_NET_TESTS'] == '1';

// The WebDAV test server read with plain HEAD and GET Range requests, so that the bridge is tried over a real network
// connection without depending on the WebDAV file system of the app
class _HttpRangeShare implements NetworkFileSystem {
  _HttpRangeShare({this.password = 'testpass'});

  final String password;
  final _client = HttpClient();
  final _base = Uri.parse('http://localhost:1880/');

  @override
  final source = const NetworkSource(
    id: 'dav',
    type: NetworkSourceType.webdav,
    name: 'Test WebDAV',
    host: 'localhost',
    port: 1880,
  );

  Future<HttpClientResponse> _open(String method, String path, {String? range}) async {
    final request = await _client.openUrl(method, _base.replace(path: path));
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic ${base64Encode(utf8.encode('tester:$password'))}');
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    return request.close();
  }

  void _check(HttpClientResponse response) {
    if (response.statusCode == HttpStatus.notFound) {
      throw const NetworkFileSystemException('No such file', isNotFound: true);
    }
    if (response.statusCode == HttpStatus.unauthorized) {
      throw const NetworkFileSystemException('Refused', isAuthentication: true);
    }
  }

  @override
  Future<List<NetworkEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<NetworkEntry> stat(String path) async {
    final response = await _open('HEAD', path);
    await response.drain<void>();
    _check(response);
    final modified = response.headers.value(HttpHeaders.lastModifiedHeader);
    return NetworkEntry(
      sourceId: source.id,
      path: path,
      isDirectory: false,
      size: response.contentLength,
      modified: modified == null ? null : HttpDate.parse(modified),
    );
  }

  @override
  Future<Uint8List> readRange(String path, int offset, int length) async {
    final response = await _open('GET', path, range: 'bytes=$offset-${offset + length - 1}');
    _check(response);
    final body = BytesBuilder(copy: false);
    await response.forEach(body.add);
    return response.statusCode == HttpStatus.requestedRangeNotSatisfiable ? Uint8List(0) : body.takeBytes();
  }

  @override
  Future<void> close() async => _client.close(force: true);
}

class _Reply {
  const _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final Uint8List body;

  String? header(String name) => headers.value(name);
}

Future<_Reply> _send(
  Uri url, {
  String method = 'GET',
  String? range,
  String? ifRange,
  HttpClient? client,
  List<int>? body,
}) async {
  final http = client ?? HttpClient();
  try {
    final request = await http.openUrl(method, url);
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
    if (ifRange != null) {
      request.headers.set(HttpHeaders.ifRangeHeader, ifRange);
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final received = BytesBuilder(copy: false);
    await response.forEach(received.add);
    return _Reply(response.statusCode, response.headers, received.takeBytes());
  } finally {
    if (client == null) {
      http.close();
    }
  }
}

// The same URL with another first segment
Uri _withToken(Uri url, String token) => url.replace(pathSegments: [token, ...url.pathSegments.skip(1)]);

// A GET sent on a raw socket and left paused once the first bytes came: a player that does not read for now
class _PausedRequest {
  late final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;

  static Future<_PausedRequest> open(LocalMediaBridge bridge, Uri url, {String? range}) async {
    final request = _PausedRequest();
    await request._open(bridge, url, range);
    return request;
  }

  Future<void> _open(LocalMediaBridge bridge, Uri url, String? range) async {
    _socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
    final firstBytes = Completer<void>();
    _subscription = _socket.listen((_) {
      if (!firstBytes.isCompleted) {
        firstBytes.complete();
      }
    });
    _socket.write('GET ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\n${range == null ? '' : 'Range: $range\r\n'}\r\n');
    await _socket.flush();
    await firstBytes.future;
    _subscription.pause();
  }

  Future<void> close() async {
    await _subscription.cancel();
    _socket.destroy();
  }
}

// Waits until [condition] holds, 10 seconds at most
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Waits until the bridge holds nothing read ahead, its clients gone, and gives what it holds then. The bridge learns
/// that a client left from its socket, and gets back what a read under way holds when that read ends: [_settled] could
/// look before, the count still for 100 ms on a loaded machine, and "the bridge holds at most 32 MiB read ahead"
/// failed now and then in the whole suite (32 MiB still held).
Future<int> _released(LocalMediaBridge bridge) async {
  await _until(() => bridge.bufferedSize == 0);
  return bridge.bufferedSize;
}

// Waits until [count] stops changing
Future<int> _settled(int Function() count) async {
  var last = count();
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final now = count();
    if (now == last) {
      return now;
    }
    last = now;
  }
  return last;
}

void main() {
  late LocalMediaBridge bridge;
  late _MemoryShare share;
  late DateTime now;

  final photo = _bytes(1000);
  final clip = _bytes(300 * 1024, seed: 7);
  final big = _bytes(10 * 1024 * 1024, seed: 3);

  setUp(() async {
    now = DateTime(2026, 1, 1);
    bridge = LocalMediaBridge(clock: () => now);
    share = _MemoryShare('nas1')
      ..directories.add('/sub')
      ..files['/photo.jpg'] = photo
      ..files['/sub/clip.mp4'] = clip
      ..files['/big.mp4'] = big
      ..files['/empty.jpg'] = Uint8List(0)
      ..files['/sub/my photo #1 (été).jpg'] = photo;
    bridge.register(share);
    await bridge.start();
  });

  tearDown(() async {
    await bridge.stop();
  });

  group('lifecycle', () {
    test('tells whether it runs and on which port', () async {
      final other = LocalMediaBridge();
      expect(other.isRunning, isFalse);
      expect(other.port, isNull);
      expect(() => other.urlFor('nas1', '/photo.jpg'), throwsStateError);

      await other.start();
      await other.start();
      expect(other.isRunning, isTrue);
      expect(other.port, greaterThan(0));

      await other.stop();
      expect(other.isRunning, isFalse);
      expect(other.port, isNull);
    });

    test('starts once when asked twice at the same time', () async {
      final other = LocalMediaBridge();
      await Future.wait([other.start(), other.start()]);
      expect(other.isRunning, isTrue);
      await other.stop();
    });

    test('listens again on the same port after a stop, so that the URLs given stay valid', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      await bridge.stop();
      expect(bridge.urlFor('nas1', '/photo.jpg'), url);

      await bridge.start();
      expect(bridge.port, url.port);
      final reply = await _send(url);
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, photo);
    });

    test('builds loopback URLs with a 32 character token, different for each bridge', () async {
      final url = bridge.urlFor('nas1', '/sub/clip.mp4');
      expect(url.scheme, 'http');
      expect(url.host, '127.0.0.1');
      expect(url.port, bridge.port);
      expect(url.pathSegments, hasLength(4));
      expect(url.pathSegments[0], matches(RegExp(r'^[A-Za-z0-9]{32}$')));
      expect(url.pathSegments.skip(1), ['nas1', 'sub', 'clip.mp4']);

      final other = LocalMediaBridge();
      await other.start();
      expect(other.urlFor('nas1', '/sub/clip.mp4').pathSegments[0], isNot(url.pathSegments[0]));
      await other.stop();
    });

    test('a stop cuts a film being streamed at once, while the share does not answer its next read', () async {
      // The close of the window of 1 November 2026 (desktop build 19): a player reading a film of a share that stopped
      // answering must get the end of its connection at once, so that its read returns
      final firstRead = Completer<void>();
      final answer = Completer<void>();
      share.beforeRead = (path) async {
        if (!firstRead.isCompleted) {
          firstRead.complete();
          return;
        }
        await answer.future;
      };
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(bridge.urlFor('nas1', '/big.mp4'))).close();
      var received = 0;
      final ended = Completer<void>();
      response.listen(
        (chunk) => received += chunk.length,
        onDone: ended.complete,
        onError: (Object _) => ended.complete(),
        cancelOnError: true,
      );
      await _until(() => received > 0 && share.reads.length > 1);
      expect(received, lessThan(big.length));

      final watch = Stopwatch()..start();
      await bridge.stop().timeout(const Duration(seconds: 2));
      await ended.future.timeout(const Duration(seconds: 2));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(received, lessThan(big.length), reason: 'the body was cut, not completed');

      // The share answers late: what it brings goes nowhere, and no other read starts
      final reads = share.reads.length;
      answer.complete();
      expect(await _settled(() => share.reads.length), reads);
      expect(await _released(bridge), 0);
    });
  });

  group('whole files', () {
    test('GET sends the file with its type, size and range support', () async {
      final reply = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, photo);
      expect(reply.header(HttpHeaders.contentTypeHeader), 'image/jpeg');
      expect(reply.header(HttpHeaders.contentLengthHeader), '1000');
      expect(reply.header(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(reply.header(HttpHeaders.lastModifiedHeader), HttpDate.format(_modified));
      expect(reply.header(HttpHeaders.contentRangeHeader), isNull);
    });

    test('GET of a video in a folder', () async {
      final reply = await _send(bridge.urlFor('nas1', '/sub/clip.mp4'));
      expect(reply.status, HttpStatus.ok);
      expect(reply.header(HttpHeaders.contentTypeHeader), 'video/mp4');
      expect(reply.body, clip);
    });

    test('HEAD sends the headers only, and the connection serves the next request', () async {
      final client = HttpClient();
      try {
        final head = await _send(bridge.urlFor('nas1', '/sub/clip.mp4'), method: 'HEAD', client: client);
        expect(head.status, HttpStatus.ok);
        expect(head.body, isEmpty);
        expect(head.header(HttpHeaders.contentLengthHeader), '${clip.length}');
        expect(head.header(HttpHeaders.contentTypeHeader), 'video/mp4');
        expect(head.header(HttpHeaders.acceptRangesHeader), 'bytes');
        expect(share.reads, isEmpty);

        final missing = await _send(bridge.urlFor('nas1', '/missing.jpg'), method: 'HEAD', client: client);
        expect(missing.status, HttpStatus.notFound);
        expect(missing.body, isEmpty);

        final get = await _send(bridge.urlFor('nas1', '/photo.jpg'), client: client);
        expect(get.body, photo);
      } finally {
        client.close();
      }
    });

    test('a HEAD then a GET stat the file once', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      await _send(url, method: 'HEAD');
      await _send(url);
      await _send(url, range: 'bytes=0-1');
      expect(share.statCount, 1);
    });

    test('the stat is asked again once a minute passed', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      await _send(url, method: 'HEAD');
      now = now.add(const Duration(seconds: 30));
      await _send(url, method: 'HEAD');
      expect(share.statCount, 1);
      now = now.add(const Duration(seconds: 31));
      await _send(url, method: 'HEAD');
      expect(share.statCount, 2);
    });

    test('a failed stat is not kept', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      share.statErrors['/photo.jpg'] = const NetworkFileSystemException('Host unreachable');
      expect((await _send(url)).status, HttpStatus.internalServerError);
      share.statErrors.clear();
      expect((await _send(url)).status, HttpStatus.ok);
      expect(share.statCount, 2);
    });

    test('an empty file', () async {
      final reply = await _send(bridge.urlFor('nas1', '/empty.jpg'));
      expect(reply.status, HttpStatus.ok);
      expect(reply.header(HttpHeaders.contentLengthHeader), '0');
      expect(reply.body, isEmpty);
      expect(share.reads, isEmpty);
    });

    test('a file of unknown size is read until it ends, without ranges', () async {
      share.unknownSize.add('/sub/clip.mp4');
      final reply = await _send(bridge.urlFor('nas1', '/sub/clip.mp4'), range: 'bytes=0-9');
      expect(reply.status, HttpStatus.ok);
      expect(reply.header(HttpHeaders.acceptRangesHeader), 'none');
      expect(reply.body, clip);
    });

    test('the content type the share gives, when a header can carry it', () async {
      share.mimeTypes['/photo.jpg'] = 'image/x-custom; charset=binary';
      share.mimeTypes['/sub/clip.mp4'] = 'video/mp4\r\nX-Injected: yes';
      final photoReply = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(photoReply.header(HttpHeaders.contentTypeHeader), 'image/x-custom');
      final clipReply = await _send(bridge.urlFor('nas1', '/sub/clip.mp4'));
      expect(clipReply.status, HttpStatus.ok);
      expect(clipReply.header(HttpHeaders.contentTypeHeader), 'video/mp4');
      expect(clipReply.header('x-injected'), isNull);
      expect(clipReply.body, clip);
    });

    test('names with spaces, signs and accents are encoded in the URL and found again', () async {
      final url = bridge.urlFor('nas1', '/sub/my photo #1 (été).jpg');
      expect(url.toString(), contains('my%20photo%20%231'));
      expect(url.fragment, isEmpty);
      final reply = await _send(url);
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, photo);
      expect(share.reads.single.path, '/sub/my photo #1 (été).jpg');
    });
  });

  group('ranges', () {
    late Uri url;

    setUp(() => url = bridge.urlFor('nas1', '/photo.jpg'));

    test('bytes=a-b', () async {
      final reply = await _send(url, range: 'bytes=10-19');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');
      expect(reply.header(HttpHeaders.contentLengthHeader), '10');
      expect(reply.header(HttpHeaders.contentTypeHeader), 'image/jpeg');
      expect(reply.body, photo.sublist(10, 20));
    });

    test('bytes=a- to the end of the file', () async {
      final reply = await _send(url, range: 'bytes=900-');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 900-999/1000');
      expect(reply.body, photo.sublist(900));
    });

    test('bytes=-n, the last bytes', () async {
      final reply = await _send(url, range: 'bytes=-50');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 950-999/1000');
      expect(reply.body, photo.sublist(950));
    });

    test('a range past the end is cut at the end', () async {
      final reply = await _send(url, range: 'bytes=990-5000');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 990-999/1000');
      expect(reply.body, photo.sublist(990));

      final suffix = await _send(url, range: 'bytes=-5000');
      expect(suffix.status, HttpStatus.partialContent);
      expect(suffix.header(HttpHeaders.contentRangeHeader), 'bytes 0-999/1000');
      expect(suffix.body, photo);
    });

    test('the first two bytes, as AVPlayer asks first', () async {
      final reply = await _send(bridge.urlFor('nas1', '/sub/clip.mp4'), range: 'bytes=0-1');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 0-1/${clip.length}');
      expect(reply.body, clip.sublist(0, 2));
    });

    test('HEAD with a range sends the range headers only', () async {
      final reply = await _send(url, method: 'HEAD', range: 'bytes=100-199');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes 100-199/1000');
      expect(reply.header(HttpHeaders.contentLengthHeader), '100');
      expect(reply.body, isEmpty);
    });

    test('ranges no byte of which is in the file are not satisfiable', () async {
      for (final range in ['bytes=1000-', 'bytes=5000-6000', 'bytes=-0']) {
        final reply = await _send(url, range: range);
        expect(reply.status, HttpStatus.requestedRangeNotSatisfiable, reason: range);
        expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes */1000', reason: range);
      }
      final empty = await _send(bridge.urlFor('nas1', '/empty.jpg'), range: 'bytes=0-');
      expect(empty.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(empty.header(HttpHeaders.contentRangeHeader), 'bytes */0');
      expect(share.reads, isEmpty);
    });

    test('headers that are not a single byte range are ignored', () async {
      for (final range in ['bytes=0-1,5-6', 'bytes=20-10', 'items=0-5', 'bytes=abc', 'bytes=-']) {
        final reply = await _send(url, range: range);
        expect(reply.status, HttpStatus.ok, reason: range);
        expect(reply.body, photo, reason: range);
      }
    });

    test('If-Range: the range when the file did not change, the whole file otherwise', () async {
      final same = await _send(url, range: 'bytes=0-9', ifRange: HttpDate.format(_modified));
      expect(same.status, HttpStatus.partialContent);
      expect(same.body, photo.sublist(0, 10));

      final changed = await _send(url, range: 'bytes=0-9', ifRange: HttpDate.format(DateTime.utc(2020)));
      expect(changed.status, HttpStatus.ok);
      expect(changed.body, photo);
    });
  });

  group('transport streams with 192 byte packets (M2TS)', () {
    // 6000 packets: more than one chunk, whose bounds fall inside the packets
    final ts = tsPackets(6000);
    final m2ts = m2tsOf(ts);

    setUp(() {
      share
        ..files['/film.m2ts'] = m2ts
        ..files['/clip.mts'] = ts
        ..files['/recording.mkv'] = m2ts
        ..mimeTypes['/recording.mkv'] = 'video/vnd.dlna.mpeg-tts';
    });

    test('served as the 188 byte TS they hold, for Media3', () async {
      final reply = await _send(bridge.urlFor('nas1', '/film.m2ts'));
      expect(reply.status, HttpStatus.ok);
      expect(reply.header(HttpHeaders.contentTypeHeader), 'video/mp2t');
      expect(reply.header(HttpHeaders.contentLengthHeader), '${ts.length}');
      expect(reply.header(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(reply.body, ts);

      // Looked at once
      final looks = share.reads.where((read) => read.path == '/film.m2ts' && read.length == m2tsSniffLength);
      await _send(bridge.urlFor('nas1', '/film.m2ts'), range: 'bytes=0-9');
      expect(looks, hasLength(1));
    });

    test('with ranges, inside the packets, open and from the end', () async {
      final url = bridge.urlFor('nas1', '/film.m2ts');
      for (final (range, start, end) in [
        ('bytes=0-1', 0, 2),
        ('bytes=100-1000', 100, 1001),
        ('bytes=187-188', 187, 189),
        ('bytes=500000-', 500000, ts.length),
        ('bytes=-1000', ts.length - 1000, ts.length),
      ]) {
        final reply = await _send(url, range: range);
        expect(reply.status, HttpStatus.partialContent, reason: range);
        expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes $start-${end - 1}/${ts.length}', reason: range);
        expect(reply.body, ts.sublist(start, end), reason: range);
      }
      final past = await _send(url, range: 'bytes=${ts.length}-');
      expect(past.status, HttpStatus.requestedRangeNotSatisfiable);
    });

    test('found by the content type a DLNA server gives too', () async {
      final reply = await _send(bridge.urlFor('nas1', '/recording.mkv'));
      expect(reply.header(HttpHeaders.contentTypeHeader), 'video/mp2t');
      expect(reply.body, ts);
    });

    test('a TS with 188 byte packets is served as it is', () async {
      final reply = await _send(bridge.urlFor('nas1', '/clip.mts'));
      expect(reply.header(HttpHeaders.contentTypeHeader), 'video/mp2t');
      expect(reply.body, ts);
    });

    test('as they are on the computers, whose player reads them', () async {
      final desktop = LocalMediaBridge(convertM2ts: false)..register(share);
      await desktop.start();
      addTearDown(desktop.stop);

      final reply = await _send(desktop.urlFor('nas1', '/film.m2ts'));
      expect(reply.body, m2ts);
      expect(share.reads.where((read) => read.path == '/film.m2ts' && read.length == m2tsSniffLength), isEmpty);
    });
  });

  group('generated media', () {
    late _MemoryMedia live;

    setUp(() {
      live = _MemoryMedia()
        ..files['live.m3u8'] = GeneratedFile(_playlistBytes, 'application/vnd.apple.mpegurl')
        ..files['seg3.m4s'] = GeneratedFile(clip, 'video/mp4');
      bridge.registerGenerated('a1b2c3d4e5f6a7b8c9d0e1f2', live);
    });

    test('serves the playlist and the segments from memory, never cached', () async {
      final playlist = await _send(bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'live.m3u8'));
      expect(playlist.status, HttpStatus.ok);
      expect(playlist.body, _playlistBytes);
      expect(playlist.header(HttpHeaders.contentTypeHeader), 'application/vnd.apple.mpegurl');
      expect(playlist.header(HttpHeaders.cacheControlHeader), 'no-cache');
      expect(playlist.header(HttpHeaders.contentLengthHeader), '${_playlistBytes.length}');

      final segment = await _send(bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'seg3.m4s'));
      expect(segment.body, clip);
      expect(segment.header(HttpHeaders.contentTypeHeader), 'video/mp4');
      expect(live.asked, ['live.m3u8', 'seg3.m4s']);
    });

    test('answers ranges and HEAD from memory', () async {
      final url = bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'seg3.m4s');
      final part = await _send(url, range: 'bytes=0-1');
      expect(part.status, HttpStatus.partialContent);
      expect(part.body, clip.sublist(0, 2));
      expect(part.header(HttpHeaders.contentRangeHeader), 'bytes 0-1/${clip.length}');
      final tail = await _send(url, range: 'bytes=-10');
      expect(tail.body, clip.sublist(clip.length - 10));
      expect((await _send(url, range: 'bytes=${clip.length}-')).status, HttpStatus.requestedRangeNotSatisfiable);

      final head = await _send(url, method: 'HEAD');
      expect(head.status, HttpStatus.ok);
      expect(head.body, isEmpty);
      expect(head.header(HttpHeaders.contentLengthHeader), '${clip.length}');
    });

    test('a file the media does not have, a wrong token, another method', () async {
      final url = bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'seg9.m4s');
      expect((await _send(url)).status, HttpStatus.notFound);
      final playlist = bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'live.m3u8');
      expect((await _send(_withToken(playlist, 'A' * 32))).status, HttpStatus.notFound);
      expect((await _send(playlist, method: 'POST')).status, HttpStatus.methodNotAllowed);
      expect(live.asked, isNot(contains('live.m3u8')), reason: 'nothing asked for a refused request');
      // Deeper paths are no file of generated media
      final deeper = playlist.replace(pathSegments: [...playlist.pathSegments.take(2), 'sub', 'live.m3u8']);
      expect((await _send(deeper)).status, HttpStatus.notFound);
    });

    test('media fetched when asked: its file, 404 for none, 502 when the fetch fails', () async {
      final fetched = _FetchedMedia({'film.m3u8': GeneratedFile(_playlistBytes, 'application/vnd.apple.mpegurl')});
      bridge.registerGenerated('f0e1d2c3b4a5968778695a4b', fetched);
      final playlist = await _send(bridge.urlFor('f0e1d2c3b4a5968778695a4b', 'film.m3u8'));
      expect(playlist.status, HttpStatus.ok);
      expect(playlist.body, _playlistBytes);
      expect(playlist.header(HttpHeaders.contentTypeHeader), 'application/vnd.apple.mpegurl');
      expect((await _send(bridge.urlFor('f0e1d2c3b4a5968778695a4b', '7.ts'))).status, HttpStatus.notFound);
      fetched.fails = true;
      expect((await _send(bridge.urlFor('f0e1d2c3b4a5968778695a4b', 'film.m3u8'))).status, HttpStatus.badGateway);
      expect(fetched.asked, ['film.m3u8', '7.ts', 'film.m3u8']);
    });

    test('nothing once unregistered; the shares are still served', () async {
      bridge.unregisterGenerated('a1b2c3d4e5f6a7b8c9d0e1f2');
      expect((await _send(bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'live.m3u8'))).status, HttpStatus.notFound);
      expect((await _send(bridge.urlFor('nas1', '/photo.jpg'))).body, photo);
    });

    test('still served after the bridge listens again', () async {
      final url = bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'live.m3u8');
      await bridge.stop();
      await bridge.start();
      expect((await _send(url)).body, _playlistBytes);
    });
  });

  // The splat viewer's session (lot SV1 of the splat viewer): a file of the computer or of the cache streamed from
  // disk with ranges, the headers each file asks for, and the small posts of the page
  group('generated files on disk, their headers and posts', () {
    const id = 'f0e1d2c3b4a5968778695a4b3c2d1e0f';
    late Directory folder;
    late File scene;
    late Uint8List sceneBytes;
    late _SinkMedia viewer;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('bridge_disk_test');
      addTearDown(() => folder.delete(recursive: true));
      sceneBytes = _bytes(3 * _mib + 17, seed: 11);
      scene = File('${folder.path}/scene.spz')..writeAsBytesSync(sceneBytes);
      viewer = _SinkMedia()
        ..files['scene.spz'] = GeneratedFile.disk(
          scene,
          'application/octet-stream',
          headers: const {'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff'},
        )
        ..files['index.html'] = GeneratedFile(
          Uint8List.fromList(utf8.encode('<!doctype html>')),
          'text/html; charset=utf-8',
          headers: const {'Content-Security-Policy': "default-src 'none'", 'X-Content-Type-Options': 'nosniff'},
        );
      bridge.registerGenerated(id, viewer);
    });

    test('streams the whole file from disk, with its headers', () async {
      final reply = await _send(bridge.urlFor(id, 'scene.spz'));
      expect(reply.status, HttpStatus.ok);
      expect(reply.body, sceneBytes);
      expect(reply.header(HttpHeaders.contentLengthHeader), '${sceneBytes.length}');
      expect(reply.header(HttpHeaders.acceptRangesHeader), 'bytes');
      expect(reply.header(HttpHeaders.contentTypeHeader), 'application/octet-stream');
      expect(reply.header(HttpHeaders.cacheControlHeader), 'no-store');
      expect(reply.header('x-content-type-options'), 'nosniff');
      expect(reply.header(HttpHeaders.lastModifiedHeader), HttpDate.format(scene.lastModifiedSync()));
    });

    test('the first, a middle and the last byte, and a range past the end', () async {
      final url = bridge.urlFor(id, 'scene.spz');
      final first = await _send(url, range: 'bytes=0-0');
      expect(first.status, HttpStatus.partialContent);
      expect(first.body, sceneBytes.sublist(0, 1));
      expect(first.header(HttpHeaders.contentRangeHeader), 'bytes 0-0/${sceneBytes.length}');
      final middle = await _send(url, range: 'bytes=${_mib + 5}-${2 * _mib + 9}');
      expect(middle.body, sceneBytes.sublist(_mib + 5, 2 * _mib + 10));
      final last = await _send(url, range: 'bytes=-1');
      expect(last.body, sceneBytes.sublist(sceneBytes.length - 1));
      final open = await _send(url, range: 'bytes=${sceneBytes.length - 3}-');
      expect(open.body, sceneBytes.sublist(sceneBytes.length - 3));
      final past = await _send(url, range: 'bytes=${sceneBytes.length}-');
      expect(past.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(past.header(HttpHeaders.contentRangeHeader), 'bytes */${sceneBytes.length}');
    });

    test(
      'a range on the condition of its date: the part when the file is the same, the whole file otherwise',
      () async {
        final url = bridge.urlFor(id, 'scene.spz');
        final date = HttpDate.format(scene.lastModifiedSync());
        final same = await _send(url, range: 'bytes=10-19', ifRange: date);
        expect(same.status, HttpStatus.partialContent);
        expect(same.body, sceneBytes.sublist(10, 20));
        final changed = await _send(url, range: 'bytes=10-19', ifRange: HttpDate.format(DateTime.utc(2001)));
        expect(changed.status, HttpStatus.ok);
        expect(changed.body.length, sceneBytes.length);
      },
    );

    test('HEAD gives the size and no body', () async {
      final head = await _send(bridge.urlFor(id, 'scene.spz'), method: 'HEAD');
      expect(head.status, HttpStatus.ok);
      expect(head.body, isEmpty);
      expect(head.header(HttpHeaders.contentLengthHeader), '${sceneBytes.length}');
    });

    test('a file of memory with its own headers', () async {
      final page = await _send(bridge.urlFor(id, 'index.html'));
      expect(page.status, HttpStatus.ok);
      expect(utf8.decode(page.body), '<!doctype html>');
      expect(page.header(HttpHeaders.contentTypeHeader), 'text/html; charset=utf-8');
      expect(page.header('content-security-policy'), "default-src 'none'");
      expect(page.header('x-content-type-options'), 'nosniff');
      expect(page.header(HttpHeaders.cacheControlHeader), 'no-cache', reason: 'the default of generated media');
    });

    test('a file gone from disk is not found', () async {
      await scene.delete();
      expect((await _send(bridge.urlFor(id, 'scene.spz'))).status, HttpStatus.notFound);
    });

    test('a post to the sink is handed over and answered 204', () async {
      final reply = await _send(bridge.urlFor(id, 'events'), method: 'POST', body: utf8.encode('{"type":"ready"}'));
      expect(reply.status, HttpStatus.noContent);
      expect(viewer.posts, [('events', '{"type":"ready"}')]);
    });

    test('a post of 16 KiB is taken, a larger one is refused with 413 and not handed over', () async {
      final most = List.filled(GeneratedMediaSink.maxPostBytes, 0x20);
      expect((await _send(bridge.urlFor(id, 'events'), method: 'POST', body: most)).status, HttpStatus.noContent);
      final over = List.filled(GeneratedMediaSink.maxPostBytes + 1, 0x20);
      final refused = await _send(bridge.urlFor(id, 'events'), method: 'POST', body: over);
      expect(refused.status, HttpStatus.requestEntityTooLarge);
      expect(viewer.posts, hasLength(1));
    });

    test('a post to a name the sink does not take is not found', () async {
      final reply = await _send(bridge.urlFor(id, 'scene.spz'), method: 'POST', body: utf8.encode('{}'));
      expect(reply.status, HttpStatus.notFound);
      expect(viewer.posts, isEmpty);
    });

    test('a post to media without a sink, and other methods, are not allowed', () async {
      final live = _MemoryMedia()..files['live.m3u8'] = GeneratedFile(_playlistBytes, 'application/vnd.apple.mpegurl');
      bridge.registerGenerated('a1b2c3d4e5f6a7b8c9d0e1f2', live);
      final post = await _send(bridge.urlFor('a1b2c3d4e5f6a7b8c9d0e1f2', 'live.m3u8'), method: 'POST', body: [1]);
      expect(post.status, HttpStatus.methodNotAllowed);
      expect(post.header(HttpHeaders.allowHeader), 'GET, HEAD');
      final put = await _send(bridge.urlFor(id, 'events'), method: 'PUT', body: [1]);
      expect(put.status, HttpStatus.methodNotAllowed);
      expect(put.header(HttpHeaders.allowHeader), 'GET, HEAD, POST');
      expect(viewer.posts, isEmpty);
    });

    test('the token is needed for the files and the posts, and nothing is served once unregistered', () async {
      final scenery = bridge.urlFor(id, 'scene.spz');
      final events = bridge.urlFor(id, 'events');
      expect((await _send(_withToken(scenery, 'A' * 32))).status, HttpStatus.notFound);
      expect((await _send(_withToken(events, 'A' * 32), method: 'POST', body: [1])).status, HttpStatus.notFound);
      bridge.unregisterGenerated(id);
      expect((await _send(scenery)).status, HttpStatus.notFound);
      expect((await _send(events, method: 'POST', body: utf8.encode('{}'))).status, HttpStatus.notFound);
      expect(viewer.posts, isEmpty);
    });
  });

  group('errors', () {
    test('a wrong token', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      final wrong = 'A' * 32;
      expect((await _send(_withToken(url, wrong))).status, HttpStatus.notFound);
      expect((await _send(_withToken(url, url.pathSegments[0].substring(1)))).status, HttpStatus.notFound);
      expect((await _send(url.replace(path: '/'))).status, HttpStatus.notFound);
      expect((await _send(url.replace(pathSegments: url.pathSegments.take(2)))).status, HttpStatus.notFound);
      expect(share.statCount, 0);
    });

    test('an unknown or unregistered source', () async {
      expect((await _send(bridge.urlFor('other', '/photo.jpg'))).status, HttpStatus.notFound);

      final url = bridge.urlFor('nas1', '/photo.jpg');
      expect((await _send(url)).status, HttpStatus.ok);
      bridge.unregister('nas1');
      expect((await _send(url)).status, HttpStatus.notFound);
    });

    test('dot segments never reach the share', () async {
      final token = bridge.urlFor('nas1', '/photo.jpg').pathSegments[0];
      final statuses = <String, String>{};
      for (final path in [
        '/$token/nas1/sub/%2E%2E/photo.jpg',
        '/$token/nas1/%2E%2E/%2E%2E/photo.jpg',
        '/$token/nas1/./sub/%2e/clip.mp4',
      ]) {
        // Sent as is, the client would resolve them first
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
        try {
          socket.write('HEAD $path HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n');
          await socket.flush();
          final reply = await socket.cast<List<int>>().transform(latin1.decoder).join();
          statuses[path] = reply.split('\r\n').first;
        } finally {
          socket.destroy();
        }
      }
      // Resolved inside the share, or out of the URL space of the bridge
      expect(statuses.values, ['HTTP/1.1 200 OK', 'HTTP/1.1 404 Not Found', 'HTTP/1.1 200 OK']);
      expect(share.statCount, 2);
    });

    test('a missing file, or a folder', () async {
      final missing = await _send(bridge.urlFor('nas1', '/missing.jpg'));
      expect(missing.status, HttpStatus.notFound);
      expect((await _send(bridge.urlFor('nas1', '/sub'))).status, HttpStatus.notFound);
      expect((await _send(bridge.urlFor('nas1', '/'))).status, HttpStatus.notFound);
    });

    test('refused credentials answer 502 with a short reason', () async {
      share.statErrors['/photo.jpg'] = const NetworkFileSystemException('Access denied', isAuthentication: true);
      final reply = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(reply.status, HttpStatus.badGateway);
      expect(String.fromCharCodes(reply.body), 'The share refused the credentials');
    });

    test('other failures answer 500', () async {
      share.statErrors['/photo.jpg'] = const FormatException('Something broke');
      expect((await _send(bridge.urlFor('nas1', '/photo.jpg'))).status, HttpStatus.internalServerError);
      share.statErrors['/sub/clip.mp4'] = const NetworkFileSystemException('Host unreachable');
      expect((await _send(bridge.urlFor('nas1', '/sub/clip.mp4'))).status, HttpStatus.internalServerError);
    });

    test('only GET and HEAD are served', () async {
      final reply = await _send(bridge.urlFor('nas1', '/photo.jpg'), method: 'DELETE');
      expect(reply.status, HttpStatus.methodNotAllowed);
      expect(reply.header(HttpHeaders.allowHeader), 'GET, HEAD');
    });

    test('a first read that fails answers with a status', () async {
      share.failReadsFrom['/photo.jpg'] = 0;
      final failed = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(failed.status, HttpStatus.internalServerError);
      expect(String.fromCharCodes(failed.body), 'The share could not be read');
      expect(failed.header(HttpHeaders.contentRangeHeader), isNull);

      share.failReadsFrom.clear();
      final next = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(next.body, photo);
    });

    test('a file gone or shorter since its stat answers with a status, and is asked again', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      await _send(url, method: 'HEAD');
      share.files['/photo.jpg'] = _bytes(100);
      final shorter = await _send(url, range: 'bytes=500-');
      expect(shorter.status, HttpStatus.internalServerError);
      final fresh = await _send(url, range: 'bytes=500-');
      expect(fresh.status, HttpStatus.requestedRangeNotSatisfiable);
      expect(fresh.header(HttpHeaders.contentRangeHeader), 'bytes */100');

      // Still known from the last stat, gone when read
      share.files.remove('/photo.jpg');
      expect((await _send(url)).status, HttpStatus.notFound);
      expect((await _send(url, method: 'HEAD')).status, HttpStatus.notFound);
    });

    test('a read that fails in the middle cuts the body, and the bridge serves the next request', () async {
      const failFrom = 5 * _mib;
      share.failReadsFrom['/big.mp4'] = failFrom;
      await expectLater(_send(bridge.urlFor('nas1', '/big.mp4')), throwsA(isA<HttpException>()));
      // 256 KiB, then twice as much each time sent, the read of the next 4 MiB failed and none was asked after it
      expect(share.reads.map((read) => read.length), [_minChunk, 2 * _minChunk, _mib, 2 * _mib, _maxChunk]);
      expect(share.reads.last.offset + share.reads.last.length, greaterThan(failFrom));
      expect(await _released(bridge), 0);

      final next = await _send(bridge.urlFor('nas1', '/photo.jpg'));
      expect(next.body, photo);
    });
  });

  group('streaming', () {
    test('a 10 MB file read whole and by ranges, in chunks of 256 KiB growing to 4 MiB', () async {
      final url = bridge.urlFor('nas1', '/big.mp4');
      final whole = await _send(url);
      expect(whole.status, HttpStatus.ok);
      expect(whole.body.length, big.length);
      expect(whole.body, big);
      expect(share.reads.map((read) => read.length), _chunksOf(big.length));
      expect(share.reads.map((read) => read.length), [
        256 * 1024,
        512 * 1024,
        _mib,
        2 * _mib,
        4 * _mib,
        2 * _mib + 256 * 1024,
      ]);

      final client = HttpClient();
      try {
        final read = BytesBuilder(copy: false);
        const step = 1024 * 1024 + 123;
        for (var offset = 0; offset < big.length; offset += step) {
          final last = offset + step - 1;
          final reply = await _send(url, range: 'bytes=$offset-$last', client: client);
          expect(reply.status, HttpStatus.partialContent);
          final end = last < big.length ? last : big.length - 1;
          expect(reply.header(HttpHeaders.contentRangeHeader), 'bytes $offset-$end/${big.length}');
          read.add(reply.body);
        }
        expect(read.takeBytes(), big);
      } finally {
        client.close();
      }

      expect(share.reads.every((read) => read.length <= _maxChunk), isTrue);
      expect(share.statCount, 1);
      // Nothing left read ahead once the bodies are sent
      expect(bridge.bufferedSize, 0);
    });

    test('an open range of a big file is streamed to the end', () async {
      share.virtualFiles['/huge.mp4'] = 40 * 1024 * 1024 + 17;
      const offset = 30 * 1024 * 1024;
      final reply = await _send(bridge.urlFor('nas1', '/huge.mp4'), range: 'bytes=$offset-');
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.body.length, 10 * 1024 * 1024 + 17);
      for (final i in [0, 1, 250, 251, 999999, reply.body.length - 1]) {
        expect(reply.body[i], _virtualByte(offset + i), reason: 'byte $i');
      }
    });

    test('a client that does not read pauses the reading, past what is read ahead', () async {
      // Far more than the socket buffers hold
      share.virtualFiles['/huge.mp4'] = 512 * _mib;
      final url = bridge.urlFor('nas1', '/huge.mp4');
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
      try {
        socket.write('GET ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
        await socket.flush();
        final firstBytes = Completer<void>();
        final subscription = socket.listen((_) {
          if (!firstBytes.isCompleted) {
            firstBytes.complete();
          }
        });
        await firstBytes.future;
        subscription.pause();

        await _until(() => bridge.bufferedSize > 8 * _mib);
        await _settled(() => share.bytesAskedOf('/huge.mp4') + bridge.bufferedSize);
        // Up to 16 MiB waits for the client, besides what fits in the socket buffers
        expect(bridge.bufferedSize, greaterThan(8 * _mib));
        expect(bridge.bufferedSize, lessThanOrEqualTo(LocalMediaBridge.defaultReadAheadSize));
        expect(share.bytesAskedOf('/huge.mp4'), lessThan(64 * _mib));

        // Gone: what was read ahead is dropped
        await subscription.cancel();
        socket.destroy();
        expect(await _released(bridge), 0);
      } finally {
        socket.destroy();
      }
    });

    test('a stream elsewhere in the file takes the reading ahead, and gives it back when it closes', () async {
      share.virtualFiles['/huge.mp4'] = 512 * _mib;
      final url = bridge.urlFor('nas1', '/huge.mp4');
      const offset = 300 * _mib;
      int bytesBelow() => share.reads
          .where((read) => read.path == '/huge.mp4' && read.offset < offset)
          .fold(0, (sum, read) => sum + read.length);
      final first = await _PausedRequest.open(bridge, url);
      try {
        await _until(() => bridge.bufferedSize > 8 * _mib);
        await _settled(() => share.reads.length + bridge.bufferedSize);
        expect(bridge.bufferedSize, greaterThan(8 * _mib));

        // The player seeks: a new request to the end of the file, the first one left open and not read
        final second = await _PausedRequest.open(bridge, url, range: 'bytes=$offset-');
        try {
          await _settled(() => share.reads.length + bridge.bufferedSize);
          // What the first one read ahead is dropped, the second one reads ahead
          expect(bridge.bufferedSize, greaterThan(8 * _mib));
          expect(bridge.bufferedSize, lessThanOrEqualTo(LocalMediaBridge.defaultReadAheadSize));
        } finally {
          await second.close();
        }

        // The second one closed: the first one reads ahead again
        final asked = bytesBelow();
        await _until(() => bytesBelow() > asked + 8 * _mib);
        await _settled(() => share.reads.length + bridge.bufferedSize);
        expect(bytesBelow(), greaterThan(asked + 8 * _mib));
        expect(bridge.bufferedSize, greaterThan(8 * _mib));
        expect(bridge.bufferedSize, lessThanOrEqualTo(LocalMediaBridge.defaultReadAheadSize));
      } finally {
        await first.close();
      }
      expect(await _released(bridge), 0);
    });

    test('a short request elsewhere in the file leaves the reading ahead to the stream', () async {
      share.virtualFiles['/huge.mp4'] = 512 * _mib;
      final url = bridge.urlFor('nas1', '/huge.mp4');
      final stream = await _PausedRequest.open(bridge, url);
      try {
        await _until(() => bridge.bufferedSize > 8 * _mib);
        await _settled(() => share.reads.length + bridge.bufferedSize);
        final buffered = bridge.bufferedSize;
        expect(buffered, greaterThan(8 * _mib));
        final reads = share.reads.length;

        // A probe of the metadata reads 4 MiB at the end of the file while the player streams
        const offset = 500 * _mib;
        final reply = await _send(url, range: 'bytes=$offset-${offset + 4 * _mib - 1}');
        expect(reply.body.length, 4 * _mib);
        expect(reply.body[12345], _virtualByte(offset + 12345));

        // The stream kept what it read ahead, and the probe gave back what it held
        expect(await _settled(() => bridge.bufferedSize), buffered);
        expect(share.reads.skip(reads).every((read) => read.offset >= offset), isTrue);
      } finally {
        await stream.close();
      }
      expect(await _released(bridge), 0);
    });

    test('the bridge holds at most 32 MiB read ahead, all files together', () async {
      final sockets = <Socket>[];
      final subscriptions = <StreamSubscription<Uint8List>>[];
      try {
        for (final name in ['a', 'b', 'c']) {
          share.virtualFiles['/$name.mp4'] = 256 * _mib;
          final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
          sockets.add(socket);
          final firstBytes = Completer<void>();
          final subscription = socket.listen((_) {
            if (!firstBytes.isCompleted) {
              firstBytes.complete();
            }
          });
          socket.write('GET ${bridge.urlFor('nas1', '/$name.mp4').path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
          await socket.flush();
          await firstBytes.future;
          subscription.pause();
          subscriptions.add(subscription);
        }
        await _until(() => bridge.bufferedSize > 16 * _mib);
        await _settled(() => share.reads.length + bridge.bufferedSize);
        expect(bridge.bufferedSize, greaterThan(16 * _mib));
        expect(bridge.bufferedSize, lessThanOrEqualTo(LocalMediaBridge.defaultMaxBufferedSize));
        // The share answers slowly as the clients leave, as on a loaded machine: a read under way gives its bytes back
        // only when it ends, which a pause of the test cannot wait for
        share.readDelay = const Duration(milliseconds: 300);
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final socket in sockets) {
          socket.destroy();
        }
      }
      expect(await _released(bridge), 0);
    });

    test('a client that leaves stops the reading, and the bridge keeps serving the others', () async {
      share.readDelay = const Duration(milliseconds: 20);
      final url = bridge.urlFor('nas1', '/big.mp4');
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, bridge.port!);
      final firstBytes = Completer<void>();
      final subscription = socket.listen((_) {
        if (!firstBytes.isCompleted) {
          firstBytes.complete();
        }
      });
      socket.write('GET ${url.path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
      await socket.flush();

      // Another player reads the same file meanwhile
      final other = _send(url, range: 'bytes=0-');

      await firstBytes.future;
      await subscription.cancel();
      socket.destroy();

      final reply = await other;
      expect(reply.status, HttpStatus.partialContent);
      expect(reply.body, big);

      // The other reader took the whole file; the one that left far less, and no read started since
      final whole = _chunksOf(big.length).length;
      final reads = await _settled(() => share.readsOf('/big.mp4'));
      expect(reads, lessThan(2 * whole));
      expect(reads, greaterThanOrEqualTo(whole + 1));
      expect(bridge.bufferedSize, 0);

      share.readDelay = Duration.zero;
      expect((await _send(bridge.urlFor('nas1', '/photo.jpg'))).body, photo);
    });

    test(
      'a slow share is read about two seconds at a time, and the player gets bytes before the first 4 MiB',
      () async {
        // 2 Mbit/s: 4 MiB read at once took 17 s, more than the 8 s a player waits for a byte (31 October 2026)
        share.bytesPerSecond = 250 * 1000;
        final client = HttpClient();
        try {
          final request = await client.getUrl(bridge.urlFor('nas1', '/big.mp4'));
          final watch = Stopwatch()..start();
          final response = await request.close();
          final gaps = <Duration>[];
          var last = Duration.zero;
          var received = 0;
          await for (final chunk in response) {
            gaps.add(watch.elapsed - last);
            last = watch.elapsed;
            received += chunk.length;
            if (received >= 3 * _mib) {
              break;
            }
          }
          expect(gaps.reduce((a, b) => a > b ? a : b), lessThan(const Duration(milliseconds: 3500)));
        } finally {
          client.close(force: true);
        }
        final sizes = share.reads.map((read) => read.length).toList();
        expect(sizes.first, 256 * 1024);
        expect(sizes.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(640 * 1024), reason: '$sizes');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test('what the reads of a file bring is measured for the players of the computers', () async {
      final url = bridge.urlFor('nas1', '/big.mp4');
      expect(bridge.trafficOf(url), isNull);
      await _send(url, range: 'bytes=0-${2 * _mib - 1}');
      final traffic = bridge.trafficOf(url);
      expect(traffic?.size, big.length);
      expect(traffic?.meter.receivedBytes, greaterThanOrEqualTo(2 * _mib));
      expect(traffic?.meter.sinceProgress(), lessThan(const Duration(seconds: 5)));
      expect(bridge.trafficOf(bridge.urlFor('nas1', '/photo.jpg')), isNull);
    });

    test('a film opened again a while after its last read is no dead link while its first bytes come', () async {
      // Read, then left alone for 40 s (review of 1 November 2026: reopened, a share film read more than 30 s earlier
      // was said to be on a share that stopped sending until its first bytes came)
      final url = bridge.urlFor('nas1', '/big.mp4');
      await _send(url, range: 'bytes=0-${_mib - 1}');
      now = now.add(const Duration(seconds: 40));
      final reading = Completer<void>();
      final answer = Completer<void>();
      share.beforeRead = (path) async {
        if (!reading.isCompleted) {
          reading.complete();
        }
        await answer.future;
      };
      final reopened = _send(url, range: 'bytes=${4 * _mib}-${5 * _mib - 1}');
      await reading.future;
      // The share takes 2 s to answer
      now = now.add(const Duration(seconds: 2));
      final meter = bridge.trafficOf(url)!.meter;
      expect(meter.sinceProgress(), const Duration(seconds: 2));
      answer.complete();
      expect((await reopened).status, HttpStatus.partialContent);
    });

    test('the size of the next read follows what the share brings', () {
      const max = LocalMediaBridge.defaultMaxChunkSize;
      // Too quick to measure: twice as much, as before
      expect(
        LocalMediaBridge.nextChunkSize(previous: _mib, read: _mib, elapsed: Duration.zero, maxChunk: max),
        2 * _mib,
      );
      // 250 kB/s: two seconds of it
      expect(
        LocalMediaBridge.nextChunkSize(
          previous: 256 * 1024,
          read: 256 * 1024,
          elapsed: const Duration(microseconds: 1048576),
          maxChunk: max,
        ),
        500 * 1000,
      );
      // Never below 128 KiB, never more than twice the read before, never above the largest
      expect(
        LocalMediaBridge.nextChunkSize(previous: _mib, read: 1000, elapsed: const Duration(seconds: 1), maxChunk: max),
        128 * 1024,
      );
      expect(
        LocalMediaBridge.nextChunkSize(
          previous: _mib,
          read: _mib,
          elapsed: const Duration(milliseconds: 100),
          maxChunk: max,
        ),
        2 * _mib,
      );
      expect(
        LocalMediaBridge.nextChunkSize(
          previous: max,
          read: max,
          elapsed: const Duration(milliseconds: 100),
          maxChunk: max,
        ),
        max,
      );
    });

    test('two readers are served at the same time', () async {
      // Each read waits until both files are being read: served one after the other, this would never end
      final bothReading = Completer<void>();
      final reading = <String>{};
      share.beforeRead = (path) {
        reading.add(path);
        if (reading.length == 2 && !bothReading.isCompleted) {
          bothReading.complete();
        }
        return bothReading.future;
      };

      final replies = await Future.wait([
        _send(bridge.urlFor('nas1', '/big.mp4')),
        _send(bridge.urlFor('nas1', '/sub/clip.mp4'), range: 'bytes=1000-'),
      ]).timeout(const Duration(seconds: 20));

      expect(replies[0].status, HttpStatus.ok);
      expect(replies[0].body, big);
      expect(replies[1].status, HttpStatus.partialContent);
      expect(replies[1].body, clip.sublist(1000));
    });

    test('two shares registered side by side', () async {
      final second = _MemoryShare('nas2')..files['/photo.jpg'] = _bytes(500, seed: 99);
      bridge.register(second);
      expect((await _send(bridge.urlFor('nas2', '/photo.jpg'))).body, second.files['/photo.jpg']);
      expect((await _send(bridge.urlFor('nas1', '/photo.jpg'))).body, photo);
    });

    test('registering a share again forgets its stats', () async {
      final url = bridge.urlFor('nas1', '/photo.jpg');
      await _send(url, method: 'HEAD');
      final replaced = _MemoryShare('nas1')..files['/photo.jpg'] = _bytes(10, seed: 5);
      bridge.register(replaced);
      final reply = await _send(url);
      expect(reply.body, replaced.files['/photo.jpg']);
      expect(replaced.statCount, 1);
    });
  });

  group(
    'against the WebDAV test server',
    skip: _netTests ? false : 'Set IMMUCH_NET_TESTS=1 to run against the test servers',
    () {
      late _HttpRangeShare dav;

      setUp(() {
        dav = _HttpRangeShare();
        bridge.register(dav);
      });

      tearDown(() => dav.close());

      Future<Uint8List> direct(String path) async {
        final response = await dav._open('GET', path);
        final body = BytesBuilder(copy: false);
        await response.forEach(body.add);
        return body.takeBytes();
      }

      test('a video through the bridge is the file on the share, whole and by ranges', () async {
        final expected = await direct('/mono-video.mp4');
        final url = bridge.urlFor('dav', '/mono-video.mp4');

        final head = await _send(url, method: 'HEAD');
        expect(head.header(HttpHeaders.contentLengthHeader), '${expected.length}');
        expect(head.header(HttpHeaders.contentTypeHeader), 'video/mp4');

        final whole = await _send(url);
        expect(whole.status, HttpStatus.ok);
        expect(whole.body, expected);

        final middle = await _send(url, range: 'bytes=1000000-2999999');
        expect(middle.status, HttpStatus.partialContent);
        expect(middle.body, expected.sublist(1000000, 3000000));

        final tail = await _send(url, range: 'bytes=-100000');
        expect(tail.body, expected.sublist(expected.length - 100000));
      });

      test('a photo through the bridge', () async {
        final expected = await direct('/mono-photo.jpg');
        final reply = await _send(bridge.urlFor('dav', '/mono-photo.jpg'));
        expect(reply.header(HttpHeaders.contentTypeHeader), 'image/jpeg');
        expect(reply.body, expected);
      });

      test('a missing file and refused credentials', () async {
        expect((await _send(bridge.urlFor('dav', '/missing.jpg'))).status, HttpStatus.notFound);

        final refused = _HttpRangeShare(password: 'wrong');
        bridge.register(refused);
        try {
          expect((await _send(bridge.urlFor('dav', '/mono-photo.jpg'))).status, HttpStatus.badGateway);
        } finally {
          await refused.close();
        }
      });
    },
  );
}

/// Generated media whose files come from an await, as a conversion of the Plex server fetches them
class _FetchedMedia implements GeneratedMediaFetch {
  _FetchedMedia(this.files);

  final Map<String, GeneratedFile> files;
  final asked = <String>[];
  bool fails = false;

  @override
  Future<GeneratedFile?> fetch(String name) async {
    asked.add(name);
    await Future<void>.delayed(Duration.zero);
    if (fails) {
      throw const SocketException('the server is gone');
    }
    return files[name];
  }

  @override
  GeneratedFile? file(String name) => throw StateError('a fetched media is never asked synchronously');
}
