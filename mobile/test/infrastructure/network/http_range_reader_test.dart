// The range reads shared by the WebDAV and DLNA clients, against a fake server: Range honoured, Range ignored (the
// transfer kept open for the next read), past the end, errors, and the transfers stopped when they are not needed.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/http_range_reader.dart';

typedef _Request = ({String method, Uri uri, Map<String, String> headers});

/// Answers GET requests for one file, in chunks, with or without honouring the Range header
class _FakeServer {
  _FakeServer(int size, {this.honourRanges = true, this.chunkSize = 1000})
    : bytes = Uint8List.fromList(List.generate(size, (i) => i % 251));

  final Uint8List bytes;
  final int chunkSize;
  bool honourRanges;

  /// Answers every request with this status and an empty body when set
  int? status;

  /// Start of the part a 206 answer says it holds, when the server does not start at the offset asked for
  int? forcedStart;

  final List<_Request> requests = [];

  /// Bodies stopped before their end
  int cancelled = 0;

  /// Bytes of bodies sent so far
  int sent = 0;

  static final uri = Uri.parse('http://192.168.1.10:8200/MediaItems/22.mp4');

  Future<(http.StreamedResponse, Uri)> send(String method, Uri uri, {Map<String, String> headers = const {}}) async {
    requests.add((method: method, uri: uri, headers: headers));
    final forced = status;
    if (forced != null) {
      return (http.StreamedResponse(_body(Uint8List(0)), forced, contentLength: 0), uri);
    }
    final range = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(headers['range'] ?? '');
    if (!honourRanges || range == null) {
      return (http.StreamedResponse(_body(bytes), 200, contentLength: bytes.length), uri);
    }
    final start = forcedStart ?? int.parse(range.group(1)!);
    if (start >= bytes.length) {
      return (
        http.StreamedResponse(_body(Uint8List(0)), 416, headers: {'content-range': 'bytes */${bytes.length}'}),
        uri,
      );
    }
    // At least one byte, for a part that begins after the one asked for
    final end = min(max(int.parse(range.group(2)!) + 1, start + 1), bytes.length);
    return (
      http.StreamedResponse(
        _body(Uint8List.sublistView(bytes, start, end)),
        206,
        contentLength: end - start,
        headers: {'content-range': 'bytes $start-${end - 1}/${bytes.length}'},
      ),
      uri,
    );
  }

  Stream<List<int>> _body(Uint8List data) async* {
    var complete = false;
    try {
      for (var i = 0; i < data.length; i += chunkSize) {
        final chunk = Uint8List.sublistView(data, i, min(i + chunkSize, data.length));
        sent += chunk.length;
        yield chunk;
      }
      complete = true;
    } finally {
      if (!complete) {
        cancelled++;
      }
    }
  }

  Future<Never> fail(http.StreamedResponse response, String key) async {
    await discardHttpBody(response);
    throw NetworkFileSystemException('$key: HTTP ${response.statusCode}', isNotFound: response.statusCode == 404);
  }

  HttpRangeReader reader({bool Function()? isClosed}) => HttpRangeReader(send: send, fail: fail, isClosed: isClosed);

  Uint8List part(int offset, int length) => Uint8List.sublistView(bytes, offset, min(offset + length, bytes.length));
}

