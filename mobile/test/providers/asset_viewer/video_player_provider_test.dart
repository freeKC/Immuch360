import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

  group('when the video does not play', () {
    /// The plugin reports [status] for one of its own calls
    void reportStatus(PlaybackStatus status, {int position = 0}) {
      final playbackInfo = _MockPlaybackInfo();
      when(() => playbackInfo.status).thenReturn(status);
      when(() => playbackInfo.position).thenReturn(position);
      when(() => controller.playbackInfo).thenReturn(playbackInfo);
      player.onNativeStatusChanged();
    }

    void reportPosition(int position) {
      final playbackInfo = _MockPlaybackInfo();
      when(() => playbackInfo.status).thenReturn(PlaybackStatus.playing);
      when(() => playbackInfo.position).thenReturn(position);
      when(() => controller.playbackInfo).thenReturn(playbackInfo);
      player.onNativePositionChanged();
    }

    setUp(() => when(() => controller.videoSource).thenReturn(serverSource));

    test('fails on an error of the native player, which counts as not playing', () async {
      await player.load(serverSource);

      player.onNativeError('Decoder init failed: c2.android.avc.decoder');

      expect(player.state.status, VideoPlaybackStatus.failed);
      expect(
        player.failure,
        const VideoPlaybackFailure(VideoFailureKind.error, 'Decoder init failed: c2.android.avc.decoder'),
      );
    });

    test('stays failed whatever the plugin reports of its own calls, until it is loaded again', () async {
      await player.load(serverSource);
      player.onNativeError('Source error');

      reportStatus(PlaybackStatus.paused);
      expect(player.state.status, VideoPlaybackStatus.failed);
      reportStatus(PlaybackStatus.playing);
      expect(player.state.status, VideoPlaybackStatus.failed);

      await player.load(serverSource);
      expect(player.state.status, VideoPlaybackStatus.buffering, reason: 'the spinner while it loads again');
      expect(player.failure, isNull);
    });

    test('play loads the video again and plays it', () async {
      await player.load(serverSource);
      player.onNativeError('Source error');
      clearInteractions(controller);

      await player.play();

      verifyInOrder([() => controller.loadVideoSource(serverSource), controller.play]);
      expect(player.state.status, isNot(VideoPlaybackStatus.failed));
    });

    test('toggle loads it again too', () async {
      await player.load(serverSource);
      player.onNativeError('Source error');
      clearInteractions(controller);

      player.toggle();
      await pumpEventQueue();

      verifyInOrder([() => controller.loadVideoSource(serverSource), controller.play]);
    });

    test('nothing is heard while an external player has the video', () async {
      await player.suspendForExternalPlayer();

      player.onNativeError('Stopped');

      expect(player.state.status, isNot(VideoPlaybackStatus.failed));
    });

    test('fails when nothing played for the stall timeout while it loads', () {
      fakeAsync((async) {
        unawaited(player.load(serverSource));
        async.elapse(const Duration(seconds: 1));
        expect(player.state.status, VideoPlaybackStatus.buffering);

        async.elapse(VideoPlayerNotifier.stallTimeout - const Duration(milliseconds: 100));
        expect(player.state.status, VideoPlaybackStatus.buffering);

        async.elapse(const Duration(milliseconds: 200));
        expect(player.state.status, VideoPlaybackStatus.failed);
        expect(player.failure, const VideoPlaybackFailure(VideoFailureKind.stalled));
        player.dispose();
      });
    });

    test('a stall ends by itself when the video plays after all', () {
      fakeAsync((async) {
        unawaited(player.load(serverSource));
        async.elapse(const Duration(seconds: 1) + VideoPlayerNotifier.stallTimeout + const Duration(seconds: 1));
        expect(player.state.status, VideoPlaybackStatus.failed);

        reportPosition(500);

        expect(player.state.status, VideoPlaybackStatus.playing);
        expect(player.failure, isNull);
        player.dispose();
      });
    });

    test('a video that buffers a while and then plays again does not fail', () {
      fakeAsync((async) {
        unawaited(player.load(serverSource));
        async.elapse(const Duration(seconds: 1));
        for (var i = 1; i <= 6; i++) {
          async.elapse(const Duration(seconds: 10));
          // The native player reports its position every few milliseconds while it plays
          reportPosition(i * 1000);
          reportPosition(i * 1000 + 10);
          expect(player.state.status, VideoPlaybackStatus.playing);
          // The position stands still again: buffering after 1 s
          async.elapse(const Duration(seconds: 2));
          expect(player.state.status, VideoPlaybackStatus.buffering);
        }
        player.dispose();
      });
    });

    test('a paused video never stalls', () {
      fakeAsync((async) {
        unawaited(player.load(serverSource));
        async.elapse(const Duration(seconds: 2));
        unawaited(player.pause());
        reportStatus(PlaybackStatus.paused);

        async.elapse(VideoPlayerNotifier.stallTimeout * 2);

        expect(player.state.status, VideoPlaybackStatus.paused);
        player.dispose();
      });
    });
  });

  // A Linux session without the screen saver service that wakelock_plus asks (org.freedesktop.ScreenSaver: a bare
  // window manager, WSLg, a CI virtual screen) refuses to keep the screen on
  group('keeping the screen on', () {
    final original = VideoPlayerNotifier.toggleWakelock;
    late List<bool> toggles;

    setUp(() {
      toggles = [];
      VideoPlayerNotifier.toggleWakelock = (on) async {
        toggles.add(on);
        throw Exception('org.freedesktop.DBus.Error.ServiceUnknown: org.freedesktop.ScreenSaver');
      };
    });

    tearDown(() => VideoPlayerNotifier.toggleWakelock = original);

    test('a refusal while the video plays, at its end and at the dispose is no unhandled error', () async {
      final playbackInfo = _MockPlaybackInfo();
      when(() => playbackInfo.status).thenReturn(PlaybackStatus.playing);
      when(() => controller.playbackInfo).thenReturn(playbackInfo);
      final errors = <Object>[];

      await runZonedGuarded(() async {
        player.onNativeStatusChanged();
        await pumpEventQueue();
        expect(player.state.status, VideoPlaybackStatus.playing, reason: 'the video plays all the same');
        player.onNativePlaybackEnded();
        player.dispose();
        await pumpEventQueue();
      }, (error, _) => errors.add(error));

      expect(toggles, [true, false, false]);
      expect(errors, isEmpty);
    });
  });
}
