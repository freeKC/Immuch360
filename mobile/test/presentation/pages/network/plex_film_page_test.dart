import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_download_action.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_play_on.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

import '../../../unit/presentation/presentation_context.dart';
import '../../system_navigation_bar.dart';

PlexFilmDetails _film() =>
    parsePlexFilmDetails(jsonDecode(File('test/fixtures/plex/metadata_film.json').readAsStringSync()))!;

final _summary = WikipediaFilmSummary(
  wiki: 'en',
  title: 'A Made Up Film',
  extract: 'A Made Up Film is a 2001 comedy made up for the tests.',
  articleUrl: Uri.parse('https://en.wikipedia.org/wiki/A_Made_Up_Film'),
);

void main() {
  late PresentationContext context;

  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  Future<List<PlexWikipediaKey>> pumpPage(
    WidgetTester tester, {
    bool tvMode = false,
    Size size = const Size(1080, 2400),
    double ratio = 2.5,
    WikipediaFilmSummary? summary,
    PlexFilmDetails? film,
    bool navigationBar = false,
  }) async {
    final asked = <PlexWikipediaKey>[];
    if (navigationBar) {
      screenWithNavigationBar(tester, size: size, ratio: ratio);
    } else {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
    }
    // A new tree each time: the providers start afresh
    await tester.pumpWidget(const SizedBox());
    await tester.pumpTestWidget(
      context,
      const PlexFilmPage(sourceId: 'source', ratingKey: '401', path: '/Movies/A Made Up Film (2001).mkv'),
      overrides: [
        plexFilmDetailsProvider.overrideWith((ref, key) async => film ?? _film()),
        plexPictureProvider.overrideWith((ref, key) async => null),
        plexFilmEntryProvider.overrideWith(
          (ref, key) async => NetworkEntry(
            sourceId: 'source',
            path: key.path,
            isDirectory: false,
            size: 8804682956,
            durationMs: 7320000,
          ),
        ),
        plexFilmFileSystemProvider.overrideWith((ref, sourceId) async => null),
        plexFilmWikipediaProvider.overrideWith((ref, key) async {
          asked.add(key);
          return summary;
        }),
        tvModeProvider.overrideWithValue(tvMode),
      ],
    );
    await tester.pumpAndSettle();
    return asked;
  }

  test('the row after Play takes Download (lot B), then Play on (lot C)', () {
    expect(filmPageActions, [filmPageDownloadAction, playOnFilmAction]);
  });

  testWidgets('shows what Plex holds of the film, and Resume where a Plex app stopped', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const Key('plex_film_title')), findsOneWidget);
    expect(find.text('Un film inventé'), findsOneWidget);
    expect(find.text('2001 · 2 h 02 · 12 and over · Comedy, Romance'), findsOneWidget);
    expect(find.text('Rotten Tomatoes 91 % · Rotten Tomatoes 84 %'), findsOneWidget);
    expect(find.text('Resume at 01:12:03'), findsOneWidget);
    expect(find.text('Play from the start'), findsOneWidget);
    expect(find.text('Nothing is real.'), findsOneWidget);
    expect(find.text('Directed by Jeanne Exemple'), findsOneWidget);
    expect(find.text('Written by Paul Exemple'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Alice Test'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Amélie'), findsOneWidget);
    expect(find.text('AT'), findsOneWidget, reason: 'initials, never a picture of Plex servers');
  });

  testWidgets('asks Wikipedia by the film numbers in the language of the app, and credits the article', (tester) async {
    final asked = await pumpPage(tester, summary: _summary);
    expect(asked.single.imdb, 'tt0000401');
    expect(asked.single.tmdb, '401');
    expect(asked.single.appLocale, 'en');
    final block = find.byKey(const Key('plex_film_wikipedia'));
    await tester.scrollUntilVisible(block, 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('From Wikipedia'), findsOneWidget);
    expect(find.text('A Made Up Film is a 2001 comedy made up for the tests.'), findsOneWidget);
    expect(find.text('From the Wikipedia article "A Made Up Film", CC BY-SA 4.0'), findsOneWidget);
    expect(find.text('Read on Wikipedia'), findsOneWidget);
  });

  testWidgets('ends above the navigation bar of the phone, Read on Wikipedia last', (tester) async {
    await pumpPage(tester, summary: _summary, navigationBar: true);
    await scrollToEnd(
      tester,
      find.descendant(of: find.byKey(const Key('plex_film_page')), matching: find.byType(Scrollable)).first,
    );
    expectAboveNavigationBar(tester, find.byKey(const Key('plex_film_wikipedia_link')));
  });

  testWidgets('shows no Wikipedia block without an article, nor for an item without numbers', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const Key('plex_film_wikipedia')), findsNothing);
    final film = _film();
    final bare = PlexFilmDetails(ratingKey: film.ratingKey, title: film.title, medias: film.medias, sectionKey: '1');
    final asked = await pumpPage(tester, film: bare, summary: _summary);
    expect(asked, isEmpty, reason: 'no request without an IMDb or TMDB number');
    expect(find.byKey(const Key('plex_film_wikipedia')), findsNothing);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('on a TV the focus starts on Play and the menu is not there', (tester) async {
    await pumpPage(tester, tvMode: true, size: const Size(1920, 1080), ratio: 2);
    final play = find.byKey(const Key('plex_film_play'));
    expect(play, findsOneWidget);
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    expect(find.ancestor(of: find.byWidget(focused!.widget), matching: play), findsWidgets);
    expect(find.byKey(const Key('plex_film_menu')), findsNothing);
  });

  testWidgets('Show the folders is in the menu, and a button of the row on a TV', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const Key('plex_film_show_folders')), findsNothing);
    await tester.tap(find.byKey(const Key('plex_film_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Show the folders'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
    await pumpPage(tester, tvMode: true, size: const Size(1920, 1080), ratio: 2);
    expect(find.byKey(const Key('plex_film_show_folders')), findsOneWidget);
    expect(find.text('Show the folders'), findsOneWidget);
  });

  testWidgets('puts the poster and the buttons beside the texts on a wide screen', (tester) async {
    await pumpPage(tester, size: const Size(2048, 1280), ratio: 2);
    final play = tester.getCenter(find.byKey(const Key('plex_film_play')));
    final summary = tester.getCenter(find.byKey(const Key('plex_film_summary')));
    expect(play.dx, lessThan(summary.dx));
  });

  test('the facts line, the duration and the initials', () async {
    final context = await PresentationContext.create();
    addTearDown(context.dispose);
    expect(plexInitials('Keanu Reeves'), 'KR');
    expect(plexInitials('Cher'), 'C');
    expect(plexInitials('  '), '?');
  });
}
