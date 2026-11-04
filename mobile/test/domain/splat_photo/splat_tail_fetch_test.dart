// The scene of a splat photo taken out of its file (plan of 3 November 2026, section 5): one GET with a suffix range,
// whatever the server answers (206, 200 with or without its length, 416), the same SPZ; checked on the way, never held
// whole, nothing left behind on a failure or a cancel; kept for the next opening.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_scenes.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_tail_fetch.dart';
import 'package:immich_mobile/domain/services/splat_viewer_files.dart';

import 'splat_photo_fixtures.dart';

/// How the test server answers a range
enum _Mode { range, whole, chunked, refuse, otherRange }

class _Server {
  _Server._(this._server);

  static Future<_Server> start() async => _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  _Mode mode = _Mode.range;
  Uint8List file = Uint8List(0);
  final requests = <String?>[];
  var sent = 0;

  /// Waits a little after each piece of the body, as a slow link
  bool slow = false;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/api/assets/a1/original');

  void listen() {
    _server.listen((request) async {
      final range = request.headers.value('range');
      requests.add(range);
      final response = request.response;
      final suffix = range == null ? null : int.tryParse(RegExp(r'bytes=-(\d+)').firstMatch(range)?.group(1) ?? '');
      Future<void> body(List<int> bytes, {bool chunked = false}) async {
        if (chunked) {
          response.headers.chunkedTransferEncoding = true;
        } else {
          response.contentLength = bytes.length;
        }
        const piece = 4096;
        for (var at = 0; at < bytes.length; at += piece) {
          final part = bytes.sublist(at, math.min(bytes.length, at + piece));
          response.add(part);
          sent += part.length;
          await response.flush();
          if (slow) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }
        await response.close();
      }

      try {
        await _answer(response, range, suffix, body);
      } catch (_) {
        // The client went away: a cancel, a cut
      }
    });
  }

