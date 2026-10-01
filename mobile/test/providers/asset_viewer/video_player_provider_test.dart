import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockNativeVideoPlayerController extends Mock implements NativeVideoPlayerController {}

class _MockPlaybackInfo extends Mock implements PlaybackInfo {}

class _MockVideoInfo extends Mock implements VideoInfo {}

void main() {
  // The restore reads the app lifecycle, like the viewer's autoplay
  TestWidgetsFlutterBinding.ensureInitialized();

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
    when(() => controller.seekTo(any())).thenAnswer((_) async {});
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

  group('resumeAfterExternalPlayerAt', () {
    /// The native player reports the video ready again, back at its start and paused
    void reportReady() {
      final playbackInfo = _MockPlaybackInfo();
      when(() => playbackInfo.position).thenReturn(0);
      when(() => playbackInfo.status).thenReturn(PlaybackStatus.paused);
      final videoInfo = _MockVideoInfo();
      when(() => videoInfo.duration).thenReturn(120000);
      when(() => controller.playbackInfo).thenReturn(playbackInfo);
      when(() => controller.videoInfo).thenReturn(videoInfo);
      player.onNativePlaybackReady();
    }

    setUp(() => when(() => controller.videoSource).thenReturn(serverSource));

    test('reloads the video, then goes where the external player stopped and plays once it is ready', () async {
      final positions = <Duration>[];
      player.addListener((state) => positions.add(state.position), fireImmediately: false);
      await player.suspendForExternalPlayer();

      await player.resumeAfterExternalPlayerAt(const Duration(seconds: 42), play: true);

      expect(player.isSuspendedForExternalPlayer, isFalse);
      verify(() => controller.loadVideoSource(serverSource)).called(1);
      verifyNever(() => controller.seekTo(any()));
      verifyNever(controller.play);

      reportReady();
      await pumpEventQueue();

      verifyInOrder([() => controller.seekTo(42000), controller.play]);
      expect(positions.last, const Duration(seconds: 42), reason: 'the viewer shows where the video is');
    });

    test('goes where the external player stopped without playing when it was paused', () async {
      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayerAt(const Duration(milliseconds: 1500), play: false);

      reportReady();
      await pumpEventQueue();

      verify(() => controller.seekTo(1500)).called(1);
      verifyNever(controller.play);
    });

    test('waits for the video the app reloaded when it came back to the foreground first', () async {
      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayer();

      await player.resumeAfterExternalPlayerAt(const Duration(seconds: 7), play: true);
      verifyNever(() => controller.seekTo(any()));

      reportReady();
      await pumpEventQueue();

      verify(() => controller.loadVideoSource(serverSource)).called(1);
      verifyInOrder([() => controller.seekTo(7000), controller.play]);
    });

    test('goes there right away when the reloaded video is ready already', () async {
      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayer();
      reportReady();

      await player.resumeAfterExternalPlayerAt(const Duration(seconds: 7), play: true);

      verifyInOrder([() => controller.seekTo(7000), controller.play]);
    });

    test('goes there once only, not again when more data loads', () async {
      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayerAt(const Duration(seconds: 7), play: false);

      reportReady();
      reportReady();
      await pumpEventQueue();

      verify(() => controller.seekTo(7000)).called(1);
    });

    group('while the app is in the background', () {
      setUp(() {
        TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        addTearDown(() => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      });

      test('goes where the external player stopped, but leaves the playing to the return to the foreground', () async {
        await player.suspendForExternalPlayer();
        await player.resumeAfterExternalPlayerAt(const Duration(seconds: 42), play: true);

        reportReady();
        await pumpEventQueue();

        verify(() => controller.seekTo(42000)).called(1);
        verifyNever(controller.play);
        expect(player.takePlayOnForeground(), isTrue);
        expect(player.takePlayOnForeground(), isFalse, reason: 'once only');
      });

      test('has nothing to play back in the foreground when the external player was paused', () async {
        await player.suspendForExternalPlayer();
        await player.resumeAfterExternalPlayerAt(const Duration(seconds: 42), play: false);

        reportReady();
        await pumpEventQueue();

        verify(() => controller.seekTo(42000)).called(1);
        expect(player.takePlayOnForeground(), isFalse);
      });

      for (final (name, action) in <(String, Future<void> Function(VideoPlayerNotifier))>[
        ('paused', (player) => player.pause()),
        ('loaded again', (player) => player.load(fileSource)),
        ('suspended again', (player) => player.suspendForExternalPlayer()),
      ]) {
        test('has nothing to play back in the foreground once the video is $name meanwhile', () async {
          await player.suspendForExternalPlayer();
          await player.resumeAfterExternalPlayerAt(const Duration(seconds: 42), play: true);
          reportReady();
          await pumpEventQueue();

          await action(player);

          expect(player.takePlayOnForeground(), isFalse);
        });
      }
    });

    test('forgets a pending position when the video goes to an external player again', () async {
      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayer();
      await player.resumeAfterExternalPlayerAt(const Duration(seconds: 7), play: true);

      await player.suspendForExternalPlayer();
      await player.resumeAfterExternalPlayer();
      reportReady();
      await pumpEventQueue();

      verifyNever(() => controller.seekTo(any()));
      verifyNever(controller.play);
    });
  });
}
