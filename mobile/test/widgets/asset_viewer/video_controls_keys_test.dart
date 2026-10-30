// The controls of a video in the asset viewer hide 5 s after they show while it plays. A remote moving between them
// starts the 5 s again: they never hide under a user who is still using them, and hide 5 s after the last key. On a
// TV any key starts the 5 s again, they also hide while the video loads, show at its end, -10 s and +10 s buttons
// follow play and pause, and the time bar under them takes the remote: left and right on it seek, 10 s, then 30 s,
// then 60 s per press of a quick series, with the step on screen (the accelerated seek of Michael Cloutier's design
// note), and faster while held.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_seek_series.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/services/gcast.service.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';

import '../../service.mocks.dart';

class _Playing extends VideoPlayerNotifier {
  _Playing(VideoPlaybackStatus status, this.seeks, {Duration duration = const Duration(minutes: 1)}) {
    state = VideoPlayerState(position: const Duration(seconds: 3), duration: duration, status: status);
  }

  final List<Duration> seeks;

  @override
  void seekTo(Duration position) {
    seeks.add(position);
    state = state.copyWith(position: position);
  }

  @override
  Future<void> pause() async => state = state.copyWith(status: VideoPlaybackStatus.paused);

  @override
  Future<void> play() async => state = state.copyWith(status: VideoPlaybackStatus.playing);

  void setStatus(VideoPlaybackStatus status, {Duration? position}) =>
      state = state.copyWith(status: status, position: position ?? state.position);
}

