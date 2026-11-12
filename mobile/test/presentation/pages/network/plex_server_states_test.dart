// What the pages say when a Plex server stops (11 November 2026): "The Plex server stopped answering" with Retry,
// read again by itself once the server answers, rather than "set up remote access"; "The Plex server cannot read
// this film's file right now" when its films volume is not mounted, rather than "no longer on the server"; and the
// wait for a server slow to send the start of a film, with Cancel.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/film_download.model.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_client.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_server_breaker.dart';
import 'package:immich_mobile/presentation/pages/network/network_video.page.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

const _stoppedText =
    'The Plex server stopped answering. It may be restarting or busy: the app tries again by itself, or tap Retry.';
const _unreadableText =
    "The Plex server cannot read this film's file right now. The disk or folder holding the films may be offline on "
    'the server: try again once it is back.';

void main() {
  late PresentationContext context;

  setUp(() async {
    PlexServerBreakers.clear();
    context = await PresentationContext.create();
  });
  tearDown(() {
    PlexServerBreakers.clear();
    return context.dispose();
  });

  /// The breaker of [sourceId], open as after the refusals of 11 November
  PlexServerBreaker openBreaker(String sourceId) {
    final breaker = PlexServerBreakers.of(sourceId);
    breaker.answered(breaker.admit()!);
    for (var i = 0; i < PlexServerBreaker.defaultThreshold; i++) {
      breaker.failed(breaker.admit()!);
    }
    expect(breaker.isOpen, isTrue);
    return breaker;
  }

  group('a film page in front of a server that stopped answering', () {
    Future<List<String>> pumpPage(WidgetTester tester, Object Function() details) async {
      final asked = <String>[];
      await tester.pumpTestWidget(
        context,
        const PlexFilmPage(sourceId: 'plex1', ratingKey: '401'),
        overrides: [
          plexFilmDetailsProvider.overrideWith((ref, key) async {
            asked.add(key.ratingKey);
            final answer = details();
            if (answer is PlexFilmDetails) {
              return answer;
            }
            throw answer as Exception;
          }),
          plexPictureProvider.overrideWith((ref, key) async => null),
          plexFilmFileSystemProvider.overrideWith((ref, sourceId) async => null),
        ],
      );
      await tester.pumpAndSettle();
      return asked;
    }

    testWidgets('says the server stopped answering, with Retry, never remote access', (tester) async {
      openBreaker('plex1');
      await pumpPage(tester, () => plexStoppedAnswering(sourceId: 'plex1', reason: ' (Connection refused)'));
      expect(find.text(_stoppedText), findsOneWidget);
      expect(find.textContaining('remote access'), findsNothing);
      expect(find.byKey(const Key('network_error_retry')), findsOneWidget);
    });

    testWidgets('Retry lets one request go to the server at once, and reads the film again', (tester) async {
      final breaker = openBreaker('plex1');
      final asked = await pumpPage(tester, () => plexStoppedAnswering(sourceId: 'plex1'));
      expect(breaker.admit(), isNull, reason: 'the first probe waits');
      await tester.tap(find.byKey(const Key('network_error_retry')));
      await tester.pumpAndSettle();
      expect(asked, hasLength(2));
      expect(breaker.admit()?.isProbe, isTrue, reason: 'Retry made the probe due at once');
    });

    testWidgets('reads the film again by itself once the server answers', (tester) async {
      final breaker = openBreaker('plex1');
      final asked = await pumpPage(tester, () => plexStoppedAnswering(sourceId: 'plex1'));
      expect(asked, hasLength(1));
      // The probe of the breaker got an answer
      breaker.probeNow();
      breaker.answered(breaker.admit()!);
      await tester.pumpAndSettle();
      expect(asked, hasLength(2));
    });
  });

  group('a film whose file the server cannot read right now', () {
    testWidgets('says so with Retry, not that the film left the server', (tester) async {
      var retried = 0;
      await tester.pumpTestWidget(
        context,
        Scaffold(
          body: NetworkErrorView(error: plexFileUnreadable, onRetry: () => retried++),
        ),
      );
      expect(find.text(_unreadableText), findsOneWidget);
      expect(find.textContaining('no longer'), findsNothing);
      await tester.tap(find.byKey(const Key('network_error_retry')));
      expect(retried, 1);
    });

    testWidgets('its download says the same, and that Retry goes on', (tester) async {
      late String text;
      await tester.pumpTestWidget(
        context,
        Builder(
          builder: (context) {
            text = filmDownloadFailureText(context, FilmDownloadFailure.unreadable);
            return const SizedBox();
          },
        ),
      );
      expect(
        text,
        "The Plex server cannot read this film's file right now: Retry goes on from where the download stopped",
      );
    });
  });

  testWidgets('the wait for the start of a film says so, and Cancel stops it', (tester) async {
    var cancelled = 0;
    await tester.pumpTestWidget(
      context,
      Scaffold(
        body: NetworkLoadingView(
          message: 'Waiting for the server…',
          detail: 'The Plex server is slow to send the start of this film.',
          onCancel: () => cancelled++,
        ),
      ),
      expectSettle: false,
    );
    expect(find.text('Waiting for the server…'), findsOneWidget);
    await tester.tap(find.byKey(const Key('network_loading_cancel')));
    expect(cancelled, 1);
  });

  test('the fault of the player on a Dolby Vision profile 5 MKV is told as its own, not as the file', () {
    const quest =
        "Unexpected NullPointerException: Attempt to invoke virtual method 'java.lang.Class java.lang.Object.getClass()' "
        'on a null object reference';
    expect(isPlayerReaderFault(quest), isTrue);
    expect(isPlayerReaderFault('Unexpected IllegalStateException'), isTrue);
    expect(isPlayerReaderFault('Response code: 500'), isFalse);
    expect(isPlayerReaderFault('None of the available extractors (Mp4Extractor) could read the stream.'), isFalse);
  });
}
