// The socket of the media bridge tells when a client closed its connection while the HTTP server holds the request
// (dart:io reads nothing of a connection while it answers on it), and the server works on it as on its own socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/watched_server_socket.dart';

void main() {
  late WatchedServerSocket socket;
  late HttpServer server;

  setUp(() async {
    socket = await WatchedServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server = HttpServer.listenOn(socket);
  });

  tearDown(() async {
    await server.close(force: true);
    await socket.close();
  });

  test('a client that leaves while its answer waits is told at once', () async {
    final held = Completer<void>();
    final seen = Completer<Future<void>?>();
    server.listen((request) async {
      seen.complete(socket.closedFrom(request.connectionInfo!.remotePort));
      await held.future;
      try {
        await request.response.close();
      } catch (_) {
        // The client is gone
      }
    });
    final client = await Socket.connect(InternetAddress.loopbackIPv4, socket.port);
    client.write('GET /film.mkv HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n');
    await client.flush();
    final closed = await seen.future;
    expect(closed, isNotNull);
    var told = false;
    unawaited(closed!.then((_) => told = true));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(told, isFalse, reason: 'the client is still there');

    client.destroy();
    await closed.timeout(const Duration(seconds: 2));
    expect(told, isTrue);
    held.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(socket.openConnections, 0);
  });

  test('requests one after the other on a kept connection, and a body posted, are served as before', () async {
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response.write('${request.method} ${request.uri.path} $body');
      await request.response.close();
    });
    final client = HttpClient();
    try {
      for (final path in ['/a', '/b']) {
        final request = await client.getUrl(Uri.parse('http://127.0.0.1:${socket.port}$path'));
        final response = await request.close();
        expect(await utf8.decoder.bind(response).join(), 'GET $path ');
      }
      final post = await client.postUrl(Uri.parse('http://127.0.0.1:${socket.port}/events'));
      post.write('{"seek": 42}');
      expect(await utf8.decoder.bind(await post.close()).join(), 'POST /events {"seek": 42}');
    } finally {
      client.close(force: true);
    }
  });
}
