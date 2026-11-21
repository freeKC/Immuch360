import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/display_rate_pacer.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

/// The window of a Meta Quest follows the display while a video plays, and rests otherwise
void main() {
  /// How many of 60 pumps of 16 ms leave a frame asked for: one per refresh while the pacer runs, none at rest
  Future<int> framesAskedOverASecond(WidgetTester tester) async {
    var asked = 0;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (tester.binding.hasScheduledFrame) {
        asked++;
      }
    }
    return asked;
  }

  Widget pacer({required bool active, bool tickersEnabled = true}) => Directionality(
    textDirection: TextDirection.ltr,
    child: TickerMode(
      enabled: tickersEnabled,
      child: DisplayRatePacer(active: active, child: const Text('video')),
    ),
  );

  testWidgets('asks for a frame at every refresh while active, and shows its child', (tester) async {
    await tester.pumpWidget(pacer(active: true));
    expect(find.text('video'), findsOneWidget);
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('asks for nothing while inactive', (tester) async {
    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);
  });

  testWidgets('starts when the video plays and stops when it pauses', (tester) async {
    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);

    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    // Playing again after a pause
    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('a page covered by another route (tickers muted) asks for nothing', (tester) async {
    await tester.pumpWidget(pacer(active: true, tickersEnabled: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('leaving the tree stops it', (tester) async {
    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);
  });

  group('VideoDisplayRatePacer', () {
    const key = 'video';

    /// The pacer of the video [key], on a Meta Quest or not, with the player shown or not
    Future<ProviderContainer> pacerOf(WidgetTester tester, {required bool horizonOs, bool enabled = true}) async {
      final container = ProviderContainer(overrides: [isHorizonOsProvider.overrideWith((ref) async => horizonOs)]);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: VideoDisplayRatePacer(playerKey: key, enabled: enabled, child: const Text('video')),
          ),
        ),
      );
      // The answer of the platform
      await tester.pump();
      await tester.pump();
      return container;
    }

    void setPlayer(ProviderContainer container, {VideoPlaybackStatus? status, Duration? position}) {
      final notifier = container.read(videoPlayerProvider(key).notifier);
      // ignore: invalid_use_of_protected_member
      notifier.state = notifier.state.copyWith(
        status: status ?? notifier.state.status,
        position: position ?? notifier.state.position,
      );
    }

    /// How many of 60 pumps of 16 ms leave a frame asked for, the position moving by [step] every 100 ms (the rate of
    /// the native player) when given
    Future<int> framesAsked(WidgetTester tester, ProviderContainer container, {Duration? step}) async {
      var asked = 0;
      for (var i = 0; i < 60; i++) {
        if (step != null && i % 6 == 0) {
          setPlayer(container, position: container.read(videoPlayerProvider(key)).position + step);
        }
        await tester.pump(const Duration(milliseconds: 16));
        if (tester.binding.hasScheduledFrame) {
          asked++;
        }
      }
      return asked;
    }

    testWidgets('on a Meta Quest, follows the display while the video plays and rests when it pauses', (tester) async {
      final container = await pacerOf(tester, horizonOs: true);
      expect(find.text('video'), findsOneWidget);
      expect(await framesAsked(tester, container), 0);

      setPlayer(container, status: VideoPlaybackStatus.playing);
      expect(await framesAsked(tester, container, step: const Duration(milliseconds: 100)), 60);

      setPlayer(container, status: VideoPlaybackStatus.paused);
      await tester.pump(VideoDisplayRatePacer.advancingHold);
      expect(await framesAsked(tester, container), 0);
    });

    testWidgets('on a phone or a TV, asks for nothing, playing or not', (tester) async {
      final container = await pacerOf(tester, horizonOs: false);
      setPlayer(container, status: VideoPlaybackStatus.playing);
      expect(await framesAsked(tester, container, step: const Duration(milliseconds: 100)), 0);

      // Its status says paused while the position moves
      setPlayer(container, status: VideoPlaybackStatus.paused);
      await tester.pump();
      expect(await framesAsked(tester, container, step: const Duration(milliseconds: 100)), 0);
    });

    testWidgets('on a Meta Quest, follows the display while the position advances with the status paused', (
      tester,
    ) async {
      // After the immersive viewer gave the video back: the native player plays, the status says paused
      final container = await pacerOf(tester, horizonOs: true);
      expect(container.read(videoPlayerProvider(key)).status, VideoPlaybackStatus.paused);
      expect(await framesAsked(tester, container, step: const Duration(milliseconds: 100)), 60);

      // The position stops: the window rests once the hold is over
      await tester.pump(VideoDisplayRatePacer.advancingHold);
      expect(await framesAsked(tester, container), 0);
    });

    testWidgets('a seek back while paused is not playback', (tester) async {
      final container = await pacerOf(tester, horizonOs: true);
      setPlayer(container, position: const Duration(seconds: 30));
      await tester.pump(VideoDisplayRatePacer.advancingHold);
      setPlayer(container, position: const Duration(seconds: 10));
      await tester.pump();
      expect(await framesAsked(tester, container), 0);
    });

    testWidgets('on a Meta Quest, rests while the video waits', (tester) async {
      final container = await pacerOf(tester, horizonOs: true);
      setPlayer(container, status: VideoPlaybackStatus.buffering);
      await tester.pump();
      expect(await framesAsked(tester, container), 0);

      // The player's own timer of the wait goes with it
      await tester.pumpWidget(const SizedBox());
      container.dispose();
    });

    testWidgets('on a Meta Quest, rests when the player is not shown', (tester) async {
      final hidden = await pacerOf(tester, horizonOs: true, enabled: false);
      setPlayer(hidden, status: VideoPlaybackStatus.playing);
      await tester.pump();
      expect(await framesAsked(tester, hidden, step: const Duration(milliseconds: 100)), 0);
    });
  });
}
