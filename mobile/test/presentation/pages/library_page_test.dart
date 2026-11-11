import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/plex_server_info.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_api.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_list.dart';
import 'package:immich_mobile/models/server_info/server_features.model.dart';
import 'package:immich_mobile/presentation/pages/library.page.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/locale_provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/plex_film_list.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/app_bar_dialog/app_bar_profile_info.dart';
import 'package:immich_mobile/widgets/common/app_bar_dialog/app_bar_server_info.dart';
import 'package:immich_mobile/widgets/common/immich_sliver_app_bar.dart';
import 'package:mocktail/mocktail.dart';

import '../../unit/presentation/presentation_context.dart';

/// Server info with the trash feature switched off
class _NoTrashServerInfo extends ServerInfoNotifier {
  _NoTrashServerInfo(super.service) {
    state = state.copyWith(
      serverFeatures: const ServerFeatures(map: true, trash: false, oauthEnabled: false, passwordLogin: true),
    );
  }
}

/// A session without a server, whatever the Store says
class _LocalSession extends LocalSessionNotifier {
  @override
  bool build() => true;
}

/// The shares of the app, whatever the Store says
class _Sources extends NetworkSourcesNotifier {
  _Sources(this.sources);

  final List<NetworkSource> sources;

  @override
  List<NetworkSource> build() => sources;
}

const _plex = NetworkSource(
  id: 'plex',
  type: NetworkSourceType.plex,
  name: 'Home Plex',
  host: '192.0.2.20',
  plex: PlexServerInfo(hash: '0123456789abcdef0123456789abcdef'),
);

/// A Plex server with the film library [libraries]
class _Films implements PlexFilmsSource {
  _Films(this.libraries);

  final List<PlexSection> libraries;

  @override
  String get filmsSourceId => _plex.id;

  @override
  bool get isOutsideHome => false;

  @override
  Future<List<({PlexSection section, String folderPath})>> filmLibraries() async => [
    for (final section in libraries) (section: section, folderPath: '/${section.title}'),
  ];

  @override
  PlexSection? filmLibraryAt(String path) => null;

  @override
  Future<List<int?>> filmYears(PlexFilmListQuery query) async => const [];

  @override
  Future<PlexFilmListPage> filmsPage(PlexFilmListQuery query, {required int start, required int size}) async =>
      const PlexFilmListPage(films: [], count: 0, offset: 0);

  @override
  Future<List<PlexFilm>> searchFilms(String sectionKey, String text) async => const [];
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final panoramaEntry = find.widgetWithText(FilledButton, '360°');
  final favoritesEntry = find.widgetWithText(FilledButton, 'Favorites');

