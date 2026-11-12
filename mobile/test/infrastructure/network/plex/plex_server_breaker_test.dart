import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/domain/services/film_download/film_transfer.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';

void main() {
  group('PlexServerBreaker', () {
    late DateTime now;
    late PlexServerBreaker breaker;

    setUp(() {
      now = DateTime(2026, 11, 11, 18, 45);
      breaker = PlexServerBreaker(
        threshold: 3,
        firstProbeDelay: const Duration(seconds: 2),
        maxProbeDelay: const Duration(seconds: 30),
        clock: () => now,
      );
      addTearDown(breaker.dispose);
    });

    test('opens after three network failures in a row, an answer between them starts the count again', () {
      breaker.failed(breaker.admit()!);
      breaker.failed(breaker.admit()!);
      breaker.answered(breaker.admit()!);
      breaker.failed(breaker.admit()!);
      breaker.failed(breaker.admit()!);
      expect(breaker.isOpen, isFalse);
      breaker.failed(breaker.admit()!);
      expect(breaker.isOpen, isTrue);
    });

    test('open, it refuses every call but one probe once its wait is over', () {
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      expect(breaker.admit(), isNull, reason: 'the first probe waits 2 s');
      expect(breaker.retryIn, const Duration(seconds: 2));
      now = now.add(const Duration(seconds: 2));
      final probe = breaker.admit();
      expect(probe?.isProbe, isTrue);
      expect(breaker.admit(), isNull, reason: 'one probe at a time: no burst');
      expect(breaker.admit(), isNull);
    });

    test('the wait between probes doubles up to its cap', () {
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      final waits = <int>[];
      for (var i = 0; i < 7; i++) {
        waits.add(breaker.retryIn.inSeconds);
        now = now.add(breaker.retryIn);
        breaker.failed(breaker.admit()!);
      }
      expect(waits, [2, 4, 8, 16, 30, 30, 30]);
    });

    test('the requests under way when it opened push no probe further', () {
      final underWay = [for (var i = 0; i < 14; i++) breaker.admit()!];
      for (final permit in underWay) {
        breaker.failed(permit);
      }
      expect(breaker.isOpen, isTrue);
      expect(breaker.retryIn, const Duration(seconds: 2), reason: '14 refusals at once are one outage');
    });

    test('an answer of the probe closes it and tells the pages; the server counts as reached', () {
      var told = 0;
      breaker.addListener(() => told++);
      expect(breaker.everReached, isFalse);
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      expect(told, 1);
      now = now.add(const Duration(seconds: 2));
      breaker.answered(breaker.admit()!);
      expect(breaker.isOpen, isFalse);
      expect(told, 2);
      expect(breaker.everReached, isTrue);
      expect(breaker.admit()?.isProbe, isFalse);
    });

    test('Retry lets one probe through at once', () {
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      expect(breaker.admit(), isNull);
      breaker.probeNow();
      expect(breaker.admit()?.isProbe, isTrue);
    });

    test('a probe stopped by its caller lets the next one go', () {
      for (var i = 0; i < 3; i++) {
        breaker.failed(breaker.admit()!);
      }
      now = now.add(const Duration(seconds: 2));
      breaker.released(breaker.admit()!);
      expect(breaker.admit()?.isProbe, isTrue);
    });

    test('probes by itself while open, and stops once the server answers', () async {
      final live = PlexServerBreaker(firstProbeDelay: const Duration(milliseconds: 20));
      addTearDown(live.dispose);
      var probes = 0;
      var up = false;
      live.onProbe = () async {
        final permit = live.admit();
        if (permit == null) {
          return;
        }
        probes++;
        up ? live.answered(permit) : live.failed(permit);
      };
      for (var i = 0; i < 3; i++) {
        live.failed(live.admit()!);
      }
      // After 20 ms, then 40 ms: waited for with room, the machine may be busy with other tests
      final until = DateTime.now().add(const Duration(seconds: 5));
      while (probes < 2 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(probes, greaterThanOrEqualTo(2));
      expect(live.isOpen, isTrue);
      up = true;
      final closed = Completer<void>();
      live.addListener(() {
        if (!live.isOpen && !closed.isCompleted) {
          closed.complete();
        }
      });
      live.probeNow();
      await closed.future.timeout(const Duration(seconds: 2));
      final after = probes;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probes, after, reason: 'no probe once closed');
    });

    test('the breakers are shared by source id, and Retry reaches every open one', () {
      addTearDown(PlexServerBreakers.clear);
      final a = PlexServerBreakers.of('a');
      expect(PlexServerBreakers.of('a'), same(a));
      expect(PlexServerBreakers.existing('b'), isNull);
      for (var i = 0; i < 3; i++) {
        a.failed(a.admit()!);
      }
      expect(a.admit(), isNull);
      PlexServerBreakers.probeAllNow();
      expect(a.admit()?.isProbe, isTrue);
    });
  });

  group('what the user is told', () {
    const refused = SocketException('Connection refused', osError: OSError('Connection refused', 111));

    test('a server never reached: does not answer at home, remote access from outside home', () {
      expect((plexErrorOf(refused) as PlexFileSystemException).failure, PlexFailure.unreachable);
      final outside = plexErrorOf(refused, outsideHome: true) as PlexFileSystemException;
      expect(outside.failure, PlexFailure.unreachableOutsideHome);
      expect(outside.message, contains('remote access'));
    });

    test('a server that answered before stopped answering, whatever failed and wherever the phone is', () {
      for (final error in <Object>[
        refused,
        const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104)),
        TimeoutException('No answer in time'),
        http.ClientException('Connection closed before full header was received'),
        const HttpException('Connection closed while receiving data'),
      ]) {
        for (final outsideHome in [false, true]) {
          final told = plexErrorOf(error, outsideHome: outsideHome, reachedBefore: true, sourceId: 'plex1');
          expect(told, isA<PlexFileSystemException>());
          told as PlexFileSystemException;
          expect(told.failure, PlexFailure.stoppedAnswering, reason: '$error');
          expect(told.message, isNot(contains('remote access')));
          expect(told.sourceId, 'plex1');
          expect(told.isStoppedAnswering, isTrue);
        }
      }
    });

    test('no address answering after the server did is a server that stopped, not one to set up', () {
      const outsideHome = PlexFileSystemException('Turn on remote access', PlexFailure.unreachableOutsideHome);
      final told = plexErrorOf(outsideHome, reachedBefore: true, sourceId: 'plex1') as PlexFileSystemException;
      expect(told.failure, PlexFailure.stoppedAnswering);
      expect(plexErrorOf(outsideHome), same(outsideHome));
    });

    test('an answer of the server stays what it said', () {
      expect(
        (plexErrorOf(const PlexHttpStatus(401), reachedBefore: true) as PlexFileSystemException).failure,
        PlexFailure.tokenRefused,
      );
      expect(
        (plexErrorOf(const PlexHttpStatus(500), reachedBefore: true) as PlexFileSystemException).failure,
        PlexFailure.failed,
      );
    });

    test('a file the server cannot read now is no film gone', () {
      expect(plexFileUnreadable.isFileUnreadable, isTrue);
      expect(plexFileUnreadable.isNotFound, isFalse);
      expect(plexFileUnreadable.failure, PlexFailure.fileUnreadable);
      expect(plexFileUnreadable.message, "The Plex server cannot read this film's file right now");
    });

    test('a request stopped by its caller is no failure of the network', () {
      expect(isPlexNetworkFailure(const PlexRequestCancelled()), isFalse);
      expect(isPlexNetworkFailure(plexStoppedAnswering()), isTrue);
    });

    test('a download of a film whose file the server cannot read tries again, then says so', () {
      final kind = filmDownloadFailureOf(plexFileUnreadable);
      expect(kind.failure, FilmDownloadFailure.unreadable);
      expect(kind.retry, isTrue);
      expect(filmDownloadFailureOf(plexStoppedAnswering()).failure, FilmDownloadFailure.unreachable);
      expect(
        filmDownloadFailureOf(const PlexFileSystemException('gone', PlexFailure.failed, isNotFound: true)).failure,
        FilmDownloadFailure.gone,
      );
    });
  });
}