  Future<void> _answer(
    HttpResponse response,
    String? range,
    int? suffix,
    Future<void> Function(List<int> bytes, {bool chunked}) body,
  ) async {
    switch (mode) {
      case _Mode.range when suffix != null:
        response.statusCode = 206;
        final start = file.length - suffix;
        response.headers.set('content-range', 'bytes $start-${file.length - 1}/${file.length}');
        await body(file.sublist(start));
      case _Mode.refuse when range != null:
        response.statusCode = 416;
        await response.close();
      case _Mode.otherRange when range != null:
        response.statusCode = 206;
        response.headers.set('content-range', 'bytes 0-99/${file.length}');
        await body(file.sublist(0, 100));
      case _Mode.chunked:
        await body(file, chunked: true);
      default:
        await body(file);
    }
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  final carrier = splatPhotoFixture('ok_v2.jpg');
  final spz = splatFixture('axes_v2.spz');
  final xmp = SplatPhotoXmp.findIn(carrier)!;
  late Directory dir;
  late _Server server;
  late IOClient client;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('splat_tail_fetch');
    server = await _Server.start()
      ..file = carrier
      ..listen();
    client = IOClient(HttpClient());
  });

  tearDown(() async {
    client.close();
    await server.close();
    await dir.delete(recursive: true);
  });

  SplatTailFromServer fromServer() =>
      SplatTailFromServer(client: client, url: server.url, headers: const {'x-immich-user-token': 'token'});

  List<String> leftovers() => dir.listSync().map((entity) => entity.uri.pathSegments.last).toList()..sort();

  for (final (mode, route) in [
    (_Mode.range, SplatTailRoute.range),
    (_Mode.whole, SplatTailRoute.whole),
    (_Mode.chunked, SplatTailRoute.chunked),
    (_Mode.refuse, SplatTailRoute.whole),
    (_Mode.otherRange, SplatTailRoute.whole),
  ]) {
    test('a server that answers ${mode.name} gives the same SPZ', () async {
      server.mode = mode;
      final out = File('${dir.path}/scene.spz');
      final fetched = await fetchSplatTail(source: fromServer(), xmp: xmp, out: out);

      expect(out.readAsBytesSync(), spz);
      expect(fetched.route, route);
      expect(fetched.head, const SplatHead(format: SplatFormat.spz, formatVersion: 2, gaussians: 686, shDegree: 0));
      expect(leftovers(), ['scene.spz'], reason: 'no .part, no .whole.part');
      expect(server.requests.first, 'bytes=-${spz.length}');
      if (mode == _Mode.range) {
        expect(server.sent, spz.length, reason: 'only the scene travels');
        expect(fetched.received, spz.length);
      } else {
        expect(fetched.received, carrier.length, reason: 'the whole photo once, its head skipped');
      }
    });
  }

  test('the copy on the device gives the same SPZ, nothing over the network', () async {
    final copy = File('${dir.path}/salon_splat.jpg')..writeAsBytesSync(carrier);
    final out = File('${dir.path}/scene.spz');
    final fetched = await fetchSplatTail(source: SplatTailFromFile(copy), xmp: xmp, out: out);
    expect(out.readAsBytesSync(), spz);
    expect(fetched.received, 0);
    expect(server.requests, isEmpty);
  });

  test('a photo smaller than its scene lost it; a damaged tail is refused; nothing is left', () async {
    final out = File('${dir.path}/scene.spz');
    server
      ..mode = _Mode.whole
      ..file = carrier.sublist(0, 800);
    await expectLater(
      fetchSplatTail(source: fromServer(), xmp: xmp, out: out),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.lost)),
    );
    server.file = splatPhotoFixture('bad_sum.jpg');
    await expectLater(
      fetchSplatTail(source: fromServer(), xmp: xmp, out: out),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.damaged)),
    );
    final copy = File('${dir.path}/trailer.jpg')..writeAsBytesSync(splatPhotoFixture('trailer.jpg'));
    await expectLater(
      fetchSplatTail(source: SplatTailFromFile(copy), xmp: xmp, out: out),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.damaged)),
    );
    expect(leftovers(), ['trailer.jpg']);
  });

  for (final mode in [_Mode.range, _Mode.whole]) {
    test('a tail that is no SPZ (${mode.name}) is refused at its first bytes, the rest never comes', () async {
      final big = _bigCarrier();
      final out = File('${dir.path}/scene.spz');
      for (final (what, file) in [
        ('a gallery appended its trailer', Uint8List.fromList([...big.bytes, ...List.filled(1008, 0x41)])),
        ('the photo lost its last byte', Uint8List.sublistView(big.bytes, 0, big.bytes.length - 1)),
      ]) {
        server
          ..mode = mode
          ..file = file
          ..slow = true
          ..sent = 0;
        await expectLater(
          fetchSplatTail(source: fromServer(), xmp: big.xmp, out: out),
          throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.damaged)),
          reason: what,
        );
        // Let the server see the close
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(server.sent, lessThan(big.xmp.splatLength! ~/ 4), reason: '$what: ${server.sent} bytes sent');
        expect(leftovers(), isEmpty, reason: what);
      }
    });
  }

  test('a tail that is no SPZ in the copy on the device is refused at its first piece', () async {
    final big = _bigCarrier();
    final copy = File('${dir.path}/trailer.jpg')..writeAsBytesSync([...big.bytes, ...List.filled(1008, 0x41)]);
    var done = 0;
    await expectLater(
      fetchSplatTail(
        source: SplatTailFromFile(copy),
        xmp: big.xmp,
        out: File('${dir.path}/scene.spz'),
        onProgress: (bytes, _) => done = bytes,
      ),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.damaged)),
    );
    expect(done, 0, reason: 'refused before its first piece is counted, not after the whole scene');
    expect(leftovers(), ['trailer.jpg']);
  });

  test('a server that dies in the middle leaves no .part', () async {
    final big = _bigCarrier();
    // The body stops with an error after 300 KB, as a connection that drops
    final dying = MockClient.streaming((request, _) async {
      final controller = StreamController<List<int>>();
      unawaited(() async {
        for (var at = 0; at < 300000; at += 65536) {
          controller.add(big.bytes.sublist(at, math.min(at + 65536, big.bytes.length)));
          await Future<void>.delayed(Duration.zero);
        }
        controller.addError(http.ClientException('Connection closed while receiving data'));
        await controller.close();
      }());
      return http.StreamedResponse(controller.stream, 200, contentLength: big.bytes.length);
    });
    final out = File('${dir.path}/scene.spz');
    await expectLater(
      fetchSplatTail(
        source: SplatTailFromServer(client: dying, url: server.url),
        xmp: big.xmp,
        out: out,
      ),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.network)),
    );
    expect(leftovers(), isEmpty);
  });

  test('a cancel during the download stops it and leaves no .part', () async {
    final big = _bigCarrier();
    server
      ..mode = _Mode.range
      ..file = big.bytes
      ..slow = true;
    final out = File('${dir.path}/scene.spz');
    final cancel = SplatPrepareCancel();
    await expectLater(
      fetchSplatTail(
        source: fromServer(),
        xmp: big.xmp,
        out: out,
        cancel: cancel,
        onProgress: (done, total) {
          if (done > 100000) {
            cancel.cancel();
          }
        },
      ),
      throwsA(isA<SplatTailFetchException>().having((e) => e.problem, 'problem', SplatTailFetchProblem.cancelled)),
    );
    expect(leftovers(), isEmpty);
    expect(server.sent, lessThan(big.bytes.length));
  });

  group('the scenes kept on this device', () {
    late SplatPhotoScenes scenes;
    late SplatViewerCache cache;

    setUp(() {
      cache = SplatViewerCache(() async => Directory('${dir.path}/cache'));
      scenes = SplatPhotoScenes(cache);
    });

    test('the second opening downloads nothing', () async {
      final first = await scenes.obtain('a1', xmp, sources: [fromServer()]);
      expect(first.fromCache, isFalse);
      expect(server.requests, hasLength(1));
      final second = await scenes.obtain('a1', xmp, sources: [fromServer()]);
      expect(second.fromCache, isTrue);
      expect(second.file.path, first.file.path);
      expect(server.requests, hasLength(1), reason: 'nothing asked of the server');
      expect(first.file.uri.pathSegments.last, 'server-a1-${xmp.splatSha256!.substring(0, 16)}.spz');
    });

    test('the copy on the device first; one that fails gives way to the server', () async {
      final trailer = File('${dir.path}/trailer.jpg')..writeAsBytesSync(splatPhotoFixture('trailer.jpg'));
      final tried = <SplatTailSource>[];
      final scene = await scenes.obtain(
        'a2',
        xmp,
        sources: [SplatTailFromFile(trailer), fromServer()],
        onSource: tried.add,
      );
      expect(tried.map((source) => source.runtimeType), [SplatTailFromFile, SplatTailFromServer]);
      expect(scene.file.readAsBytesSync(), spz);
    });

    test('a kept scene of another length is taken again', () async {
      final first = await scenes.obtain('a3', xmp, sources: [fromServer()]);
      first.file.writeAsBytesSync([1, 2, 3]);
      final again = await scenes.obtain('a3', xmp, sources: [fromServer()]);
      expect(again.fromCache, isFalse);
      expect(again.file.readAsBytesSync(), spz);
    });

    test('the prune keeps the 5 newest scenes within their bytes, apart from the reduced copies', () async {
      final folder = await cache.folder();
      final now = DateTime.now();
      for (var i = 0; i < 7; i++) {
        File('${folder.path}/server-a$i-0123456789abcdef.spz')
          ..writeAsBytesSync(Uint8List(10))
          ..setLastModifiedSync(now.subtract(Duration(minutes: i)));
      }
      for (var i = 0; i < 3; i++) {
        File('${folder.path}/reduced-$i.spz')
          ..writeAsBytesSync(Uint8List(10))
          ..setLastModifiedSync(now.subtract(Duration(days: 3, minutes: i)));
      }
      File('${folder.path}/server-old-0123456789abcdef.spz.part')
        ..writeAsBytesSync(Uint8List(10))
        ..setLastModifiedSync(now.subtract(const Duration(days: 2)));
      await cache.prune();
      final names = folder.listSync().map((entity) => entity.uri.pathSegments.last).toList()..sort();
      expect(names, [
        'reduced-0.spz',
        'reduced-1.spz',
        'reduced-2.spz',
        for (var i = 0; i < 5; i++) 'server-a$i-0123456789abcdef.spz',
      ]);

      final small = SplatViewerCache(() async => folder, serverMaxBytes: 25);
      await small.prune();
      expect(folder.listSync().where((entity) => entity.path.contains('server-')), hasLength(2));
    });
  });
}

/// A carrier of a 2 MB SPZ (axes_v2.spz followed by zeros, a head the probe reads), its packet
({Uint8List bytes, SplatPhotoXmp xmp}) _bigCarrier() {
  final carrier = splatPhotoFixture('ok_v2.jpg');
  final spz = Uint8List(2 << 20)..setAll(0, splatFixture('axes_v2.spz'));
  final head = carrier.sublist(0, carrier.length - 913);
  final xmp = SplatPhotoXmp.findIn(carrier)!;
  final big = SplatPhotoXmp(
    splatVersion: xmp.splatVersion,
    splatGaussians: xmp.splatGaussians,
    splatShDegree: xmp.splatShDegree,
    splatLength: spz.length,
    splatSha256: sha256.convert(spz).toString(),
    splatName: 'big.spz',
  );
  return (bytes: Uint8List.fromList([...head, ...spz]), xmp: big);
}
