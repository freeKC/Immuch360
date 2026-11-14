// The http client of the worker isolate against local servers: what comes back, in how many batches, the reading
// held back by a reader that does not read, the aborts, the cuts of the server and the ranges of HttpRangeReader.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';
import 'package:immich_mobile/infrastructure/network/isolate_http_client.dart';

const _kib = 1024;
const _mib = 1024 * 1024;

// The byte at [offset] of the files of the server
Uint8List _bytes(int start, int length) => Uint8List.fromList([for (var i = 0; i < length; i++) (start + i) * 7 % 251]);

/// A server on 127.0.0.1 answering by path
class _Server {
  _Server._(this._server) {
    _server.listen((request) async {
      try {
        await (_routes[request.uri.path] ?? _notFound)(request);
      } catch (_) {
        // A client that went away
      }
    });
  }

  static Future<_Server> start() async => _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final _routes = <String, Future<void> Function(HttpRequest)>{};

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  void on(String path, Future<void> Function(HttpRequest request) route) => _routes[path] = route;

  Future<void> close() => _server.close(force: true);

  static Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = 404;
    await request.response.close();
  }

  /// A file with ranges, as Plex serves its parts
  Future<void> ranges(HttpRequest request, int size) async {
    final response = request.response;
    final range = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(request.headers.value('range') ?? '');
    if (range == null) {
      response.contentLength = size;
      response.add(_bytes(0, size));
      return response.close();
    }
    final start = int.parse(range.group(1)!);
    final end = range.group(2)!.isEmpty ? size - 1 : int.parse(range.group(2)!);
    if (start >= size) {
      response.statusCode = 416;
      return response.close();
    }
    final last = end < size ? end : size - 1;
    response
      ..statusCode = 206
      ..headers.set('content-range', 'bytes $start-$last/$size')
      ..contentLength = last - start + 1
      ..add(_bytes(start, last - start + 1));
    await response.close();
  }
}

/// A server on a raw socket that answers each request with [total] bytes, in pieces of [piece] each written once the
/// socket took the one before, and tells when its client went away (an HttpServer blocked in a flush does not)
class _Streamer {
  _Streamer._(this._server, this.total, this.piece) {
    _server.listen((socket) {
      var answered = false;
      void left(Object? _) {
        if (!clientLeft.isCompleted) {
          clientLeft.complete();
        }
      }

      socket.listen(
        (_) async {
          if (answered) {
            return;
          }
          answered = true;
          socket.add('HTTP/1.1 200 OK\r\ncontent-length: $total\r\n\r\n'.codeUnits);
          final block = Uint8List(piece);
          try {
            for (var sent = 0; sent < total && !clientLeft.isCompleted; sent += piece) {
              socket.add(piece <= total - sent ? block : Uint8List.sublistView(block, 0, total - sent));
              await socket.flush();
              flushed += piece;
            }
          } catch (error) {
            left(error);
          }
        },
        onError: left,
        onDone: () => left(null),
      );
    });
  }

  static Future<_Streamer> start(int total, {int piece = _mib}) async =>
      _Streamer._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0), total, piece);

  final ServerSocket _server;
  final int total;
  final int piece;

  /// Bytes the socket took
  int flushed = 0;

  /// Completes when the client went away
  final clientLeft = Completer<void>();

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/film');

  Future<void> close() => _server.close();
}

/// A server on a raw socket that promises [promised] bytes, sends [sent] of them and cuts the connection
Future<ServerSocket> _cuttingServer(int promised, int sent) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    var answered = false;
    socket.listen((_) async {
      if (answered) {
        return;
      }
      answered = true;
      socket.add('HTTP/1.1 200 OK\r\ncontent-length: $promised\r\ncontent-type: video/mp4\r\n\r\n'.codeUnits);
      socket.add(Uint8List(sent));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      socket.destroy();
    }, onError: (Object _) {});
  });
  return server;
}

