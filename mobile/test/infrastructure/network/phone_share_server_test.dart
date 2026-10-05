import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/infrastructure/network/lite_xml.dart';
import 'package:immich_mobile/infrastructure/network/phone_share_server.dart';
import 'package:immich_mobile/infrastructure/network/webdav_file_system.dart';

import '../../domain/services/phone_share/phone_gallery_fakes.dart';

const _user = 'phone4821';
const _password = 'k7m3x9p2';

// The sizes of the test files: the video spans several chunks of the server
const _photoSize = 70000;
const _videoSize = 2 * PhoneShareServer.chunkSize + 12345;

// More than the sockets of the loopback hold: a client that does not read it keeps the server waiting
const _bigSize = 24 * 1024 * 1024;

class _Answer {
  _Answer(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final Uint8List body;

  String get text => utf8.decode(body, allowMalformed: true);

  /// The hrefs of a multistatus answer, in order
  List<String> get hrefs => [for (final href in parseLiteXml(text).descendantsNamed('href')) href.text];

  /// The display names of a multistatus answer, in order
  List<String> get names => [for (final name in parseLiteXml(text).descendantsNamed('displayname')) name.text];
}

void main() {
  late Directory temp;
  late FakePhoneGallery gallery;
  late FakePhoneShareFiles files;
  late DateTime now;
  late PhoneShareServer server;
  late int port;
  late HttpClient client;
  late List<int> photoBytes;
  late List<int> videoBytes;

  String basic(String user, String password) => 'Basic ${base64.encode(utf8.encode('$user:$password'))}';

  Future<_Answer> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? authorization,
    bool anonymous = false,
    List<int>? body,
    String host = '127.0.0.1',
  }) async {
    final request = await client.openUrl(method, Uri.parse('http://$host:$port$path'));
    if (!anonymous) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization ?? basic(_user, _password));
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return _Answer(response.statusCode, response.headers, builder.takeBytes());
  }

  Future<void> startServer({
    bool Function(InternetAddress)? isAllowedClient,
    Future<List<String>> Function()? servedAddresses,
    Duration bodyWaitTimeout = PhoneShareServer.defaultBodyWaitTimeout,
    Duration stallTimeout = PhoneShareServer.defaultStallTimeout,
  }) async {
    server = PhoneShareServer(
      tree: PhoneGalleryTree(source: gallery, files: files, panoramaIds: () => {'v1'}, clock: () => now),
      files: files,
      username: _user,
      password: _password,
      isAllowedClient: isAllowedClient,
      servedAddresses: servedAddresses,
      preferredPort: 0,
      clock: () => now,
      bodyWaitTimeout: bodyWaitTimeout,
      stallTimeout: stallTimeout,
    );
    port = await server.start();
  }

  /// [action] again until [done] holds of its result, for ten seconds at most: for what the server does on its side
  /// of a socket, which the client does not see
  Future<T> eventually<T>(Future<T> Function() action, bool Function(T result) done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (true) {
      final result = await action();
      if (done(result) || DateTime.now().isAfter(deadline)) {
        return result;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A PROPFIND whose body is sent in part: the server waits for the rest of it, before it checks the credentials
  Future<HttpClientRequest> startSlow({String? authorization}) async {
    final request = await client.openUrl('PROPFIND', Uri.parse('http://127.0.0.1:$port/'));
    request.headers.set(HttpHeaders.authorizationHeader, authorization ?? basic(_user, _password));
    request.contentLength = 2;
    request.add([0x20]);
    await request.flush();
    // An aborted request ends with an error nobody waits for
    unawaited(request.done.then<void>((_) {}, onError: (Object _) {}));
    return request;
  }

  /// Sends the rest of the body of [request]; gives the status
  Future<int> finishSlow(HttpClientRequest request) async {
    request.add([0x20]);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  /// A video of [_bigSize] bytes in the Camera album, for a server started after; gives its path
  String addBigVideo() {
    gallery.add(
      galleryAsset('big', 'BIG.mp4', type: AssetType.video, createdAt: DateTime(2026, 9, 6, 10)),
      albums: ['a1'],
    );
    files.add('big', File('${temp.path}/big.mp4')..writeAsBytesSync(Uint8List(_bigSize)), mimeType: 'video/mp4');
    return '/Albums/Camera/BIG.mp4';
  }

  /// A GET of [path] whose body is never read: once its headers came, the server holds a body slot for it
  Future<HttpClientResponse> getWithoutReading(HttpClient stalled, String path) async {
    final request = await stalled.openUrl('GET', Uri.parse('http://127.0.0.1:$port$path'));
    request.headers.set(HttpHeaders.authorizationHeader, basic(_user, _password));
    final response = await request.close();
    expect(response.statusCode, 200);
    return response;
  }

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('phone_share_server_test');
    gallery = FakePhoneGallery();
    files = FakePhoneShareFiles();
    now = DateTime.utc(2026, 10, 5, 8);
    client = HttpClient();

    photoBytes = patternBytes(_photoSize);
    videoBytes = patternBytes(_videoSize, seed: 7);
    gallery.albumList.addAll([galleryAlbum('a1', 'Camera'), galleryAlbum('a2', 'Été à la plage')]);
    gallery.add(galleryAsset('p1', 'IMG_0001.jpg', createdAt: DateTime(2026, 9, 4, 10)), albums: ['a1']);
    gallery.add(
      galleryAsset('v1', 'VID été 2026.mp4', type: AssetType.video, createdAt: DateTime(2026, 9, 5, 10)),
      albums: ['a1', 'a2'],
    );
    files.add('p1', File('${temp.path}/p1.jpg')..writeAsBytesSync(photoBytes), mimeType: 'image/jpeg');
    files.add(
      'v1',
      File('${temp.path}/v1.mp4')..writeAsBytesSync(videoBytes),
      mimeType: 'video/mp4',
      fileName: 'VID été 2026.mp4',
    );
    await startServer();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    temp.deleteSync(recursive: true);
  });

  group('authentication', () {
    test('OPTIONS tells a read-only WebDAV server', () async {
      final answer = await send('OPTIONS', '/');

      expect(answer.status, 200);
      expect(answer.headers.value('dav'), '1');
      expect(answer.headers.value('allow'), 'OPTIONS, PROPFIND, GET, HEAD');
      expect(answer.headers.value('ms-author-via'), 'DAV');
      expect(answer.headers.value('server'), 'Immuch360');
    });

    test('asks for Basic credentials when there are none', () async {
      final answer = await send('PROPFIND', '/', anonymous: true);

      expect(answer.status, 401);
      expect(answer.headers.value('www-authenticate'), 'Basic realm="Immuch360", charset="UTF-8"');
    });

    test('refuses a wrong user name or password, and a header that does not parse', () async {
      expect((await send('PROPFIND', '/', authorization: basic(_user, 'wrongpass'))).status, 401);
      expect((await send('PROPFIND', '/', authorization: basic('PHONE4821', _password))).status, 401);
      expect((await send('PROPFIND', '/', authorization: 'Basic not-base64!')).status, 401);
      expect((await send('PROPFIND', '/', authorization: 'Bearer abc')).status, 401);
      expect((await send('GET', '/Albums/Camera/IMG_0001.jpg', authorization: basic(_user, ''))).status, 401);
    });

    test('accepts the password with spaces and in upper case', () async {
      expect((await send('PROPFIND', '/', authorization: basic(_user, 'K7M3 X9P2'))).status, 207);
      expect((await send('PROPFIND', '/', authorization: basic(_user, ' k7m3  x9p2 '))).status, 207);
    });

    test('blocks an address for a minute after ten failures', () async {
      for (var i = 0; i < 10; i++) {
        expect((await send('PROPFIND', '/', authorization: basic(_user, 'guess$i'))).status, 401);
      }

      final blocked = await send('PROPFIND', '/');
      expect(blocked.status, 429);
      expect(blocked.headers.value('retry-after'), '60');

      now = now.add(const Duration(seconds: 59));
      expect((await send('PROPFIND', '/')).status, 429);

      now = now.add(const Duration(seconds: 2));
      expect((await send('PROPFIND', '/')).status, 207);
    });

    test('forgets the failures older than a minute', () async {
      for (var i = 0; i < 9; i++) {
        await send('PROPFIND', '/', authorization: basic(_user, 'guess$i'));
      }
      now = now.add(const Duration(seconds: 61));
      expect((await send('PROPFIND', '/', authorization: basic(_user, 'again'))).status, 401);

      expect((await send('PROPFIND', '/')).status, 207);
    });

    test('requests sent at once with wrong credentials get ten tries in all, the others 429', () async {
      final requests = [for (var i = 0; i < 14; i++) await startSlow(authorization: basic(_user, 'guess$i'))];
      // All of them wait for the end of their body when the bodies end together
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final statuses = await Future.wait(requests.map(finishSlow));

      expect(statuses.where((status) => status == 401), hasLength(PhoneShareServer.maxFailures));
      expect(statuses.where((status) => status == 429), hasLength(14 - PhoneShareServer.maxFailures));
    });

    test('refuses a request while 16 others of its address wait for their credentials', () async {
      final waiting = [for (var i = 0; i < PhoneShareServer.maxUnauthenticated; i++) await startSlow()];

      // Answered as usual until the server read the headers of all of them
      final refused = await eventually(() => send('PROPFIND', '/'), (answer) => answer.status != 207);
      expect(refused.status, 429);
      expect(refused.headers.value('retry-after'), '1');
      expect(refused.headers.persistentConnection, isFalse);

      for (final request in waiting) {
        request.abort();
      }
      expect((await eventually(() => send('PROPFIND', '/'), (answer) => answer.status == 207)).status, 207);
    });

    test('a request without credentials is no failure', () async {
      for (var i = 0; i < 12; i++) {
        expect((await send('PROPFIND', '/', anonymous: true)).status, 401);
      }

      expect((await send('PROPFIND', '/')).status, 207);
    });

    test('refuses a client outside the local network and closes its connection', () async {
      await server.stop();
      await startServer(isAllowedClient: (_) => false);

      final answer = await send('PROPFIND', '/');

      expect(answer.status, 403);
      expect(answer.headers.persistentConnection, isFalse);
    });

    test('listens on the loopback and the served addresses only, and follows them', () async {
      // Two more addresses of the machine stand for the Wi-Fi of the phone and its mobile data: the whole 127/8 is
      // the loopback on Linux, not on macOS
      try {
        await (await ServerSocket.bind('127.0.0.2', 0)).close();
      } on SocketException {
        markTestSkipped('127.0.0.2 is not an address of this machine');
        return;
      }
      var served = ['127.0.0.2'];
      await server.stop();
      await startServer(servedAddresses: () async => served);

      expect((await send('OPTIONS', '/', host: '127.0.0.2')).status, 200);
      expect((await send('OPTIONS', '/')).status, 200);
      await expectLater(send('OPTIONS', '/', host: '127.0.0.3'), throwsA(isA<SocketException>()));

      served = ['127.0.0.3'];
      await server.refreshServedAddresses();

      expect((await send('OPTIONS', '/', host: '127.0.0.3')).status, 200);
      client.close(force: true);
      client = HttpClient();
      await expectLater(send('OPTIONS', '/', host: '127.0.0.2'), throwsA(isA<SocketException>()));
    });

    test('isLocalNetworkAddress keeps the loopback, link-local and private addresses only', () {
      bool local(String address) => isLocalNetworkAddress(InternetAddress(address));

      expect(local('127.0.0.1'), isTrue);
      expect(local('192.168.1.20'), isTrue);
      expect(local('192.168.43.5'), isTrue);
      expect(local('10.0.2.2'), isTrue);
      expect(local('172.16.0.1'), isTrue);
      expect(local('172.20.10.2'), isTrue);
      expect(local('169.254.3.4'), isTrue);
      expect(local('::1'), isTrue);
      expect(local('fe80::1'), isTrue);
      expect(local('fd12:3456::1'), isTrue);
      expect(local('::ffff:192.168.1.20'), isTrue);

      expect(local('8.8.8.8'), isFalse);
      expect(local('172.32.0.1'), isFalse);
      expect(local('100.64.0.1'), isFalse);
      expect(local('192.169.1.1'), isFalse);
      expect(local('2001:db8::1'), isFalse);
      expect(local('::ffff:8.8.8.8'), isFalse);
    });

    test('normalizePhoneSharePassword drops the spaces and the case', () {
      expect(normalizePhoneSharePassword('K7m3 x9P2'), 'k7m3x9p2');
      expect(normalizePhoneSharePassword('\tk7m3\nx9p2 '), 'k7m3x9p2');
    });
  });

  group('methods', () {
    for (final method in ['PUT', 'DELETE', 'MKCOL', 'LOCK', 'MOVE', 'COPY', 'PROPPATCH', 'POST']) {
      test('refuses $method with 405', () async {
        final answer = await send(method, '/Albums/Camera/IMG_0001.jpg', body: utf8.encode('<x/>'));

        expect(answer.status, 405);
        expect(answer.headers.value('allow'), 'OPTIONS, PROPFIND, GET, HEAD');
        expect(files.files['p1']!.file.readAsBytesSync(), photoBytes);
      });
    }

    test('reads past a large request body without keeping the connection', () async {
      final answer = await send('PUT', '/Albums/Camera/new.jpg', body: List.filled(3 * 1024 * 1024, 1));

      expect(answer.status, 405);
      expect(File('${temp.path}/new.jpg').existsSync(), isFalse);
      expect((await send('PROPFIND', '/')).status, 207);
    });
  });

  group('PROPFIND', () {
    test('depth 0 on the root answers the root only', () async {
      final answer = await send('PROPFIND', '/', headers: {'depth': '0'});

      expect(answer.status, 207);
      expect(answer.headers.contentType?.mimeType, 'application/xml');
      expect(answer.headers.contentType?.charset, 'utf-8');
      expect(answer.hrefs, ['/']);
      expect(answer.text, contains('<D:collection/>'));
    });

    test('depth 1 on the root lists the three folders, the folder itself first', () async {
      final answer = await send('PROPFIND', '/', headers: {'depth': '1'});

      expect(answer.hrefs, ['/', '/Albums/', '/By%20month/', '/360/']);
      expect(answer.names, ['', 'Albums', 'By month', '360']);
    });

    test('lists the albums with encoded hrefs', () async {
      final answer = await send('PROPFIND', '/Albums', headers: {'depth': '1'});

      expect(answer.hrefs, ['/Albums/', '/Albums/Camera/', '/Albums/%C3%89t%C3%A9%20%C3%A0%20la%20plage/']);
      expect(answer.names, ['Albums', 'Camera', 'Été à la plage']);
    });

    test('lists an album with the size, type, date and tag of each file', () async {
      final answer = await send('PROPFIND', '/Albums/Camera/', headers: {'depth': '1'});

      expect(answer.status, 207);
      expect(answer.hrefs, [
        '/Albums/Camera/',
        '/Albums/Camera/VID%20%C3%A9t%C3%A9%202026.mp4',
        '/Albums/Camera/IMG_0001.jpg',
      ]);
      final resources = parseWebDavMultistatus(answer.text)!;
      final video = resources[1];
      expect(video.isCollection, isFalse);
      expect(video.href, '/Albums/Camera/VID été 2026.mp4');
      expect(video.contentLength, _videoSize);
      expect(video.contentType, 'video/mp4');
      expect(video.lastModified, DateTime.fromMillisecondsSinceEpoch(1757000000000, isUtc: true));
      expect(answer.text, contains('<D:getetag>&quot;v1-1757000000000&quot;</D:getetag>'));
      expect(resources[0].isCollection, isTrue);
    });

    test('lists an album with an accented name asked with an encoded path', () async {
      final answer = await send('PROPFIND', '/Albums/%C3%89t%C3%A9%20%C3%A0%20la%20plage', headers: {'depth': '1'});

      expect(answer.status, 207);
      expect(answer.names, ['Été à la plage', 'VID été 2026.mp4']);
    });

    test('depth 0 and 1 on a file answer the file only', () async {
      for (final depth in ['0', '1']) {
        final answer = await send('PROPFIND', '/Albums/Camera/IMG_0001.jpg', headers: {'depth': depth});

        expect(answer.status, 207);
        expect(answer.hrefs, ['/Albums/Camera/IMG_0001.jpg']);
        expect(answer.text, contains('<D:getcontentlength>$_photoSize</D:getcontentlength>'));
      }
    });

    test('a depth of infinity, or none, is answered as 1', () async {
      for (final headers in [
        {'depth': 'infinity'},
        <String, String>{},
      ]) {
        final answer = await send('PROPFIND', '/Albums', headers: headers);

        expect(answer.status, 207);
        expect(answer.hrefs, hasLength(3));
      }
    });

    test('an unknown path, a path out of the tree or an encoded slash is not found', () async {
      expect((await send('PROPFIND', '/Albums/Nope')).status, 404);
      expect((await send('GET', '/Albums/Camera/%2E%2E/%2E%2E/%2E%2E/etc/passwd')).status, 404);
      expect((await send('GET', '/etc/passwd')).status, 404);
      expect((await send('PROPFIND', '/Albums%2FCamera')).status, 404);
      expect((await send('GET', '/Albums/Camera%2FIMG_0001.jpg')).status, 404);
    });

    test('leaves out the size the platform does not tell, and tells it once the file was opened', () async {
      files.toldSize = 0;

      final before = await send('PROPFIND', '/Albums/Camera/IMG_0001.jpg', headers: {'depth': '0'});
      expect(before.text, isNot(contains('getcontentlength')));

      expect((await send('HEAD', '/Albums/Camera/IMG_0001.jpg')).status, 200);
      now = now.add(const Duration(seconds: 31));

      final after = await send('PROPFIND', '/Albums/Camera/IMG_0001.jpg', headers: {'depth': '0'});
      expect(after.text, contains('<D:getcontentlength>$_photoSize</D:getcontentlength>'));
    });
  });

  group('GET and HEAD', () {
    const photo = '/Albums/Camera/IMG_0001.jpg';

    test('GET sends the whole file with its headers', () async {
      final answer = await send('GET', photo);

      expect(answer.status, 200);
      expect(answer.body, photoBytes);
      expect(answer.headers.contentType?.mimeType, 'image/jpeg');
      expect(answer.headers.contentLength, _photoSize);
      expect(answer.headers.value('accept-ranges'), 'bytes');
      expect(answer.headers.value('etag'), '"p1-1757000000000"');
      expect(
        answer.headers.value('last-modified'),
        HttpDate.format(DateTime.fromMillisecondsSinceEpoch(1757000000000, isUtc: true)),
      );
    });

    test('GET of a video bigger than one chunk', () async {
      final answer = await send('GET', '/360/VID%20%C3%A9t%C3%A9%202026.mp4');

      expect(answer.status, 200);
      expect(answer.body.length, _videoSize);
      expect(answer.body, videoBytes);
    });

    test('GET with a range sends that part', () async {
      final answer = await send('GET', photo, headers: {'range': 'bytes=1000-1999'});

      expect(answer.status, 206);
      expect(answer.headers.value('content-range'), 'bytes 1000-1999/$_photoSize');
      expect(answer.body, photoBytes.sublist(1000, 2000));
    });

    test('GET with an open range or a suffix range', () async {
      final open = await send('GET', photo, headers: {'range': 'bytes=69000-'});
      final suffix = await send('GET', photo, headers: {'range': 'bytes=-500'});

      expect(open.status, 206);
      expect(open.body, photoBytes.sublist(69000));
      expect(suffix.status, 206);
      expect(suffix.headers.value('content-range'), 'bytes ${_photoSize - 500}-${_photoSize - 1}/$_photoSize');
      expect(suffix.body, photoBytes.sublist(_photoSize - 500));
    });

    test('a range past the end is not satisfiable', () async {
      final answer = await send('GET', photo, headers: {'range': 'bytes=$_photoSize-'});

      expect(answer.status, 416);
      expect(answer.headers.value('content-range'), 'bytes */$_photoSize');
    });

    test('HEAD sends the headers without the body', () async {
      final answer = await send('HEAD', photo, headers: {'range': 'bytes=0-99'});

      expect(answer.status, 206);
      expect(answer.body, isEmpty);
      expect(answer.headers.contentLength, 100);
      expect(answer.headers.value('content-range'), 'bytes 0-99/$_photoSize');
    });

    test('If-Range sends the part when the file did not change, the whole file otherwise', () async {
      final etag = (await send('HEAD', photo)).headers.value('etag')!;
      final lastModified = (await send('HEAD', photo)).headers.value('last-modified')!;

      final sameTag = await send('GET', photo, headers: {'range': 'bytes=0-9', 'if-range': etag});
      final sameDate = await send('GET', photo, headers: {'range': 'bytes=0-9', 'if-range': lastModified});
      final changed = await send('GET', photo, headers: {'range': 'bytes=0-9', 'if-range': '"other"'});

      expect(sameTag.status, 206);
      expect(sameTag.body, photoBytes.sublist(0, 10));
      expect(sameDate.status, 206);
      expect(changed.status, 200);
      expect(changed.body, photoBytes);
    });

    test('a folder has no body', () async {
      expect((await send('GET', '/Albums/Camera/')).status, 404);
      expect((await send('HEAD', '/')).status, 404);
    });

    test('a file gone from the device since the listing is not found', () async {
      expect((await send('PROPFIND', '/Albums/Camera')).status, 207);
      files.files['p1']!.file.deleteSync();

      expect((await send('GET', photo)).status, 404);
      expect((await send('HEAD', photo)).status, 404);
    });

    test('asks the platform once for the place of a file read many times', () async {
      for (var i = 0; i < 5; i++) {
        await send('GET', photo, headers: {'range': 'bytes=${i * 100}-${i * 100 + 99}'});
      }

      expect(files.openCalls, ['p1']);
    });

    test('a body waits its turn for a while only, then the answer is 503', () async {
      final big = addBigVideo();
      await server.stop();
      await startServer(bodyWaitTimeout: const Duration(milliseconds: 200));
      final stalled = HttpClient();
      addTearDown(() => stalled.close(force: true));
      for (var i = 0; i < PhoneShareServer.maxBodies; i++) {
        await getWithoutReading(stalled, big);
      }

      final busy = await send('GET', photo);

      expect(busy.status, 503);
      expect(busy.headers.value('retry-after'), '${PhoneShareServer.busyRetryAfter.inSeconds}');

      // The clients that held the turns leave: the turns are free again
      stalled.close(force: true);
      expect((await eventually(() => send('GET', photo), (answer) => answer.status == 200)).body, photoBytes);
    });

    test('a client that stops reading is cut after the stall timeout, and its turn goes to the next body', () async {
      final big = addBigVideo();
      await server.stop();
      await startServer(stallTimeout: const Duration(milliseconds: 300));
      final stalled = HttpClient();
      addTearDown(() => stalled.close(force: true));
      final responses = [for (var i = 0; i < PhoneShareServer.maxBodies; i++) await getWithoutReading(stalled, big)];

      final stopwatch = Stopwatch()..start();
      final next = await send('GET', photo);

      expect(next.status, 200);
      expect(next.body, photoBytes);
      expect(stopwatch.elapsed, lessThan(PhoneShareServer.defaultBodyWaitTimeout));
      var received = 0;
      // What the sockets held arrives, then the end of a connection cut before the end of the body
      await expectLater(
        responses.first.forEach((chunk) => received += chunk.length),
        throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
      );
      expect(received, lessThan(_bigSize));
    });

    test('sends at most 8 bodies at once and serves the others after', () async {
      final answers = await Future.wait([
        for (var i = 0; i < 12; i++) send('GET', '/Albums/Camera/VID%20%C3%A9t%C3%A9%202026.mp4'),
      ]);

      for (final answer in answers) {
        expect(answer.status, 200);
        expect(answer.body.length, _videoSize);
      }
    });
  });

  group('activity', () {
    test('tells the requests of the authenticated clients, without their credentials', () async {
      final seen = <PhoneShareActivity>[];
      final subscription = server.activity.listen(seen.add);
      addTearDown(subscription.cancel);

      await send('PROPFIND', '/', anonymous: true);
      await send('PROPFIND', '/Albums', headers: {'depth': '1'});
      await send('GET', '/Albums/Camera/IMG_0001.jpg');
      await pumpEventQueue();

      expect(
        [for (final activity in seen) '${activity.client} ${activity.method} ${activity.path}'],
        ['127.0.0.1 PROPFIND /Albums', '127.0.0.1 GET /Albums/Camera/IMG_0001.jpg'],
      );
      expect(server.lastRequestAt, now);
    });

    test('stop closes the server, start listens again', () async {
      await server.stop();
      expect(server.port, isNull);
      await expectLater(send('OPTIONS', '/'), throwsA(isA<SocketException>()));

      port = await server.start();
      expect((await send('OPTIONS', '/')).status, 200);
    });
  });

  group('end to end with the WebDAV client of the app', () {
    late WebDavFileSystem webDav;

    setUp(() async {
      webDav = await WebDavFileSystem.open(
        NetworkSource(
          id: 'phone',
          type: NetworkSourceType.webdav,
          name: 'Immuch360 on Pixel',
          host: '127.0.0.1',
          port: port,
          share: '/',
          username: _user,
          discoveryId: '0123456789abcdef',
        ),
        'K7M3 X9P2',
      );
    });

    tearDown(() => webDav.close());

    test('lists, stats and reads the files of the phone', () async {
      final root = await webDav.list('/');
      expect([for (final entry in root) entry.path], ['/360', '/Albums', '/By month']);
      expect(root.every((entry) => entry.isDirectory), isTrue);

      final albums = await webDav.list('/Albums');
      expect([for (final entry in albums) entry.path], ['/Albums/Camera', '/Albums/Été à la plage']);

      final camera = await webDav.list('/Albums/Camera');
      expect([for (final entry in camera) entry.name], ['IMG_0001.jpg', 'VID été 2026.mp4']);
      expect(camera.first.size, _photoSize);
      expect(camera.last.isVideo, isTrue);

      final months = await webDav.list('/By month');
      expect([for (final entry in months) entry.name], ['2026-09']);
      expect(
        [for (final entry in await webDav.list('/By month/2026-09')) entry.name],
        ['IMG_0001.jpg', 'VID été 2026.mp4'],
      );

      final stat = await webDav.stat('/Albums/Été à la plage/VID été 2026.mp4');
      expect(stat.isDirectory, isFalse);
      expect(stat.size, _videoSize);
      expect(stat.guessedMimeType, 'video/mp4');

      expect(await webDav.readRange('/Albums/Camera/IMG_0001.jpg', 5000, 3000), photoBytes.sublist(5000, 8000));
      expect(
        await webDav.readRange('/360/VID été 2026.mp4', PhoneShareServer.chunkSize - 10, 20),
        videoBytes.sublist(PhoneShareServer.chunkSize - 10, PhoneShareServer.chunkSize + 10),
      );
      expect(
        await webDav.readRange('/Albums/Camera/IMG_0001.jpg', _photoSize - 4, 100),
        photoBytes.sublist(_photoSize - 4),
      );
      expect(webDav.supportsRanges, isTrue);
    });

    test('a wrong password is an authentication failure', () async {
      await expectLater(
        WebDavFileSystem.open(
          NetworkSource(
            id: 'phone',
            type: NetworkSourceType.webdav,
            name: 'Phone',
            host: '127.0.0.1',
            port: port,
            username: _user,
          ),
          'wrong',
        ),
        throwsA(isA<Object>().having((error) => '$error', 'error', contains('refused the user name or the password'))),
      );
    });

    test('the media bridge of a headset streams a video of the phone with ranges', () async {
      final bridge = LocalMediaBridge();
      await bridge.start();
      addTearDown(bridge.stop);
      bridge.register(webDav);
      final url = bridge.urlFor('phone', '/Albums/Camera/VID été 2026.mp4');

      final whole = await client.getUrl(url).then((request) => request.close());
      final wholeBytes = await whole.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));
      expect(whole.statusCode, 200);
      expect(wholeBytes.takeBytes(), videoBytes);

      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=1048000-1049999');
      final part = await request.close();
      final partBytes = await part.fold<BytesBuilder>(BytesBuilder(), (builder, chunk) => builder..add(chunk));
      expect(part.statusCode, 206);
      expect(part.headers.value('content-range'), 'bytes 1048000-1049999/$_videoSize');
      expect(partBytes.takeBytes(), videoBytes.sublist(1048000, 1050000));
    });
  });
}
