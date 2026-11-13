import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/pages/network/plex_films_library.page.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_media_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/plex_film_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_text_entry.widget.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/store.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';
import 'package:immich_mobile/providers/network/plex_films.provider.dart';
import 'package:immich_mobile/routing/router.dart';

import '../../../providers/network/film_download_fakes.dart';
import 'network_viewer_fakes.dart';

const _source = NetworkSource(
  id: 'plex',
  type: NetworkSourceType.plex,
  name: 'Home Plex',
  host: '192.0.2.20',
  rootPath: '/',
  useTls: true,
  plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
);

PlexFilm _film(int id, String title, int? year, {int viewCount = 0}) => PlexFilm(
  ratingKey: '$id',
  title: title,
  year: year,
  viewCount: viewCount,
  parts: [
    PlexFileItem(
      partKey: '/library/parts/${1000 + id}/1/file.mkv',
      fileName: '$title.mkv',
      partId: 1000 + id,
      size: 1000,
      mimeType: 'video/x-matroska',
      title: title,
      year: year,
      isPoster: true,
    ),
  ],
);

/// A Plex server as the films page and the folder view see it: a share whose movie library is at /Movies
class _PlexShare extends MemoryShare implements PlexFilmsSource {
  _PlexShare(this.films) : super(_source);

  final List<PlexFilm> films;
  final List<String> searched = [];

  /// The queries of the light pass of the years, one per reading of the list
  final List<PlexFilmListQuery> asked = [];

  static const movies = PlexSection(key: '1', title: 'Movies', type: 'movie', agent: 'tv.plex.agents.movie');

  List<PlexFilm> _of(PlexFilmListQuery query) {
    final text = query.searchedTitle?.toLowerCase();
    final unwatched = query.queryParameters()['unwatched'] == '1';
    return [
      for (final f in films)
        if ((text == null || f.title.toLowerCase().contains(text)) && (!unwatched || f.viewCount == 0)) f,
    ];
  }

  @override
  String get filmsSourceId => _source.id;

  @override
  bool get isOutsideHome => false;

  @override
  Future<List<int?>> filmYears(PlexFilmListQuery query) async {
    asked.add(query);
    return [for (final f in _of(query)) f.year];
  }

  @override
  Future<PlexFilmListPage> filmsPage(PlexFilmListQuery query, {required int start, required int size}) async {
    final all = _of(query);
    final page = all.skip(start).take(size).toList();
    return PlexFilmListPage(films: page, count: page.length, offset: start, totalSize: all.length);
  }

  @override
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text) async {
    searched.add(text);
    return const [];
  }

  @override
  Future<List<PlexFilm>> filmsByFoldedTitle(
    PlexFilmListQuery query,
    String text, {
    Set<String> except = const {},
    int limit = plexFoldedSearchLimit,
  }) async => const [];

  @override
  Future<List<({PlexSection section, String folderPath})>> filmLibraries() async => [
    (section: movies, folderPath: '/Movies'),
  ];

  @override
  PlexSection? filmLibraryAt(String path) => path == '/Movies' ? movies : null;
}