/// A port where nothing listens
Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late _Server server;
  late IsolateHttpClient client;

  setUp(() async {
    server = await _Server.start();
    client = IsolateHttpClient(HttpClient.new);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  test('a GET comes back with its status, headers and body, the body in few large batches', () async {
    server.on('/film', (request) async {
      final response = request.response
        ..headers.set('x-test', 'yes')
        ..contentLength = 8 * _mib;
      // In pieces of 16 KiB, the size of the reads of a TLS body
      for (var at = 0; at < 8 * _mib; at += 16 * _kib) {
        response.add(_bytes(at, 16 * _kib));
      }
      await response.close();
    });
    final before = IsolateHttpClient.batchesReceived;

    final response = await client.send(http.Request('GET', server.url('/film')));
    final body = await response.stream.toBytes();

    expect(response.statusCode, 200);
    expect(response.headers['x-test'], 'yes');
    expect(response.contentLength, 8 * _mib);
    expect((response as http.BaseResponseWithUrl).url, server.url('/film'));
    expect(body, _bytes(0, 8 * _mib));
    final batches = IsolateHttpClient.batchesReceived - before;
    // 512 pieces of 16 KiB: the isolate of the app sees at most one message per 64 KiB
    expect(batches, lessThanOrEqualTo(128), reason: '$batches batches for 8 MiB');
  });

  test('a request with a body sends it, and an error status comes back as it is', () async {
    server.on('/echo', (request) async {
      final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      request.response
        ..statusCode = 418
        ..add(body);
      await request.response.close();
    });

    final response = await client.post(server.url('/echo'), body: 'hello');

    expect(response.statusCode, 418);
    expect(response.body, 'hello');
  });

  test('a reader that does not read holds the transfer back, and its cancel ends it', () async {
    final streamer = await _Streamer.start(256 * _mib);
    addTearDown(streamer.close);

    final response = await client.send(http.Request('GET', streamer.url));
    final reader = StreamIterator(response.stream);
    expect(await reader.moveNext(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final held = streamer.flushed;
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // The window of the worker and the buffers of the sockets, not the 256 MiB
    expect(held, lessThan(48 * _mib), reason: '${held ~/ _mib} MiB sent to a reader that read one batch');
    expect(streamer.flushed - held, lessThanOrEqualTo(2 * _mib), reason: 'the transfer stopped');

    await reader.cancel();
    await streamer.clientLeft.future.timeout(const Duration(seconds: 5));
  });

  test('a body read as it comes is all there, its batches taken one after the other', () async {
    final streamer = await _Streamer.start(64 * _mib, piece: 64 * _kib);
    addTearDown(streamer.close);

    final response = await client.send(http.Request('GET', streamer.url));
    var length = 0;
    await for (final chunk in response.stream) {
      length += chunk.length;
    }

    expect(length, 64 * _mib);
  });

  test('an abort before the answer fails the request at once', () async {
    server.on('/slow', (request) async {
      await Future<void>.delayed(const Duration(seconds: 5));
      await request.response.close();
    });
    final abort = Completer<void>();
    final watch = Stopwatch()..start();

    final sent = client.send(http.AbortableRequest('GET', server.url('/slow'), abortTrigger: abort.future));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    abort.complete();

    await expectLater(sent, throwsA(isA<http.RequestAbortedException>()));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('an abort in the middle of the body ends it with the error, and the server sees the client leave', () async {
    final streamer = await _Streamer.start(256 * _mib);
    addTearDown(streamer.close);
    final abort = Completer<void>();

    final response = await client.send(http.AbortableRequest('GET', streamer.url, abortTrigger: abort.future));
    final errors = <Object>[];
    final done = Completer<void>();
    var length = 0;
    response.stream.listen(
      (chunk) {
        length += chunk.length;
        if (!abort.isCompleted) {
          abort.complete();
        }
      },
      onError: errors.add,
      onDone: done.complete,
    );

    await done.future.timeout(const Duration(seconds: 5));
    expect(errors.single, isA<http.RequestAbortedException>());
    expect(length, lessThan(256 * _mib));
    await streamer.clientLeft.future.timeout(const Duration(seconds: 5));
  });

  test('a server that cuts the body short is an error of the body, after the bytes that came', () async {
    final cutting = await _cuttingServer(4 * _mib, 300 * _kib);
    addTearDown(cutting.close);

    final response = await client.send(http.Request('GET', Uri.parse('http://127.0.0.1:${cutting.port}/film')));
    var length = 0;
    Object? error;
    try {
      await for (final chunk in response.stream) {
        length += chunk.length;
      }
    } catch (caught) {
      error = caught;
    }

    expect(error, isA<http.ClientException>());
    expect(length, 300 * _kib);
  });

  test('a refused connection fails the request as IOClient does', () async {
    final port = await _deadPort();

    await expectLater(
      client.send(http.Request('GET', Uri.parse('http://127.0.0.1:$port/'))),
      throwsA(allOf(isA<http.ClientException>(), isA<SocketException>())),
    );
  });

  test('a closed client refuses its requests, while another client still sends', () async {
    server.on('/ok', (request) => request.response.close());
    final other = IsolateHttpClient(HttpClient.new);
    addTearDown(other.close);
    client.close();

    await expectLater(client.get(server.url('/ok')), throwsA(isA<http.ClientException>()));
    expect((await other.get(server.url('/ok'))).statusCode, 200);
  });

  test('a body left in the middle frees its client for the next request', () async {
    final streamer = await _Streamer.start(64 * _mib);
    addTearDown(streamer.close);
    server.on('/ok', (request) => request.response.close());

    final response = await client.send(http.Request('GET', streamer.url));
    await response.stream.first;

    expect((await client.get(server.url('/ok'))).statusCode, 200);
    await streamer.clientLeft.future.timeout(const Duration(seconds: 5));
  });

  group('the ranges of HttpRangeReader through it', () {
    late HttpRangeReader reader;
    const size = 3 * _mib + 123;

    setUp(() {
      server.on('/part', (request) => server.ranges(request, size));
      reader = HttpRangeReader(
        send: (method, uri, {headers = const {}, abort}) async {
          final request = http.AbortableRequest(method, uri, abortTrigger: abort)..headers.addAll(headers);
          return (await client.send(request), uri);
        },
        fail: (response, key) async {
          await discardHttpBody(response);
          throw NetworkFileSystemException('Status ${response.statusCode} for $key');
        },
      );
    });

    tearDown(() => reader.close());

    test('reads the ranges asked, clamped at the end, none past it', () async {
      final url = server.url('/part');
      expect(await reader.read(url, 'part', 0, 4 * _kib), _bytes(0, 4 * _kib));
      expect(await reader.read(url, 'part', 2 * _mib, _mib), _bytes(2 * _mib, _mib));
      expect(await reader.read(url, 'part', size - 100, 4 * _kib), _bytes(size - 100, 100));
      expect(await reader.read(url, 'part', size, 10), isEmpty);
    });

    test('a read stopped while it waits ends at once with NetworkReadAborted', () async {
      server.on('/part', (request) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        await server.ranges(request, size);
      });
      final abort = Completer<void>();
      final watch = Stopwatch()..start();

      final read = reader.read(server.url('/part'), 'part', 0, _mib, abort: abort.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      abort.complete();

      await expectLater(read, throwsA(isA<NetworkReadAborted>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
