// The contract of the desktop HTTP stack, written from the native clients the phones use (HttpClientManager.kt with
// the OkHttp configuration of network.repository.dart, URLSessionManager.swift and NetworkApiImpl.swift), against an
// HTTP server on 127.0.0.1. No other network, no file of the user: the secrets live in flutter_secure_storage's test
// platform and the trusted certificates in a temporary folder.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/network/desktop_http_stack.dart';
import 'package:immich_mobile/desktop/network/trusted_certificates.dart';
import 'package:immich_mobile/desktop/platform/desktop_network_api.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/repositories/secure_storage.repository.dart';
import 'package:web_socket/web_socket.dart';

const _userAgent = 'immich-unknown/9.9.9-test';

/// A server that answers by path and keeps the headers of each request it received
class _Server {
  _Server._(this._server) {
    _server.listen(_handle);
  }

  static Future<_Server> start() async => _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final requests = <({String path, HttpHeaders headers, List<int> body})>[];

  /// Ends the handlers that wait on purpose
  final release = Completer<void>();

  int get port => _server.port;
  String get ip => 'http://127.0.0.1:$port';
  String get name => 'http://localhost:$port';

  HttpHeaders headersOf(String path) => requests.lastWhere((r) => r.path == path).headers;

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/socket') {
      requests.add((path: request.uri.path, headers: request.headers, body: const []));
      final socket = await WebSocketTransformer.upgrade(request, protocolSelector: (protocols) => protocols.first);
      // An echo, closed when the client closes
      socket.listen(socket.add, onDone: () => unawaited(socket.close()));
      return;
    }
    final body = await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
    requests.add((path: request.uri.path, headers: request.headers, body: body));
    final response = request.response;
    switch (request.uri.path) {
      case '/api/auth/login':
        response.headers
          ..add('set-cookie', 'immich_access_token=TOKEN-1; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax')
          ..add('set-cookie', 'immich_auth_type=password; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax')
          ..add('set-cookie', 'immich_is_authenticated=true; Path=/; Max-Age=34560000; SameSite=Lax');
        response.write('{"accessToken":"TOKEN-1"}');
      case '/api/auth/logout':
        for (final name in ['immich_access_token', 'immich_auth_type', 'immich_is_authenticated']) {
          response.headers.add('set-cookie', '$name=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT');
        }
      case '/silent':
        // Takes the body, then never answers
        await release.future;
      case '/stall':
        response
          ..contentLength = 1000
          ..add(List.filled(10, 1));
        await response.flush();
        await release.future;
      case '/big':
        response.add(List.filled(256 * 1024, 7));
      case '/upload':
        response
          ..statusCode = HttpStatus.created
          ..write(jsonEncode({'length': body.length, 'declared': request.contentLength}));
      default:
        response.write('ok');
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
  late _Server server;
  late Directory folder;

  DesktopHttpStack makeStack({Duration? readTimeout, Duration? writeTimeout}) => DesktopHttpStack(
    secrets: const SecureStorageRepository(FlutterSecureStorage()),
    trustedCertificates: TrustedCertificates(folder: () async => Directory('${folder.path}/trusted')),
    userAgent: () async => _userAgent,
    readTimeout: readTimeout ?? const Duration(seconds: 60),
    writeTimeout: writeTimeout ?? const Duration(seconds: 60),
  );

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    folder = await Directory.systemTemp.createTemp('immuch360_http_');
    server = await _Server.start();
  });

  tearDown(() async {
    await server.close();
    await folder.delete(recursive: true);
  });

  test('the settings of the OkHttp configuration and of the native pools', () {
    final stack = DesktopHttpStack();
    expect(stack.connectTimeout, const Duration(seconds: 30));
    expect(stack.readTimeout, const Duration(seconds: 60));
    expect(stack.writeTimeout, const Duration(seconds: 60));
    expect(DesktopHttpStack.maxConnectionsPerHost, 64);
  });

  group('headers', () {
    test(
      'the custom headers go with every request, before any server is known, and a request\'s own header wins',
      () async {
        final stack = makeStack();
        await stack.init();
        await stack.setRequestHeaders({'X-Proxy-Token': 'abc', 'X-Choice': 'custom'}, const [], null);

        // The address the user is typing, as in ApiService.resolveEndpoint before the first sign in
        final response = await stack.client.get(
          Uri.parse('${server.ip}/.well-known/immich'),
          headers: {'X-Choice': 'request'},
        );
        expect(response.statusCode, 200);
        final headers = server.headersOf('/.well-known/immich');
        expect(headers.value('x-proxy-token'), 'abc');
        expect(headers.value('x-choice'), 'request');
        expect(headers.value('user-agent'), _userAgent);
        expect(headers.value('cookie'), isNull);
      },
    );

    test('Basic authentication from the address, decoded as OkHttp does', () async {
      final stack = makeStack();
      await stack.init();
      await stack.client.get(Uri.parse('http://user:p%40ss@127.0.0.1:${server.port}/echo'));
      expect(server.headersOf('/echo').value('authorization'), 'Basic ${base64.encode(utf8.encode('user:p@ss'))}');
      expect(stack.headersFor(Uri.parse('http://user:p%40ss@127.0.0.1/')), {
        'authorization': 'Basic ${base64.encode(utf8.encode('user:p@ss'))}',
      });
    });
  });

  group('the session', () {
    test('the cookies of the sign in come back, also to the other address of the server', () async {
      final stack = makeStack();
      await stack.init();
      await stack.setRequestHeaders(const {}, ['${server.ip}/api', '${server.name}/api'], null);

      await stack.client.post(Uri.parse('${server.ip}/api/auth/login'), body: '{}');
      await stack.client.get(Uri.parse('${server.ip}/api/users/me'));
      expect(server.headersOf('/api/users/me').value('cookie'), contains('immich_access_token=TOKEN-1'));

      await stack.client.get(Uri.parse('${server.name}/api/server/ping'));
      expect(server.headersOf('/api/server/ping').value('cookie'), contains('immich_access_token=TOKEN-1'));

      // What a player, the image fetcher and the transfers get for a request of their own
      expect(stack.headersFor(Uri.parse('${server.name}/api/assets/a/original')), {
        'cookie': allOf(contains('immich_access_token=TOKEN-1'), contains('immich_is_authenticated=true')),
      });
    });

    test('the logout of the server ends the session on every address', () async {
      final stack = makeStack();
      await stack.init();
      await stack.setRequestHeaders(const {}, ['${server.ip}/api', '${server.name}/api'], null);
      await stack.client.post(Uri.parse('${server.ip}/api/auth/login'));
      await stack.client.post(Uri.parse('${server.ip}/api/auth/logout'));
      await stack.client.get(Uri.parse('${server.name}/api/users/me'));
      expect(server.headersOf('/api/users/me').value('cookie'), isNull);
    });

    test('a token handed over with the headers is the session (a sign in migrated from an older version)', () async {
      final stack = makeStack();
      await stack.init();
      await stack.setRequestHeaders({'X-A': 'b'}, ['${server.ip}/api'], 'MIGRATED');
      await stack.client.get(Uri.parse('${server.ip}/api/users/me'));
      expect(server.headersOf('/api/users/me').value('cookie'), contains('immich_access_token=MIGRATED'));
      await stack.clearToken();
      await stack.client.get(Uri.parse('${server.ip}/api/users/me'));
      expect(server.headersOf('/api/users/me').value('cookie'), isNull);
    });

    test('headers, addresses and cookies survive a restart of the app', () async {
      final first = makeStack();
      await first.init();
      await first.setRequestHeaders({'X-Proxy-Token': 'abc'}, ['${server.ip}/api', '${server.name}/api'], null);
      await first.client.post(Uri.parse('${server.ip}/api/auth/login'));

      // Another isolate or the next start: nothing but the saved state
      final next = makeStack();
      await next.init();
      await next.client.get(Uri.parse('${server.name}/api/server/ping'));
      final headers = server.headersOf('/api/server/ping');
      expect(headers.value('x-proxy-token'), 'abc');
      expect(headers.value('cookie'), contains('immich_access_token=TOKEN-1'));
    });

    test('a saved state that cannot be read leaves an empty stack, not a failed start', () async {
      FlutterSecureStorage.setMockInitialValues({
        DesktopHttpStack.sessionKey: '{not json',
        DesktopHttpStack.clientCertificateKey: '{"pkcs12":"AAAA","password":"x"}',
      });
      final stack = makeStack();
      await stack.init();
      expect(stack.customHeaders, isEmpty);
      expect(stack.hasClientCertificate, isFalse);
      expect((await stack.client.get(Uri.parse('${server.ip}/x'))).statusCode, 200);
    });
  });

  group('timeouts', () {
    test('no answer within the read timeout once the body is sent: a ClientException', () async {
      final stack = makeStack(readTimeout: const Duration(milliseconds: 300));
      await stack.init();
      await expectLater(
        stack.client.post(Uri.parse('${server.ip}/silent'), body: 'x'),
        throwsA(isA<http.ClientException>().having((e) => e.message, 'message', 'Read timed out')),
      );
    });

    test('an answer that stops in the middle: a ClientException in the body', () async {
      final stack = makeStack(readTimeout: const Duration(milliseconds: 300));
      await stack.init();
      final response = await stack.client.send(http.Request('GET', Uri.parse('${server.ip}/stall')));
      expect(response.statusCode, 200);
      await expectLater(
        response.stream.toBytes(),
        throwsA(isA<http.ClientException>().having((e) => e.message, 'message', 'Read timed out')),
      );
    });

    test('a reader that pauses longer than the read timeout is not a stalled server', () async {
      final stack = makeStack(readTimeout: const Duration(milliseconds: 200));
      await stack.init();
      final response = await stack.client.send(http.Request('GET', Uri.parse('${server.ip}/big')));
      final received = <int>[];
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = response.stream.listen(
        (chunk) {
          received.addAll(chunk);
          if (received.length == chunk.length) {
            subscription.pause(Future<void>.delayed(const Duration(milliseconds: 600)));
          }
        },
        onError: done.completeError,
        onDone: done.complete,
      );
      await done.future;
      await subscription.cancel();
      expect(received.length, 256 * 1024);
    });

    test('a server that stops reading the body: a ClientException within the write timeout', () async {
      // A raw socket that accepts and never reads, so that the kernel buffers fill and dart:io stops taking chunks
      final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final held = <Socket>[];
      silent.listen(held.add);
      addTearDown(() async {
        for (final socket in held) {
          socket.destroy();
        }
        await silent.close();
      });

      final stack = makeStack(writeTimeout: const Duration(milliseconds: 300));
      await stack.init();
      final chunk = Uint8List(1024 * 1024);
      Stream<List<int>> body() async* {
        for (var i = 0; i < 1024; i++) {
          yield chunk;
        }
      }

      final request = http.StreamedRequest('POST', Uri.parse('http://127.0.0.1:${silent.port}/upload'))
        ..contentLength = chunk.length * 1024;
      unawaited(request.sink.addStream(body()).then((_) => request.sink.close()));
      await expectLater(
        stack.client.send(request),
        throwsA(isA<http.ClientException>().having((e) => e.message, 'message', 'Write timed out')),
      );
    });

    test('an abort by the caller stays an abort, as the upload cancel expects', () async {
      final stack = makeStack(readTimeout: const Duration(seconds: 5));
      await stack.init();
      final abort = Completer<void>();
      final request = http.AbortableRequest('POST', Uri.parse('${server.ip}/silent'), abortTrigger: abort.future);
      final sent = stack.client.send(request);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      abort.complete();
      await expectLater(sent, throwsA(isA<http.RequestAbortedException>()));
    });
  });

  test('a multipart upload arrives whole, with its declared length', () async {
    final stack = makeStack();
    await stack.init();
    final bytes = List<int>.generate(300 * 1024, (i) => i % 251);
    final request = http.MultipartRequest('POST', Uri.parse('${server.ip}/upload'))
      ..fields['deviceAssetId'] = 'f0123'
      ..files.add(http.MultipartFile.fromBytes('assetData', bytes, filename: 'a.jpg'));
    final response = await http.Response.fromStream(await stack.client.send(request));
    expect(response.statusCode, 201);
    final answer = jsonDecode(response.body) as Map<String, dynamic>;
    expect(answer['length'], answer['declared']);
    expect(answer['length'], greaterThan(bytes.length));
    final body = server.requests.lastWhere((r) => r.path == '/upload').body;
    expect(utf8.decode(body, allowMalformed: true), contains('name="deviceAssetId"'));
  });

  test('the shared client cannot be closed by a caller', () async {
    final stack = makeStack();
    await stack.init();
    stack.client.close();
    expect((await stack.client.get(Uri.parse('${server.ip}/x'))).statusCode, 200);
  });

  test('the websocket of socket.io carries the session, the custom headers and the protocols', () async {
    final stack = makeStack();
    await stack.init();
    await stack.setRequestHeaders({'X-Proxy-Token': 'abc'}, ['${server.ip}/api'], null);
    await stack.client.post(Uri.parse('${server.ip}/api/auth/login'));

    final socket = await stack.createWebSocket(
      Uri.parse('ws://127.0.0.1:${server.port}/socket'),
      headers: {'X-Extra': '1'},
      protocols: ['immich'],
    );
    expect(socket.protocol, 'immich');
    final headers = server.headersOf('/socket');
    expect(headers.value('cookie'), contains('immich_access_token=TOKEN-1'));
    expect(headers.value('x-proxy-token'), 'abc');
    expect(headers.value('x-extra'), '1');
    expect(headers.value('user-agent'), _userAgent);

    socket.sendText('hello');
    expect(await socket.events.first, TextDataReceived('hello'));
    await socket.close();
  });

  group('DesktopNetworkApi', () {
    test('passes the settings to the stack and answers what has no meaning on a computer', () async {
      final stack = makeStack();
      await stack.init();
      final api = DesktopNetworkApi(stack: stack);
      await api.setRequestHeaders({'X-A': 'b'}, ['${server.ip}/api'], null);
      expect(stack.customHeaders, {'X-A': 'b'});
      expect(await api.getClientPointer(), 0);
      expect(await api.getAppGroupId(), '');
      expect(await api.hasCertificate(), isFalse);
      await expectLater(
        api.selectCertificate(ClientCertPrompt(title: 't', message: 'm', cancel: 'c', confirm: 'o')),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'unsupported')),
      );
      // Not a PKCS#12 file: refused, nothing kept
      await expectLater(
        api.addCertificate(ClientCertData(data: Uint8List.fromList([1, 2, 3]), password: 'x')),
        throwsA(isA<TlsException>()),
      );
      expect(await api.hasCertificate(), isFalse);
    });
  });
}
