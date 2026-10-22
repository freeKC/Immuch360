// The controller of the iPhone and iPad live view, with a fake playlist and a fake player API, on a fake clock: the
// states of an earlier player ignored, no picture in time, the video alone after a refusal and no loop after it, a
// lost stream opened again with growing waits and given up after the last, a stop while the playlist starts.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_hls.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import '../../pages/camera/camera_fakes.dart';

void main() {
  late FakeCameraLiveApi api;
  late FakeLiveHlsStarter starter;
  late List<CameraLiveEvent> events;

  setUp(() {
    api = FakeCameraLiveApi();
    starter = FakeLiveHlsStarter();
    events = [];
  });

  CameraLiveHlsController controller({
    List<Duration> retryDelays = const [Duration(seconds: 1), Duration(seconds: 2)],
  }) => CameraLiveHlsController(
    viewId: 3,
    api: api,
    startStream: starter.call,
    onEvent: events.add,
    retryDelays: retryDelays,
    firstFrameTimeout: const Duration(seconds: 25),
  );

  void play(CameraLiveHlsController live) =>
      live.play(host: '192.0.2.30', port: 554, user: 'viewer', password: cameraAccountPassword, hd: false);

  CameraLiveEvent event(CameraLiveState state, {String? error, bool hasAudio = true}) =>
      (state: state, error: error, hasAudio: hasAudio);

  test('ignores the states of the player before it has the playlist of this open', () {
    fakeAsync((async) {
      starter.autoReady = false;
      final live = controller();
      play(live);
      async.flushMicrotasks();
      live.onPlayerEvent(event(CameraLiveState.failed, error: 'old player'));
      live.onPlayerEvent(event(CameraLiveState.playing));
      async.flushMicrotasks();
      expect(events.map((e) => e.state), [CameraLiveState.connecting]);
      expect(starter.streams, hasLength(1));
      starter.streams.single.ready();
      async.flushMicrotasks();
      expect(api.sources.single.$2.isHls, isTrue);
      live.onPlayerEvent(event(CameraLiveState.playing));
      expect(events.last.state, CameraLiveState.playing);
      live.dispose();
    });
  });

  test('no picture in time: the video alone, then the reason, never a loop', () {
    fakeAsync((async) {
      final live = controller();
      play(live);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 26));
      expect(starter.streams.map((stream) => stream.withAudio), [true, false]);
      expect(starter.streams.first.stopped, isTrue);
      async.elapse(const Duration(seconds: 26));
      expect(starter.streams, hasLength(2));
      expect(events.last, event(CameraLiveState.failed, error: tapoLiveNoPicture, hasAudio: false));
      async.elapse(const Duration(minutes: 5));
      expect(starter.streams, hasLength(2));
      live.dispose();
    });
  });

  test('a lost stream is opened again after each wait, and given up after the last', () {
    fakeAsync((async) {
      final live = controller();
      play(live);
      async.flushMicrotasks();
      live.onPlayerEvent(event(CameraLiveState.playing));
      for (var i = 0; i < 2; i++) {
        starter.streams.last.lose(tapoLiveStreamLost);
        async.flushMicrotasks();
        expect(events.last.state, CameraLiveState.buffering);
        async.elapse(Duration(seconds: i + 1));
        expect(starter.streams, hasLength(i + 2));
        // The new open never shows a frame, its stream is lost again
      }
      starter.streams.last.lose(tapoLiveStreamLost);
      async.flushMicrotasks();
      expect(events.last, event(CameraLiveState.failed, error: tapoLiveStreamLost));
      async.elapse(const Duration(minutes: 1));
      expect(starter.streams, hasLength(3));
      expect(starter.streams.every((stream) => stream.stopped), isTrue);
      live.dispose();
    });
  });

  test('a frame shown again starts the waits from the first one', () {
    fakeAsync((async) {
      final live = controller();
      play(live);
      async.flushMicrotasks();
      live.onPlayerEvent(event(CameraLiveState.playing));
      starter.streams.last.lose(tapoLiveStreamLost);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      live.onPlayerEvent(event(CameraLiveState.playing));
      starter.streams.last.lose(tapoLiveStreamLost);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(starter.streams, hasLength(3), reason: 'the first wait again');
      live.dispose();
    });
  });

  test('the player failing after it played opens the stream again, with its sound', () {
    fakeAsync((async) {
      final live = controller();
      play(live);
      async.flushMicrotasks();
      live.onPlayerEvent(event(CameraLiveState.playing));
      live.onPlayerEvent(event(CameraLiveState.failed, error: 'CoreMediaErrorDomain -12888'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(starter.streams.map((stream) => stream.withAudio), [true, true]);
      live.dispose();
    });
  });

  test('a stop while the playlist starts: no player, the stream stopped, idle', () {
    fakeAsync((async) {
      starter.autoReady = false;
      final live = controller();
      play(live);
      async.flushMicrotasks();
      live.stop();
      async.flushMicrotasks();
      expect(starter.streams.single.stopped, isTrue);
      expect(api.sources, isEmpty);
      expect(api.stops, [3]);
      expect(events.last.state, CameraLiveState.idle);
      live.dispose();
    });
  });

  test('the sound button follows the playlist and the player', () {
    fakeAsync((async) {
      final live = controller();
      play(live);
      async.flushMicrotasks();
      expect(events.last.hasAudio, isTrue);
      live.onPlayerEvent(event(CameraLiveState.playing, hasAudio: false));
      expect(events.last.hasAudio, isFalse, reason: 'the player plays no sound');
      live.setMuted(false);
      expect(api.mutes.last, (3, false));
      live.dispose();
    });
  });

  test('tells the reasons of a stream that never started', () {
    fakeAsync((async) {
      starter.autoReady = false;
      final reasons = {
        const TapoCameraException(TapoErrorKind.busy, code: 453): cameraLiveBusy,
        const TapoCameraException(TapoErrorKind.unreachable, detail: '192.0.2.30'): cameraLiveUnreachable,
        const TapoCameraException(TapoErrorKind.unsupported, detail: 'RTSP PLAY 454'): 'RTSP PLAY 454',
        const TapoCameraException(TapoErrorKind.h265): cameraLiveH265,
      };
      for (final MapEntry(key: error, value: reason) in reasons.entries) {
        final live = controller();
        play(live);
        async.flushMicrotasks();
        starter.streams.last.refuse(error);
        async.flushMicrotasks();
        expect(events.last, event(CameraLiveState.failed, error: reason));
        live.dispose();
      }
    });
  });
}
