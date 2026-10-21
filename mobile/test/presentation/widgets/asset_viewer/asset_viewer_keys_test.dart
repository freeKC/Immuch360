// The asset viewer with a remote control: left and right go through the photos; on a TV through the videos too,
// whatever they do, while a keyboard of a phone seeks through a video that plays; on a TV OK shows the controls of a
// video with play and pause focused, any key brings them back and they hide 5 s after the last key while it plays;
// info and Menu open the details, and on a TV so does OK held 700 ms, which then acts on its release (held on play and
// pause, it presses the button once, never once per repeat); Up from play and pause reaches the top bar at once; the
// bars never take the focus while hidden, and the viewer takes it back when they hide; on a TV Back leaves the bars
// before it closes the viewer, and OK on the Back arrow of the top bar closes it.

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
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_details.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_bottom_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';
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
  _FakePlayer(this.calls, {VideoPlaybackStatus status = VideoPlaybackStatus.playing}) {
    state = VideoPlayerState(
      position: const Duration(seconds: 30),
      duration: const Duration(minutes: 2),
      status: status,
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

  @override
  Future<void> retry() async {
    calls.add('retry');
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
    // The remote control layout around the app, as main.dart has it: directional navigation, where every row of the
    // details takes the focus
    bool shell = false,
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
              builder: shell ? (context, child) => TvShell(enabled: tvMode, child: child!) : null,
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

  final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 120000);

  Future<ProviderContainer> pumpVideo(
    WidgetTester tester,
    List<String> calls, {
    bool tvMode = true,
    VideoPlaybackStatus status = VideoPlaybackStatus.playing,
  }) => pumpViewer(
    tester,
    [video, ...photos],
    tvMode: tvMode,
    overrides: [videoPlayerProvider(video.id).overrideWith((ref) => _FakePlayer(calls, status: status))],
  );

  bool showing(ProviderContainer container) => container.read(assetViewerProvider).showingControls;

  bool playPauseFocused(WidgetTester tester) =>
      Focus.of(tester.element(find.byType(AnimatedPlayPause))).hasPrimaryFocus;

  testWidgets('on a TV left and right go through the assets while a video plays, without the bars', (tester) async {
    final calls = <String>[];
    final container = await pumpVideo(tester, calls);
    final jump = container.read(assetViewerJumpProvider);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 1);
    expect(container.read(assetViewerProvider).currentAsset, photos[0]);
    expect(showing(container), isFalse, reason: 'going through a timeline does not flash the bars');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(jump.currentIndex, 0);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(jump.currentIndex, 1);
    expect(calls, isEmpty, reason: 'no seek');
  });

  testWidgets('on a TV left and right leave a video that loads and never plays', (tester) async {
    final container = await pumpVideo(tester, [], status: VideoPlaybackStatus.buffering);

    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(container.read(assetViewerJumpProvider).currentIndex, 1);
  });

  testWidgets('on a TV a video alone in its timeline seeks with left and right', (tester) async {
    final calls = <String>[];
    await pumpViewer(
      tester,
      [video],
      overrides: [videoPlayerProvider(video.id).overrideWith((ref) => _FakePlayer(calls))],
    );

    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowLeft);

    expect(calls, ['seek 40', 'seek 30', 'seek 20']);
  });

  testWidgets('on a TV OK shows the bars with play and pause focused, and a second OK pauses', (tester) async {
    final calls = <String>[];
    final container = await pumpVideo(tester, calls);

    await press(tester, LogicalKeyboardKey.select);
    expect(showing(container), isTrue);
    expect(playPauseFocused(tester), isTrue, reason: 'never the Back button: a second OK would close the viewer');
    expect(calls, isEmpty);

    await press(tester, LogicalKeyboardKey.select);
    expect(calls, ['pause']);

    // Right moves between the buttons of the bar now, to -10 s, which OK presses
    await press(tester, LogicalKeyboardKey.arrowRight);
    await press(tester, LogicalKeyboardKey.select);
    expect(calls, ['pause', 'seek 20']);
    expect(container.read(assetViewerJumpProvider).currentIndex, 0);
  });

  testWidgets('on a TV fast forward, rewind and play and pause keep their meaning, and show the bars', (tester) async {
    final calls = <String>[];
    final container = await pumpVideo(tester, calls);

    await press(tester, LogicalKeyboardKey.mediaFastForward);
    expect(calls, ['seek 40']);
    expect(showing(container), isTrue);

    container.read(assetViewerProvider.notifier).setControls(false);
    await press(tester, LogicalKeyboardKey.mediaPlayPause);
    expect(calls, ['seek 40', 'pause']);
    expect(showing(container), isTrue);

    await press(tester, LogicalKeyboardKey.mediaRewind);
    await press(tester, LogicalKeyboardKey.mediaPlay);
    expect(calls, ['seek 40', 'pause', 'seek 30', 'play']);
  });

  testWidgets('on a TV the bars of a video that plays hide 5 s after the last key, and any key brings them back', (
    tester,
  ) async {
    final container = await pumpVideo(tester, []);

    await press(tester, LogicalKeyboardKey.channelUp);
    expect(showing(container), isTrue);

    await tester.pump(const Duration(seconds: 3));
    // A key the viewer takes itself starts the 5 s again
    await press(tester, LogicalKeyboardKey.mediaFastForward);
    await tester.pump(const Duration(seconds: 3));
    expect(showing(container), isTrue, reason: '3.6 s after the last key');
    await tester.pump(const Duration(seconds: 2));
    expect(showing(container), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(showing(container), isFalse, reason: 'left and right leave the bars as they are');
    expect(container.read(assetViewerJumpProvider).currentIndex, 1);
  });

  testWidgets('on a TV the bars hide under play and pause, and the next key is not lost', (tester) async {
    final container = await pumpVideo(tester, []);

    await press(tester, LogicalKeyboardKey.select);
    expect(playPauseFocused(tester), isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(showing(container), isFalse);
    expect(focusIn<VideoControls>(), isFalse);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(container.read(assetViewerJumpProvider).currentIndex, 1);
  });

  testWidgets('on a TV the bars of a paused video stay', (tester) async {
    final container = await pumpVideo(tester, [], status: VideoPlaybackStatus.paused);

    await press(tester, LogicalKeyboardKey.select);
    await tester.pump(const Duration(seconds: 10));

    expect(showing(container), isTrue);
  });

  testWidgets('a keyboard of a phone seeks through a video that plays, and goes on once it is paused', (tester) async {
    final calls = <String>[];
    await pumpVideo(tester, calls, tvMode: false);

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

  testWidgets('a video that does not play lets left and right go to the next asset, as a paused one', (tester) async {
    final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 120000);
    final calls = <String>[];
    final container = await pumpViewer(
      tester,
      [video, ...photos],
      tvMode: false,
      overrides: [videoPlayerProvider(video.id).overrideWith((ref) => _FakePlayer(calls))],
    );

    container.read(videoPlayerProvider(video.id).notifier).onNativeError('Decoder init failed');
    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(calls, isEmpty, reason: 'no seek in a video that does not play');
    expect(container.read(assetViewerJumpProvider).currentIndex, 1);
    // The viewer probes the file of the failed video for the logs: its time limit runs out here
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('info opens the details', (tester) async {
    await pumpViewer(tester, photos);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await press(tester, LogicalKeyboardKey.info);

    expect(events.whereType<ViewerShowDetailsEvent>(), isNotEmpty);
  });

  testWidgets('Menu opens the details too: most remotes of Google TV have no info key', (tester) async {
    await pumpViewer(tester, photos);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await press(tester, LogicalKeyboardKey.contextMenu);

    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
  });

  testWidgets('on a TV OK held on a photo opens the details, and the rest of that press does nothing', (tester) async {
    final container = await pumpViewer(tester, photos);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 150));
    expect(events.whereType<ViewerShowDetailsEvent>(), isEmpty, reason: '650 ms');
    expect(showing(container), isFalse, reason: 'OK acts on its release on a TV');

    await tester.pump(const Duration(milliseconds: 100));
    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    await tester.pump();
    // The details show the bars with them, as the info key does
    final bars = showing(container);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    expect(events.whereType<ViewerHideDetailsEvent>(), isEmpty);
    expect(showing(container), bars, reason: 'the release is no short OK, which would hide the bars of a photo');
    expect(container.read(assetViewerJumpProvider).currentIndex, 0);

    // The next press is a plain OK again
    container.read(assetViewerProvider.notifier).setShowingDetails(false);
    await settle(tester);
    final before = showing(container);
    await press(tester, LogicalKeyboardKey.select);
    expect(showing(container), !before, reason: 'a short OK shows or hides the bars of a photo');
  });

  testWidgets('on a TV OK held on a video opens the details instead of focusing play and pause', (tester) async {
    final calls = <String>[];
    final container = await pumpVideo(tester, calls);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 300));
    expect(showing(container), isFalse, reason: 'held, OK does not show the controls yet');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);

    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    expect(focusIn<VideoControls>(), isFalse, reason: 'a short OK would focus play and pause');
    // The timers of the controls that the details showed run out
    await tester.pump(const Duration(seconds: 6));
  });

  // The repeats of a held OK as a remote sends them, every 50 ms from 500 ms on: from [from] to [until] after the key
  // went down
  Future<void> repeatOk(WidgetTester tester, {required Duration from, required Duration until}) async {
    const firstRepeat = Duration(milliseconds: 500);
    var held = from;
    if (held < firstRepeat) {
      await tester.pump(firstRepeat - held);
      held = firstRepeat;
    }
    while (held < until) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 50));
      held += const Duration(milliseconds: 50);
    }
  }

  testWidgets('on a TV OK held on play and pause presses it once, then opens the details', (tester) async {
    final calls = <String>[];
    await pumpVideo(tester, calls, status: VideoPlaybackStatus.paused);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);

    await press(tester, LogicalKeyboardKey.select);
    expect(playPauseFocused(tester), isTrue);
    expect(calls, isEmpty);

    // A short OK on the button: one press, and nothing more once the time of a hold is past
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await tester.pump(const Duration(seconds: 1));
    expect(calls, ['play']);
    expect(events.whereType<ViewerShowDetailsEvent>(), isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await repeatOk(tester, from: Duration.zero, until: const Duration(milliseconds: 650));
    expect(calls, ['play', 'pause'], reason: 'one press as the key went down, none for its three repeats');
    expect(events.whereType<ViewerShowDetailsEvent>(), isEmpty, reason: '650 ms');

    await repeatOk(tester, from: const Duration(milliseconds: 650), until: const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    expect(events.whereType<ViewerHideDetailsEvent>(), isEmpty, reason: 'the rest of the press closes nothing');
    // The details hold the video as they open (one more pause); the repeats pressed nothing
    expect(calls, ['play', 'pause', 'pause']);
    // The timers of the controls run out
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('on a TV OK held on play of a failed video tries it once, then opens the details', (tester) async {
    final calls = <String>[];
    final container = await pumpVideo(tester, calls);
    final events = <Event>[];
    final subscription = EventStream.shared.listen<Event>(events.add);
    addTearDown(subscription.cancel);
    container.read(videoPlayerProvider(video.id).notifier).onNativeError('Decoder init failed');
    await settle(tester);

    await press(tester, LogicalKeyboardKey.select);
    expect(playPauseFocused(tester), isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await repeatOk(tester, from: Duration.zero, until: const Duration(milliseconds: 650));
    expect(calls, ['retry'], reason: 'not a reload for every other repeat');

    await repeatOk(tester, from: const Duration(milliseconds: 650), until: const Duration(milliseconds: 1500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(events.whereType<ViewerShowDetailsEvent>(), hasLength(1));
    // The details hold the video as they open (a pause); the repeats pressed nothing
    expect(calls, ['retry', 'pause']);
    // The viewer probes the file of the failed video for the logs, and the controls have their timers: they run out
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('on a TV the details take the focus as they open, and the viewer has it again as they close', (
    tester,
  ) async {
    final container = await pumpViewer(tester, photos, shell: true);
    container.read(assetViewerProvider.notifier).setShowingDetails(true);
    await settle(tester);
    expect(focusIn<AssetDetails>(), isTrue, reason: 'their first row has it');

    container.read(assetViewerProvider.notifier).setShowingDetails(false);
    await settle(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(container.read(assetViewerJumpProvider).currentIndex, 1, reason: 'the viewer has the keys again');
  });

  testWidgets('a keyboard of a phone: OK acts as it goes down, held or not', (tester) async {
    final calls = <String>[];
    await pumpVideo(tester, calls, tvMode: false);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(calls, ['pause']);
    await tester.pump(const Duration(seconds: 1));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(calls, ['pause']);
  });

  testWidgets('on a TV Up from play and pause reaches the top bar in one press', (tester) async {
    await pumpVideo(tester, []);

    await press(tester, LogicalKeyboardKey.select);
    expect(playPauseFocused(tester), isTrue);

    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(focusIn<ViewerTopAppBar>(), isTrue);
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
