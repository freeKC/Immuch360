// The live view of a camera on a computer (camera_live_view.dart) with fake players: the address with the account
// encoded, the states mapped to the camera page, a muted pooled player of its own kind, a lost stream opened again
// after its delays and given up after the last, a stream that never played or a refused account not retried, a
// stalled picture, the player given back when stopped, the HD and SD switch, a lost graphics device; then the view
// itself on the camera page of a computer, and the app away.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/camera_live_view.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/presentation/widgets/camera/camera_live_view.widget.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';

import '../../presentation/pages/camera/camera_fakes.dart';
import 'fake_playback_engine.dart';

const _url = 'rtsp://192.0.2.30:554/stream2';
const _user = 'viewer';
const _password = 'p@ss w:rd/+%é';
const _address = 'rtsp://viewer:p%40ss%20w%3Ard%2F%2B%25%C3%A9@192.0.2.30:554/stream2';

void main() {
  group('the address', () {
    test('holds the account percent-encoded, every byte outside the unreserved characters', () {
      expect(cameraRtspUrlWithAccount(_url, _user, _password), _address);
      expect(
        cameraRtspUrlWithAccount('rtsp://[fd00::30]:554/stream1', 'a.b_c~d-e', 'x'),
        'rtsp://a.b_c~d-e:x@[fd00::30]:554/stream1',
      );
      expect(Uri.decodeComponent(Uri.parse(_address).userInfo.split(':').last), _password);
    });

    test('without a password or a user, and refused when not a plain rtsp address', () {
      expect(cameraRtspUrlWithAccount(_url, _user, ''), 'rtsp://viewer@192.0.2.30:554/stream2');
      expect(cameraRtspUrlWithAccount(_url, '', ''), _url);
      expect(cameraRtspUrlWithAccount('http://192.0.2.30/stream2', _user, _password), isNull);
      expect(cameraRtspUrlWithAccount('rtsp://other@192.0.2.30:554/stream2', _user, _password), isNull);
      expect(cameraRtspUrlWithAccount('rtsp:///stream2', _user, _password), isNull);
    });
  });

  test('the states of the camera page', () {
    expect(cameraLiveStateOf(CameraLiveStatus.connecting), CameraLiveState.connecting);
    expect(cameraLiveStateOf(CameraLiveStatus.live), CameraLiveState.playing);
    expect(cameraLiveStateOf(CameraLiveStatus.lost), CameraLiveState.buffering);
    expect(cameraLiveStateOf(CameraLiveStatus.stopped), CameraLiveState.idle);
    expect(cameraLiveStateOf(CameraLiveStatus.stopped, error: 'x'), CameraLiveState.failed);
  });

  group('the session', () {
    late FakePlayers players;
    late List<CameraLiveEvent> events;
    late CameraLiveSession session;

    void start(FakeAsync async, {List<Duration> retryDelays = CameraLiveSession.defaultRetryDelays}) {
      players = FakePlayers();
      events = [];
      session = CameraLiveSession(pool: players.pool, onEvent: events.add, retryDelays: retryDelays);
      unawaited(session.play(url: _url, user: _user, password: _password));
      async.flushMicrotasks();
    }

    FakePlaybackEngine engine() => players.made.single;

    List<CameraLiveState> states() => [for (final event in events) event.state];

    /// libmpv's part: the stream is open with [audio] tracks and its first frame shows
    void frame({bool audio = true}) {
      engine().audioTracks.value = audio ? const [DesktopAudioTrack(id: '1', codec: 'pcm_alaw')] : const [];
      engine().load(Duration.zero, size: (width: 1280, height: 720));
    }

    void finish(FakeAsync async) {
      unawaited(session.dispose());
      async.flushMicrotasks();
      async.flushTimers();
    }

    test('opens the address with the account on a muted live player, then shows live with the frame', () {
      fakeAsync((async) {
        start(async);
        expect(engine().kind, PlayerKind.live);
        expect(engine().calls, ['open $_address at 0 streamed', 'play']);
        expect(engine().volume, 0);
        expect(states(), [CameraLiveState.connecting]);
        frame();
        expect(states(), [CameraLiveState.connecting, CameraLiveState.playing]);
        expect(session.status, CameraLiveStatus.live);
        expect(events.last.hasAudio, isTrue);
        session.setMuted(false);
        async.flushMicrotasks();
        expect(engine().volume, 1);
        finish(async);
      });
    });

    test('a stream without sound says so, as the phones do', () {
      fakeAsync((async) {
        start(async);
        frame(audio: false);
        expect(events.last, (state: CameraLiveState.playing, error: null, hasAudio: false));
        finish(async);
      });
    });

    test('the sound button does not flicker while mpv lists the tracks, video first', () {
      fakeAsync((async) {
        start(async);
        // DesktopPlayer's order: whether there is a video, then the audio tracks
        engine().hasVideo.value = true;
        engine().audioTracks.value = const [DesktopAudioTrack(id: '1', codec: 'pcm_alaw')];
        engine().load(Duration.zero);
        expect(events.map((event) => event.hasAudio), everyElement(isTrue));
        expect(events.last.state, CameraLiveState.playing);
        finish(async);
      });
    });

    test('a stream that ends after playing is opened again after 1 s, and plays on', () {
      fakeAsync((async) {
        start(async);
        frame();
        engine().completed.value = true;
        expect(session.status, CameraLiveStatus.lost);
        expect(events.last.state, CameraLiveState.buffering);
        async.elapse(const Duration(milliseconds: 900));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(1));
        async.elapse(const Duration(milliseconds: 200));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(2));
        expect(session.status, CameraLiveStatus.lost, reason: 'no frame of the new open yet');
        frame();
        expect(session.status, CameraLiveStatus.live);
        expect(players.made, hasLength(1), reason: 'the same player');
        finish(async);
      });
    });

    test('a lost stream is opened again after each delay, then given up', () {
      fakeAsync((async) {
        start(async, retryDelays: const [Duration(seconds: 1), Duration(seconds: 2)]);
        frame();
        engine().emit(PlayerEventKind.failed, 'libmpv: loading failed');
        async.elapse(const Duration(seconds: 1));
        engine().emit(PlayerEventKind.failed, 'libmpv: loading failed');
        async.elapse(const Duration(seconds: 2));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(3));
        engine().emit(PlayerEventKind.failed, 'libmpv: loading failed');
        async.flushMicrotasks();
        expect(session.status, CameraLiveStatus.stopped);
        expect(events.last, (state: CameraLiveState.failed, error: 'libmpv: loading failed', hasAudio: true));
        expect(players.pool.activeCount(PlayerKind.live), 0, reason: 'the player is given back');
        expect(players.pool.idleCount(PlayerKind.live), 1);
        expect(engine().calls.last, 'stop');
        async.elapse(const Duration(minutes: 5));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(3));
        finish(async);
      });
    });

    test('a frame between two losses starts the delays again', () {
      fakeAsync((async) {
        start(async, retryDelays: const [Duration(seconds: 1), Duration(seconds: 2)]);
        for (var i = 0; i < 4; i++) {
          frame();
          engine().completed.value = true;
          async.elapse(const Duration(seconds: 1));
        }
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(5));
        expect(session.status, CameraLiveStatus.lost);
        finish(async);
      });
    });

    test('a stream that never showed a frame is not opened again', () {
      fakeAsync((async) {
        start(async);
        engine().emit(PlayerEventKind.failed, 'libmpv: loading failed');
        async.flushMicrotasks();
        expect(events.last, (state: CameraLiveState.failed, error: 'libmpv: loading failed', hasAudio: true));
        async.elapse(const Duration(minutes: 5));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(1));
        finish(async);
      });
    });

    test('a refused account is never asked again, even after the stream played', () {
      fakeAsync((async) {
        start(async);
        frame();
        engine().completed.value = true;
        async.elapse(const Duration(seconds: 1));
        engine().emit(PlayerEventKind.failed, 'libmpv: loading failed: method DESCRIBE failed: 401 Unauthorized');
        async.elapse(const Duration(minutes: 5));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(2));
        expect(session.status, CameraLiveStatus.stopped);
        expect(events.last.state, CameraLiveState.failed);
        expect(events.last.error, contains('401'));
        finish(async);
      });
    });

    test('a camera that answers and sends no picture is given up after the connect timeout', () {
      fakeAsync((async) {
        start(async);
        async.elapse(const Duration(seconds: 19));
        expect(session.status, CameraLiveStatus.connecting);
        async.elapse(const Duration(seconds: 2));
        expect(events.last, (state: CameraLiveState.failed, error: cameraLiveNoPicture, hasAudio: true));
        finish(async);
      });
    });

    test('a picture that waits for the stream shows lost, live again when it moves, opened again when it stays', () {
      fakeAsync((async) {
        start(async);
        frame();
        engine().buffering.value = true;
        expect(session.status, CameraLiveStatus.lost);
        async.elapse(const Duration(seconds: 3));
        engine().buffering.value = false;
        engine().position.value = const Duration(seconds: 4);
        expect(session.status, CameraLiveStatus.live);
        for (var second = 5; second < 10; second++) {
          async.elapse(const Duration(seconds: 1));
          engine().position.value = Duration(seconds: second);
        }
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(1), reason: 'it moves');
        async.elapse(const Duration(seconds: 11));
        expect(session.status, CameraLiveStatus.lost);
        async.elapse(const Duration(seconds: 1));
        expect(engine().calls.where((call) => call.startsWith('open')), hasLength(2), reason: 'stalled 10 s');
        finish(async);
      });
    });

    test('stop gives the player back and reports idle; play takes it again', () {
      fakeAsync((async) {
        start(async);
        frame();
        unawaited(session.stop());
        async.flushMicrotasks();
        expect(events.last.state, CameraLiveState.idle);
        expect(session.videoController.value, isNull);
        expect(players.pool.activeCount(PlayerKind.live), 0);
        expect(engine().calls, containsAllInOrder(['pause', 'stop']));
        async.elapse(const Duration(minutes: 1));
        unawaited(session.play(url: _url, user: _user, password: _password));
        async.flushMicrotasks();
        expect(players.made, hasLength(1), reason: 'the idle player of the pool');
        expect(engine().calls.last, 'play');
        expect(events.last.state, CameraLiveState.connecting);
        finish(async);
      });
    });

    test('the HD stream replaces the SD one in the same player', () {
      fakeAsync((async) {
        start(async);
        frame();
        unawaited(session.play(url: 'rtsp://192.0.2.30:554/stream1', user: _user, password: _password));
        async.flushMicrotasks();
        expect(engine().calls.where((call) => call.startsWith('open')), [
          'open $_address at 0 streamed',
          'open ${_address.replaceAll('stream2', 'stream1')} at 0 streamed',
        ]);
        expect(events.last.state, CameraLiveState.connecting);
        finish(async);
      });
    });

    test('a lost graphics device: a new player opens the stream again', () {
      fakeAsync((async) {
        start(async);
        frame();
        engine().textureLost.value = true;
        async.flushMicrotasks();
        expect(players.made, hasLength(2));
        expect(players.made.first.disposed, isTrue);
        expect(players.made.last.calls, ['open $_address at 0 streamed', 'play']);
        expect(session.status, CameraLiveStatus.lost);
        finish(async);
      });
    });

    test('the account is hidden in every player text from the first play', () {
      fakeAsync((async) {
        start(async);
        expect(redactPlayerText('auth for viewer with p@ss w:rd/+%é'), 'auth for <hidden> with <hidden>');
        expect(redactPlayerText('Failed to open rtsp://viewer:p@ss w:rd/+%é@192.0.2.30/x'), isNot(contains('rd/')));
        expect(redactPlayerText('Failed to open $_address.'), 'Failed to open <url>');
        finish(async);
      });
    });
  });

  group('on the camera page of a computer', () {
    late FakePlayers players;
    late FakeCameraLiveApi live;

    /// A test on Windows with libmpv and fake players, made inside the test so that their futures run on its clock
    void desktopTest(String description, Future<void> Function(WidgetTester tester) body) {
      testWidgets(description, (tester) async {
        players = FakePlayers();
        live = FakeCameraLiveApi();
        desktopPlayerPool = players.pool;
        desktopVideoAvailable = true;
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await body(tester);
        } finally {
          desktopPlayerPool = null;
          desktopVideoAvailable = false;
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }

    Future<void> pump(WidgetTester tester, {ValueNotifier<bool>? shown, bool fullScreen = false}) async {
      final visible = shown ?? ValueNotifier(true);
      await pumpCameraApp(
        tester,
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (context, show, _) => show
                ? SizedBox(
                    width: 640,
                    height: 360,
                    child: CameraLiveTile(
                      host: cameraHost,
                      port: 554,
                      user: _user,
                      password: _password,
                      fullScreen: fullScreen,
                      preferHd: false,
                      onFullScreen: (_) {},
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        overrides: cameraOverrides(live: live),
      );
    }

    FakePlaybackEngine engine() => players.made.single;

    desktopTest('plays the SD stream in a pooled player, no Android view, and shows the states', (tester) async {
      await pump(tester);
      expect(find.byType(DesktopCameraLiveView), findsOneWidget);
      expect(find.byType(PlatformViewLink), findsNothing);
      expect(live.sources, isEmpty, reason: 'the Android API is not used');
      expect(engine().calls, ['open $_address at 0 streamed', 'play']);
      expect(find.text('Connecting to the camera'), findsOneWidget);
      engine().audioTracks.value = const [DesktopAudioTrack(id: '1')];
      engine().load(Duration.zero);
      await tester.pump();
      expect(find.byKey(const Key('camera_live_badge')), findsOneWidget);
      expect(find.text('Connecting to the camera'), findsNothing);

      await tester.tap(find.byKey(const Key('camera_live_sound')));
      await tester.pump();
      expect(engine().volume, 1);

      await tester.tap(find.byKey(const Key('camera_live_quality')));
      // The page hears of the new open once the frame that started it is built
      await tester.pumpAndSettle();
      expect(engine().calls.where((call) => call.startsWith('open')).last, contains('/stream1'));
      expect(find.text('Connecting to the camera'), findsOneWidget);

      engine().emit(PlayerEventKind.failed, 'libmpv: loading failed');
      await tester.pump();
      expect(find.text('The live view did not start: libmpv: loading failed'), findsOneWidget);
      expect(find.byKey(const Key('camera_live_badge')), findsNothing);
    });

    desktopTest('gives the player back while the app is away and when the view goes', (tester) async {
      final shown = ValueNotifier(true);
      await pump(tester, shown: shown);
      engine().load(Duration.zero);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(players.pool.activeCount(PlayerKind.live), 0);
      expect(find.byKey(const Key('camera_live_badge')), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(players.pool.activeCount(PlayerKind.live), 1);
      expect(engine().calls.where((call) => call.startsWith('open')), hasLength(2));
      shown.value = false;
      await tester.pumpAndSettle();
      expect(players.pool.activeCount(PlayerKind.live), 0);
      expect(players.pool.idleCount(PlayerKind.live), 1);
    });

    desktopTest('a view that gave up is not tried again at each return of the window', (tester) async {
      await pump(tester);
      engine().emit(PlayerEventKind.failed, 'libmpv: loading failed: 401 Unauthorized');
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(engine().calls.where((call) => call.startsWith('open')), hasLength(1));
      expect(find.textContaining('401'), findsOneWidget);
    });

    desktopTest('without libmpv, the live view is announced for later', (tester) async {
      desktopVideoAvailable = false;
      await pump(tester);
      expect(find.byKey(const Key('camera_live_later')), findsOneWidget);
      expect(players.made, isEmpty);
    });
  });
}
