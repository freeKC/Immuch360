// A quick series of seeks in the asset viewer, with the real player state and a native player whose seeks take half a
// second, as on the TV emulator: on a TV the presses of left and right on a video alone and on its time bar, and the
// fast forward keys; on a phone the arrows of a keyboard while the video plays. Each press goes from where the one
// before takes the video, whatever the native player still reports of the seeks on their way: on build 33 a series
// that changed direction ended where an earlier press had put the video (right three times then left: no move at all).

import 'dart:async';
import 'dart:math';

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
import 'package:immich_mobile/presentation/widgets/tv/remote_seek_series.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

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

class _MockNativeVideoPlayerController extends Mock implements NativeVideoPlayerController {}

class _MockPlaybackInfo extends Mock implements PlaybackInfo {}

class _MockVideoInfo extends Mock implements VideoInfo {}

/// The native player of Android as the viewer's player state hears it: a seek reaches it at once and lands [seekTime]
/// later; until then it tells where it was ([report], its position loop), then where it landed, never past [endMs],
/// and that it is ready again, as Media3 does after each seek
class _SlowNativePlayer {
  _SlowNativePlayer({required this.positionMs, required this.endMs, required this.status}) {
    final playbackInfo = _MockPlaybackInfo();
    when(() => playbackInfo.position).thenAnswer((_) => positionMs);
    when(() => playbackInfo.status).thenAnswer((_) => status);
    when(() => controller.playbackInfo).thenReturn(playbackInfo);
    final videoInfo = _MockVideoInfo();
    when(() => videoInfo.duration).thenReturn(endMs);
    when(() => controller.videoInfo).thenReturn(videoInfo);
    when(controller.play).thenAnswer((_) async => status = PlaybackStatus.playing);
    when(controller.pause).thenAnswer((_) async => status = PlaybackStatus.paused);
    when(() => controller.seekTo(any())).thenAnswer((invocation) async {
      final target = invocation.positionalArguments.first as int;
      seeks.add(target);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      positionMs = min(target, endMs);
      notifier?.onNativePositionChanged();
      notifier?.onNativePlaybackReady();
    });
  }

  final controller = _MockNativeVideoPlayerController();
  final int endMs;
  PlaybackStatus status;
  int positionMs;
  VideoPlayerNotifier? notifier;

  /// Where the native player was asked to go, in order
  final seeks = <int>[];

  /// The player tells where it is, whatever seek is under way
  void report() => notifier?.onNativePositionChanged();

  /// The player state of the viewer, with this native player behind it, ready
  VideoPlayerNotifier attach() {
    final notifier = this.notifier = VideoPlayerNotifier()..attachController(controller);
    notifier.onNativePlaybackReady();
    if (status == PlaybackStatus.playing) {
      notifier.onNativeStatusChanged();
    }
    return notifier;
  }
}

