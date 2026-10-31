import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:native_video_player/native_video_player.dart';

class _MockNativeVideoPlayerController extends Mock implements NativeVideoPlayerController {}

class _MockPlaybackInfo extends Mock implements PlaybackInfo {}

class _MockVideoInfo extends Mock implements VideoInfo {}

/// What the watch progress hears of the external players, in minutes
class _RecordingWatcher implements VideoPositionWatcher {
  _RecordingWatcher({this.resumeAt = Duration.zero});

  final Duration resumeAt;
  final events = <String>[];

  @override
  void onSuspend(Duration position) => events.add('suspend ${position.inMinutes}');

  @override
  void onHandBack(Duration position) => events.add('hand back ${position.inMinutes}');

  @override
  Duration resumePositionAfterExternalPlayer() => resumeAt;
}

/// The native player of Android as the notifier hears it: a seek reaches it at once but lands [seekTime] later (about
/// 0.5 s on the TV emulator under load). Until then it goes on telling where it was ([report], its position loop, and
/// the ready and position of the seek before), then reports where it landed, never past its real [endMs], and that it
/// is ready again, as Media3 does after each seek.
class _SlowNativePlayer {
  _SlowNativePlayer(
    this.controller,
    this.notifier, {
    required this.positionMs,
    required this.endMs,
    int? durationMs,
    this.seekTime = const Duration(milliseconds: 500),
  }) {
    final playbackInfo = _MockPlaybackInfo();
    when(() => playbackInfo.position).thenAnswer((_) => positionMs);
    when(() => playbackInfo.status).thenAnswer((_) => status);
    when(() => controller.playbackInfo).thenReturn(playbackInfo);
    final videoInfo = _MockVideoInfo();
    when(() => videoInfo.duration).thenReturn(durationMs ?? endMs);
    when(() => controller.videoInfo).thenReturn(videoInfo);
    when(() => controller.seekTo(any())).thenAnswer((invocation) async {
      final target = invocation.positionalArguments.first as int;
      seeks.add(target);
      await Future<void>.delayed(seekTime);
      positionMs = min(target, endMs);
      notifier.onNativePositionChanged();
      notifier.onNativePlaybackReady();
    });
    notifier.onNativePlaybackReady();
  }

  final _MockNativeVideoPlayerController controller;
  final VideoPlayerNotifier notifier;
  final int endMs;
  final Duration seekTime;
  PlaybackStatus status = PlaybackStatus.paused;
  int positionMs;

  /// The positions the native player was asked to seek to, in order
  final seeks = <int>[];