void main() {
  late ProviderContainer container;
  final outside = FocusNode(debugLabel: 'the viewer');

  const wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUp(() {
    // The player lets the screen sleep again when it goes
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      wakelock,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelock, null);
  });

  tearDownAll(outside.dispose);

  late List<Duration> seeks;

  Future<void> pump(
    WidgetTester tester, {
    bool tvMode = false,
    VideoPlaybackStatus status = VideoPlaybackStatus.playing,
    Duration duration = const Duration(minutes: 1),
  }) async {
    seeks = [];
    container = ProviderContainer(
      overrides: [
        gCastServiceProvider.overrideWithValue(MockGCastService()),
        videoPlayerProvider('video').overrideWith((ref) => _Playing(status, seeks, duration: duration)),
        tvModeProvider.overrideWithValue(tvMode),
      ],
    );
    addTearDown(container.dispose);
    container.read(assetViewerProvider.notifier).setControls(true);
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: UncontrolledProviderScope(
          container: container,
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(
                body: Column(
                  children: [
                    Focus(focusNode: outside, child: const SizedBox(height: 100)),
                    const VideoControls(videoPlayerName: 'video'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  bool showing() => container.read(assetViewerProvider).showingControls;

  // A video that loads has its stall check running (VideoPlayerNotifier.stallTimeout): pausing it stops the check, and
  // starts no hide timer
  void stopLoading() =>
      (container.read(videoPlayerProvider('video').notifier) as _Playing).setStatus(VideoPlaybackStatus.paused);

  testWidgets('hide 5 s after they show while the video plays', (tester) async {
    await pump(tester);

    await tester.pump(const Duration(seconds: 4));
    expect(showing(), isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(showing(), isFalse);
  });

  testWidgets('a key inside the controls starts the 5 s again', (tester) async {
    await pump(tester);
    // The play button has the focus, as after Down in the viewer
    Focus.of(
      tester.element(find.descendant(of: find.byType(IconButton), matching: find.byType(AnimatedPlayPause))),
    ).requestFocus();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 3));
    expect(showing(), isTrue, reason: '6 s after they showed, 3 s after the key');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 4));
    expect(showing(), isTrue);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(showing(), isFalse, reason: '5 s after the last key');
  });

  testWidgets('a key elsewhere does not keep them', (tester) async {
    await pump(tester);
    outside.requestFocus();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));

    expect(showing(), isFalse);
  });

  testWidgets('on a TV a key elsewhere, one the viewer takes itself, starts the 5 s again', (tester) async {
    await pump(tester, tvMode: true);
    outside.requestFocus();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.mediaFastForward);
    await tester.pump(const Duration(seconds: 3));
    expect(showing(), isTrue, reason: '6 s after they showed, 3 s after the key');
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    expect(showing(), isFalse, reason: '5 s after the last key');
  });

  testWidgets('on a TV they hide while the video loads too', (tester) async {
    await pump(tester, tvMode: true, status: VideoPlaybackStatus.buffering);

    await tester.pump(const Duration(seconds: 5, milliseconds: 100));

    expect(showing(), isFalse);
    stopLoading();
  });

  testWidgets('a phone keeps them while the video loads, as before', (tester) async {
    await pump(tester, status: VideoPlaybackStatus.buffering);

    await tester.pump(const Duration(seconds: 10));

    expect(showing(), isTrue);
    stopLoading();
  });

  testWidgets('paused, they stay', (tester) async {
    await pump(tester, tvMode: true, status: VideoPlaybackStatus.paused);

    await tester.pump(const Duration(seconds: 10));

    expect(showing(), isTrue);
  });

  testWidgets('on a TV they show when the video ends, not when a video just loaded is reported ended', (tester) async {
    await pump(tester, tvMode: true);
    final player = container.read(videoPlayerProvider('video').notifier) as _Playing;
    await tester.pump(const Duration(seconds: 6));
    expect(showing(), isFalse);

    player.setStatus(VideoPlaybackStatus.completed, position: Duration.zero);
    await tester.pump();
    expect(showing(), isFalse, reason: 'at its start: a video just loaded');

    player.setStatus(VideoPlaybackStatus.playing);
    await tester.pump(const Duration(seconds: 6));
    player.setStatus(VideoPlaybackStatus.completed, position: const Duration(minutes: 1));
    await tester.pump();
    expect(showing(), isTrue);
    await tester.pump(const Duration(seconds: 10));
    expect(showing(), isTrue, reason: 'ended, they stay');
  });

  testWidgets('on a TV -10 s and +10 s follow play and pause, and seek within the video', (tester) async {
    await pump(tester, tvMode: true);
    final back = find.byKey(const Key('video_controls_seek_back'));
    final forward = find.byKey(const Key('video_controls_seek_forward'));
    expect(back, findsOneWidget);
    expect(forward, findsOneWidget);
    expect(find.byIcon(Icons.replay_10), findsOneWidget);
    expect(find.byIcon(Icons.forward_10), findsOneWidget);

    // Play and pause first, where OK puts the focus; right from there reaches -10 s, then +10 s
    Focus.of(
      tester.element(find.descendant(of: find.byType(IconButton), matching: find.byType(AnimatedPlayPause))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(seeks, [Duration.zero], reason: '3 s back from 3 s: the start, not before');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(seeks, [Duration.zero, const Duration(seconds: 10)]);

    for (var i = 0; i < 6; i++) {
      await tester.tap(forward);
      await tester.pump();
    }
    expect(seeks.last, const Duration(minutes: 1), reason: 'not past the end');
  });

  testWidgets('a phone has no -10 s and +10 s buttons', (tester) async {
    await pump(tester);

    expect(find.byKey(const Key('video_controls_seek_back')), findsNothing);
    expect(find.byKey(const Key('video_controls_seek_forward')), findsNothing);
  });

  testWidgets('on a TV Down from the buttons reaches the time bar, where left and right seek, faster while held', (
    tester,
  ) async {
    await pump(tester, tvMode: true);
    final player = container.read(videoPlayerProvider('video').notifier) as _Playing;
    Focus.of(
      tester.element(find.descendant(of: find.byType(IconButton), matching: find.byType(AnimatedPlayPause))),
    ).requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Video time bar');
    expect(
      tester
          .widget<ExcludeFocus>(find.ancestor(of: find.byType(Slider), matching: find.byType(ExcludeFocus)).first)
          .excluding,
      isTrue,
      reason: 'the bar takes the keys, never the slider, which would keep the arrows',
    );

    // Presses apart, each of its own series: 10 s each
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(remoteSeekSeriesWindow);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(remoteSeekSeriesWindow);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(remoteSeekSeriesWindow);
    expect(seeks, const [Duration(seconds: 13), Duration(seconds: 23), Duration(seconds: 13)]);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Video time bar', reason: 'the arrows stay on the bar');

    // Held: the video waits, the steps grow, and it plays on once the key is released
    seeks.clear();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    for (var i = 0; i < 25; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    }
    await tester.pump();
    expect(player.state.status, VideoPlaybackStatus.paused, reason: 'held');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.first, const Duration(seconds: 23));
    expect(seeks[1], const Duration(seconds: 25), reason: '2 s per repeat at first');
    expect(seeks.last, const Duration(minutes: 1), reason: 'faster after a second, and not past the end');
    expect(player.state.status, VideoPlaybackStatus.playing);

    // OK plays and pauses, Up goes back to the buttons
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(player.state.status, VideoPlaybackStatus.paused);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('Video time bar'));
  });

  /// Down from play and pause to the time bar of a TV
  Future<void> focusTimeBar(WidgetTester tester) async {
    Focus.of(
      tester.element(find.descendant(of: find.byType(IconButton), matching: find.byType(AnimatedPlayPause))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Video time bar');
  }

  final hint = find.byKey(const Key('video_seek_hint'));

  /// The hint shows the way of the last press and its step
  void expectHint({required bool forward, required int seconds}) {
    expect(hint, findsOneWidget);
    expect(
      find.descendant(
        of: hint,
        matching: find.byIcon(forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded),
      ),
      findsOneWidget,
    );
    expect(find.descendant(of: hint, matching: find.text('$seconds s')), findsOneWidget);
  }

  testWidgets('on a TV a quick series on the time bar moves 10 s, then 30 s, then 60 s, the step on screen', (
    tester,
  ) async {
    await pump(tester, tvMode: true, duration: const Duration(minutes: 10));
    await focusTimeBar(tester);
    expect(hint, findsNothing);
    const quick = Duration(milliseconds: 500);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, const [Duration(seconds: 13)]);
    expectHint(forward: true, seconds: 10);
    await tester.pump(quick);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expectHint(forward: true, seconds: 30);
    await tester.pump(quick);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expectHint(forward: true, seconds: 60);
    await tester.pump(quick);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks, const [Duration(seconds: 13), Duration(seconds: 43), Duration(seconds: 103), Duration(seconds: 163)]);
    expectHint(forward: true, seconds: 60);

    // 1.5 s without a press: the hint goes, and the next press moves 10 s again
    await tester.pump(remoteSeekSeriesWindow);
    expect(hint, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.last, const Duration(seconds: 173));
    expectHint(forward: true, seconds: 10);

    // The other way starts a series of its own
    await tester.pump(quick);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(seeks.last, const Duration(seconds: 163));
    expectHint(forward: false, seconds: 10);
    await tester.pump(quick);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(seeks.last, const Duration(seconds: 133));
    expectHint(forward: false, seconds: 30);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Video time bar', reason: 'the arrows stay on the bar');
    await tester.pump(remoteSeekSeriesWindow);
  });

  testWidgets('on a TV a series stops at the start and at the end of the video', (tester) async {
    await pump(tester, tvMode: true);
    await focusTimeBar(tester);

    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(seeks, const [Duration(seconds: 13), Duration(seconds: 43), Duration(minutes: 1)]);

    await tester.pump(remoteSeekSeriesWindow);
    seeks.clear();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(seeks, const [Duration(seconds: 50), Duration(seconds: 20), Duration.zero]);
    await tester.pump(remoteSeekSeriesWindow);
  });

  testWidgets('on a TV a held key keeps its own ramp and ends the series', (tester) async {
    await pump(tester, tvMode: true, duration: const Duration(minutes: 10));
    await focusTimeBar(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    // Held within the series: its press is one of the series (30 s), its repeats follow the ramp of a held key
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(hint, findsNothing, reason: 'held, the bar shows where the video goes');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 300));
    expect(seeks, const [Duration(seconds: 13), Duration(seconds: 43), Duration(seconds: 45), Duration(seconds: 47)]);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(seeks.last, const Duration(seconds: 57), reason: 'after a held key the next press moves 10 s');
    expectHint(forward: true, seconds: 10);
    await tester.pump(remoteSeekSeriesWindow);
  });

  testWidgets('on a TV -10 s and +10 s stay 10 s, however quick', (tester) async {
    await pump(tester, tvMode: true, duration: const Duration(minutes: 10));
    final forward = find.byKey(const Key('video_controls_seek_forward'));
    for (var i = 0; i < 3; i++) {
      await tester.tap(forward);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(seeks, const [Duration(seconds: 13), Duration(seconds: 23), Duration(seconds: 33)]);
    expect(hint, findsNothing);
  });

  testWidgets('a phone has no seek hint', (tester) async {
    await pump(tester);
    expect(find.byType(VideoSeekHint), findsNothing);
  });

  testWidgets('elsewhere the time bar is the plain slider, which takes the focus as before', (tester) async {
    await pump(tester);
    expect(find.ancestor(of: find.byType(Slider), matching: find.byType(ExcludeFocus)), findsNothing);
    expect(find.byKey(const Key('video_time_bar')), findsNothing);
  });
}
