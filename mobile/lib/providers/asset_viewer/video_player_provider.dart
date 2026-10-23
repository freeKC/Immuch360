import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'video_player_provider.freezed.dart';

enum VideoPlaybackStatus {
  paused,
  playing,
  buffering,
  completed,

  /// The video does not play: the native player reported an error, or nothing played for
  /// [VideoPlayerNotifier.stallTimeout] while it loaded (see [VideoPlayerNotifier.failure]). Not playing: the remote
  /// goes to the next item, play tries again (see [VideoPlayerNotifier.retry]).
  failed,
}

/// Why a video is [VideoPlaybackStatus.failed]
enum VideoFailureKind {
  /// The native player reported an error: a decoder that refused the video, a file it could not read
  error,

  /// Nothing played for [VideoPlayerNotifier.stallTimeout] while the video loaded: a network or a server too slow for
  /// its bit rate, or a decoder that never gave a frame. It clears by itself when the video plays after all.
  stalled,
}

/// Why a video does not play: its [kind], and the native player's own [message] for an error (technical, not
/// translated: for the logs and as the last resort of the failure panel)
class VideoPlaybackFailure {
  const VideoPlaybackFailure(this.kind, [this.message]);

  final VideoFailureKind kind;
  final String? message;

  @override
  bool operator ==(Object other) => other is VideoPlaybackFailure && other.kind == kind && other.message == message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'VideoPlaybackFailure($kind, $message)';
}

@freezed
abstract class VideoPlayerState with _$VideoPlayerState {
  const factory VideoPlayerState({
    required Duration position,
    required Duration duration,
    required VideoPlaybackStatus status,
  }) = _VideoPlayerState;
}

const _defaultState = VideoPlayerState(
  position: Duration.zero,
  duration: Duration.zero,
  status: VideoPlaybackStatus.paused,
);

final videoPlayerProvider = StateNotifierProvider.autoDispose.family<VideoPlayerNotifier, VideoPlayerState, String>((
  ref,
  name,
) {
  return VideoPlayerNotifier();
});

class VideoPlayerNotifier extends StateNotifier<VideoPlayerState> {
  static final _log = Logger('VideoPlayerNotifier');

  /// How long a video may load, or stall once it played, before it counts as failed: the 360° player of Android
  /// gives up later (30 s, with Media3's own stuck buffering check), the flat players had no limit at all
  static const stallTimeout = Duration(seconds: 20);

  VideoPlayerNotifier() : super(_defaultState);

  NativeVideoPlayerController? _controller;
  Timer? _bufferingTimer;
  Timer? _seekTimer;
  // Runs while the status is buffering, see [stallTimeout]
  Timer? _stallTimer;
  VideoPlaybackFailure? _failure;
  VideoPlaybackStatus? _holdStatus;

  // Set while the video plays in an external player (the native 360° player): see [suspendForExternalPlayer]
  bool _suspended = false;
  VideoSource? _sourceAfterSuspension;

  // Whether the native player reported the video ready since it was last loaded
  bool _ready = false;
  // Where to take the video once it is ready again after an external player: see [resumeAfterExternalPlayerAt]
  ({Duration position, bool play})? _pendingRestore;
  // A restore that should have played, but came while the app was in the background: see [takePlayOnForeground]
  bool _playOnForeground = false;

  /// Whether [suspendForExternalPlayer] stopped this player
  bool get isSuspendedForExternalPlayer => _suspended;

  final _tracksChanged = ValueNotifier(0);

  /// Changes when the audio and subtitle tracks of the video may have changed: a native player attached, a video
  /// loaded, a track picked (see [tracks]); what the track menus of the controls listen to
  ValueListenable<int> get tracksChanged => _tracksChanged;

  /// Why the video does not play while the status is [VideoPlaybackStatus.failed], null otherwise
  VideoPlaybackFailure? get failure => _failure;

  /// Every status change goes through here: the stall check runs while the status is buffering, and a failure lasts
  /// only as long as the failed status
  @override
  @protected
  set state(VideoPlayerState value) {
    super.state = value;
    if (value.status != VideoPlaybackStatus.failed) {
      _failure = null;
    }
    if (value.status != VideoPlaybackStatus.buffering) {
      _stallTimer?.cancel();
      _stallTimer = null;
    } else {
      _stallTimer ??= Timer(stallTimeout, _onStalled);
    }
  }