void main() {
  late Drift db;
  late StoreService store;
  late _PlexShare share;

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    store = await StoreService.create(storeRepository: StoreRepository(db), listenUpdates: false);
    await store.put(StoreKey.networkSources, NetworkSource.encodeList(const [_source]));
    share = _PlexShare([
      _film(1, 'The Example Night', 2021),
      _film(2, 'Élan du matin', 2021),
      _film(3, 'Ten Rooms', 2019, viewCount: 1),
      _film(4, 'Home cut', null),
    ]);
    share.folders['/'] = [share.folder('/Movies'), share.folder('/Home videos')];
    share.folders['/Movies'] = [share.folder('/Movies/Ten Rooms')];
  });

  tearDown(() async {
    await store.dispose();
    await db.close();
  });

  Future<RootStackRouter> pumpFilms(
    WidgetTester tester, {
    bool tvMode = false,
    List<Override> overrides = const [],
    Widget? home,
    Size size = const Size(800, 2000),
  }) async {
    // Tall enough for every year of the test films at once
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = await pumpNetworkRouter(
      tester,
      home:
          home ?? const PlexFilmsLibraryPage(sourceId: 'plex', sectionKey: '1', title: 'Movies', folderPath: '/Movies'),
      settle: false,
      overrides: [
        ...overrides,
        storeServiceProvider.overrideWithValue(store),
        tvModeProvider.overrideWithValue(tvMode),
        overrideConnections((ref) => FakeConnections(ref, share)),
        plexFilmsSourceProvider.overrideWithValue((sourceId) async => share),
      ],
    );
    await tester.pumpAndSettle();
    return router;
  }

  Finder tileOf(String title) =>
      find.byWidgetPredicate((widget) => widget is PlexFilmTile && widget.film.title == title);

  testWidgets('every film under its year, newest first, with its title and year under the poster', (tester) async {
    await pumpFilms(tester);

    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('2021'), findsWidgets);
    expect(find.text('2 films'), findsOneWidget);
    expect(find.text('1 film'), findsNWidgets(2));
    expect(find.text('Year unknown'), findsOneWidget);
    expect(find.byType(PlexFilmTile), findsNWidgets(4));
    expect(
      tester.getTopLeft(find.text('Ten Rooms')).dy,
      greaterThan(tester.getTopLeft(find.text('Élan du matin')).dy),
      reason: '2019 after 2021',
    );
    expect(
      tester.getTopLeft(find.text('Home cut')).dy,
      greaterThan(tester.getTopLeft(find.text('Ten Rooms')).dy),
      reason: 'the films without a year last',
    );
    expect(
      tester.getSemantics(tileOf('Élan du matin')),
      matchesSemantics(label: 'Élan du matin, 2021', isButton: true, hasTapAction: true, hasLongPressAction: true),
    );
    expect(find.byKey(const Key('plex_films_scrubber')), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('plex_films_scrubber')),
        matching: find.byIcon(Icons.unfold_more_rounded),
      ),
      findsOneWidget,
      reason: 'drawn, and see-through while hidden',
    );
    final opacity = tester.widget<AnimatedOpacity>(
      find.descendant(of: find.byKey(const Key('plex_films_scrubber')), matching: find.byType(AnimatedOpacity)),
    );
    expect(opacity.opacity, 0, reason: 'four films fit on the screen: no scrubber');
  });

  testWidgets('the search shows the titles that hold the text, and Clear or Back shows every film again', (
    tester,
  ) async {
    await pumpFilms(tester);

    await tester.enterText(find.byKey(const Key('plex_films_search')), 'ROOM');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PlexFilmTile), findsNWidgets(4), reason: 'nothing before the 300 ms');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(PlexFilmTile), findsOneWidget);
    expect(tileOf('Ten Rooms'), findsOneWidget);
    expect(share.searched, ['ROOM'], reason: 'the spelling tolerant search too');

    await tester.enterText(find.byKey(const Key('plex_films_search')), 'nothing like it');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('No film matches “nothing like it”.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plex_films_search_clear')));
    await tester.pumpAndSettle();
    expect(find.byType(PlexFilmTile), findsNWidgets(4));

    await tester.enterText(find.byKey(const Key('plex_films_search')), 'room');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlexFilmsLibraryPage), findsOneWidget, reason: 'Back clears the search first');
    expect(find.byType(PlexFilmTile), findsNWidgets(4));
  });

  testWidgets('a tap plays the film by its own path, a long press opens its menu', (tester) async {
    await pumpFilms(tester);

    await tester.longPress(tileOf('Ten Rooms'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex_film_menu_play')), findsOneWidget);
    expect(find.text('Ten Rooms'), findsWidgets);
    await tester.tap(find.byKey(const Key('plex_film_menu_play')));
    await tester.pumpAndSettle();
    expect(find.text('video plex /.films/1/3/1003/Ten Rooms.mkv'), findsOneWidget);
  });

  testWidgets('a tap opens the page another lot gives, when it gives one', (tester) async {
    await pumpFilms(
      tester,
      overrides: [
        // A stand in for the film page of lot A2
        plexFilmOpenRouteProvider.overrideWithValue(
          (target) => NetworkPhotoRoute(sourceId: target.sourceId, path: '/film/${target.film.ratingKey}'),
        ),
      ],
    );
    await tester.tap(tileOf('Home cut'));
    await tester.pumpAndSettle();
    expect(find.text('photo plex /film/4'), findsOneWidget);
  });

  testWidgets('a tap opens the film page of lot A2, for the file Play opens there', (tester) async {
    await pumpFilms(tester);
    await tester.tap(tileOf('Ten Rooms'));
    await tester.pumpAndSettle();
    expect(find.text('film plex 3 /.films/1/3/1003/Ten Rooms.mkv'), findsOneWidget);
  });

  testWidgets('the filter button opens the filters of lot A2 without an order, and the list keeps what they keep', (
    tester,
  ) async {
    await pumpFilms(
      tester,
      overrides: [plexFilmFilterOptionsProvider.overrideWith((ref, key) async => const PlexFilmFilterOptions())],
    );
    expect(tileOf('Ten Rooms'), findsOneWidget);
    expect(find.byIcon(Icons.filter_list_rounded), findsOneWidget);
    await tester.tap(find.byKey(const Key('plex_films_filters')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex_film_filters')), findsOneWidget);
    // The films page orders its years newest first: the sheet offers no other order
    expect(find.byKey(const Key('plex_film_sort_title')), findsNothing);
    await tester.tap(find.byKey(const Key('plex_film_unwatched')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plex_film_filters_apply')));
    await tester.pumpAndSettle();
    final parameters = share.asked.last.queryParameters();
    expect(parameters['unwatched'], '1');
    expect(parameters['sort'], 'year:desc,titleSort');
    expect(tileOf('Ten Rooms'), findsNothing);
    expect(tileOf('The Example Night'), findsOneWidget);
    expect(find.byIcon(Icons.filter_alt_rounded), findsOneWidget);
  });

  testWidgets('the menu of a film offers Download and Play on on a phone, neither on a TV', (tester) async {
    final root = Directory.systemTemp.createTempSync('films_menu_');
    addTearDown(() => root.deleteSync(recursive: true));
    final films = FakeFilmEnvironment(root, FakeDownloadShare({}));
    addTearDown(films.close);
    await pumpFilms(
      tester,
      overrides: [
        filmDownloadEnvironmentProvider.overrideWithValue(films.environment),
        filmDownloadOfferedProvider.overrideWithValue(true),
        isHorizonOsProvider.overrideWith((ref) async => false),
      ],
    );
    // The app asks once at its start whether it runs on a Quest (main.dart)
    unawaited(
      ProviderScope.containerOf(tester.element(find.byType(PlexFilmsLibraryPage))).read(isHorizonOsProvider.future),
    );
    await tester.pump();
    await tester.longPress(tileOf('Ten Rooms'));
    await tester.pumpAndSettle();
    final download = find.byKey(ValueKey('plex_film_menu_${Icons.download_rounded.codePoint}'));
    final playOn = find.byKey(ValueKey('plex_film_menu_${Icons.cast_rounded.codePoint}'));
    expect(download, findsOneWidget);
    expect(playOn, findsOneWidget);
    expect(find.text('Download to this device'), findsOneWidget);
  });

  testWidgets('the menu of a film on a TV has Play and no Download nor Play on', (tester) async {
    await pumpFilms(tester, tvMode: true);
    await tester.longPress(tileOf('Ten Rooms'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex_film_menu_play')), findsOneWidget);
    expect(find.byKey(ValueKey('plex_film_menu_${Icons.download_rounded.codePoint}')), findsNothing);
    expect(find.byKey(ValueKey('plex_film_menu_${Icons.cast_rounded.codePoint}')), findsNothing);
  });

  testWidgets('the page menu shows the folders of the library', (tester) async {
    final router = await pumpFilms(tester);
    await tester.tap(find.byKey(const Key('plex_films_menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plex_films_show_folders')));
    await tester.pumpAndSettle();
    expect(router.current.name, NetworkBrowserRoute.name);
    expect(router.current.argsAs<NetworkBrowserRouteArgs>().path, '/Movies');
  });

  testWidgets('on a TV: seven posters a row, the first one focused, no scrubber', (tester) async {
    share = _PlexShare([for (var i = 0; i < 10; i++) _film(i + 1, 'Film $i', 2020)]);
    await pumpFilms(tester, tvMode: true, size: const Size(960, 540));

    final first = tester.getTopLeft(tileOf('Film 0')).dy;
    expect(tester.getTopLeft(tileOf('Film 6')).dy, first);
    expect(tester.getTopLeft(tileOf('Film 7')).dy, greaterThan(first));
    expect(find.byKey(const Key('plex_films_scrubber')), findsNothing);
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused?.findAncestorWidgetOfExactType<PlexFilmTile>()?.film.title, 'Film 0');
  });

  testWidgets('on a TV the arrows go from poster to poster, and Up from the first row to the search field', (
    tester,
  ) async {
    share = _PlexShare([for (var i = 0; i < 20; i++) _film(i + 1, 'Film $i', 2020)]);
    await pumpFilms(tester, tvMode: true, size: const Size(960, 540));
    String? focusedFilm() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<PlexFilmTile>()?.film.title;

    expect(focusedFilm(), 'Film 0');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(focusedFilm(), 'Film 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(focusedFilm(), 'Film 8', reason: 'seven a row');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(focusedFilm(), isNull);
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      find
              .descendant(of: find.byWidget(focused.widget), matching: find.byKey(const Key('plex_films_search')))
              .evaluate()
              .isNotEmpty ||
          focused.findAncestorWidgetOfExactType<TvTextEntry>() != null,
      isTrue,
      reason: 'the search field, which OK opens in the TV keyboard dialog',
    );
  });

  testWidgets('the scrubber shows once the list moves, and dragged it moves the list and tells the year', (
    tester,
  ) async {
    share = _PlexShare([for (var i = 0; i < 400; i++) _film(i + 1, 'Film $i', 2020 - i ~/ 10)]);
    await pumpFilms(tester, size: const Size(400, 800));
    final scrubber = find.byKey(const Key('plex_films_scrubber'));
    final strip = tester.getRect(scrubber);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
    await tester.pump();
    final gesture = await tester.startGesture(Offset(strip.center.dx, strip.top + 60));
    await gesture.moveBy(const Offset(0, 40));
    await gesture.moveTo(Offset(strip.center.dx, strip.top + strip.height / 2));
    await tester.pump();
    final bubble = find.byKey(const Key('plex_films_scrubber_year'));
    expect(bubble, findsOneWidget);
    final year = int.parse(tester.widget<Text>(find.descendant(of: bubble, matching: find.byType(Text))).data!);
    expect(year, inInclusiveRange(1995, 2005), reason: 'about halfway down 2020 to 1981');
    expect(find.text('Film 0'), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(bubble, findsNothing);
  });

  testWidgets('Ctrl F and the slash go to the search field', (tester) async {
    await pumpFilms(tester);
    final field = find.byKey(const Key('plex_films_search'));
    final focusNode = tester.widget<TextField>(field).focusNode!;
    expect(focusNode.hasFocus, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'the slash is no text');
  });

  testWidgets('the folder view opens a film library on its films page, other folders as folders', (tester) async {
    await pumpFilms(
      tester,
      home: const NetworkBrowserPage(sourceId: 'plex', path: '/'),
    );
    await tester.tap(find.widgetWithText(NetworkFolderTile, 'Movies'));
    await tester.pumpAndSettle();
    expect(find.text('films plex 1 Movies /Movies'), findsOneWidget);
  });
}
