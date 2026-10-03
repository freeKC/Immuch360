// The hook the immersive viewer of the Meta Quest moves the asset viewer with once it closes, and loads the timeline
// around the page on screen with after a search (see AssetViewerJump)

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset);
  }
}

void main() {
  late PresentationContext context;
  final assets = <BaseAsset>[
    LocalAssetStub.image1,
    LocalAssetStub.image2,
    LocalAssetStub.image1.copyWith(id: 'local-third'),
  ];

  setUp(() async {
    context = await PresentationContext.create();
    // The viewer follows the asset it shows, which nothing changes here
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await context.dispose();
  });

  TimelineService timelineOf(List<BaseAsset> assets) => TimelineService((
    assetSource: (index, count) async => assets.skip(index).take(count).toList(),
    bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
    origin: TimelineOrigin.main,
  ));

  Future<void> pumpViewer(
    WidgetTester tester,
    TimelineService timeline, {
    Widget? replacement,
    BaseAsset? first,
  }) async {
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
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(first ?? assets[0])),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Material(child: replacement ?? AssetViewerPage(initialIndex: 0, timelineService: timeline)),
            ),
          ),
        ),
      ),
    );
    // Lets the timeline load and the first frames run, without waiting for the loading spinners
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The thumbnails cannot load here (no platform channels), which is beside the point
    tester.takeException();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    tester.takeException();
  }

  // The page on screen shows its asset: its hero, rather than the spinner of a page that found no asset
  Finder heroOf(BaseAsset asset) =>
      find.byWidgetPredicate((widget) => widget is Hero && widget.tag == '${asset.heroTag}_0');

  testWidgets('tells the page on screen, and moves the viewer to another one of its timeline', (tester) async {
    final timeline = timelineOf(assets);
    addTearDown(timeline.dispose);
    await pumpViewer(tester, timeline);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    final jump = container.read(assetViewerJumpProvider);

    expect(jump.currentIndex, 0);

    unawaited(jump.jumpTo(2));
    await settle(tester);

    expect(jump.currentIndex, 2);
    expect(container.read(assetViewerProvider).currentAsset, assets[2]);

    unawaited(jump.jumpTo(7));
    await tester.pump();
    expect(jump.currentIndex, 2, reason: 'no such page');

    // Each asset viewer route has its own: the one of the whole app is not this one
    final root = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(identical(root.read(assetViewerJumpProvider), jump), isFalse);
    expect(root.read(assetViewerJumpProvider).currentIndex, isNull);

    // Once the viewer is gone, nothing moves
    await pumpViewer(tester, timeline, replacement: const SizedBox());
    expect(jump.currentIndex, isNull);
    await jump.jumpTo(1);
    await jump.recenter();
  });

  group('on a timeline longer than its buffer', () {
    // Past what the timeline loads at once (kTimelineAssetLoadBatchSize), so that a search far away moves its buffer
    final many = <BaseAsset>[
      for (var index = 0; index < 3000; index++) LocalAssetStub.image1.copyWith(id: 'local-$index'),
    ];

    testWidgets('jumps far from the buffer, the page showing its asset', (tester) async {
      final timeline = timelineOf(many);
      addTearDown(timeline.dispose);
      await pumpViewer(tester, timeline, first: many[0]);
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
      final jump = container.read(assetViewerJumpProvider);
      expect(timeline.hasRange(2000, 1), isFalse);

      unawaited(jump.jumpTo(2000));
      await settle(tester);

      expect(jump.currentIndex, 2000);
      expect(container.read(assetViewerProvider).currentAsset, many[2000]);
      expect(heroOf(many[2000]), findsOneWidget);
    });

    testWidgets('loads the timeline around the page on screen again, which shows its asset again', (tester) async {
      final timeline = timelineOf(many);
      addTearDown(timeline.dispose);
      await pumpViewer(tester, timeline, first: many[0]);
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
      final jump = container.read(assetViewerJumpProvider);
      expect(heroOf(many[0]), findsOneWidget);

      // A search reads the timeline far away, and a sync reloads it meanwhile: the page finds no asset in the buffer
      await timeline.loadAssets(2500, 32);
      EventStream.shared.emit(const TimelineReloadEvent());
      await settle(tester);
      expect(heroOf(many[0]), findsNothing);
      await timeline.loadAssets(2500, 32);

      unawaited(jump.recenter());
      await settle(tester);

      expect(timeline.hasRange(0, 2), isTrue);
      expect(jump.currentIndex, 0);
      expect(heroOf(many[0]), findsOneWidget);
    });

    testWidgets('loads the timeline around the page on screen again when it cannot jump', (tester) async {
      final timeline = timelineOf(many);
      addTearDown(timeline.dispose);
      await pumpViewer(tester, timeline, first: many[0]);
      final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
      final jump = container.read(assetViewerJumpProvider);

      // A search reads the timeline far away, and a sync reloads it meanwhile: the page finds no asset in the buffer
      await timeline.loadAssets(2500, 32);
      EventStream.shared.emit(const TimelineReloadEvent());
      await settle(tester);
      expect(heroOf(many[0]), findsNothing);
      await timeline.loadAssets(2500, 32);

      // The asset the immersive viewer closed on is past the end of the timeline now, after a deletion
      unawaited(jump.jumpTo(many.length + 10));
      await settle(tester);

      expect(jump.currentIndex, 0);
      expect(timeline.hasRange(0, 2), isTrue);
      expect(heroOf(many[0]), findsOneWidget);
    });
  });
}