  @override
  void dispose() {
    _bufferingTimer?.cancel();
    _seekTimer?.cancel();
    _stallTimer?.cancel();
    unawaited(_keepScreenOn(false));
    _controller = null;
    _tracksChanged.dispose();

    super.dispose();
  }

  void attachController(NativeVideoPlayerController controller) {
    _controller = controller;
    _tracksChanged.value++;
  }

  /// The native player reported other tracks: a video loaded, a track picked
  void onNativeTracksChanged() {
    if (mounted) {
      _tracksChanged.value++;
    }
  }

  /// The audio and subtitle tracks of the video, their languages named in [locale] (a BCP 47 tag): none before a
  /// native player is attached, and none where the player does not list them (iOS, and the computers, which have
  /// their own audio track menu)
  Future<List<NativeVideoTrack>> tracks({String? locale}) async {
    final controller = _controller;
    if (controller == null) {
      return const [];
    }
    try {
      return await controller.getTracks(locale: locale);
    } catch (e) {
      _log.warning('Error listing the tracks: $e');
      return const [];
    }
  }

  /// Plays [track], one of [tracks]
  Future<void> selectTrack(NativeVideoTrack track) async {
    try {
      if (!(await _controller?.selectTrack(track) ?? true)) {
        _log.info('The tracks changed before $track was picked');
      }
    } catch (e) {
      _log.severe('Error selecting a track: $e');
    }
  }

  /// Plays no track of [type]: subtitles off
  Future<void> disableTracks(NativeVideoTrackType type) async {
    try {
      await _controller?.disableTracks(type);
    } catch (e) {
      _log.severe('Error turning the $type tracks off: $e');
    }
  }

  Future<void> load(VideoSource source) async {
    if (_suspended) {
      _sourceAfterSuspension = source;
      return;
    }

    _ready = false;
    _playOnForeground = false;
    if (state.status == VideoPlaybackStatus.failed) {
      // Loading again: the spinner, and a new stall check, from now on
      state = state.copyWith(status: VideoPlaybackStatus.buffering);
    }
    _startBufferingTimer();
    try {
      await _controller?.loadVideoSource(source);
    } catch (e) {
      _log.severe('Error loading video source: $e');
    }
  }

  /// Loads the video again and plays it: what play does on a video that failed
  Future<void> retry() async {
    final source = _controller?.videoSource;
    if (source == null || _suspended) {
      return;
    }
    await load(source);
    await play();
  }

  /// The native player reported an error ([message]): the video fails until it is loaded again
  void onNativeError(String message) {
    if (!mounted || _suspended) {
      return;
    }
    _fail(VideoPlaybackFailure(VideoFailureKind.error, message));
  }

  void _onStalled() {
    _stallTimer = null;
    if (!mounted || state.status != VideoPlaybackStatus.buffering) {
      return;
    }
    _log.warning('Nothing played for ${stallTimeout.inSeconds} s: ${_controller?.videoSource?.path ?? 'no source'}');
    _fail(const VideoPlaybackFailure(VideoFailureKind.stalled));
  }

  void _fail(VideoPlaybackFailure failure) {
    _bufferingTimer?.cancel();
    unawaited(_keepScreenOn(false));
    // Before the state: its listeners read the failure with the status
    _failure = failure;
    state = state.copyWith(status: VideoPlaybackStatus.failed);
  }

  Future<void> pause() async {
    _playOnForeground = false;
    if (_controller == null) {
      return;
    }

    _bufferingTimer?.cancel();

    try {
      await _controller!.pause();
      await _flushSeek();
    } catch (e) {
      _log.severe('Error pausing video: $e');
    }
  }

  Future<void> play() async {
    if (_controller == null || _suspended) {
      return;
    }
    if (state.status == VideoPlaybackStatus.failed) {
      await retry();
      return;
    }

    try {
      await _flushSeek();
      await _controller!.play();
    } catch (e) {
      _log.severe('Error playing video: $e');
    }

    _startBufferingTimer();
  }

