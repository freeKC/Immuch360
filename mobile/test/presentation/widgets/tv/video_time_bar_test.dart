// The time bar of the video controls, dragged by a finger while the video plays: its player gets one seek, where the
// finger lifted, then plays on. Until 13 November 2026 it got one every 150 ms of the drag, each a new range request
// to the share or the server while the ones before still came in (S24 and a Plex film: the picture back 5 s after a
// drag of 0.55 s, tens of seconds after a slower one).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_time_bar.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockController extends Mock implements NativeVideoPlayerController {}

class _MockPlaybackInfo extends Mock implements PlaybackInfo {}

class _MockVideoInfo extends Mock implements VideoInfo {}

void main() {
  late _MockController controller;
  late VideoPlayerNotifier player;
  late List<String> calls;
  var positionMs = 140000;

  setUp(() {
    calls = [];
    positionMs = 140000;
    controller = _MockController();
    final playbackInfo = _MockPlaybackInfo();
    when(() => playbackInfo.position).thenAnswer((_) => positionMs);
    when(() => playbackInfo.status).thenReturn(PlaybackStatus.playing);
    when(() => controller.playbackInfo).thenReturn(playbackInfo);
    final videoInfo = _MockVideoInfo();
    when(() => videoInfo.duration).thenReturn(7200000);
    when(() => controller.videoInfo).thenReturn(videoInfo);
    when(controller.play).thenAnswer((_) async => calls.add('play'));
    when(controller.pause).thenAnswer((_) async => calls.add('pause'));
    when(() => controller.seekTo(any())).thenAnswer((invocation) async {
      calls.add('seek ${invocation.positionalArguments.first}');
    });
    player = VideoPlayerNotifier()..attachController(controller);
    // A 2 h film that plays at 2:20
    player.onNativePlaybackReady();
  });

  Widget bar({bool shown = true}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 720,
          child: shown
              ? StatefulBuilder(
                  builder: (context, _) => VideoTimeBar(
                    position: player.state.position,
                    duration: player.state.duration,
                    tvMode: false,
                    onHold: player.beginScrub,
                    onRelease: player.endScrub,
                    onSeek: player.seekTo,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    ),
  );

  testWidgets('a drag of 2 s while the film plays: the player gets one seek, where the finger lifted, then plays', (
    tester,
  ) async {
    await tester.pumpWidget(bar());
    expect(player.state.status, VideoPlaybackStatus.playing);
    final slider = find.byType(Slider);
    final start = tester.getTopLeft(slider) + Offset(10, tester.getSize(slider).height / 2);

    final gesture = await tester.startGesture(start);
    // 120 moves of 4 px, one per frame of 16 ms; the player's position loop goes on meanwhile
    for (var move = 0; move < 120; move++) {
      await gesture.moveBy(const Offset(4, 0));
      await tester.pump(const Duration(milliseconds: 16));
      if (move % 15 == 0) {
        player.onNativePositionChanged();
      }
    }
    expect(calls, ['pause'], reason: 'nothing but the pause reaches the player while the finger is on the bar');
    final shown = player.state.position;
    expect(shown, greaterThan(const Duration(minutes: 40)), reason: 'the time follows the finger');

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));

    expect(calls, ['pause', 'seek ${shown.inMilliseconds}', 'play']);
    // Its timers (the landing of the seek, the buffering) end with it
    player.dispose();
  });

  testWidgets(
    'the bar gone in the middle of a drag (the controls hidden) still ends it: its seek goes, the film plays',
    (tester) async {
      await tester.pumpWidget(bar());
      final slider = find.byType(Slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      for (var move = 0; move < 10; move++) {
        await gesture.moveBy(const Offset(8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final shown = player.state.position;

      await tester.pumpWidget(bar(shown: false));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();

      expect(calls, ['pause', 'seek ${shown.inMilliseconds}', 'play']);
      // Its timers (the landing of the seek, the buffering) end with it
      player.dispose();
    },
  );
}
