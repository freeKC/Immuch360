// The controller the viewer and the network page already drive (VideoPlayerNotifier and the two pages hold a
// NativeVideoPlayerController), made of a pooled media_kit player on the computers (design 2.2, "The flat player").
// Nothing of the notifier or of the pages changes: they load, play, pause, stop, seek, loop and set the volume as on
// the phones, and get the same notifications (ready, status, position, ended, error).
//
// What differs from the phones' native players, and is mapped here:
// - mpv's stop unloads the file: a play after a stop opens it again from the start, as the native players restart;
// - the pool may take the player away for another page (player_pool.dart): the position and whether the video
//   played are noted, and the next call that needs the player reopens the video there;
// - mpv says when a frame of the new file is on the texture (playback-restart): "ready" waits for it, so that a
//   reused player never shows the last frame of the previous video;
// - mpv takes a file it can no longer read (a share or a server gone, a drive pulled out) for its end: an end well
//   before the duration is reported as the error the phones give, and a load of the same video again (the Retry of
//   the network page) starts where it stopped;
// - a player whose graphics device was lost (a driver update, a GPU reset) shows no picture any more: the pool
//   replaces it, and the video opens again where it was in the new one;
// - buffering: the position stands still while mpv waits for its cache, which is how the existing controls tell a
//   stall (VideoPlayerNotifier, NetworkVideoBufferingIndicator); [buffering] gives mpv's own state as well;
// - audio tracks, which the phones' flat players do not offer: listed here for the audio track button of the
//   controls (desktop_audio_track_button.dart).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('DesktopVideoController');

/// What a player of the computers is given for a [VideoSource]: a path of this computer or a media bridge URL (see
/// desktop_video_sources.dart). Throws when the source cannot be played here.
typedef DesktopVideoSourceResolver = Future<String> Function(VideoSource source);

/// The player that played or loaded last: the audio track button of the controls follows it. One video plays at a
/// time on the computers, the viewer loading only the page on screen.
final activeDesktopVideo = ValueNotifier<MediaKitVideoPlayerController?>(null);

class MediaKitVideoPlayerController with ChangeNotifier implements NativeVideoPlayerController {
  MediaKitVideoPlayerController({
    required PlayerPool pool,
    required this._resolve,
    String label = 'video',
    this.positionInterval = const Duration(milliseconds: 200),
  }) {
    _lease = pool.lease(PlayerKind.playback, label: label, onSuspend: _onSuspend);
  }

  /// How often the position is passed on while the video plays: the slider and the stall detection of the controls
  /// (700 ms) need a few a second, not mpv's one per frame
  final Duration positionInterval;

  /// How long "ready" waits for the frame size once a frame is shown, for a file whose video track mpv sizes late
  static const readyWithoutSize = Duration(seconds: 2);

  /// How far before its duration a video may end and still count as ended, at least: the last frame of a file is a
  /// frame or so before the duration its container declares, and a stop further back is a file that could not be read
  /// on. One hundredth of the duration when that is more, for a duration FFmpeg estimates (a stream without index).
  static const endTolerance = Duration(seconds: 2);

  final DesktopVideoSourceResolver _resolve;
  late final PlayerLease _lease;

  @override
  final onPlaybackReady = ChangeNotifier();