  /// Stops the video while it plays in an external player: nothing plays behind that player, even a video that
  /// becomes ready later, and stopping, unlike pausing, frees the decoder and the buffered data for it.
  /// [play] does nothing and [load] waits until [resumeAfterExternalPlayer].
  Future<void> suspendForExternalPlayer() async {
    if (_suspended) {
      return;
    }

    _suspended = true;
    _ready = false;
    _pendingRestore = null;
    _playOnForeground = false;
    _bufferingTimer?.cancel();
    _seekTimer?.cancel();

    final controller = _controller;
    _sourceAfterSuspension = controller?.videoSource;
    if (controller == null || _sourceAfterSuspension == null) {
      return;
    }

    try {
      await controller.stop();
    } catch (e) {
      _log.severe('Error stopping video: $e');
    }
  }

  /// Ends [suspendForExternalPlayer]: loads the video again, stopped at the start like a video that did not autoplay
  Future<void> resumeAfterExternalPlayer() async {
    if (!_suspended) {
      return;
    }

    _suspended = false;
    final source = _sourceAfterSuspension;
    _sourceAfterSuspension = null;
    if (source != null) {
      await load(source);
    }
  }

  /// Ends [suspendForExternalPlayer] after an external player that played the video on (the Spatial 2.5D player):
  /// once the video is loaded again, goes to [position], where that player stopped, and plays when [play].
  ///
  /// Coming back to the foreground also ends the suspension, see [resumeAfterExternalPlayer], and may happen before
  /// or after the external player reports where it stopped: either way, the video goes to [position] as soon as the
  /// native player reports it ready, or right away when it already did.
  Future<void> resumeAfterExternalPlayerAt(Duration position, {required bool play}) async {
    final restore = (position: position, play: play);
    if (_suspended) {
      _pendingRestore = restore;
      await resumeAfterExternalPlayer();
      return;
    }

    if (_ready) {
      await _restore(restore);
    } else {
      _pendingRestore = restore;
    }
  }

