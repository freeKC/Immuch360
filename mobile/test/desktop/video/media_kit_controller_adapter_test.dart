// The controller of the desktop player against a fake player (plan 2.5): the same notifications as the phones'
// NativeVideoPlayerController for what VideoPlayerNotifier and the two pages do (load, play, pause, stop, seek, loop,
// volume, speed, ended, error), the readiness that waits for a frame of the new file, the suspension by the pool and
// the resume at the position, a file that can no longer be read, a page that goes while its video opens, a lost
// picture, the audio tracks.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:native_video_player/native_video_player.dart';

import 'fake_playback_engine.dart';

const _bridgeUrl = 'http://127.0.0.1:41000/Zq8secretBridgeToken/smb-1/clips/a.mp4';

Future<VideoSource> _network(String url) => VideoSource.init(path: url, type: VideoSourceType.network);

Future<VideoSource> _file(String path) => VideoSource.init(path: path, type: VideoSourceType.file);

Future<String> _asIs(VideoSource source) async => source.path;

void main() {
  late FakePlayers players;

  setUp(() {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 10));
    MediaKitVideoPlayerController.preferredAudioLanguage = null;
  });

  MediaKitVideoPlayerController controller({DesktopVideoSourceResolver? resolve}) =>
      MediaKitVideoPlayerController(pool: players.pool, resolve: resolve ?? _asIs, positionInterval: Duration.zero);

  test('a load opens the source paused, and "ready" comes once a frame of it is shown, with its size', () async {
    final video = controller();
    var ready = 0;
    video.onPlaybackReady.addListener(() => ready++);

    await video.loadVideoSource(await _network(_bridgeUrl));
    final engine = players.made.single;
    expect(engine.calls, ['open $_bridgeUrl at 0 streamed']);
    expect(engine.playing.value, isFalse);
    await pumpEventQueue();

    expect(ready, 1);
    expect(video.videoInfo?.toJson(), {'height': 1080, 'width': 1920, 'duration': 10000});
    expect(video.videoSource?.path, _bridgeUrl);
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped, reason: 'as the native players after a load');
  });

  test('a file of this computer opens as a path, without the streaming cache', () async {
    final video = controller();
    await video.loadVideoSource(await _file(r'C:\Videos\a.mp4'));
    expect(players.made.single.calls.first, r'open C:\Videos\a.mp4 at 0');
  });

  test('no "ready" before the frame: a reused player shows nothing of the previous video', () async {
    players = FakePlayers();
    final video = controller();
    var ready = 0;
    video.onPlaybackReady.addListener(() => ready++);
    await video.loadVideoSource(await _network(_bridgeUrl));
    final engine = players.made.single;
    engine.duration.value = const Duration(seconds: 3);
    engine.videoSize.value = (width: 640, height: 360);
    await pumpEventQueue();
    expect(ready, 0, reason: 'duration and size known, but no frame of this file yet');

    engine.emit(PlayerEventKind.restarted);
    expect(ready, 1);
  });

  test('play, pause, speed, volume and loop reach the player; status and position follow', () async {
    final video = controller();
    final statuses = <PlaybackStatus>[];
    video.onPlaybackStatusChanged.addListener(() => statuses.add(video.onPlaybackStatusChanged.value));
    await video.setVolume(0.5);
    await video.setLoop(true);
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    final engine = players.made.single;
    expect(engine.volume, 0.5);
    expect(engine.loop, isTrue);

    await video.setPlaybackSpeed(1.5);
    expect(engine.rate, 1, reason: 'a speed set while paused waits for the play, as on the phones');
    await video.play();
    expect(engine.playing.value, isTrue);
    expect(engine.rate, 1.5);
    expect(await video.isPlaying(), isTrue);

    engine.position.value = const Duration(milliseconds: 2500);
    expect(video.onPlaybackPositionChanged.value, 2500);
    expect(video.playbackInfo?.positionFraction, 0.25);

    await video.pause();
    expect(await video.isPlaying(), isFalse);
    expect(statuses, [PlaybackStatus.playing, PlaybackStatus.paused]);
  });

  test('the end of the video stops it and is told once', () async {
    final video = controller();
    var ended = 0;
    video.onPlaybackEnded.addListener(() => ended++);
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await video.play();
    final engine = players.made.single;

    // mpv's last frame, a little before the duration the container declares
    engine.position.value = const Duration(milliseconds: 9960);
    engine.completed.value = true;
    expect(ended, 1);
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped);
    expect(video.onError.value, isNull);
  });

  test('a file that can no longer be read halfway is an error, not the end; loaded again, it starts there', () async {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60));
    final video = controller();
    var ended = 0;
    var ready = 0;
    video.onPlaybackEnded.addListener(() => ended++);
    video.onPlaybackReady.addListener(() => ready++);
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await video.play();
    final engine = players.made.single;

    // The share went away: mpv plays what it had, then stops there as at the end of the file
    engine.position.value = const Duration(seconds: 30);
    engine.completed.value = true;
    await pumpEventQueue();
    expect(ended, 0);
    expect(video.onError.value, contains('could no longer be read'));
    expect(video.onError.value, isNot(contains('Zq8secretBridgeToken')));
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped);
    expect(video.onPlaybackPositionChanged.value, 30000, reason: 'the page shows where it stopped');
    expect(engine.calls.last, 'stop', reason: 'the decoder and the connection let go');

    // The Retry of the network page loads the same video again
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    expect(engine.calls.where((call) => call.startsWith('open')).last, 'open $_bridgeUrl at 30000 streamed');
    expect(video.onError.value, isNull);
    expect(ready, 2);
    expect(
      video.onPlaybackStatusChanged.value,
      PlaybackStatus.paused,
      reason: 'play goes on from there, where "ended" would replay from the start',
    );

    // Another video, or the same one played to its end, starts at 0 again
    await video.seekTo(0);
    await video.loadVideoSource(await _network(_bridgeUrl));
    expect(engine.calls.where((call) => call.startsWith('open')).last, 'open $_bridgeUrl at 0 streamed');
  });

  test('a duration FFmpeg estimates: an end within a hundredth of it is still the end', () async {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(minutes: 10));
    final video = controller();
    var ended = 0;
    video.onPlaybackEnded.addListener(() => ended++);
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await video.play();
    final engine = players.made.single;

    engine.position.value = const Duration(minutes: 9, seconds: 55);
    engine.completed.value = true;
    expect(ended, 1);
    expect(video.onError.value, isNull);
  });

  test('seek: clamped to the video, the position follows at once while paused', () async {
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    final engine = players.made.single;

    await video.seekTo(4000);
    expect(engine.calls.last, 'seek 4000');
    expect(video.onPlaybackPositionChanged.value, 4000);
    await video.seekTo(99000);
    expect(engine.calls.last, 'seek 10000');
    await video.seekBackward(15000);
    expect(engine.calls.last, 'seek 0');
  });

  test('stop closes the file, and a play opens it again from the start', () async {
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await video.play();
    final engine = players.made.single;

    await video.stop();
    expect(engine.calls.last, 'stop');
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped);
    expect(video.onPlaybackPositionChanged.value, 0);

    await video.play();
    expect(engine.calls.sublist(engine.calls.length - 2), ['open $_bridgeUrl at 0 streamed', 'play']);
  });

  test('positions are passed on a few times a second, not at every frame, the last one included', () {
    fakeAsync((async) {
      // Made in the fake zone, so that its futures run when the test flushes them
      players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 10));
      final video = MediaKitVideoPlayerController(pool: players.pool, resolve: _asIs);
      final positions = <int>[];
      video.onPlaybackPositionChanged.addListener(() => positions.add(video.onPlaybackPositionChanged.value));
      unawaited(_network(_bridgeUrl).then(video.loadVideoSource));
      async.flushMicrotasks();
      final engine = players.made.single;
      positions.clear();

      for (var ms = 0; ms <= 1000; ms += 40) {
        engine.position.value = Duration(milliseconds: ms);
        async.elapse(const Duration(milliseconds: 40));
      }
      async.elapse(const Duration(seconds: 1));

      expect(positions.length, inInclusiveRange(4, 7), reason: 'about one each 200 ms over a second');
      expect(positions.last, 1000, reason: 'the position where it stopped is passed on');
    });
  });

  test('a source that cannot be played is an error for the page, without its address', () async {
    final video = controller(
      resolve: (source) async =>
          throw UnsupportedError('cannot open ${source.path} with cookie: immich_access_token=SECRET123'),
    );
    await video.loadVideoSource(await _network(_bridgeUrl));

    final error = video.onError.value;
    expect(error, isNotNull);
    expect(error, isNot(contains('Zq8secretBridgeToken')));
    expect(error, isNot(contains('SECRET123')));
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped);
    expect(players.made, isEmpty, reason: 'no player taken for a source refused');
  });

  test('a file libmpv cannot play is an error for the page; a retry tells it again', () async {
    players = FakePlayers();
    final video = controller();
    final errors = <String?>[];
    video.onError.addListener(() => errors.add(video.onError.value));

    await video.loadVideoSource(await _network(_bridgeUrl));
    players.made.single.emit(PlayerEventKind.failed, 'libmpv: unrecognized file format');
    expect(video.onError.value, 'libmpv: unrecognized file format');

    await video.loadVideoSource(await _network(_bridgeUrl));
    players.made.single.emit(PlayerEventKind.failed, 'libmpv: unrecognized file format');
    expect(errors.whereType<String>(), hasLength(2));
  });

  test('a player taken by the pool comes back at the position, playing if it played', () async {
    players = FakePlayers(
      maxPlayers: {PlayerKind.playback: 1},
      onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60),
    );
    final first = controller();
    await first.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await first.play();
    final engine = players.made.single;
    engine.position.value = const Duration(seconds: 42);

    // Another page takes the only player
    final second = controller();
    await second.loadVideoSource(await _file('/videos/b.mp4'));
    expect(first.onPlaybackStatusChanged.value, PlaybackStatus.paused);
    expect(first.videoController.value, isNull);
    expect(engine.resource, '/videos/b.mp4');

    // The first page needs its player again (a play, a seek): it reopens where it was and plays on
    await first.play();
    expect(engine.calls.where((call) => call.startsWith('open')).last, 'open $_bridgeUrl at 42000 streamed');
    expect(engine.playing.value, isTrue);
    expect(first.onPlaybackStatusChanged.value, PlaybackStatus.playing);
    expect(second.onPlaybackStatusChanged.value, isNot(PlaybackStatus.playing));
  });

  test('a seek while the pool has the player opens the video again at the place asked', () async {
    players = FakePlayers(
      maxPlayers: {PlayerKind.playback: 1},
      onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60),
    );
    final first = controller();
    await first.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await first.play();
    final engine = players.made.single;
    engine.position.value = const Duration(seconds: 42);
    final second = controller();
    await second.loadVideoSource(await _file('/videos/b.mp4'));
    expect(engine.resource, '/videos/b.mp4');

    await first.seekTo(10000);
    expect(engine.calls.where((call) => call.startsWith('open')).last, 'open $_bridgeUrl at 10000 streamed');
    expect(engine.calls.where((call) => call.startsWith('seek')), isEmpty, reason: 'opened there, not sought');
    expect(first.onPlaybackStatusChanged.value, PlaybackStatus.playing, reason: 'it played when it was taken');
  });

  test('the page a swipe left (paused) gives its player to the next one, and gets it back where it was', () async {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60));
    final left = controller();
    await left.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await left.play();
    final engine = players.made.single;
    engine.position.value = const Duration(seconds: 12);
    await left.pause();

    final next = controller();
    await next.loadVideoSource(await _file('/videos/b.mp4'));
    expect(players.made, hasLength(1), reason: 'one decoder for the viewer, not two');
    expect(engine.resource, '/videos/b.mp4');
    expect(left.videoController.value, isNull);

    await left.play();
    expect(engine.calls.where((call) => call.startsWith('open')).last, 'open $_bridgeUrl at 12000 streamed');
  });

  test('a page that goes while its video opens: the file is not opened after the player is stopped', () async {
    final hold = Completer<void>();
    players = FakePlayers(onCreate: (engine) => engine.holdVolume = hold);
    final video = controller();
    final loading = video.loadVideoSource(await _file('/videos/a.mp4'));
    await pumpEventQueue();
    final engine = players.made.single;
    expect(engine.calls, isEmpty, reason: 'the open waits for its volume');

    video.dispose();
    await pumpEventQueue();
    expect(engine.calls, isEmpty, reason: 'the pool waits for the open before it stops the player');
    hold.complete();
    await loading;
    await pumpEventQueue();
    expect(engine.calls.where((call) => call.startsWith('open')), isEmpty);
    expect(engine.calls.last, 'stop');
    expect(players.pool.idleCount(PlayerKind.playback), 1);
  });

  test('a stop while the video opens: no file is left open', () async {
    final hold = Completer<void>();
    players = FakePlayers(onCreate: (engine) => engine.holdVolume = hold);
    final video = controller();
    final loading = video.loadVideoSource(await _file('/videos/a.mp4'));
    await pumpEventQueue();
    final engine = players.made.single;

    final stopping = video.stop();
    hold.complete();
    await loading;
    await stopping;
    expect(engine.calls.where((call) => call.startsWith('open')), isEmpty);
    expect(engine.resource, isNull);
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.stopped);
  });

  test('a lost picture: a new player takes over, and the video goes on where it was', () async {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60));
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    await video.play();
    final lost = players.made.single;
    lost.position.value = const Duration(seconds: 20);

    lost.textureLost.value = true;
    await pumpEventQueue();
    expect(lost.disposed, isTrue);
    final fresh = players.made.last;
    expect(fresh, isNot(same(lost)));
    expect(fresh.calls, ['open $_bridgeUrl at 20000 streamed', 'play']);
    expect(video.onPlaybackStatusChanged.value, PlaybackStatus.playing);
    expect(video.engine, same(fresh));
  });

  test('a player whose picture is lost while it changes hands is replaced before the next page plays', () async {
    players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(seconds: 60));
    final left = controller();
    await left.loadVideoSource(await _file('/videos/a.mp4'));
    await pumpEventQueue();
    final lost = players.made.single;
    lost.position.value = const Duration(seconds: 12);
    // The device goes as the pool stops the player for the next page, when no page listens to it
    lost.position.addListener(() {
      if (lost.position.value == Duration.zero) {
        lost.textureLost.value = true;
      }
    });

    final next = controller();
    await next.loadVideoSource(await _file('/videos/b.mp4'));
    await pumpEventQueue();

    expect(lost.disposed, isTrue);
    final fresh = players.made.last;
    expect(fresh, isNot(same(lost)));
    expect(fresh.calls.where((call) => call.startsWith('open')).single, 'open /videos/b.mp4 at 0');
    expect(next.engine, same(fresh));
  });

  test('dispose gives the player back to the pool, stopped, for the next page', () async {
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    final engine = players.made.single;

    video.dispose();
    await pumpEventQueue();
    expect(engine.calls.last, 'stop');
    expect(players.pool.idleCount(PlayerKind.playback), 1);

    final next = controller();
    await next.loadVideoSource(await _file('/videos/c.mp4'));
    expect(players.made, hasLength(1), reason: 'reused, not made again');
  });

  test('audio tracks: listed, chosen, and the language picked is preferred for the next video', () async {
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    final engine = players.made.single;
    const tracks = [
      DesktopAudioTrack(id: '1', language: 'eng', channels: 2, isDefault: true),
      DesktopAudioTrack(id: '2', language: 'fre', channels: 6),
    ];
    engine.audioTracks.value = tracks;
    engine.audioTrack.value = '1';
    expect(video.audioTracks.value, tracks);
    expect(video.audioTrack.value, '1');
    expect(activeDesktopVideo.value, same(video));

    await video.selectAudioTrack('2');
    expect(engine.calls.last, 'audio 2');
    expect(MediaKitVideoPlayerController.preferredAudioLanguage, 'fre');

    await video.loadVideoSource(await _network(_bridgeUrl));
    await pumpEventQueue();
    engine.audioTrack.value = '1';
    engine.audioTracks.value = List.of(tracks);
    expect(engine.calls.last, 'audio 2', reason: 'the French track again');
  });

  test('buffering follows mpv', () async {
    final video = controller();
    await video.loadVideoSource(await _network(_bridgeUrl));
    final engine = players.made.single;
    engine.buffering.value = true;
    expect(video.buffering.value, isTrue);
    engine.buffering.value = false;
    expect(video.buffering.value, isFalse);
  });
}