void main() {
  late PresentationContext context;
  final video = LocalAssetStub.image1.copyWith(id: 'video1', type: AssetType.video, durationMs: 360000);
  final photos = <BaseAsset>[LocalAssetStub.image1, LocalAssetStub.image2];

  setUp(() async {
    context = await PresentationContext.create();
    when(() => context.service.asset.service.watchAsset(any())).thenAnswer((_) => const Stream.empty());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      null,
    );
    await context.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // The thumbnails cannot load here (no platform channels), which is beside the point
    tester.takeException();
  }

  /// The viewer on [video] (alone in its timeline unless [withPhotos]) with [native] behind its player
  Future<void> pumpViewer(
    WidgetTester tester,
    _SlowNativePlayer native, {
    required bool tvMode,
    bool withPhotos = false,
  }) async {
    final assets = [video, if (withPhotos) ...photos];
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.skip(index).take(count).toList(),
      bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
      origin: TimelineOrigin.main,
    ));
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
            tvModeProvider.overrideWithValue(tvMode),
            assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(video)),
            videoPlayerProvider(video.id).overrideWith((ref) => native.attach()),
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
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(AssetViewer)));

  Duration shownPosition(WidgetTester tester) => containerOf(tester).read(videoPlayerProvider(video.id)).position;

  /// [keys] 390 ms apart, as `input keyevent` sent them on the TV emulator, the player telling where it is after each
  Future<void> quickSeries(WidgetTester tester, _SlowNativePlayer native, List<LogicalKeyboardKey> keys) async {
    for (final key in keys) {
      await tester.sendKeyEvent(key);
      await tester.pump(const Duration(milliseconds: 200));
      native.report();
      await tester.pump(const Duration(milliseconds: 190));
      native.report();
    }
  }

  /// Lets every seek land, the series and the controls run out
  Future<void> letItLand(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.pump(remoteSeekSeriesWindow);
    await tester.pump(const Duration(seconds: 6));
  }

  const right = LogicalKeyboardKey.arrowRight;
  const left = LogicalKeyboardKey.arrowLeft;

  testWidgets('on a TV right three times then left, quick, on a video alone: 10 + 30 + 60 - 10 s', (tester) async {
    final native = _SlowNativePlayer(positionMs: 3000, endMs: 360000, status: PlaybackStatus.paused);
    await pumpViewer(tester, native, tvMode: true);

    await quickSeries(tester, native, [right, right, right, left]);
    await letItLand(tester);

    expect(shownPosition(tester), const Duration(seconds: 93));
    expect(native.positionMs, 93000, reason: 'the video went there');
    expect(native.seeks.last, 93000);
  });

  testWidgets('on a TV left three times then right, and right twice then left, quick', (tester) async {
    final native = _SlowNativePlayer(positionMs: 180000, endMs: 360000, status: PlaybackStatus.paused);
    await pumpViewer(tester, native, tvMode: true);

    await quickSeries(tester, native, [left, left, left, right]);
    await letItLand(tester);
    expect(shownPosition(tester), const Duration(seconds: 90));
    expect(native.positionMs, 90000);

    await quickSeries(tester, native, [right, right, left]);
    await letItLand(tester);
    expect(shownPosition(tester), const Duration(seconds: 120));
    expect(native.positionMs, 120000);
  });

  testWidgets('on a TV the time bar: right three times then left, quick', (tester) async {
    final native = _SlowNativePlayer(positionMs: 3000, endMs: 360000, status: PlaybackStatus.paused);
    await pumpViewer(tester, native, tvMode: true, withPhotos: true);

    // OK shows the controls with play and pause focused, Down goes to the time bar under them
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await settle(tester);
    expect(Focus.of(tester.element(find.byType(AnimatedPlayPause))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(Focus.of(tester.element(find.byKey(const Key('video_time_bar')))).hasPrimaryFocus, isTrue);

    await quickSeries(tester, native, [right, right, right, left]);
    expect(find.text('01:33 / 06:00'), findsOneWidget, reason: 'the time shows the target of the series');
    await letItLand(tester);

    expect(shownPosition(tester), const Duration(seconds: 93));
    expect(native.positionMs, 93000);
  });

  testWidgets('on a TV the fast forward and rewind keys: three forward, two back, quick', (tester) async {
    final native = _SlowNativePlayer(positionMs: 133000, endMs: 360000, status: PlaybackStatus.paused);
    await pumpViewer(tester, native, tvMode: true, withPhotos: true);

    await quickSeries(tester, native, [
      LogicalKeyboardKey.mediaFastForward,
      LogicalKeyboardKey.mediaFastForward,
      LogicalKeyboardKey.mediaFastForward,
    ]);
    await letItLand(tester);
    expect(shownPosition(tester), const Duration(minutes: 2, seconds: 43));
    expect(native.positionMs, 163000);

    await quickSeries(tester, native, [LogicalKeyboardKey.mediaRewind, LogicalKeyboardKey.mediaRewind]);
    await letItLand(tester);
    expect(shownPosition(tester), const Duration(minutes: 2, seconds: 23));
    expect(native.positionMs, 143000);
  });

  testWidgets('a phone: the arrows of a keyboard on a video that plays, right three times then left, quick', (
    tester,
  ) async {
    final native = _SlowNativePlayer(positionMs: 30000, endMs: 360000, status: PlaybackStatus.playing);
    await pumpViewer(tester, native, tvMode: false, withPhotos: true);

    await quickSeries(tester, native, [right, right, right, left]);
    // The seeks landed, the video plays on from the last one
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(native.seeks.last, 50000);
    expect(native.positionMs, 50000);
    native
      ..positionMs = 50400
      ..report();
    expect(shownPosition(tester), const Duration(milliseconds: 50400), reason: 'the time follows the video again');
    await tester.pump(const Duration(seconds: 6));
  });
}