  Future<void> _restore(({Duration position, bool play}) restore) async {
    final controller = _controller;
    if (controller == null || !mounted) {
      return;
    }

    // Straight to the native player: the video came back at its start, whatever the state still says
    _seekTimer?.cancel();
    state = state.copyWith(position: restore.position);
    try {
      await controller.seekTo(restore.position.inMilliseconds);
    } catch (e) {
      _log.severe('Error seeking video: $e');
    }

    if (restore.play) {
      // Same rule as the viewer's autoplay: nothing plays behind another app. The viewer plays it once the app is
      // back in the foreground, see [takePlayOnForeground].
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden) {
        _playOnForeground = true;
      } else {
        await play();
      }
    }
  }

  /// Whether a video taken back from an external player should play now that the app is in the foreground again:
  /// it was playing there, but became ready while the app was in the background, so it stayed paused. True once
  /// only, and no longer after the video is paused, toggled, loaded again or suspended meanwhile.
  bool takePlayOnForeground() {
    final play = _playOnForeground;
    _playOnForeground = false;
    return play;
  }

  Future<void> _flushSeek() async {
    final timer = _seekTimer;
    if (timer == null || !timer.isActive) {
      return;
    }

    timer.cancel();
    await _controller?.seekTo(state.position.inMilliseconds);
  }

  void seekTo(Duration position) {
    if (_controller == null || state.position == position) {
      return;
    }

    state = state.copyWith(position: position);

    if (_seekTimer?.isActive ?? false) {
      return;
    }

    _seekTimer = Timer(const Duration(milliseconds: 150), () {
      unawaited(_controller?.seekTo(state.position.inMilliseconds));
    });
  }

  /// Seeks [delta] from where the video is: not before its start, nor past its end once its duration is known
  void seekBy(Duration delta) {
    var target = state.position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (state.duration > Duration.zero && target > state.duration) {
      target = state.duration;
    }
    seekTo(target);
  }

  void toggle() {
    _holdStatus = null;
    _playOnForeground = false;

    switch (state.status) {
      case VideoPlaybackStatus.paused:
        unawaited(play());
      case VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering:
        unawaited(pause());
      case VideoPlaybackStatus.completed:
        unawaited(restart());
      case VideoPlaybackStatus.failed:
        unawaited(retry());
    }
  }

  /// Pauses playback and preserves the current status for later restoration.
  void hold() {
    if (_holdStatus != null) {
      return;
    }

    _holdStatus = state.status;
    unawaited(pause());
  }

  /// Restores playback to the status before [hold] was called.
  void release() {
    final status = _holdStatus;
    _holdStatus = null;

    switch (status) {
      case VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering:
        unawaited(play());
      default:
    }
  }

  Future<void> restart() async {
    seekTo(Duration.zero);
    await play();
  }

  Future<void> setVolume(double volume) async {
    try {
      await _controller?.setVolume(volume);
    } catch (e) {
      _log.severe('Error setting volume: $e');
    }
  }

  Future<void> setLoop(bool loop) async {
    try {
      await _controller?.setLoop(loop);
    } catch (e) {
      _log.severe('Error setting loop: $e');
    }
  }

  void onNativePlaybackReady() {
    if (!mounted) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    final videoInfo = _controller?.videoInfo;

    if (playbackInfo == null || videoInfo == null) {
      return;
    }

    state = state.copyWith(
      position: Duration(milliseconds: playbackInfo.position),
      duration: Duration(milliseconds: videoInfo.duration),
      // A player in error stays failed until it is loaded again; a stall ends here
      status: _failedOnError ? VideoPlaybackStatus.failed : _mapStatus(playbackInfo.status),
    );

    _ready = true;
    final restore = _pendingRestore;
    if (restore != null) {
      _pendingRestore = null;
      unawaited(_restore(restore));
    }
  }

  void onNativePositionChanged() {
    if (!mounted || (_seekTimer?.isActive ?? false)) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    if (playbackInfo == null) {
      return;
    }

    final position = Duration(milliseconds: playbackInfo.position);
    if (state.position == position) {
      return;
    }

    if (state.status == VideoPlaybackStatus.playing) {
      _startBufferingTimer();
    }

    // It moves: the buffering, or the stall, is over
    final moving =
        state.status == VideoPlaybackStatus.buffering ||
        (state.status == VideoPlaybackStatus.failed && !_failedOnError);
    state = state.copyWith(position: position, status: moving ? VideoPlaybackStatus.playing : state.status);
  }

  void onNativeStatusChanged() {
    // The plugin reports the status of its own calls (play, pause, stop), which do not lift an error
    if (!mounted || _failedOnError) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    if (playbackInfo == null) {
      return;
    }

    final newStatus = _mapStatus(playbackInfo.status);
    switch (newStatus) {
      case VideoPlaybackStatus.playing:
        unawaited(_keepScreenOn(true));
        _startBufferingTimer();
      default:
        onNativePlaybackEnded();
    }

    if (state.status != newStatus) {
      state = state.copyWith(status: newStatus);
    }
  }

  void onNativePlaybackEnded() {
    unawaited(_keepScreenOn(false));
    _bufferingTimer?.cancel();
  }

  /// What keeps the screen on, replaced by the tests
  @visibleForTesting
  static Future<void> Function(bool on) toggleWakelock = (on) => WakelockPlus.toggle(enable: on);

  /// Keeps the screen on while the video plays, or lets it go. A Linux session without the screen saver service that
  /// wakelock_plus asks (org.freedesktop.ScreenSaver: a bare window manager, WSLg, a CI virtual screen) refuses it: the
  /// video plays all the same, without an unhandled error per video
  static Future<void> _keepScreenOn(bool on) async {
    try {
      await toggleWakelock(on);
    } catch (error) {
      _log.fine('The screen cannot be kept on: $error');
    }
  }

  void _startBufferingTimer() {
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && state.status != VideoPlaybackStatus.completed && state.status != VideoPlaybackStatus.failed) {
        state = state.copyWith(status: VideoPlaybackStatus.buffering);
      }
    });
  }

  bool get _failedOnError => _failure?.kind == VideoFailureKind.error;

  static VideoPlaybackStatus _mapStatus(PlaybackStatus status) => switch (status) {
    PlaybackStatus.playing => VideoPlaybackStatus.playing,
    PlaybackStatus.paused => VideoPlaybackStatus.paused,
    PlaybackStatus.stopped => VideoPlaybackStatus.completed,
  };
}
