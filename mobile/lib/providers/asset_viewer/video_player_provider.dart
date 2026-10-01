import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

part 'video_player_provider.freezed.dart';

enum VideoPlaybackStatus { paused, playing, buffering, completed }

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

  VideoPlayerNotifier() : super(_defaultState);

  NativeVideoPlayerController? _controller;
  Timer? _bufferingTimer;
  Timer? _seekTimer;
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

  @override
  void dispose() {
    _bufferingTimer?.cancel();
    _seekTimer?.cancel();
    unawaited(WakelockPlus.disable());
    _controller = null;

    super.dispose();
  }

  void attachController(NativeVideoPlayerController controller) {
    _controller = controller;
  }

  Future<void> load(VideoSource source) async {
    if (_suspended) {
      _sourceAfterSuspension = source;
      return;
    }

    _ready = false;
    _playOnForeground = false;
    _startBufferingTimer();
    try {
      await _controller?.loadVideoSource(source);
    } catch (e) {
      _log.severe('Error loading video source: $e');
    }
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
      status: _mapStatus(playbackInfo.status),
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

    state = state.copyWith(
      position: position,
      status: state.status == VideoPlaybackStatus.buffering ? VideoPlaybackStatus.playing : state.status,
    );
  }

  void onNativeStatusChanged() {
    if (!mounted) {
      return;
    }

    final playbackInfo = _controller?.playbackInfo;
    if (playbackInfo == null) {
      return;
    }

    final newStatus = _mapStatus(playbackInfo.status);
    switch (newStatus) {
      case VideoPlaybackStatus.playing:
        unawaited(WakelockPlus.enable());
        _startBufferingTimer();
      default:
        onNativePlaybackEnded();
    }

    if (state.status != newStatus) {
      state = state.copyWith(status: newStatus);
    }
  }

  void onNativePlaybackEnded() {
    unawaited(WakelockPlus.disable());
    _bufferingTimer?.cancel();
  }

  void _startBufferingTimer() {
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && state.status != VideoPlaybackStatus.completed) {
        state = state.copyWith(status: VideoPlaybackStatus.buffering);
      }
    });
  }

  static VideoPlaybackStatus _mapStatus(PlaybackStatus status) => switch (status) {
    PlaybackStatus.playing => VideoPlaybackStatus.playing,
    PlaybackStatus.paused => VideoPlaybackStatus.paused,
    PlaybackStatus.stopped => VideoPlaybackStatus.completed,
  };
}
