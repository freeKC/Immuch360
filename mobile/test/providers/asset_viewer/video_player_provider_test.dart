import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockNativeVideoPlayerController extends Mock implements NativeVideoPlayerController {}

void main() {
  final serverSource = VideoSource(path: 'https://server/assets/1/video/playback', type: .network, headers: const {});
  final fileSource = VideoSource(path: 'file:///videos/1.mp4', type: .file, headers: const {});

  late _MockNativeVideoPlayerController controller;
  late VideoPlayerNotifier player;

  setUpAll(() => registerFallbackValue(serverSource));

  setUp(() {
    controller = _MockNativeVideoPlayerController();
    when(controller.play).thenAnswer((_) async {});
    when(controller.pause).thenAnswer((_) async {});
    when(controller.stop).thenAnswer((_) async {});
    when(() => controller.loadVideoSource(any())).thenAnswer((_) async {});
    player = VideoPlayerNotifier()..attachController(controller);
  });

  group('suspendForExternalPlayer', () {
    test('stops a loaded video, so it frees its decoder instead of keeping it paused', () async {
      when(() => controller.videoSource).thenReturn(serverSource);

      await player.suspendForExternalPlayer();

      expect(player.isSuspendedForExternalPlayer, isTrue);
      verify(controller.stop).called(1);
      verifyNever(controller.pause);
    });

    test('keeps the video from playing until the external player closes', () async {
      when(() => controller.videoSource).thenReturn(serverSource);
      await player.suspendForExternalPlayer();

      await player.play();
      player.toggle();
      await pumpEventQueue();

      verifyNever(controller.play);
    });

    test('reloads the video when the external player closes, without playing it', () async {
      when(() => controller.videoSource).thenReturn(serverSource);
      await player.suspendForExternalPlayer();

      await player.resumeAfterExternalPlayer();

      expect(player.isSuspendedForExternalPlayer, isFalse);
      verify(() => controller.loadVideoSource(serverSource)).called(1);
      verifyNever(controller.play);

      await player.play();
      verify(controller.play).called(1);
    });

    test('holds back a video that starts loading meanwhile, then loads it', () async {
      // Tapped before the viewer had loaded anything
      when(() => controller.videoSource).thenReturn(null);
      await player.suspendForExternalPlayer();
      verifyNever(controller.stop);

      await player.load(fileSource);
      verifyNever(() => controller.loadVideoSource(any()));

      await player.resumeAfterExternalPlayer();
      verify(() => controller.loadVideoSource(fileSource)).called(1);
    });

    test('changes nothing when no external player was opened', () async {
      await player.resumeAfterExternalPlayer();

      verifyNever(() => controller.loadVideoSource(any()));
      await player.play();
      verify(controller.play).called(1);
    });
  });
}
