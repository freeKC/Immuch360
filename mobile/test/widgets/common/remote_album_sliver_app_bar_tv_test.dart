// An album of the server on a TV (the remote control layout): its header of 400 dp puts the first tile under the bottom
// of a TV screen of 540 dp, so the page opens with the first tile focused and scrolled into view, which cuts the
// header with the name of the album at its bottom. The bar then shows the name, whenever the header is cut. Up from
// the first tile goes to the Back arrow and brings the page back to its top, the header whole again with the name, the
// dates and the count; Down goes back to the first tile. On a phone the bar shows the name only once the header is
// folded, as in Immich.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/widgets/common/remote_album_sliver_app_bar.dart';

import '../../unit/presentation/presentation_context.dart';

final _album = RemoteAlbum(
  id: 'album-1',
  name: 'Panoramas',
  ownerId: 'owner-1',
  description: '',
  createdAt: DateTime(2024, 11, 9),
  updatedAt: DateTime(2024, 11, 9),
  isActivityEnabled: false,
  order: AlbumAssetOrder.desc,
  assetCount: 18,
  ownerName: 'Owner',
  isShared: false,
);

class _CurrentAlbum extends CurrentAlbumNotifier {
  @override
  RemoteAlbum? build() => _album;
}

/// The app with the real navigation observer, and a button that opens the album
class _App extends ConsumerStatefulWidget {
  const _App({required this.localizations});

  final BuildContext localizations;

  @override
  ConsumerState<_App> createState() => _AppState();
}

class _AppState extends ConsumerState<_App> {
  late final _observer = AppNavigationObserver(ref: ref);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    localizationsDelegates: widget.localizations.localizationDelegates,
    supportedLocales: widget.localizations.supportedLocales,
    locale: widget.localizations.locale,
    navigatorObservers: [_observer],
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const _AlbumPage())),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

/// The page of an album of the server: its bar over the header of its first month and a grid of tiles of 160 dp, six
/// to a row, as the timeline lays them out on a 1080p TV
class _AlbumPage extends StatelessWidget {
  const _AlbumPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: CustomScrollView(
      slivers: [
        RemoteAlbumSliverAppBar(
          kebabMenu: IconButton(icon: const Icon(Icons.more_vert), tooltip: 'Menu', onPressed: () {}),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 125, child: Text('November 2024'))),
        SliverGrid.count(
          crossAxisCount: 6,
          children: [
            for (var i = 0; i < 18; i++)
              InkWell(
                key: ValueKey('tile $i'),
                onTap: () {},
                child: Center(child: Text('tile $i')),
              ),
          ],
        ),
      ],
    ),
  );
}

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final firstTile = find.byKey(const ValueKey('tile 0'));
  final firstTileText = find.text('tile 0');
  final back = find.byIcon(Icons.arrow_back);
  final scrollable = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable));

  /// The name of the album in the bar, not in the header under it
  final nameInBar = find.descendant(of: find.byType(NavigationToolbar), matching: find.text(_album.name));

  /// The name of the album at the bottom of the header
  final nameInHeader = find.descendant(of: find.byType(FlexibleSpaceBar), matching: find.text(_album.name));

  bool hasFocus(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasPrimaryFocus;

  double offset(WidgetTester tester) => tester.state<ScrollableState>(scrollable).position.pixels;

  bool whollyOnScreen(WidgetTester tester, Finder finder) {
    final rect = tester.getRect(finder);
    return rect.top >= 0 && rect.bottom <= 540;
  }

  /// Opens the album on a TV screen of 960 x 540 dp, in the remote control layout when [tvMode]
  Future<void> openAlbum(WidgetTester tester, {required bool tvMode}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final timeline = TimelineService((
      assetSource: (index, count) async => const [],
      bucketSource: () => Stream.value(const <Bucket>[]),
      origin: TimelineOrigin.remoteAlbum,
    ));
    addTearDown(timeline.dispose);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
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
            timelineServiceProvider.overrideWithValue(timeline),
            currentRemoteAlbumProvider.overrideWith(_CurrentAlbum.new),
            remoteAlbumDateRangeProvider.overrideWith(
              (ref, _) => Stream.value((DateTime(2024, 11, 9, 9), DateTime(2024, 11, 9, 18))),
            ),
            remoteAlbumSharedUsersProvider.overrideWith((ref, _) async => const <UserDto>[]),
          ],
          child: Builder(builder: (localizations) => _App(localizations: localizations)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('on a TV', () {
    testWidgets('the first tile takes the focus and comes into view, and the bar shows the name over the cut header', (
      tester,
    ) async {
      await openAlbum(tester, tvMode: true);

      expect(hasFocus(tester, firstTileText), isTrue, reason: 'OK opens it, Down goes on in the grid');
      expect(whollyOnScreen(tester, firstTile), isTrue, reason: 'scrolled up from under the screen');
      expect(offset(tester), greaterThan(0), reason: 'the header is cut');
      expect(nameInBar, findsOneWidget, reason: 'the name of the album stays in sight');
      expect(tester.getRect(nameInBar).top, greaterThanOrEqualTo(0));
    });

    testWidgets('Up from the first tile goes to Back and brings the page back to its top, the header whole', (
      tester,
    ) async {
      await openAlbum(tester, tvMode: true);
      expect(hasFocus(tester, firstTileText), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      expect(hasFocus(tester, back), isTrue);
      expect(offset(tester), 0, reason: 'the page is back at its top');
      final name = tester.getRect(nameInHeader);
      final header = tester.getRect(find.byType(FlexibleSpaceBar));
      expect(name.top, greaterThanOrEqualTo(header.top));
      expect(name.bottom, lessThanOrEqualTo(header.bottom), reason: 'the name shows whole at the bottom of the header');
      expect(header.bottom, 400, reason: 'the header whole');
      expect(nameInBar, findsNothing, reason: 'the header shows it');
    });

    testWidgets('Down from Back then goes back to the first tile, in view', (tester) async {
      await openAlbum(tester, tvMode: true);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(hasFocus(tester, back), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(hasFocus(tester, firstTileText), isTrue);
      expect(whollyOnScreen(tester, firstTile), isTrue);
      expect(nameInBar, findsOneWidget);
    });
  });

  testWidgets('on a phone the bar shows the name only once the header is folded, as in Immich', (tester) async {
    await openAlbum(tester, tvMode: false);
    final position = tester.state<ScrollableState>(scrollable).position;

    position.jumpTo(200);
    await tester.pumpAndSettle();
    expect(nameInBar, findsNothing, reason: 'the header is cut, not folded');

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(nameInBar, findsOneWidget);
  });
}
