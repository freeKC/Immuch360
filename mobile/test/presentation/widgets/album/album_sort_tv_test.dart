// The sort button of the albums with a remote control: a dialog that keeps the focus (the menu let the arrows go to
// the albums under it), its title translated, the current mode marked and focused first, a new mode sorts and the
// current one reverses the order, Back changes nothing; phones keep the menu.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/presentation/widgets/album/album_selector.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

import '../../../unit/presentation/presentation_context.dart';

/// No albums, and the sorts the selector asks for
class _Albums extends RemoteAlbumNotifier {
  _Albums(this.sorts);

  final List<(AlbumSortMode, bool)> sorts;

  @override
  RemoteAlbumState build() => const RemoteAlbumState(albums: []);

  @override
  Future<void> refresh() async {}

  @override
  Future<List<RemoteAlbum>> sortAlbums(List<RemoteAlbum> albums, AlbumSortMode sortMode, {bool isReverse = false}) {
    sorts.add((sortMode, isReverse));
    return Future.value(albums);
  }

  @override
  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) => albums;
}

void main() {
  late PresentationContext context;
  late List<(AlbumSortMode, bool)> sorts;

  setUp(() async {
    context = await PresentationContext.create();
    sorts = [];
  });

  tearDown(() async {
    await context.dispose();
  });

  Future<void> pumpAlbums(WidgetTester tester, {required bool tvMode}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
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
            tvModeProvider.overrideWithValue(tvMode),
            remoteAlbumProvider.overrideWith(() => _Albums(sorts)),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              // As main.dart does
              builder: (context, child) => TvShell(enabled: tvMode, child: child!),
              home: Scaffold(
                body: CustomScrollView(
                  slivers: [
                    AlbumSelector(onAlbumSelected: (_) {}),
                    // Where the menu let the focus go: the albums under the sort button
                    SliverToBoxAdapter(
                      child: TextButton(onPressed: () {}, child: const Text('an album')),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sortButton(String label) => find.ancestor(of: find.text(label), matching: find.byType(RemoteFocusable));

  Finder option(AlbumSortMode mode) => find.byKey(ValueKey('album_sort_${mode.name}'));

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == focused;
      if (!found) {
        focused.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> openWithOk(WidgetTester tester, String label) async {
    Focus.of(tester.element(find.text(label))).requestFocus();
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.select);
  }

  group('on TV', () {
    testWidgets('OK opens a dialog that keeps the focus, with the current mode marked and focused', (tester) async {
      await pumpAlbums(tester, tvMode: true);
      // The default: most recent photo, reversed
      await openWithOk(tester, 'Most recent photo');

      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('Sort albums by...'), findsOneWidget);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(tester.widget<ListTile>(option(AlbumSortMode.mostRecent)).selected, isTrue);
      expect(tester.widget<ListTile>(option(AlbumSortMode.title)).selected, isFalse);
      expect(focusedIn(option(AlbumSortMode.mostRecent)), isTrue);
      // Most recent sorts newest first by default, reversed here: the arrow up, as on the button
      expect(
        find.descendant(of: option(AlbumSortMode.mostRecent), matching: find.byIcon(Icons.keyboard_arrow_up_rounded)),
        findsOneWidget,
      );

      for (final key in [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowUp]) {
        for (var i = 0; i < AlbumSortMode.values.length + 2; i++) {
          await press(tester, key);
          expect(focusedIn(find.byType(SimpleDialog)), isTrue, reason: '$key ${i + 1}');
          expect(focusedIn(find.text('an album')), isFalse);
        }
      }
      // Up to the top: the first mode
      expect(focusedIn(option(AlbumSortMode.values.first)), isTrue);
    });

    testWidgets('OK on another mode sorts by it, OK on the current mode reverses the order', (tester) async {
      await pumpAlbums(tester, tvMode: true);
      sorts.clear();
      await openWithOk(tester, 'Most recent photo');
      for (var i = 0; i < AlbumSortMode.values.length; i++) {
        await press(tester, LogicalKeyboardKey.arrowUp);
      }
      expect(focusedIn(option(AlbumSortMode.title)), isTrue);

      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(SimpleDialog), findsNothing);
      expect(sorts.last, (AlbumSortMode.title, false));
      expect(find.text('Album title'), findsOneWidget);
      // Back on the button
      expect(focusedIn(sortButton('Album title')), isTrue);
      // Album title sorts A to Z by default
      expect(
        find.descendant(of: sortButton('Album title'), matching: find.byIcon(Icons.keyboard_arrow_up_rounded)),
        findsOneWidget,
      );

      await press(tester, LogicalKeyboardKey.select);
      expect(focusedIn(option(AlbumSortMode.title)), isTrue);
      await press(tester, LogicalKeyboardKey.select);

      expect(sorts.last, (AlbumSortMode.title, true));
      expect(
        find.descendant(of: sortButton('Album title'), matching: find.byIcon(Icons.keyboard_arrow_down)),
        findsOneWidget,
      );
    });

    testWidgets('Back closes the dialog without a change', (tester) async {
      await pumpAlbums(tester, tvMode: true);
      sorts.clear();
      await openWithOk(tester, 'Most recent photo');
      await press(tester, LogicalKeyboardKey.arrowUp);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(SimpleDialog), findsNothing);
      expect(sorts, isEmpty);
      expect(find.text('Most recent photo'), findsOneWidget);
    });

    testWidgets('the title follows the language', (tester) async {
      await pumpAlbums(tester, tvMode: true);
      await tester.element(find.byType(AlbumSelector)).setLocale(const Locale('fr'));
      await tester.pumpAndSettle();
      await openWithOk(tester, 'Photo la plus récente');

      expect(find.text('Trier les albums par...'), findsOneWidget);
    });
  });

  testWidgets('phones keep the menu', (tester) async {
    await pumpAlbums(tester, tvMode: false);
    await tester.tap(sortButton('Most recent photo'));
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(find.byType(MenuItemButton), findsNWidgets(AlbumSortMode.values.length));

    await tester.tap(find.widgetWithText(MenuItemButton, 'Album title'));
    await tester.pumpAndSettle();
    expect(sorts.last, (AlbumSortMode.title, false));
  });
}