void main() {
  test('reads a range with a Range request, along with the headers given', () async {
    final server = _FakeServer(10000);
    final reader = server.reader();

    expect(reader.supportsRanges, isNull);
    final bytes = await reader.read(
      _FakeServer.uri,
      '64\$1',
      2500,
      3000,
      headers: {'transferMode.dlna.org': 'Streaming', 'range': 'ignored'},
    );

    expect(bytes, server.part(2500, 3000));
    expect(reader.supportsRanges, isTrue);
    final request = server.requests.single;
    expect(request.method, 'GET');
    expect(request.uri, _FakeServer.uri);
    expect(request.headers, {
      'transferMode.dlna.org': 'Streaming',
      'range': 'bytes=2500-5499',
      'accept-encoding': 'identity',
    });
    expect(server.cancelled, 0, reason: 'a body read to its end lets its connection serve again');
    await reader.close();
  });

  test('gives fewer bytes at the end of the file, and none past it', () async {
    final server = _FakeServer(10000);
    final reader = server.reader();

    expect(await reader.read(_FakeServer.uri, 'k', 9900, 500), server.part(9900, 100));
    expect(await reader.read(_FakeServer.uri, 'k', 10000, 10), isEmpty);
    expect(await reader.read(_FakeServer.uri, 'k', 0, 0), isEmpty);
    expect(server.requests, hasLength(2), reason: 'nothing asked for an empty read');
    await reader.close();
  });

  test('skips the start of a part that begins before the offset asked for', () async {
    final server = _FakeServer(10000)..forcedStart = 0;
    final reader = server.reader();

    expect(await reader.read(_FakeServer.uri, 'k', 1500, 100), server.part(1500, 100));
    await reader.close();
  });

  test('refuses a part that begins after the offset asked for', () async {
    final server = _FakeServer(10000)..forcedStart = 2000;
    final reader = server.reader();

    await expectLater(
      reader.read(_FakeServer.uri, '/DCIM/a.mp4', 1500, 100),
      throwsA(
        isA<NetworkFileSystemException>().having((e) => e.message, 'message', contains('another part of /DCIM/a.mp4')),
      ),
    );
    await reader.close();
  });

  test('hands an unexpected status to fail, with the key', () async {
    final server = _FakeServer(10000)..status = 404;
    final reader = server.reader();

    await expectLater(
      reader.read(_FakeServer.uri, '64\$1', 0, 100),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
    );
    expect(reader.supportsRanges, isNull);
    await reader.close();
  });

  group('on a server that ignores ranges', () {
    test('remembers it, and reads one after the other share one transfer', () async {
      final server = _FakeServer(100000, honourRanges: false);
      final reader = server.reader();

      expect(await reader.read(_FakeServer.uri, 'k', 0, 2500), server.part(0, 2500));
      expect(reader.supportsRanges, isFalse);
      expect(await reader.read(_FakeServer.uri, 'k', 2500, 1000), server.part(2500, 1000));
      expect(await reader.read(_FakeServer.uri, 'k', 10000, 500), server.part(10000, 500));
      expect(server.requests, hasLength(1));
      expect(server.sent, lessThan(20000), reason: 'the transfer stops once the bytes asked for arrived');

      // Before where the transfer is: from the start again
      expect(await reader.read(_FakeServer.uri, 'k', 100, 100), server.part(100, 100));
      expect(server.requests, hasLength(2));
      // Another key never takes the transfer of this one
      expect(await reader.read(_FakeServer.uri, 'other', 10500, 100), server.part(10500, 100));
      expect(server.requests, hasLength(3));

      await reader.close();
      expect(server.cancelled, 3, reason: 'close stops the transfers kept open');
    });

    test('a file that fits in the bytes asked for does not tell', () async {
      final server = _FakeServer(500, honourRanges: false);
      final reader = server.reader();

      expect(await reader.read(_FakeServer.uri, 'k', 0, 1000), server.part(0, 500));
      expect(reader.supportsRanges, isNull);
      await reader.close();
    });

    test('keeps at most three transfers per key, dropping the oldest', () async {
      final server = _FakeServer(100000, honourRanges: false);
      final reader = server.reader();

      // Each read is before where the transfers kept so far stand, so each one needs a transfer of its own
      for (final offset in [4000, 3000, 2000, 1000]) {
        await reader.read(_FakeServer.uri, 'k', offset, 10);
      }

      expect(server.requests, hasLength(4));
      await pumpEventQueue();
      expect(server.cancelled, 1);
      await reader.close();
      expect(server.cancelled, 4);
    });

    test('stops a transfer kept open when no read comes within openReadTimeout', () {
      fakeAsync((async) {
        final server = _FakeServer(100000, honourRanges: false);
        final reader = server.reader();
        Uint8List? bytes;

        unawaited(reader.read(_FakeServer.uri, 'k', 0, 100).then((value) => bytes = value));
        async.flushMicrotasks();
        expect(bytes, server.part(0, 100));
        expect(server.cancelled, 0);

        async.elapse(HttpRangeReader.openReadTimeout - const Duration(seconds: 1));
        expect(server.cancelled, 0);
        async.elapse(const Duration(seconds: 2));
        expect(server.cancelled, 1);

        // The next read asks again
        unawaited(reader.read(_FakeServer.uri, 'k', 100, 100).then((value) => bytes = value));
        async.flushMicrotasks();
        expect(bytes, server.part(100, 100));
        expect(server.requests, hasLength(2));
        unawaited(reader.close());
        async.flushMicrotasks();
      });
    });

    test('keeps nothing open once the owner says it is closed', () async {
      final server = _FakeServer(100000, honourRanges: false);
      final reader = server.reader(isClosed: () => true);

      expect(await reader.read(_FakeServer.uri, 'k', 0, 100), server.part(0, 100));
      await pumpEventQueue();

      expect(server.cancelled, 1);
    });
  });

  group('discardHttpBody', () {
    test('reads a small body to its end', () async {
      final server = _FakeServer(5000);

      await discardHttpBody(http.StreamedResponse(server._body(server.bytes), 500));

      expect(server.sent, 5000);
      expect(server.cancelled, 0);
    });

    test('stops a large body', () async {
      final server = _FakeServer(1024 * 1024, chunkSize: 8192);

      await discardHttpBody(http.StreamedResponse(server._body(server.bytes), 500));

      expect(server.cancelled, 1);
      expect(server.sent, lessThan(HttpRangeReader.maxDiscardedBody + 3 * 8192));
    });
  });
}
