// RemoteImageApi on the computers against an image server on 127.0.0.1 that answers as the Immich server does
// (Cache-Control of server/src/utils/file.ts, an ETag): the encoded shape of the answer and its malloc buffer, the
// disk cache and its HTTP rules, cancellation and errors. Synthetic bytes only: the API hands the encoded image over
// without decoding it.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/desktop/network/remote_image_cache.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/desktop/platform/desktop_remote_image_api.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';

const _assetCache = 'private, max-age=86400, no-transform, stale-while-revalidate=2592000, stale-if-error=2592000';

class _ImageServer {
  _ImageServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_ImageServer> start() async => _ImageServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final hits = <String, int>{};
  final conditional = <String>[];
  final release = Completer<void>();

  /// What each path answers: body, Cache-Control, ETag; the status for a forced error
  final bodies = <String, List<int>>{};
  final cacheControl = <String, String>{};
  final etags = <String, String>{};
  final failures = <String, int>{};

  String url(String path) => 'http://127.0.0.1:${_server.port}$path';

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    hits[path] = (hits[path] ?? 0) + 1;
    final response = request.response;
    final ifNoneMatch = request.headers.value('if-none-match');
    if (ifNoneMatch != null) {
      conditional.add(path);
    }
    if (path == '/slow') {
      await release.future;
    }
    if (path == '/private' && !(request.headers.value('cookie') ?? '').contains('immich_access_token=SESSION')) {
      response.statusCode = HttpStatus.unauthorized;
    } else if (failures[path] case final status?) {
      response.statusCode = status;
    } else if (bodies[path] case final body?) {
      if (cacheControl[path] case final value?) {
        response.headers.set('cache-control', value);
      }
      final etag = etags[path];
      if (etag != null) {
        response.headers.set('etag', etag);
      }
      if (etag != null && ifNoneMatch == etag) {
        response.statusCode = HttpStatus.notModified;
      } else {
        response.add(body);
      }
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() async {
    if (!release.isCompleted) {
      release.complete();
    }
    await _server.close(force: true);
  }
}

void main() {
  late _ImageServer server;
  late Directory folder;
  late DesktopHttpStack stack;
  late DateTime now;
  var requestId = 0;

  RemoteImageCache makeCache({int maxBytes = RemoteImageCache.defaultMaxBytes}) =>
      RemoteImageCache(folder: () async => Directory('${folder.path}/remote_images'), maxBytes: maxBytes);

  DesktopRemoteImageApi makeApi(RemoteImageCache cache) =>
      DesktopRemoteImageApi(stack: stack, cache: cache, clock: () => now);

  /// The bytes of an answer, freed as the image loader frees them
  List<int>? take(Map<String, int>? answer) {
    if (answer == null) {
      return null;
    }
    expect(answer.keys.toSet(), {'pointer', 'length'});
    final pointer = Pointer<Uint8>.fromAddress(answer['pointer']!);
    final bytes = List<int>.of(pointer.asTypedList(answer['length']!));
    malloc.free(pointer);
    return bytes;
  }

  Future<List<int>?> fetch(DesktopRemoteImageApi api, String path) async =>
      take(await api.requestImage(server.url(path), requestId: requestId++, preferEncoded: false, width: 256));

  List<File> stored() => Directory('${folder.path}/remote_images').existsSync()
      ? Directory(
          '${folder.path}/remote_images',
        ).listSync().whereType<File>().where((f) => f.path.endsWith('.img')).toList()
      : [];

  /// The cache writes after answering; waits until [condition] holds
  Future<void> until(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(condition(), isTrue);
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    now = DateTime.utc(2026, 10, 8, 12);
    folder = await Directory.systemTemp.createTemp('immuch360_images_');
    server = await _ImageServer.start();
    stack = DesktopHttpStack(
      secrets: const SecureStorageRepository(FlutterSecureStorage()),
      trustedCertificates: TrustedCertificates(folder: () async => Directory('${folder.path}/trusted')),
      userAgent: () async => 'immich-unknown/test',
    );
    await stack.init();
    server
      ..bodies['/thumb'] = List.generate(1000, (i) => i % 256)
      ..cacheControl['/thumb'] = _assetCache
      ..etags['/thumb'] = '"v1"';
  });

