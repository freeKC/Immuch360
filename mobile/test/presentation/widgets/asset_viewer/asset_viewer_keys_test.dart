// The asset viewer with a remote control: left and right go through the photos, and seek through a video that
// plays; info opens the details; the bars never take the focus while hidden, and the viewer takes it back when they
// hide; on a TV Back leaves the bars before it closes the viewer, and OK on the Back arrow of the top bar closes it.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
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

/// A player with nothing native behind it, that records the seeks
class _FakePlayer extends VideoPlayerNotifier {
  _FakePlayer(this.calls) {
    state = const VideoPlayerState(
      position: Duration(seconds: 30),
      duration: Duration(minutes: 2),
      status: VideoPlaybackStatus.playing,
    );
  }

  final List<String> calls;

  @override
  Future<void> play() async {
    calls.add('play');
    state = state.copyWith(status: VideoPlaybackStatus.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    state = state.copyWith(status: VideoPlaybackStatus.paused);
  }

  @override
  void seekTo(Duration position) {
    calls.add('seek ${position.inSeconds}');
    state = state.copyWith(position: position);
  }
}

void main() {
  late PresentationContext context;
  late int systemPops;
  final photos = <BaseAsset>[
    LocalAssetStub.image1,
    LocalAssetStub.image2,
    LocalAssetStub.image1.copyWith(id: 'local-third'),
  ];

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    systemPops = 0;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') {
        systemPops++;
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
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMessageHandler('dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle', null);
    await context.dispose();
  });

  TimelineService timelineOf(List<BaseAsset> assets) => TimelineService((
    assetSource: (index, count) async => assets.skip(index).take(count).toList(),
    bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
    origin: TimelineOrigin.main,
  ));

  Future<ProviderContainer> pumpViewer(
    WidgetTester tester,
    List<BaseAsset> assets, {
    bool tvMode = true,
    List<Override> overrides = const [],
    bool pushed = false,
  }) async {
    final timeline = timelineOf(assets);
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
            ...overrides,
            tvModeProvider.overrideWithValue(tvMode),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(assets[0])),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: pushed
                  ? Builder(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
                            ),
                          ),
                          child: const Text('open'),
                        ),
                      ),
                    )
                  : Material(child: AssetViewerPage(initialIndex: 0, timelineService: timeline)),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    if (pushed) {
      await tester.tap(find.text('open'));
      await settle(tester);
    }
    return ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester);
  }

  bool focusIn<T extends Widget>() =>
      FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<T>() != null;

  testWidgets('left and right go through the photos, as the next and previous keys do', (tester) async {
    final container = await pumpViewer(tester, photos);
    final jump = container.read(assetViewerJumpProvider);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 1);
    expect(container.read(assetViewerProvider).currentAsset, photos[1]);

    await press(tester, LogicalKeyboardKey.mediaTrackNext);
    expect(jump.currentIndex, 2);

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.mediaTrackPrevious);
    expect(jump.currentIndex, 0);
  });

  testWidgets('left and right seek through a video that plays', (tester) async {
    final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 120000);
    final calls = <String>[];
    await pumpViewer(
      tester,
      [video, ...photos],
      overrides: [videoPlayerProvider(video.id).overrideWith((ref) => _FakePlayer(calls))],
    );

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(calls, ['seek 40', 'seek 30', 'seek 20']);

    // Paused, the arrows go to the next asset
    await press(tester, LogicalKeyboardKey.select);
    expect(calls.last, 'pause');
    await press(tester, LogicalKeyboardKey.arrowRight);
    final container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));
    expect(container.read(assetViewerJumpProvider).currentIndex, 1);
  });

  testWidgets('info opens the details', (tester) async {
    await pumpViewer(tester, photos);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await press(tester, LogicalKeyboardKey.info);

    expect(events.whereType<ViewerShowDetailsEvent>(), isNotEmpty);
  });

  testWidgets('while the bars are hidden their buttons cannot take the focus, so no arrow lands there', (tester) async {
    final container = await pumpViewer(tester, photos);
    // The focus of each button, through its icon
    List<FocusNode> buttonsOf(Type bar) =>
        find.descendant(of: find.byType(bar), matching: find.byType(Icon)).evaluate().map(Focus.of).toList();
    expect(container.read(assetViewerProvider).showingControls, isFalse);
    expect(buttonsOf(ViewerTopAppBar), isNotEmpty);
    expect(buttonsOf(ViewerTopAppBar).where((node) => node.canRequestFocus), isEmpty);
    expect(buttonsOf(ViewerBottomAppBar).where((node) => node.canRequestFocus), isEmpty);

    container.read(assetViewerProvider.notifier).setControls(true);
    await settle(tester);
    expect(buttonsOf(ViewerTopAppBar).where((node) => node.canRequestFocus), isNotEmpty);
  });

  testWidgets('Up shows the bars and focuses the top one; when they hide, the viewer takes the keys again', (
    tester,
  ) async {
    final container = await pumpViewer(tester, photos);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(container.read(assetViewerProvider).showingControls, isTrue);
    expect(focusIn<ViewerTopAppBar>(), isTrue);

    container.read(assetViewerProvider.notifier).setControls(false);
    await settle(tester);
    expect(focusIn<ViewerTopAppBar>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(container.read(assetViewerJumpProvider).currentIndex, 1, reason: 'the next key is not lost');
  });

  testWidgets('on a TV Back leaves the bars first, then closes the viewer', (tester) async {
    final container = await pumpViewer(tester, photos);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<ViewerTopAppBar>(), isTrue);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(focusIn<ViewerTopAppBar>(), isFalse);
    expect(container.read(assetViewerProvider).showingControls, isFalse);
    expect(systemPops, 0);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(systemPops, 1);
  });

  testWidgets('on a TV OK on the Back arrow of the top bar closes the viewer', (tester) async {
    // A flat photo, nothing to do on it on a TV: the Back arrow is all the top bar has
    await pumpViewer(tester, photos, pushed: true);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<ViewerTopAppBar>(), isTrue);

    await press(tester, LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    tester.takeException();

    expect(find.byType(AssetViewer), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a phone closes the viewer at the first Back, as before', (tester) async {
    await pumpViewer(tester, photos, tvMode: false);
    await press(tester, LogicalKeyboardKey.arrowUp);

    await tester.binding.handlePopRoute();
    await settle(tester);

    expect(systemPops, 1);
  });
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  // The thumbnails cannot load here (no platform channels), which is beside the point
  tester.takeException();
}