  /// The player tells where it is, [positionMs] (moved on by [play] while it plays), whatever seek is under way
  void report({int? positionMs, bool ready = false}) {
    if (positionMs != null) {
      this.positionMs = positionMs;
    }
    notifier.onNativePositionChanged();
    if (ready) {
      notifier.onNativePlaybackReady();
    }
  }
}

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

    group('the watch progress (a film resumed where it was left)', () {
      test('seekWhenReady goes there at the first ready after the load, without playing', () async {
        player.seekWhenReady(const Duration(minutes: 42));
        await player.load(serverSource);
        verifyNever(() => controller.seekTo(any()));

        reportReady();
        await pumpEventQueue();

        verify(() => controller.seekTo(42 * 60000)).called(1);
        verifyNever(controller.play);

        reportReady();
        await pumpEventQueue();
        verifyNever(() => controller.seekTo(any()));
      });

      test('the position of an external player wins over it', () async {
        await player.suspendForExternalPlayer();
        await player.resumeAfterExternalPlayerAt(const Duration(seconds: 7), play: false);
        player.seekWhenReady(const Duration(minutes: 42));

        reportReady();
        await pumpEventQueue();

        verify(() => controller.seekTo(7000)).called(1);
        verifyNever(() => controller.seekTo(42 * 60000));
      });

      test(
        'the watcher hears the position before an external player takes the video, and the one it hands back',
        () async {
          final watcher = _RecordingWatcher();
          player.watcher = watcher;
          reportReady();
          player.seekTo(const Duration(minutes: 30));
          await Future<void>.delayed(VideoPlayerNotifier.seekDelay * 2);

          await player.suspendForExternalPlayer();
          await player.resumeAfterExternalPlayerAt(const Duration(minutes: 31), play: false);

          expect(watcher.events, ['suspend 30', 'hand back 31']);
        },
      );

      test('a video back from an external player that told no position loads where the watcher says', () async {
        player.watcher = _RecordingWatcher(resumeAt: const Duration(minutes: 42));
        await player.suspendForExternalPlayer();

        await player.resumeAfterExternalPlayer();
        reportReady();
        await pumpEventQueue();

        verify(() => controller.seekTo(42 * 60000)).called(1);
        verifyNever(controller.play);
      });
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

    test('a video nothing decodes fails at once, without loading, and play loads it anyway', () async {
      const refusal = VideoSourceRefusal(codec: 'H.264', width: 5760, height: 2880, maxWidth: 4096, maxHeight: 2304);
      when(() => controller.videoSource).thenReturn(null);

      player.refuse(serverSource, refusal);

      expect(player.state.status, VideoPlaybackStatus.failed);
      expect(player.failure, const VideoPlaybackFailure(VideoFailureKind.refused, null, refusal));
      verifyNever(() => controller.loadVideoSource(any()));

      await player.play();

      verifyInOrder([() => controller.loadVideoSource(serverSource), controller.play]);
      expect(player.state.status, isNot(VideoPlaybackStatus.failed));
    });

    test('an error the app put in its words carries the kind, the codec and the frame of the video', () async {
      await player.load(serverSource);

      player.onNativeError('immuch360-playback-error:noFrame:video/avc:5760:2880');

      expect(player.failure?.native?.kind, NativePlaybackErrorKind.noFrame);
      expect(player.failure?.native?.codec, 'H.264');
      expect(const VideoPlaybackFailure(VideoFailureKind.error, 'Source error').native, isNull);
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

  // A quick series of presses on a TV (10 s, 30 s, 60 s, each 390 ms after the last, as on the TV emulator), the time
  // bar and the fast forward keys: each seek goes from where the one before takes the video, whatever the native player
  // still reports of the seeks on their way
  group('a series of seeks', () {
    const press = Duration(milliseconds: 390);

    /// The player of a 6 min video paused at [start], with seeks that land in [seekTime]
    _SlowNativePlayer slowPlayer({
      Duration start = const Duration(seconds: 3),
      Duration end = const Duration(minutes: 6),
      Duration? duration,
      Duration seekTime = const Duration(milliseconds: 500),
    }) => _SlowNativePlayer(
      controller,
      player,
      positionMs: start.inMilliseconds,
      endMs: end.inMilliseconds,
      durationMs: duration?.inMilliseconds,
      seekTime: seekTime,
    );

    void pressAll(FakeAsync async, List<int> seconds) {
      for (final step in seconds) {
        player.seekBy(Duration(seconds: step));
        async.elapse(press);
      }
    }

    test('presses add up from the target of the one before, never from a seek still on its way', () {
      fakeAsync((async) {
        final native = slowPlayer();
        final shown = <Duration>[];
        player.addListener((state) => shown.add(state.position), fireImmediately: false);

        pressAll(async, [10, 30, 60]);
        async.elapse(const Duration(seconds: 3));

        expect(player.state.position, const Duration(seconds: 103));
        expect(native.seeks.last, 103000, reason: 'the player goes where the last press asked');
        expect(native.positionMs, 103000);
        for (var i = 1; i < shown.length; i++) {
          expect(shown[i], greaterThanOrEqualTo(shown[i - 1]), reason: 'the time never goes back meanwhile: $shown');
        }
        player.dispose();
      });
    });

    test('a press the other way goes back from the target of the series: right three times then left', () {
      fakeAsync((async) {
        final native = slowPlayer();

        pressAll(async, [10, 30, 60, -10]);
        async.elapse(const Duration(seconds: 3));

        expect(player.state.position, const Duration(seconds: 93));
        expect(native.positionMs, 93000);
        expect(native.seeks.last, 93000);
        player.dispose();
      });
    });

    test('left three times then right, and right twice then left', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(minutes: 3));

        pressAll(async, [-10, -30, -60, 10]);
        async.elapse(const Duration(seconds: 3));
        expect(player.state.position, const Duration(seconds: 90));
        expect(native.positionMs, 90000);

        pressAll(async, [10, 30, -10]);
        async.elapse(const Duration(seconds: 3));
        expect(player.state.position, const Duration(seconds: 120));
        expect(native.positionMs, 120000);
        player.dispose();
      });
    });

    test('the fast forward keys, 10 s per press: the ready of a seek within the 150 ms of the next press', () {
      fakeAsync((async) {
        // Each seek lands 300 ms after it left, while the next press waits its 150 ms
        final native = slowPlayer(
          start: const Duration(minutes: 2, seconds: 13),
          seekTime: const Duration(milliseconds: 300),
        );

        pressAll(async, [10, 10, 10]);
        async.elapse(const Duration(seconds: 4));

        expect(player.state.position, const Duration(minutes: 2, seconds: 43));
        expect(native.positionMs, 163000);
        player.dispose();
      });
    });

    test('a position of the player from before the seek, during it, changes neither the time nor the next press', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(seconds: 30));

        player.seekTo(const Duration(seconds: 60));
        async.elapse(const Duration(milliseconds: 200));
        expect(native.seeks, [60000], reason: 'the seek reached the player');
        // Its position loop and the ready of the seek before, still under way
        native.report(positionMs: 30000, ready: true);
        expect(player.state.position, const Duration(seconds: 60));
        native.report(positionMs: 30200);
        expect(player.state.position, const Duration(seconds: 60));

        player.seekBy(const Duration(seconds: 10));
        expect(player.state.position, const Duration(seconds: 70), reason: 'from the target, not from 30 s');
        async.elapse(const Duration(seconds: 2));
        expect(native.seeks.last, 70000);
        expect(player.state.position, const Duration(seconds: 70));
        player.dispose();
      });
    });

    test('right then left back to the start: the second seek goes, though the player still reports the start', () {
      fakeAsync((async) {
        // Paused at 1:00; each seek lands 300 ms after it left
        final native = slowPlayer(start: const Duration(seconds: 60), seekTime: const Duration(milliseconds: 300));

        player.seekBy(const Duration(seconds: 10));
        async.elapse(const Duration(milliseconds: 200));
        expect(native.seeks, [70000], reason: 'the seek to 1:10 is under way');
        player.seekBy(const Duration(seconds: -10));
        async.elapse(const Duration(milliseconds: 20));
        // Before the first seek landed the player still tells where it was: 1:00, the target of the second press
        native.report();
        async.elapse(const Duration(seconds: 3));

        expect(native.seeks, [70000, 60000], reason: 'both seeks reached the player');
        expect(native.positionMs, 60000, reason: 'the player is back at the start');
        expect(player.state.position, const Duration(seconds: 60));
        player.dispose();
      });
    });

    test('once the seek landed, the positions of a playing video show again at once', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(seconds: 30))..status = PlaybackStatus.playing;
        native.report(positionMs: 30100);
        expect(player.state.position, const Duration(milliseconds: 30100));

        player.seekTo(const Duration(seconds: 60));
        async.elapse(const Duration(milliseconds: 700));
        expect(player.state.position, const Duration(seconds: 60));
        native.report(positionMs: 60300);
        expect(player.state.position, const Duration(milliseconds: 60300), reason: 'the video plays on from there');
        native.report(positionMs: 60500);
        expect(player.state.position, const Duration(milliseconds: 60500));
        player.dispose();
      });
    });

    test('a seek the player stops short of, at its real end, shows where it stopped', () {
      fakeAsync((async) {
        // The file says 6:00, the player ends at 5:55
        final native = slowPlayer(
          start: const Duration(minutes: 5, seconds: 20),
          end: const Duration(minutes: 5, seconds: 55),
          duration: const Duration(minutes: 6),
        );

        pressAll(async, [10, 30]);
        async.elapse(const Duration(seconds: 3));

        expect(native.seeks.last, 360000, reason: 'the series asked for 6:00');
        expect(player.state.position, const Duration(minutes: 5, seconds: 55), reason: 'where the player is');
        player.seekBy(const Duration(seconds: -10));
        async.elapse(const Duration(seconds: 3));
        expect(player.state.position, const Duration(minutes: 5, seconds: 45));
        expect(native.positionMs, 345000);
        player.dispose();
      });
    });

    test('a seek whose call fails leaves the time where the player is', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(seconds: 30));
        when(() => controller.seekTo(any())).thenAnswer((_) async => throw PlatformException(code: 'seek'));

        player.seekTo(const Duration(seconds: 60));
        async.elapse(const Duration(seconds: 3));

        expect(player.state.position, Duration(milliseconds: native.positionMs));
        native.report(positionMs: 31000);
        expect(player.state.position, const Duration(seconds: 31));
        player.dispose();
      });
    });

    test('pause sends the seek waiting for its 150 ms at once, and the series goes on from it', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(seconds: 30));

        player.seekBy(const Duration(seconds: 10));
        unawaited(player.pause());
        async.flushMicrotasks();
        expect(native.seeks, [40000]);
        native.report(positionMs: 30000, ready: true);
        player.seekBy(const Duration(seconds: 30));
        async.elapse(const Duration(seconds: 3));

        expect(player.state.position, const Duration(seconds: 70));
        expect(native.positionMs, 70000);
        player.dispose();
      });
    });

    test('a video loaded again forgets the seek under way', () {
      fakeAsync((async) {
        final native = slowPlayer(start: const Duration(seconds: 30));
        when(() => controller.videoSource).thenReturn(fileSource);
        player.seekTo(const Duration(seconds: 60));
        async.elapse(const Duration(milliseconds: 200));

        unawaited(player.load(fileSource));
        native.report(positionMs: 0, ready: true);

        expect(player.state.position, Duration.zero);
        async.elapse(const Duration(seconds: 2));
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