  tearDown(() async {
    await server.close();
    // The cache writes after answering, and Windows refuses to delete a file still being written: the folder goes
    // once the last write ended, while a file left open for good still fails here
    for (var attempt = 0; ; attempt++) {
      try {
        await folder.delete(recursive: true);
        return;
      } on FileSystemException {
        if (attempt == 50) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  });

  test('the encoded image in a malloc buffer, with the session of the stack', () async {
    await stack.setRequestHeaders(const {}, [server.url('/api')], 'SESSION');
    server
      ..bodies['/private'] = [1, 2, 3, 4]
      ..cacheControl['/private'] = _assetCache;
    final api = makeApi(makeCache());
    expect(await fetch(api, '/private'), [1, 2, 3, 4]);

    await stack.clearToken();
    final other = makeApi(makeCache(maxBytes: 0));
    await expectLater(
      other.requestImage(server.url('/private?again'), requestId: requestId++, preferEncoded: true),
      throwsA(isA<RemoteImageHttpException>().having((e) => e.statusCode, 'status', 401)),
    );
  });

  test('a fresh copy is used without asking the server, the next start included', () async {
    final cache = makeCache();
    final api = makeApi(cache);
    final body = await fetch(api, '/thumb');
    await until(() => stored().length == 1);
    expect(await fetch(api, '/thumb'), body);
    expect(await fetch(makeApi(makeCache()), '/thumb'), body);
    expect(server.hits['/thumb'], 1);
  });

  test('past max-age, within stale-while-revalidate: shown at once, checked in the background with the ETag', () async {
    final api = makeApi(makeCache());
    final body = await fetch(api, '/thumb');
    await until(() => stored().length == 1);

    now = now.add(const Duration(days: 2));
    expect(await fetch(api, '/thumb'), body);
    await until(() => server.conditional.contains('/thumb'));
    // The 304 renewed the copy: fresh again, no more question
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await fetch(api, '/thumb'), body);
    expect(server.hits['/thumb'], 2);
  });

  test('no-cache (the faces): asked at each use, a 304 keeps the stored body', () async {
    server
      ..bodies['/face'] = [9, 9, 9]
      ..cacheControl['/face'] = 'private, no-cache, no-transform'
      ..etags['/face'] = '"f1"';
    final api = makeApi(makeCache());
    expect(await fetch(api, '/face'), [9, 9, 9]);
    await until(() => stored().length == 1);
    expect(await fetch(api, '/face'), [9, 9, 9]);
    expect(server.hits['/face'], 2);
    expect(server.conditional, ['/face']);
  });

  test('a changed image replaces the stored one', () async {
    final api = makeApi(makeCache());
    await fetch(api, '/thumb');
    await until(() => stored().length == 1);

    now = now.add(const Duration(days: 40));
    server
      ..bodies['/thumb'] = [5, 6, 7]
      ..etags['/thumb'] = '"v2"';
    expect(await fetch(api, '/thumb'), [5, 6, 7]);
    await until(() => stored().single.lengthSync() == RemoteImageCache.headerSize + 3);
    expect(await fetch(api, '/thumb'), [5, 6, 7]);
    expect(server.hits['/thumb'], 2);
  });

  test('no-store is never kept, nor an answer with neither a lifetime nor a validator', () async {
    server
      ..bodies['/secret'] = [1]
      ..cacheControl['/secret'] = 'no-store'
      ..bodies['/plain'] = [2];
    final api = makeApi(makeCache());
    await fetch(api, '/secret');
    await fetch(api, '/secret');
    expect(server.hits['/secret'], 2);
    expect(await fetch(api, '/plain'), [2]);
    expect(await fetch(api, '/plain'), [2]);
    expect(server.hits['/plain'], 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stored(), isEmpty);
  });

  test('a failing server leaves the stored copy in use for stale-if-error, a refused or lost image does not', () async {
    server
      ..bodies['/short'] = [3, 1, 4]
      ..cacheControl['/short'] = 'private, max-age=60, stale-if-error=86400'
      ..etags['/short'] = '"s1"';
    final api = makeApi(makeCache());
    await fetch(api, '/short');
    await until(() => stored().length == 1);

    now = now.add(const Duration(minutes: 5));
    server.failures['/short'] = HttpStatus.serviceUnavailable;
    expect(await fetch(api, '/short'), [3, 1, 4]);

    server.failures['/short'] = HttpStatus.notFound;
    await expectLater(
      fetch(api, '/short'),
      throwsA(isA<RemoteImageHttpException>().having((e) => e.statusCode, 'status', 404)),
    );

    // Beyond stale-if-error: the failure shows
    now = now.add(const Duration(days: 2));
    server.failures['/short'] = HttpStatus.serviceUnavailable;
    await expectLater(fetch(api, '/short'), throwsA(isA<RemoteImageHttpException>()));
  });

  test('an image the server does not have is an error, as the native fetchers answer', () async {
    final api = makeApi(makeCache());
    await expectLater(
      fetch(api, '/missing'),
      throwsA(isA<RemoteImageHttpException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('a cancelled request answers null', () async {
    server
      ..bodies['/slow'] = [1, 2]
      ..cacheControl['/slow'] = _assetCache;
    final api = makeApi(makeCache());
    final id = requestId++;
    final answer = api.requestImage(server.url('/slow'), requestId: id, preferEncoded: true);
    await until(() => server.hits['/slow'] == 1);
    await api.cancelRequest(id);
    expect(await answer, isNull);
    // Cancelling an unknown or finished request does nothing
    await api.cancelRequest(id);
  });

  test('clearCache empties the cache and answers the bytes freed', () async {
    server
      ..bodies['/other'] = [1, 2, 3]
      ..cacheControl['/other'] = _assetCache;
    final api = makeApi(makeCache());
    await fetch(api, '/thumb');
    await fetch(api, '/other');
    await until(() => stored().length == 2);
    expect(await api.clearCache(), 2 * RemoteImageCache.headerSize + 1000 + 3);
    expect(stored(), isEmpty);
    await fetch(api, '/thumb');
    expect(server.hits['/thumb'], 2);
    await until(() => stored().length == 1);
  });

  test('above the size limit the least recently used images go first', () async {
    for (final name in ['a', 'b', 'c', 'd']) {
      server
        ..bodies['/$name'] = List.filled(200, 1)
        ..cacheControl['/$name'] = _assetCache;
    }
    // Three images of 712 bytes fit below 90 % of the limit, a fourth goes beyond it; one image may take an eighth
    final cache = makeCache(maxBytes: 2500);
    final api = makeApi(cache);
    await fetch(api, '/a');
    await until(() => stored().length == 1);
    await fetch(api, '/b');
    await until(() => stored().length == 2);
    await fetch(api, '/c');
    await until(() => stored().length == 3);
    // a is used again, so b is now the oldest
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await fetch(api, '/a');
    await fetch(api, '/d');
    Set<String> kept() => stored().map((f) => f.uri.pathSegments.last).toSet();
    await until(() => kept().contains('${cache.keyOf(server.url('/d'))}.img') && kept().length == 3);
    // The count follows the deletion
    await until(() => cache.totalBytes == 3 * (RemoteImageCache.headerSize + 200));
    expect(kept(), isNot(contains('${cache.keyOf(server.url('/b'))}.img')));
    expect(kept(), contains('${cache.keyOf(server.url('/a'))}.img'));
  });

  test('a start counts what earlier runs kept and removes the writes they left unfinished', () async {
    final api = makeApi(makeCache());
    await fetch(api, '/thumb');
    await until(() => stored().length == 1);
    final images = Directory('${folder.path}/remote_images');
    final unfinished = File('${images.path}/${'0' * 64}.1000.tmp')..writeAsBytesSync([1, 2, 3]);

    final next = makeCache();
    // The first use reads the folder
    expect(await next.lookup(next.keyOf(server.url('/thumb'))), isNotNull);
    await until(() => next.totalBytes == RemoteImageCache.headerSize + 1000);
    await until(() => !unfinished.existsSync());
  });

  test('the files hold no address: a shared link key never reaches the disk', () async {
    server
      ..bodies['/shared'] = [1, 2, 3]
      ..cacheControl['/shared'] = _assetCache;
    final cache = makeCache();
    final api = makeApi(cache);
    final url = server.url('/shared?key=SHARED-LINK-KEY');
    take(await api.requestImage(url, requestId: requestId++, preferEncoded: true));
    await until(() => stored().length == 1);
    final file = stored().single;
    expect(file.uri.pathSegments.last, '${cache.keyOf(url)}.img');
    expect(latin1.decode(file.readAsBytesSync()), isNot(contains('SHARED-LINK-KEY')));
  });

  test('an unreadable cache file is a miss, not an error', () async {
    final cache = makeCache();
    final api = makeApi(cache);
    await fetch(api, '/thumb');
    await until(() => stored().length == 1);
    stored().single.writeAsBytesSync([1, 2, 3]);
    expect(await fetch(api, '/thumb'), hasLength(1000));
    expect(server.hits['/thumb'], 2);
    // Written again whole
    await until(() => stored().single.lengthSync() == RemoteImageCache.headerSize + 1000);
  });
}
