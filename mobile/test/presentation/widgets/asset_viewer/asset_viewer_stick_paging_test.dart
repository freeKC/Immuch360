// The thumbstick of a Meta Quest controller in the 2D window: MainActivity takes its sideways scrolls while the asset
// viewer asks for them, and sends one "page" call per push (QuestStickPaging.kt). The viewer goes to the next or the
// previous asset on it, stays on a zoomed photo, and asks for the pushes only on a Meta Quest, while it is the page on
// top and its details are hidden.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../unit/presentation/presentation_context.dart';

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset, showingControls: false);
  }
}

const _stickChannel = MethodChannel('immuch360/quest_stick');

void main() {
  late PresentationContext context;
  // What the viewer asked MainActivity, in order: true to take the pushes, false to leave them
  late List<Object?> pagingAsked;
  final photos = <BaseAsset>[
    LocalAssetStub.image1,
    LocalAssetStub.image2,
    LocalAssetStub.image1.copyWith(id: 'local-third'),
  ];

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    pagingAsked = [];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_stickChannel, (call) async {
      if (call.method == 'setPaging') {
        pagingAsked.add(call.arguments);
      }
      return null;
    });
    messenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_stickChannel, null);
    messenger.setMockMessageHandler('dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle', null);
    await context.dispose();
  });

  TimelineService timelineOf(List<BaseAsset> assets) => TimelineService((
    assetSource: (index, count) async => assets.skip(index).take(count).toList(),
    bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
    origin: TimelineOrigin.main,
  ));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The thumbnails cannot load here (no platform channels), which is beside the point
    tester.takeException();
  }

  /// The viewer on a Meta Quest, or on another Android device with [quest] false
  Future<ProviderContainer> pumpViewer(WidgetTester tester, {bool quest = true}) async {
    final timeline = timelineOf(photos);
    addTearDown(timeline.dispose);
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
            tvModeProvider.overrideWithValue(false),
            isHorizonOsProvider.overrideWith((ref) async => quest),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(photos[0])),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  // A push of the thumbstick as MainActivity sends it: 1 to the right, -1 to the left
  Future<void> push(WidgetTester tester, int step) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      _stickChannel.name,
      _stickChannel.codec.encodeMethodCall(MethodCall('page', step)),
      (_) {},
    );
    await settle(tester);
  }

  testWidgets('a push to the right goes to the next photo, to the left to the previous one', (tester) async {
    final container = await pumpViewer(tester);
    final jump = container.read(assetViewerJumpProvider);

    await push(tester, 1);
    expect(jump.currentIndex, 1);
    expect(container.read(assetViewerProvider).currentAsset, photos[1]);

    await push(tester, 1);
    expect(jump.currentIndex, 2);

    await push(tester, -1);
    expect(jump.currentIndex, 1);
  });

  testWidgets('a push past the last photo stays on it', (tester) async {
    final container = await pumpViewer(tester);
    final jump = container.read(assetViewerJumpProvider);

    await push(tester, -1);
    expect(jump.currentIndex, 0);
    await push(tester, 1);
    await push(tester, 1);
    await push(tester, 1);
    expect(jump.currentIndex, 2);
  });

  testWidgets('a zoomed photo stays where it is', (tester) async {
    final container = await pumpViewer(tester);
    final jump = container.read(assetViewerJumpProvider);
    container.read(assetViewerProvider.notifier).setZoomed(true);
    await settle(tester);

    await push(tester, 1);
    expect(jump.currentIndex, 0);

    container.read(assetViewerProvider.notifier).setZoomed(false);
    await settle(tester);
    await push(tester, 1);
    expect(jump.currentIndex, 1);
  });

  testWidgets('the viewer asks for the pushes while it is open, and leaves them once it closes', (tester) async {
    await pumpViewer(tester);
    expect(pagingAsked, [true]);

    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);

    expect(pagingAsked, [true, false]);
  });

  testWidgets('a page pushed over the viewer keeps the scrolls of the stick, and the viewer takes them back after it', (
    tester,
  ) async {
    final container = await pumpViewer(tester);
    final jump = container.read(assetViewerJumpProvider);
    final navigator = Navigator.of(tester.element(find.byType(AssetViewer)));

    final over = navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('over'))));
    await settle(tester);
    expect(pagingAsked, [true, false]);
    await push(tester, 1);
    expect(jump.currentIndex, 0, reason: 'the viewer under the page does not move');

    navigator.pop();
    await over;
    await settle(tester);
    expect(pagingAsked, [true, false, true]);
    await push(tester, 1);
    expect(jump.currentIndex, 1);
  });

  testWidgets('a phone, a tablet or a TV box never asks for the pushes: its scrolls stay as they were', (tester) async {
    final container = await pumpViewer(tester, quest: false);
    final jump = container.read(assetViewerJumpProvider);
    expect(pagingAsked, isEmpty);

    container.read(assetViewerProvider.notifier).setShowingDetails(true);
    await settle(tester);
    container.read(assetViewerProvider.notifier).setShowingDetails(false);
    await settle(tester);
    await push(tester, 1);
    expect(jump.currentIndex, 0);

    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    expect(pagingAsked, isEmpty);
  });

  testWidgets('the details keep the scrolls of the stick for their own lists, and the viewer takes them back after', (
    tester,
  ) async {
    final container = await pumpViewer(tester);
    final jump = container.read(assetViewerJumpProvider);
    expect(pagingAsked, [true]);

    container.read(assetViewerProvider.notifier).setShowingDetails(true);
    await settle(tester);
    expect(pagingAsked, [true, false]);
    await push(tester, 1);
    expect(jump.currentIndex, 0, reason: 'the people row of the details scrolls instead');

    container.read(assetViewerProvider.notifier).setShowingDetails(false);
    await settle(tester);
    expect(pagingAsked, [true, false, true]);
    await push(tester, 1);
    expect(jump.currentIndex, 1);
  });
}