  /// Pumps [library] (the Library shortcut buttons by default) under a real router whose other routes render a stub
  /// page, so a push can be observed. [local] runs it in a session without a server.
  Future<void> pumpLibraryButtons(
    WidgetTester tester, {
    bool trash = true,
    bool local = false,
    Widget library = const Scaffold(body: CustomScrollView(slivers: [LibraryActionButtonGrid()])),
    List<NetworkSource>? sources,
    List<Override> overrides = const [],
  }) async {
    final router = RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo(LibraryRoute.name, builder: (_) => library),
        ),
        AutoRoute(
          path: '/panorama-360',
          page: PageInfo(Panorama360Route.name, builder: (_) => const Text('360 timeline')),
        ),
        AutoRoute(
          path: '/favorites',
          page: PageInfo(FavoriteRoute.name, builder: (_) => const Text('favorites timeline')),
        ),
        AutoRoute(
          path: '/local-albums',
          page: PageInfo(LocalAlbumsRoute.name, builder: (_) => const Text('device albums')),
        ),
        AutoRoute(
          path: '/login',
          page: PageInfo(LoginRoute.name, builder: (_) => const Text('login page')),
        ),
        AutoRoute(
          path: '/plex-films',
          page: PageInfo(
            PlexFilmsLibraryRoute.name,
            builder: (data) {
              final args = data.argsAs<PlexFilmsLibraryRouteArgs>();
              return Text('films ${args.sourceId} ${args.sectionKey} ${args.title} ${args.folderPath}');
            },
          ),
        ),
      ],
    );

    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            ...context.overrides,
            ...overrides,
            if (sources != null) networkSourcesProvider.overrideWith(() => _Sources(sources)),
            if (!trash) serverInfoProvider.overrideWith((ref) => _NoTrashServerInfo(context.service.serverInfo)),
            if (local) ...[
              localSessionProvider.overrideWith(_LocalSession.new),
              localAlbumProvider.overrideWith((ref) => Stream.value(const [])),
              localeProvider.overrideWithValue(const Locale('en')),
            ],
          ],
          child: Builder(
            builder: (context) => MaterialApp.router(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              routerConfig: router.config(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Library 360° entry', () {
    testWidgets('sits next to Favorites, in the same style, with the 360 icon', (tester) async {
      await pumpLibraryButtons(tester);

      expect(panoramaEntry, findsOneWidget);
      expect(find.descendant(of: panoramaEntry, matching: find.byIcon(Icons.threesixty_rounded)), findsOneWidget);
      expect(favoritesEntry, findsOneWidget);

      final firstRow = find.ancestor(of: favoritesEntry, matching: find.byType(Row)).first;
      expect(find.descendant(of: firstRow, matching: panoramaEntry), findsOneWidget);
      expect(tester.getTopLeft(panoramaEntry).dy, tester.getTopLeft(favoritesEntry).dy);
      expect(tester.getTopLeft(panoramaEntry).dx, greaterThan(tester.getTopLeft(favoritesEntry).dx));
      expect(tester.getSize(panoramaEntry), tester.getSize(favoritesEntry));
    });

    testWidgets('opens the 360° timeline when tapped', (tester) async {
      await pumpLibraryButtons(tester);

      await tester.tap(panoramaEntry);
      await tester.pumpAndSettle();

      expect(find.text('360 timeline'), findsOneWidget);
    });

    testWidgets('keeps the other entries, trash included when the server has it', (tester) async {
      await pumpLibraryButtons(tester);

      for (final label in ['Favorites', '360°', 'Archived', 'Shared links', 'Trash']) {
        expect(find.widgetWithText(FilledButton, label), findsOneWidget, reason: label);
      }

      await tester.tap(favoritesEntry);
      await tester.pumpAndSettle();

      expect(find.text('favorites timeline'), findsOneWidget);
    });

    testWidgets('is still shown when the server has no trash', (tester) async {
      await pumpLibraryButtons(tester, trash: false);

      expect(panoramaEntry, findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Trash'), findsNothing);
    });
  });

  group('Library Films entry', () {
    const movies = PlexSection(key: '1', title: 'Movies', type: 'movie', agent: 'tv.plex.agents.movie');
    const kids = PlexSection(key: '3', title: 'Kids', type: 'movie', agent: 'tv.plex.agents.movie');
    final filmsEntry = find.widgetWithText(FilledButton, 'Films');

    testWidgets('is not there without a Plex server', (tester) async {
      await pumpLibraryButtons(tester, sources: const []);

      expect(filmsEntry, findsNothing);
    });

    testWidgets('opens the only film library of the Plex server on its films page', (tester) async {
      await pumpLibraryButtons(
        tester,
        sources: const [_plex],
        overrides: [
          plexFilmsSourceProvider.overrideWithValue((id) async => _Films(const [movies])),
        ],
      );

      expect(filmsEntry, findsOneWidget);
      await tester.tap(filmsEntry);
      await tester.pumpAndSettle();

      expect(find.text('films plex 1 Movies /Movies'), findsOneWidget);
    });

    testWidgets('asks which library when there are several, and says when there is none', (tester) async {
      var libraries = const [movies, kids];
      await pumpLibraryButtons(
        tester,
        sources: const [_plex],
        overrides: [plexFilmsSourceProvider.overrideWithValue((id) async => _Films(libraries))],
      );

      await tester.tap(filmsEntry);
      await tester.pumpAndSettle();
      expect(find.text('Choose a film library'), findsOneWidget);
      await tester.tap(find.text('Kids'));
      await tester.pumpAndSettle();
      expect(find.text('films plex 3 Kids /Kids'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      libraries = const [];
      await tester.tap(filmsEntry);
      await tester.pumpAndSettle();
      expect(find.textContaining('No film library on your Plex servers'), findsOneWidget);
    });
  });

  group('Library without a server', () {
    setUp(() {
      when(context.service.user.tryGetMyUser).thenReturn(null);
    });

    testWidgets('keeps only the 360° entry, which opens the 360° timeline', (tester) async {
      await pumpLibraryButtons(tester, local: true);

      expect(panoramaEntry, findsOneWidget);
      for (final label in ['Favorites', 'Archived', 'Shared links', 'Trash']) {
        expect(find.widgetWithText(FilledButton, label), findsNothing, reason: label);
      }

      await tester.tap(panoramaEntry);
      await tester.pumpAndSettle();

      expect(find.text('360 timeline'), findsOneWidget);
    });

    testWidgets('keeps only the albums of the device among the collections, and no quick access', (tester) async {
      await pumpLibraryButtons(tester, local: true, library: const LibraryPage());

      expect(find.text('On this device'), findsOneWidget);
      for (final label in ['People', 'Places', 'Memories', 'Folders', 'Locked Folder', 'Partners']) {
        expect(find.text(label), findsNothing, reason: label);
      }

      await tester.tap(find.text('On this device'));
      await tester.pumpAndSettle();

      expect(find.text('device albums'), findsOneWidget);
    });

    testWidgets('offers an Immich server where the entries of a server would be, which opens the login form', (
      tester,
    ) async {
      await pumpLibraryButtons(tester, local: true, library: const LibraryPage());
      final entry = find.byKey(const Key('library_connect_server'));

      await tester.dragUntilVisible(entry, find.byType(CustomScrollView).first, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.descendant(of: entry, matching: find.text('Connect to an Immich server')), findsOneWidget);
      expect(
        find.descendant(of: entry, matching: find.text('Sync with an Immich server to back up, search and share')),
        findsOneWidget,
      );

      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.text('login page'), findsOneWidget);
    });
  });

  group('App bar without a server', () {
    setUp(() {
      when(context.service.user.tryGetMyUser).thenReturn(null);
    });

    final connectEntry = find.text('Connect to a server');

    Future<void> openProfileDialog(WidgetTester tester) async {
      await pumpLibraryButtons(tester, local: true, library: const LibraryPage());
      await tester.tap(find.byIcon(Icons.face_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the face icon and no backup button', (tester) async {
      await pumpLibraryButtons(
        tester,
        local: true,
        library: const Scaffold(body: CustomScrollView(slivers: [ImmichSliverAppBar()])),
      );

      expect(find.byIcon(Icons.face_outlined), findsOneWidget);
      expect(find.byIcon(Icons.backup_rounded), findsNothing);
    });

    testWidgets('profile dialog describes the session instead of the account and the server', (tester) async {
      await openProfileDialog(tester);

      expect(find.text('This device only'), findsOneWidget);
      expect(
        find.text('The app shows the photos and videos of this device. Nothing is sent anywhere.'),
        findsOneWidget,
      );
      expect(find.byType(AppBarProfileInfoBox), findsNothing);
      expect(find.byType(AppBarServerInfo), findsNothing);
      expect(find.text('Server Storage'), findsNothing);
      for (final label in ['Sign Out', 'Free Up Space']) {
        expect(find.text(label), findsNothing, reason: label);
      }
      expect(find.text('Settings'), findsOneWidget);
      expect(connectEntry, findsOneWidget);
      verifyNever(() => context.service.serverInfo.getDiskInfo());
      verifyNever(context.service.user.refreshMyUser);
    });

    testWidgets('profile dialog opens the login page to connect a server', (tester) async {
      await openProfileDialog(tester);

      await tester.tap(connectEntry);
      await tester.pumpAndSettle();

      expect(find.text('login page'), findsOneWidget);
    });
  });
}
