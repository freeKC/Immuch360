// A timeline on a 1080p TV, the 360° list among others: a header of one bar instead of the tall picture header, tiles
// sized so that a whole row shows on the first screen inside the overscan margins, and device thumbnails asked large
// enough to cover their tile. The same in the Photos tab, under the tab shell. Out of the remote control layout the
// timeline is the one of a phone.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';
import 'package:immich_mobile/presentation/widgets/timeline/fixed/segment.model.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/widgets/common/mesmerizing_sliver_app_bar.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  // The store and the settings that the thumbnails read
  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  /// [count] 360° photos of the device, 2:1
  List<BaseAsset> panoramas(int count) =>
      List<BaseAsset>.generate(count, (i) => LocalAssetStub.image1.copyWith(id: 'pano$i', width: 5760, height: 2880));

  /// The timeline of [count] panoramas on its own page, or as the Photos tab of the tab shell when [inTabShell]
  Future<void> pumpTimeline(
    WidgetTester tester, {
    required bool tvMode,
    int count = 12,
    bool inTabShell = false,
  }) async {
    final assets = panoramas(count);
    if (tvMode) {
      // A Google TV at 1920 x 1080 and 320 dpi: 960 x 540 logical pixels
      tester.view
        ..physicalSize = const Size(1920, 1080)
        ..devicePixelRatio = 2;
    } else {
      tester.view
        ..physicalSize = const Size(1206, 2622)
        ..devicePixelRatio = 3;
    }
    addTearDown(tester.view.reset);

    final service = TimelineService((
      assetSource: (i, n) async => assets.sublist(i, math.min(i + n, assets.length)),
      bucketSource: () => Stream.value([TimeBucket(date: DateTime(2026, 10, 5), assetCount: assets.length)]),
      origin: TimelineOrigin.main,
    ));
    addTearDown(service.dispose);

    const timeline = Timeline(
      withScrubber: false,
      groupBy: GroupAssetsBy.day,
      appBar: MesmerizingSliverAppBar(title: '360°'),
    );
    // The other tabs build lazily, never in these tests
    AutoRoute tab(String name, String path, {bool initial = false}) => AutoRoute(
      path: path,
      initial: initial,
      page: PageInfo(name, builder: (_) => initial ? timeline : const SizedBox.shrink()),
    );
    final router = RootStackRouter.build(
      routes: [
        if (inTabShell)
          AutoRoute(
            path: '/',
            initial: true,
            page: PageInfo(TabShellRoute.name, builder: (_) => const TabShellPage()),
            children: [
              tab(MainTimelineRoute.name, 'photos', initial: true),
              tab(SearchRoute.name, 'search'),
              tab(AlbumsRoute.name, 'albums'),
              tab(LibraryRoute.name, 'library'),
            ],
          )
        else
          AutoRoute(initial: true, page: PageInfo('Panorama360', builder: (_) => timeline)),
      ],
    );

    final Widget app = ProviderScope(
      overrides: [
        timelineServiceProvider.overrideWithValue(service),
        appConfigProvider.overrideWithValue(const AppConfig()),
        tvModeProvider.overrideWithValue(tvMode),
        if (inTabShell) readonlyModeProvider.overrideWith(_NotReadOnly.new),
      ],
      child: Builder(
        builder: (context) => MaterialApp.router(
          routerConfig: router.config(),
          // As main.dart does
          builder: (context, child) => tvMode ? TvShell(child: child!) : child!,
          // The labels of the tabs come through EasyLocalization
          localizationsDelegates: inTabShell ? context.localizationDelegates : null,
          supportedLocales: inTabShell ? context.supportedLocales : const [Locale('en', 'US')],
          locale: inTabShell ? context.locale : null,
        ),
      ),
    );
    await tester.pumpWidget(
      inTabShell
          ? EasyLocalization(
              supportedLocales: locales.values.toList(),
              path: translationsPath,
              startLocale: locales.values.first,
              fallbackLocale: locales.values.first,
              saveLocale: false,
              useFallbackTranslations: true,
              assetLoader: const CodegenLoader(),
              child: app,
            )
          : app,
    );
    // Segments, then the assets of the rows
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // The thumbnails of the device do not load in a test
    tester.takeException();
  }

  Finder tiles() => find.byType(ThumbnailTile);

  group('on a 1080p TV', () {
    testWidgets('a header of one bar, and a whole row of tiles on the first screen inside the margins', (tester) async {
      await pumpTimeline(tester, tvMode: true);

      final bar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
      expect(bar.expandedHeight, isNull, reason: 'one bar, not the picture header of 300 dp');
      expect(bar.pinned, isTrue);
      expect(find.text('360°'), findsOneWidget, reason: 'the title shows in the bar');
      final rects = [for (final tile in tiles().evaluate()) tester.getRect(find.byWidget(tile.widget))];
      expect(rects, isNotEmpty);
      final firstRow = rects.where((rect) => (rect.top - rects.first.top).abs() < 1).toList();
      expect(firstRow.length, greaterThanOrEqualTo(6), reason: 'tiles of about 150 dp, not the 4 of a phone');
      const screen = Size(960, 540);
      for (final rect in firstRow) {
        expect(rect.left, greaterThanOrEqualTo(TvShell.overscan.left - 0.5), reason: 'inside the left margin');
        expect(rect.right, lessThanOrEqualTo(screen.width - TvShell.overscan.right + 0.5));
        expect(rect.bottom, lessThanOrEqualTo(screen.height - TvShell.overscan.bottom), reason: 'the row shows whole');
      }
    });

    /// Down to the last row, then up five rows: the focused tile and its ring stay inside the overscan margins
    Future<void> expectArrowsKeepFocusInsideMargins(WidgetTester tester) async {
      const screenHeight = 540.0;
      // How far the ring reaches out of the tile, its dark outline included
      const ring = TvFocusRing.gap + TvFocusRing.strokeWidth + 1;
      final barBottom = tester.getRect(find.byType(AppBar)).bottom;
      Focus.of(tester.element(tiles().first)).requestFocus();
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);

      // 48 tiles make fewer rows than presses: the last ones stay on the last row
      for (var press = 1; press <= 12; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        final rect = FocusManager.instance.primaryFocus!.rect;
        expect(
          rect.bottom + ring,
          lessThanOrEqualTo(screenHeight - TvShell.overscan.bottom + 0.5),
          reason: 'Down $press times: the row and its ring above the bottom margin, not flush with the screen',
        );
        expect(rect.top - ring, greaterThanOrEqualTo(barBottom - 0.5), reason: 'Down $press times: under the bar');
      }
      final scrolled = scrollable.position.pixels;
      expect(scrolled, scrollable.position.maxScrollExtent, reason: 'down to the end of the grid');

      for (var press = 1; press <= 5; press++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        final rect = FocusManager.instance.primaryFocus!.rect;
        expect(
          rect.top - ring,
          greaterThanOrEqualTo(barBottom + TvShell.overscan.top - 0.5),
          reason: 'Up $press times: the row and its ring a margin under the bar, not flush with it',
        );
      }
      expect(scrollable.position.pixels, lessThan(scrolled), reason: 'the rows above came back into view');
    }

    testWidgets('the arrows keep the focused tile and its ring inside the overscan margins, down and up', (
      tester,
    ) async {
      await pumpTimeline(tester, tvMode: true, count: 48);
      await expectArrowsKeepFocusInsideMargins(tester);
    });

    testWidgets('in the Photos tab too, where the empty bottom bar of the tab shell takes the bottom padding away', (
      tester,
    ) async {
      await pumpTimeline(tester, tvMode: true, count: 48, inTabShell: true);
      expect(find.byType(NavigationRail), findsOneWidget, reason: 'landscape: the rail, and an empty bottom bar');
      final tab = tester.element(find.byType(Timeline));
      expect(MediaQuery.paddingOf(tab).bottom, 0, reason: 'what the Scaffold of the tab shell hands down');
      await expectArrowsKeepFocusInsideMargins(tester);
    });

    testWidgets('a thumbnail is smoothed as it is drawn smaller than decoded, fine detail without speckles', (
      tester,
    ) async {
      await pumpTimeline(tester, tvMode: true);

      final thumbnail = tester.widget<Thumbnail>(
        find.descendant(of: tiles().first, matching: find.byType(Thumbnail)).first,
      );
      expect(
        thumbnail.filterQuality,
        FilterQuality.medium,
        reason: 'mipmaps: the thumbnails of a TV come larger than their tile',
      );
    });

    testWidgets('a device thumbnail is asked large enough to cover its tile, a 2:1 photo included', (tester) async {
      await pumpTimeline(tester, tvMode: true);

      final tile = tiles().first;
      final physical = tester.getSize(tile) * 2;
      final provider = tester.widget<Thumbnail>(find.descendant(of: tile, matching: find.byType(Thumbnail)).first);
      final local = provider.imageProvider! as LocalThumbProvider;
      // Android fits the thumbnail inside the size asked, aspect kept: a 2:1 photo needs a box twice as wide as the
      // tile is high for its height to fill the tile
      final fitted = Size(
        math.min(local.size.width, local.size.height * 2),
        math.min(local.size.height, local.size.width / 2),
      );
      expect(fitted.height, greaterThanOrEqualTo(physical.height - 1), reason: 'not stretched up, so not blurred');
      expect(fitted.width, greaterThanOrEqualTo(physical.width - 1));
    });
  });

  group('on a phone', () {
    testWidgets('the picture header, the tiles per row of the settings and thumbnails of the usual size', (
      tester,
    ) async {
      await pumpTimeline(tester, tvMode: false);

      expect(tester.widget<SliverAppBar>(find.byType(SliverAppBar)).expandedHeight, 300);
      final rects = [for (final tile in tiles().evaluate()) tester.getRect(find.byWidget(tile.widget))];
      final firstRow = rects.where((rect) => (rect.top - rects.first.top).abs() < 1);
      expect(firstRow.length, 4, reason: 'the 4 tiles per row of the settings');
      expect(firstRow.first.left, 0, reason: 'from the edge of the screen');
      final provider = tester.widget<Thumbnail>(find.descendant(of: tiles().first, matching: find.byType(Thumbnail)));
      expect((provider.imageProvider! as LocalThumbProvider).size, kThumbnailResolution);
      expect(provider.filterQuality, FilterQuality.low, reason: 'as before');
    });
  });

  testWidgets('a thumbnail paints its image with the filter quality asked', (tester) async {
    final image = (await tester.runAsync(() => createTestImage(width: 64, height: 32)))!;
    addTearDown(image.dispose);
    Future<void> pumpThumbnail(FilterQuality? quality) => tester.pumpWidget(
      Center(
        child: SizedBox.square(
          dimension: 16,
          child: quality == null
              ? Thumbnail(key: UniqueKey(), imageProvider: _ImageOf(image))
              : Thumbnail(key: UniqueKey(), imageProvider: _ImageOf(image), filterQuality: quality),
        ),
      ),
    );
    PaintPattern paintsWith(FilterQuality quality) => paints
      ..something((method, arguments) => method == #drawImageRect && (arguments[3] as Paint).filterQuality == quality);

    await pumpThumbnail(FilterQuality.medium);
    expect(find.byType(Thumbnail), paintsWith(FilterQuality.medium));

    await pumpThumbnail(null);
    expect(find.byType(Thumbnail), paintsWith(FilterQuality.low), reason: 'the default, a phone');
  });

  group('tvThumbnailDecodeSize', () {
    LocalAsset photo(int? width, int? height) => LocalAssetStub.image1.copyWith(width: width, height: height);

    test('covers a square tile with a wide photo, an upright one, and one of unknown size', () {
      const tile = Size.square(286);
      expect(tvThumbnailDecodeSize(photo(5760, 2880), tile), const Size.square(572));
      expect(tvThumbnailDecodeSize(photo(3000, 4000), tile), const Size.square(382));
      expect(tvThumbnailDecodeSize(photo(null, null), tile), const Size.square(286));
    });

    test('stays a thumbnail of the device, at most 768 px', () {
      expect(tvThumbnailDecodeSize(photo(8000, 1000), const Size.square(300)), const Size.square(768));
    });
  });

  group('tvTimelineColumnCount', () {
    test('tiles of at most 160 dp, never fewer than the setting asks', () {
      expect(tvTimelineColumnCount(864, 4), 6);
      expect(tvTimelineColumnCount(864, 8), 8);
      expect(tvTimelineColumnCount(0, 4), 4, reason: 'the zero sized first frame');
    });
  });
}

class _NotReadOnly extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

/// [image] at once, as a decoded thumbnail in the cache
class _ImageOf extends ImageProvider<_ImageOf> {
  const _ImageOf(this.image);

  final ui.Image image;

  @override
  Future<_ImageOf> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_ImageOf key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image.clone())));
}