  @override
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);

  @override
  final onPlaybackPositionChanged = ValueNotifier<int>(0);

  @override
  final onPlaybackSpeedChanged = ValueNotifier<double>(1);

  @override
  final onVolumeChanged = ValueNotifier<double>(0);

  @override
  final onPlaybackEnded = ChangeNotifier();

  @override
  final onError = ValueNotifier<String?>(null);

  final _videoController = ValueNotifier<VideoController?>(null);
  final _buffering = ValueNotifier(false);
  final _audioTracks = ValueNotifier<List<DesktopAudioTrack>>(const []);
  final _audioTrack = ValueNotifier<String?>(null);

  /// The texture the view draws, null while the controller holds no player
  ValueListenable<VideoController?> get videoController => _videoController;

  /// mpv waits for its cache
  ValueListenable<bool> get buffering => _buffering;

  /// The audio tracks of the file, none until it is open
  ValueListenable<List<DesktopAudioTrack>> get audioTracks => _audioTracks;

  /// The id of the audio track that plays
  ValueListenable<String?> get audioTrack => _audioTrack;

  /// The player held now, for the measurement harness and the tests
  @visibleForTesting
  PlaybackEngine? get engine => _engine;

  /// The language last picked in the audio track menu, chosen first for the next videos of the session
  static String? preferredAudioLanguage;

  VideoSource? _videoSource;
  VideoInfo? _videoInfo;
  double _speed = 1;
  double _volume = 0;
  bool _loop = false;

  /// What the player opens for [_videoSource]; null before a load succeeded
  String? _resource;

  /// The file was closed by [stop] or a failure: a play or a seek opens it again
  bool _unloaded = false;

  /// Where the video was when the pool took the player away, see [_onSuspend]
  ({Duration position, bool playing})? _resumeAt;

  /// Where a video stopped when its file could no longer be read, see [_onCompleted]: a load of the same source
  /// starts there
  ({String path, Duration position})? _stoppedEarly;

  /// The load after [_stoppedEarly] reports "paused" once ready, so that play goes on from there rather than "ended",
  /// which the controls would replay from the start
  bool _pausedWhenReady = false;

  PlaybackEngine? _engine;
  StreamSubscription<PlayerEvent>? _events;

  /// Changed by every load and stop: what an older one started is not taken for the current video
  int _generation = 0;
  bool _ready = false;
  bool _restarted = false;
  bool _audioChosen = false;
  Timer? _readyTimer;
  Timer? _positionTimer;
  bool _positionPending = false;
  bool _disposed = false;

  PlaybackStatus get _status => onPlaybackStatusChanged.value;

  int get _position => onPlaybackPositionChanged.value;

  @override
  VideoSource? get videoSource => _videoSource;

  @override
  VideoInfo? get videoInfo => _videoInfo;

  @override
  PlaybackInfo? get playbackInfo {
    final duration = _videoInfo?.duration ?? 0;
    return PlaybackInfo(
      status: _status,
      position: _position,
      positionFraction: duration > 0 ? _position / duration : 0,
      speed: _speed,
      volume: _volume,
      error: onError.value,
    );
  }

  @override
  Future<void> loadVideoSource(VideoSource videoSource) async {
    final stoppedEarly = _stoppedEarly;
    _stoppedEarly = null;
    final start = stoppedEarly != null && stoppedEarly.path == videoSource.path ? stoppedEarly.position : Duration.zero;
    await stop();
    final generation = ++_generation;
    _videoSource = null;
    _videoInfo = null;
    _resource = null;
    _resumeAt = null;
    _audioChosen = false;
    _pausedWhenReady = start > Duration.zero;
    // A load that fails the same way twice is still told to the page
    onError.value = null;
    final String resource;
    try {
      resource = await _resolve(videoSource);
    } catch (error) {
      _fail(generation, 'This video cannot be played on the computer: ${redactPlayerText('$error')}');
      return;
    }
    if (_disposed || generation != _generation) {
      return;
    }
    _resource = resource;
    _videoSource = videoSource;
    final engine = await _engineForUse();
    if (engine == null || generation != _generation) {
      return;
    }
    await _open(engine, generation, start);
  }

  @override
  Future<void> play() async {
    final engine = await _engineForUse();
    if (engine == null) {
      return;
    }
    if (_unloaded && !await _open(engine, _generation, Duration.zero)) {
      return;
    }
    if (!await _onEngine(engine, engine.play)) {
      return;
    }
    onPlaybackStatusChanged.value = PlaybackStatus.playing;
    await setPlaybackSpeed(_speed);
    activeDesktopVideo.value = this;
  }

  @override
  Future<void> pause() async {
    _resumeAt = _resumeAt == null ? null : (position: _resumeAt!.position, playing: false);
    await _engine?.pause();
    if (_status == PlaybackStatus.playing) {
      onPlaybackStatusChanged.value = PlaybackStatus.paused;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _ready = false;
    _restarted = false;
    _readyTimer?.cancel();
    _positionTimer?.cancel();
    _positionTimer = null;
    _positionPending = false;
    final engine = _engine;
    if (engine != null && !_unloaded) {
      // After an open still running, never before it: the file would stay open
      await _onEngine(engine, engine.stop);
    }
    _unloaded = true;
    _buffering.value = false;
    onPlaybackPositionChanged.value = 0;
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
  }

  @override
  Future<bool> isPlaying() async => _status == PlaybackStatus.playing && (_engine?.playing.value ?? false);

  @override
  Future<void> seekTo(int milliseconds) async {
    final duration = _videoInfo?.duration ?? 0;
    final position = math.max(0, math.min(milliseconds, duration));
    final suspended = _lease.isSuspended;
    final engine = await _engineForUse(resumeAt: suspended ? Duration(milliseconds: position) : null);
    if (engine == null) {
      return;
    }
    if (_unloaded) {
      await _open(engine, _generation, Duration(milliseconds: position));
    } else if (!suspended) {
      await engine.seek(Duration(milliseconds: position));
    }
    if (_status != PlaybackStatus.playing) {
      onPlaybackPositionChanged.value = position;
    }
  }

  @override
  Future<void> seekForward(int milliseconds) {
    final duration = _videoInfo?.duration ?? 0;
    return seekTo(math.min(_position + milliseconds, duration));
  }

  @override
  Future<void> seekBackward(int milliseconds) => seekTo(math.max(_position - milliseconds, 0));

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (_status == PlaybackStatus.playing) {
      await _engine?.setRate(speed);
    }
    _speed = speed;
    onPlaybackSpeedChanged.value = speed;
  }

  @override
  Future<void> setVolume(double volume) async {
    await _engine?.setVolume(volume);
    _volume = volume;
    onVolumeChanged.value = volume;
  }

  @override
  Future<void> setLoop(bool loop) async {
    _loop = loop;
    await _engine?.setLoop(loop);
  }

  /// Plays the audio track [id] of [audioTracks], and prefers its language for the next videos
  Future<void> selectAudioTrack(String id) async {
    final track = _audioTracks.value.where((track) => track.id == id).firstOrNull;
    if (track == null) {
      return;
    }
    preferredAudioLanguage = track.language ?? preferredAudioLanguage;
    await _engine?.setAudioTrack(id);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _readyTimer?.cancel();
    _positionTimer?.cancel();
    _unbind();
    if (identical(activeDesktopVideo.value, this)) {
      activeDesktopVideo.value = null;
    }
    // The player goes back to the pool, stopped; the notifiers stay, as the phones' controller leaves them, since the
    // pages remove their listeners after the view that disposes this
    unawaited(_lease.release());
    super.dispose();
  }

  /// The player for a call, taken from the pool when needed. After a suspension the video opens again where it was,
  /// or at [resumeAt] (a seek), and plays on if it played. Null without a video or once disposed.
  Future<PlaybackEngine?> _engineForUse({Duration? resumeAt}) async {
    if (_disposed || _resource == null) {
      return null;
    }
    final wasSuspended = _lease.isSuspended;
    final PlaybackEngine engine;
    try {
      engine = await _lease.acquire();
    } catch (error) {
      _log.warning('No player for the video: $error');
      return null;
    }
    if (_disposed) {
      return null;
    }
    if (!identical(_lease.engine, engine)) {
      // Another page took it before this one used it (both asked at once): taken back at the next call
      return null;
    }
    if (!identical(engine, _engine)) {
      _bind(engine);
    }
    final resume = _resumeAt;
    _resumeAt = null;
    if (wasSuspended && resume != null && !_unloaded) {
      if (await _open(engine, _generation, resumeAt ?? resume.position) &&
          resume.playing &&
          await _onEngine(engine, engine.play)) {
        onPlaybackStatusChanged.value = PlaybackStatus.playing;
      }
    }
    return engine;
  }

  /// Opens the video of this controller at [start] in [engine], with the volume and the loop of the page. False when
  /// nothing was opened: the controller was disposed, stopped or loaded again meanwhile, or the pool took the player.
  Future<bool> _open(PlaybackEngine engine, int generation, Duration start) {
    final resource = _resource;
    if (resource == null) {
      return Future.value(false);
    }
    _unloaded = false;
    _ready = false;
    _restarted = false;
    // Opened again from its start or elsewhere (a replay, a seek): the place where the file stopped is no longer used
    _stoppedEarly = null;
    // Checked before each call, the page may have gone or the pool taken the player while the previous one ran: an
    // open that came after the pool's stop would leave the file held by a parked player
    bool current() => !_disposed && generation == _generation && identical(_lease.engine, engine);
    return _lease.guard(() async {
      try {
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await engine.setVolume(_volume);
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await engine.setLoop(_loop);
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await engine.open(resource, start: start, streamed: resource.startsWith('http'));
        return true;
      } catch (error) {
        _fail(generation, 'The video could not be opened: ${redactPlayerText('$error')}');
        return false;
      }
    });
  }

  /// An open left undone because the pool took the player: the video opens at [start] in the next one
  bool _openDropped(PlaybackEngine engine, int generation, Duration start) {
    if (!_disposed && generation == _generation && !identical(_lease.engine, engine)) {
      _resumeAt ??= (position: start, playing: false);
    }
    return false;
  }

  /// Runs [action] on [engine] after what the lease runs before it, when the lease still holds [engine]; false when it
  /// does not (the pool took it: the action would reach another page's video)
  Future<bool> _onEngine(PlaybackEngine engine, Future<void> Function() action) => _lease.guard(() async {
    if (!identical(_lease.engine, engine)) {
      return false;
    }
    await action();
    return true;
  });

  /// Called by the pool before it gives the player to another page: where the video was, to come back to it
  Future<void> _onSuspend() async {
    final engine = _engine;
    if (engine != null && !_unloaded) {
      // An open the pool cut short already noted where it was to start
      _resumeAt ??= (position: engine.position.value, playing: _status == PlaybackStatus.playing);
    }
    _unbind();
    if (_status == PlaybackStatus.playing) {
      onPlaybackStatusChanged.value = PlaybackStatus.paused;
    }
  }

  /// The texture of the player can no longer show a picture: the pool replaces the player, and the video opens again
  /// where it was, playing if it played
  void _onTextureLost() {
    final engine = _engine;
    if (engine == null || !engine.textureLost.value || _disposed) {
      return;
    }
    unawaited(_replacePlayer());
  }

  Future<void> _replacePlayer() async {
    await _lease.discard();
    if (!_disposed && !_unloaded) {
      await _engineForUse();
    }
  }

  void _bind(PlaybackEngine engine) {
    _unbind();
    _engine = engine;
    engine.position.addListener(_onPosition);
    engine.duration.addListener(_checkReady);
    engine.videoSize.addListener(_checkReady);
    engine.hasVideo.addListener(_checkReady);
    engine.completed.addListener(_onCompleted);
    engine.textureLost.addListener(_onTextureLost);
    engine.buffering.addListener(_onBuffering);
    engine.audioTracks.addListener(_onAudioTracks);
    engine.audioTrack.addListener(_onAudioTrack);
    _events = engine.events.listen(_onEvent);
    _videoController.value = engine.videoController;
    // Lost while another page held it, or before: no change comes to tell it
    if (engine.textureLost.value) {
      _onTextureLost();
    }
  }

  void _unbind() {
    final engine = _engine;
    if (engine == null) {
      return;
    }
    engine.position.removeListener(_onPosition);
    engine.duration.removeListener(_checkReady);
    engine.videoSize.removeListener(_checkReady);
    engine.hasVideo.removeListener(_checkReady);
    engine.completed.removeListener(_onCompleted);
    engine.textureLost.removeListener(_onTextureLost);
    engine.buffering.removeListener(_onBuffering);
    engine.audioTracks.removeListener(_onAudioTracks);
    engine.audioTrack.removeListener(_onAudioTrack);
    unawaited(_events?.cancel());
    _events = null;
    _engine = null;
    _videoController.value = null;
    _buffering.value = false;
  }

  void _onEvent(PlayerEvent event) {
    switch (event.kind) {
      case PlayerEventKind.loaded:
        break;
      case PlayerEventKind.restarted:
        if (!_restarted && !_unloaded) {
          _restarted = true;
          _readyTimer?.cancel();
          _readyTimer = Timer(readyWithoutSize, () => _announceReady(force: true));
          _checkReady();
        }
      case PlayerEventKind.failed:
        // A file libmpv cannot open, before "ready". Once a file plays, mpv 0.39 takes a read error for its end and
        // sends no failure: see [_onCompleted]
        if (!_unloaded) {
          _fail(_generation, event.message ?? 'The video could not be played');
        }
    }
  }

  void _checkReady() => _announceReady(force: false);

  /// Tells the page that the video is ready once a frame of it is shown and its duration and size are known (the
  /// size: unless mpv does not tell it within [readyWithoutSize])
  void _announceReady({required bool force}) {
    final engine = _engine;
    if (_ready || !_restarted || _unloaded || engine == null) {
      return;
    }
    final duration = engine.duration.value;
    final size = engine.videoSize.value;
    final sized = size != null || engine.hasVideo.value == false;
    if (duration <= Duration.zero || (!sized && !force)) {
      return;
    }
    _ready = true;
    _readyTimer?.cancel();
    _videoInfo = VideoInfo.fromJson({
      'width': size?.width ?? 0,
      'height': size?.height ?? 0,
      'duration': duration.inMilliseconds,
    });
    if (_pausedWhenReady) {
      _pausedWhenReady = false;
      if (_status == PlaybackStatus.stopped) {
        onPlaybackStatusChanged.value = PlaybackStatus.paused;
      }
    }
    activeDesktopVideo.value = this;
    onPlaybackReady.notifyListeners();
  }

  void _onPosition() {
    if (!_ready || _unloaded) {
      return;
    }
    if (positionInterval <= Duration.zero) {
      _sendPosition();
      return;
    }
    if (_positionTimer != null) {
      // Passed on when the interval ends, the last one of a burst too (where the video paused, for instance)
      _positionPending = true;
      return;
    }
    _sendPosition();
    _positionTimer = Timer(positionInterval, _positionIntervalEnded);
  }

  void _positionIntervalEnded() {
    _positionTimer = null;
    if (_positionPending) {
      _positionPending = false;
      _sendPosition();
      _positionTimer = Timer(positionInterval, _positionIntervalEnded);
    }
  }

  void _sendPosition() {
    final engine = _engine;
    if (engine == null || !_ready || _unloaded) {
      return;
    }
    onPlaybackPositionChanged.value = engine.position.value.inMilliseconds;
  }

  void _onCompleted() {
    final engine = _engine;
    if (engine == null || !engine.completed.value || !_ready || _unloaded) {
      return;
    }
    _sendPosition();
    final position = engine.position.value;
    final duration = engine.duration.value;
    final tolerance = duration ~/ 100 > endTolerance ? duration ~/ 100 : endTolerance;
    if (duration > Duration.zero && position < duration - tolerance) {
      // mpv 0.39 takes a read error for the end of the file, after FFmpeg's reconnects too, plays what it had, and
      // stops there (keep-open) without a failure: the share, the server or the drive went away
      final path = _videoSource?.path;
      _fail(_generation, 'The video stopped before its end: its file could no longer be read');
      if (path != null) {
        _stoppedEarly = (path: path, position: position);
      }
      // The decoder and the connection are let go; the position stays on the page
      unawaited(_onEngine(engine, engine.stop));
      return;
    }
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
    onPlaybackEnded.notifyListeners();
  }

  void _onBuffering() => _buffering.value = _engine?.buffering.value ?? false;

  void _onAudioTracks() {
    final tracks = _engine?.audioTracks.value ?? const [];
    _audioTracks.value = tracks;
    // The language picked last, once per video, when the file has it and does not play it already
    final language = preferredAudioLanguage;
    if (_audioChosen || tracks.length < 2 || language == null) {
      return;
    }
    _audioChosen = true;
    final track = tracks.where((track) => track.language == language).firstOrNull;
    if (track != null && track.id != _engine?.audioTrack.value) {
      unawaited(_engine?.setAudioTrack(track.id));
    }
  }

  void _onAudioTrack() => _audioTrack.value = _engine?.audioTrack.value;

  void _fail(int generation, String message) {
    if (_disposed || generation != _generation) {
      return;
    }
    _log.warning(message);
    _unloaded = true;
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
    onError.value = message;
  }
}
