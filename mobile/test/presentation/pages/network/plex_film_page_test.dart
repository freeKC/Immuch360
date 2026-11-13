import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_actions.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_download_action.dart';
import 'package:immich_mobile/presentation/pages/network/film_page_play_on.dart';
import 'package:immich_mobile/presentation/pages/network/plex_film.page.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart' show filmDownloadOfferedProvider;
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_version.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';

import '../../../providers/network/film_download_fakes.dart';
import '../../../unit/presentation/presentation_context.dart';
import '../../system_navigation_bar.dart';

PlexFilmDetails _film() =>
    parsePlexFilmDetails(jsonDecode(File('test/fixtures/plex/metadata_film.json').readAsStringSync()))!;

/// The film of the fixture with two versions, as La Bataille de Gaulle on the test server: 2160p HEVC HDR 52 GB first,
/// 1080p HEVC 3 GB second
PlexFilmDetails _twoVersions(String ratingKey) {
  final film = _film();
  PlexFilmMedia media(int id, String resolution, int size, {bool hdr = false}) => PlexFilmMedia(
    id: id,
    videoResolution: resolution,
    videoCodec: 'hevc',
    container: 'mkv',
    parts: [
      PlexFilmPart(
        id: id + 100,
        key: '/library/parts/${id + 100}/1/file.mkv',
        file: '/films/Film.$resolution.mkv',
        size: size,
        container: 'mkv',
        streams: [
          PlexStream(id: id * 10, type: PlexStreamType.video, codec: 'hevc', colorTrc: hdr ? 'smpte2084' : 'bt709'),
          PlexStream(id: id * 10 + 1, type: PlexStreamType.audio, index: 1, codec: 'eac3', languageTag: 'fr'),
        ],
      ),
    ],
  );
  return PlexFilmDetails(
    ratingKey: ratingKey,
    title: film.title,
    sectionKey: '1',
    medias: [media(501, '4k', 55834574848, hdr: true), media(502, '1080', 3221225472)],
  );
}

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
    String ratingKey = '401',
    FilmVersionDevice device = (screenHeight: null, phone: false, decodes: null),
    List<Override> extra = const [],
    List<String>? entriesAsked,
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
      PlexFilmPage(sourceId: 'source', ratingKey: ratingKey, path: '/Movies/A Made Up Film (2001).mkv'),
      overrides: [
        filmVersionDeviceProvider.overrideWith((ref) async => device),
        ...extra,
        plexFilmDetailsProvider.overrideWith((ref, key) async => film ?? _film()),
        plexPictureProvider.overrideWith((ref, key) async => null),
        plexFilmEntryProvider.overrideWith((ref, key) async {
          entriesAsked?.add(key.path);
          return NetworkEntry(
            sourceId: 'source',
            path: key.path,
            isDirectory: false,
            size: 8804682956,
            durationMs: 7320000,
          );
        }),
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

  group('a film with several versions (release 47)', () {
    testWidgets('shows them, the one for this screen picked; a pick is remembered for the film', (tester) async {
      await pumpPage(
        tester,
        film: _twoVersions('14488'),
        ratingKey: '14488',
        device: (screenHeight: 1080, phone: false, decodes: null),
      );
      expect(find.byKey(const Key('plex_film_versions')), findsOneWidget);
      expect(find.text('2160p HEVC HDR, 52 GiB'), findsOneWidget);
      expect(find.text('1080p HEVC, 3.0 GiB'), findsOneWidget);
      ChoiceChip chip(int index) => tester.widget<ChoiceChip>(find.byKey(Key('plex_film_version_$index')));
      expect(chip(1).selected, isTrue, reason: 'a 1080p screen');
      expect(chip(0).selected, isFalse);
      expect(find.textContaining('MKV, 3.0 GiB'), findsOneWidget, reason: 'the lines of the file Play opens');

      await tester.tap(find.byKey(const Key('plex_film_version_0')));
      await tester.pumpAndSettle();
      expect(chip(0).selected, isTrue);
      expect(find.textContaining('MKV, 52.0 GiB'), findsOneWidget);
      expect(StoreService.I.tryGet(StoreKey.plexFilmVersions), contains('"source:14488":501'));

      // Opened again: the pick stays
      await pumpPage(
        tester,
        film: _twoVersions('14488'),
        ratingKey: '14488',
        device: (screenHeight: 1080, phone: false, decodes: null),
      );
      expect(chip(0).selected, isTrue);
    });

    testWidgets('a film with one version shows no choice', (tester) async {
      await pumpPage(tester);
      expect(find.byKey(const Key('plex_film_versions')), findsNothing);
    });

    testWidgets('Download asks which version, and copies the one picked', (tester) async {
      final root = Directory.systemTemp.createTempSync('film_versions_');
      addTearDown(() => root.deleteSync(recursive: true));
      final films = FakeFilmEnvironment(root, FakeDownloadShare({}));
      addTearDown(films.close);
      final asked = <String>[];
      await pumpPage(
        tester,
        film: _twoVersions('14489'),
        ratingKey: '14489',
        device: (screenHeight: 2160, phone: false, decodes: null),
        entriesAsked: asked,
        extra: [
          filmDownloadEnvironmentProvider.overrideWithValue(films.environment),
          filmDownloadsProvider.overrideWith(FilmDownloadsNotifier.new),
          filmDownloadOfferedProvider.overrideWithValue(true),
          networkSourceProvider.overrideWith(
            (ref, id) => const NetworkSource(
              id: 'source',
              type: NetworkSourceType.plex,
              name: 'Home Plex',
              host: '192.0.2.20',
              rootPath: '/',
              plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
            ),
          ),
        ],
      );
      final button = find.byKey(const Key('film_version_download_button'));
      expect(button, findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('film_version_download_dialog')), findsOneWidget);
      expect(find.text('Which version to download?'), findsOneWidget);
      asked.clear();
      await tester.tap(find.byKey(const Key('film_version_download_1')));
      await tester.pumpAndSettle();
      expect(asked, contains('/.films/1/14489/602/Film.1080.mkv'), reason: 'the 1080p file, by its own path');
    });
  });

  test('the facts line, the duration and the initials', () async {
    final context = await PresentationContext.create();
    addTearDown(context.dispose);
    expect(plexInitials('Keanu Reeves'), 'KR');
    expect(plexInitials('Cher'), 'C');
    expect(plexInitials('  '), '?');
  });
}
