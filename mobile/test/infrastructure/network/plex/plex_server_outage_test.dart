// A Plex server that stops in front of the app, as the test server did on 11 November 2026: its listener stopped
// after an evening of playback (94 refusals in 76 s, up to 14 at once, then "set up remote access" on screen), and
// after its reboot the volume of the films stayed unmounted (404 on every part, the metadata still served), then sent
// the first MiB of a film in 74 s.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';

import 'fake_plex_server.dart';

NetworkSource _source() => const NetworkSource(
  id: 'plex-outage-test',
  type: NetworkSourceType.plex,
  name: 'Test Plex',
  host: '192.0.2.20',
  rootPath: '/',
  useTls: true,
  discoveryId: plexTestMachine,
  plex: PlexServerInfo(hash: plexTestHash),
);

Future<int> _deadPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Object? _fixture(String name) => jsonDecode(File('test/fixtures/plex/$name').readAsStringSync());

Matcher _failure(PlexFailure failure) => isA<PlexFileSystemException>().having((e) => e.failure, 'failure', failure);

void main() {
  late FakePlexServer server;

  setUp(() async {
    PlexServerBreakers.clear();
    server = await FakePlexServer.start();
    server.metadata['401'] = _fixture('metadata_film.json');
    server.partSizes[4010] = 2000;
  });
  tearDown(() async {
    await server.close();
    PlexServerBreakers.clear();
  });

  Future<PlexFileSystem> open({Uri? public, http.Client? client, Uri? local, PlexServerBreaker? breaker}) async {
    final fileSystem = await PlexFileSystem.open(
      _source(),
      plexTestToken,
      client: client,
      baseOverride: local ?? server.base,
      publicBaseOverride: public,
      clientIdentifier: 'client-test-0000',
      breaker: breaker,
    );
    addTearDown(fileSystem.close);
    return fileSystem;
  }

  final filmPath = plexFilmPath(sectionKey: '1', ratingKey: '401', partId: 4010, name: 'A Made Up Film (2001).mkv');

  group('a server that stopped answering', () {
    test('is told so, never as one to reach from outside home, once it answered in this run', () async {
      final plex = await open(public: Uri.parse('http://127.0.0.1:${await _deadPort()}'));
      await plex.list('/');
      await server.close();
      await expectLater(plex.list('/Movies'), throwsA(_failure(PlexFailure.stoppedAnswering)));
      try {
        await plex.list('/Photos');
        fail('the server is down');
      } on PlexFileSystemException catch (error) {
        expect(error.message, isNot(contains('remote access')));
        expect(error.sourceId, 'plex-outage-test');
      }
    });

    test('never reached in this run, the advice for outside home stays', () async {
      await expectLater(
        open(
          local: Uri.parse('http://127.0.0.1:${await _deadPort()}'),
          public: Uri.parse('http://127.0.0.1:${await _deadPort()}'),
        ),
        throwsA(_failure(PlexFailure.unreachableOutsideHome)),
      );
    });

    test('after three failures the calls fail at once without a request, one probe at a time', () async {
      final inner = IOClient(HttpClient());
      addTearDown(inner.close);
      var down = false;
      var sent = 0;
      final client = MockClient.streaming((request, _) async {
        sent++;
        if (down) {
          throw const SocketException('Connection refused', osError: OSError('Connection refused', 111));
        }
        final copy = http.Request(request.method, request.url)
          ..followRedirects = false
          ..headers.addAll(request.headers);
        return inner.send(copy);
      });
      addTearDown(client.close);
      final breaker = PlexServerBreaker(
        firstProbeDelay: const Duration(milliseconds: 150),
        maxProbeDelay: const Duration(milliseconds: 300),
      );
      addTearDown(breaker.dispose);
      final plex = await open(client: client, breaker: breaker);
      await plex.list('/Movies');
      down = true;
      sent = 0;

      // The tiles of a page ask for their pictures all at once
      final pictures = [
        for (var i = 0; i < 14; i++) plex.picture('/library/metadata/$i/thumb/1', width: 200, height: 300),
      ];
      for (final picture in pictures) {
        await expectLater(picture, throwsA(_failure(PlexFailure.stoppedAnswering)));
      }
      expect(breaker.isOpen, isTrue);
      final burst = sent;
      expect(burst, lessThanOrEqualTo(14 * 3), reason: 'each picture once, the address chosen again once for all');

      // While open, nothing reaches the network
      for (var i = 0; i < 20; i++) {
        await expectLater(plex.list('/Photos'), throwsA(_failure(PlexFailure.stoppedAnswering)));
      }
      expect(
        sent - burst,
        lessThanOrEqualTo(4),
        reason: 'a probe of the breaker at most, with its new choice of address',
      );

      // The server answers again: the next probe closes the breaker by itself
      down = false;
      final closed = Completer<void>();
      breaker.addListener(() {
        if (!breaker.isOpen && !closed.isCompleted) {
          closed.complete();
        }
      });
      await closed.future.timeout(const Duration(seconds: 3));
      expect(await plex.list('/Photos'), isNotEmpty);
    });

    test('Retry lets a call through at once', () async {
      final breaker = PlexServerBreaker(firstProbeDelay: const Duration(minutes: 1));
      addTearDown(breaker.dispose);
      final plex = await open(breaker: breaker);
      await plex.list('/');
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      await expectLater(plex.list('/Movies'), throwsA(_failure(PlexFailure.stoppedAnswering)));
      PlexServerBreakers.probeAllNow();
      breaker.probeNow();
      expect(await plex.list('/Movies'), isNotEmpty);
      expect(breaker.isOpen, isFalse);
    });
  });

  group('a film whose file the server cannot read', () {
    test('the metadata there, the part answering 404: the file cannot be read right now', () async {
      final plex = await open();
      await plex.stat(filmPath);
      server.partSizes.remove(4010);
      await expectLater(
        plex.readRange(filmPath, 0, 16),
        throwsA(
          isA<PlexFileSystemException>()
              .having((e) => e.failure, 'failure', PlexFailure.fileUnreadable)
              .having((e) => e.isFileUnreadable, 'isFileUnreadable', isTrue)
              .having((e) => e.isNotFound, 'isNotFound', isFalse),
        ),
      );
      // Looked for again once (a rescan gives new keys), then told
      expect(server.requests.where((r) => r.path.startsWith('/library/parts/4010/')).length, 2);
    });

    test('the film gone from the server too: no longer on the server', () async {
      final plex = await open();
      await plex.stat(filmPath);
      server.partSizes.remove(4010);
      server.metadata.remove('401');
      await expectLater(
        plex.readRange(filmPath, 0, 16),
        throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'isNotFound', isTrue)),
      );
    });

    test('a file of a folder still listed whose part answers 404 cannot be read right now', () async {
      final plex = await open();
      await plex.list('/Movies');
      server.partSizes.remove(11);
      await expectLater(plex.readRange('/Movies/a.mp4', 0, 10), throwsA(_failure(PlexFailure.fileUnreadable)));
    });

    test('its download stops with the same words', () async {
      final plex = await open();
      await plex.stat(filmPath);
      server.partSizes.remove(4010);
      await expectLater(plex.openDownload(filmPath), throwsA(_failure(PlexFailure.fileUnreadable)));
    });
  });

  group('the first bytes of a film', () {
    const partPath = '/library/parts/11/1700000000/file.mp4';

    test('are waited for longer than any other answer, the server slow after a remount', () async {
      final plex = await open();
      await plex.list('/Movies');
      server.delays[partPath] = const Duration(milliseconds: 600);
      final watch = Stopwatch()..start();
      await plex.waitForFirstBytes('/Movies/a.mp4', timeout: const Duration(seconds: 5));
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 600)));
      final asked = server.requests.lastWhere((r) => r.path == partPath);
      expect(asked.headers['range'], 'bytes=0-${PlexFileSystem.filmStartBytes - 1}');
      expect(asked.headers['x-plex-token'], plexTestToken);
    });

    test('nothing in time: the server stopped answering', () async {
      final plex = await open();
      await plex.list('/Movies');
      server.delays[partPath] = const Duration(seconds: 3);
      await expectLater(
        plex.waitForFirstBytes('/Movies/a.mp4', timeout: const Duration(milliseconds: 300)),
        throwsA(_failure(PlexFailure.stoppedAnswering)),
      );
    });

    test('Cancel stops the wait at once, which is no failure of the server', () async {
      final breaker = PlexServerBreaker();
      addTearDown(breaker.dispose);
      final plex = await open(breaker: breaker);
      await plex.list('/Movies');
      server.delays[partPath] = const Duration(seconds: 5);
      final cancel = Completer<void>();
      final wait = plex.waitForFirstBytes('/Movies/a.mp4', cancel: cancel.future);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final watch = Stopwatch()..start();
      cancel.complete();
      await expectLater(wait, throwsA(isA<PlexRequestCancelled>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(breaker.failures, 0);
    });

    test('a part answering 404 while the film is known: the file cannot be read right now', () async {
      final plex = await open();
      await plex.list('/Movies');
      server.partSizes.remove(11);
      await expectLater(plex.waitForFirstBytes('/Movies/a.mp4'), throwsA(_failure(PlexFailure.fileUnreadable)));
    });
  });
}
