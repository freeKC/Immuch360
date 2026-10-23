import 'package:async/async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_track_buttons.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_time_bar.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';

/// Play, pause and seek for the video of the asset viewer. They hide 5 s after they show while it plays, and 5 s after
/// the last key that reaches them.
///
/// On a TV (the remote control layout) they also hide while the video loads, every key of the remote starts the 5 s
/// again wherever it goes, they show when the video ends, and -10 s and +10 s buttons follow play and pause, for the
/// remotes without fast forward and rewind (left and right go to the previous or next asset there, see
/// remoteVideoArrows); the time bar under them takes the remote: left and right on it seek, faster while held (see
/// VideoTimeBar). The audio track and subtitle menus follow, for a video that has several audio tracks or subtitles
/// (VideoTrackButtons, DesktopAudioTrackButton).
class VideoControls extends ConsumerStatefulWidget {
  final String videoPlayerName;

  static const List<Shadow> _controlShadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

  const VideoControls({super.key, required this.videoPlayerName});

  @override
  ConsumerState<VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends ConsumerState<VideoControls> {
  late final RestartableTimer _hideTimer;

  AutoDisposeStateNotifierProvider<VideoPlayerNotifier, VideoPlayerState> get _provider =>
      videoPlayerProvider(widget.videoPlayerName);

  @override
  void initState() {
    super.initState();
    _hideTimer = RestartableTimer(videoControlsHideAfter, _onHideTimer);
    HardwareKeyboard.instance.addHandler(_onAnyKey);
  }

  @override
  void didUpdateWidget(covariant VideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPlayerName != widget.videoPlayerName) {
      _hideTimer.reset();
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onAnyKey);
    _hideTimer.cancel();
    super.dispose();
  }

  /// On a TV every key starts the 5 s again, the keys that the viewer takes itself (fast forward, play and pause...)
  /// included: the controls hide 5 s after the last key, never under a user who is still using the remote
  bool _onAnyKey(KeyEvent event) {
    if (mounted && event is! KeyUpEvent && ref.read(tvModeProvider)) {
      _hideTimer.reset();
    }
    return false;
  }

  void _onHideTimer() {
    if (!mounted) {
      return;
    }
    final tvMode = ref.read(tvModeProvider);
    // On a TV, not under a menu or a dialog of the viewer: 5 s once it closes
    if (tvMode && !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _hideTimer.reset();
      return;
    }
    final status = ref.read(_provider).status;
    // A TV also hides them while the video loads: a slow network would keep them there for ever
    if (status == VideoPlaybackStatus.playing || (tvMode && status == VideoPlaybackStatus.buffering)) {
      ref.read(assetViewerProvider.notifier).setControls(false);
    }
  }

  /// On a TV the controls show when the video reaches its end (loop off): the replay button and the time are there.
  /// A video just loaded is reported ended too, at its start, which does not count.
  void _onStatus(VideoPlaybackStatus? previous, VideoPlaybackStatus status) {
    _hideTimer.reset();
    if (status == VideoPlaybackStatus.completed &&
        previous != VideoPlaybackStatus.completed &&
        ref.read(tvModeProvider) &&
        ref.read(_provider).position > Duration.zero) {
      ref.read(assetViewerProvider.notifier).setControls(true);
    }
  }

  void _toggle(bool isCasting) {
    if (isCasting) {
      ref.read(castProvider.notifier).toggle();
      return;
    }

    ref.read(_provider.notifier).toggle();
  }

  /// The -10 s and +10 s buttons of a TV
  void _seekBy(bool isCasting, Duration delta) {
    _hideTimer.reset();
    if (!isCasting) {
      ref.read(_provider.notifier).seekBy(delta);
      return;
    }
    final cast = ref.read(castProvider);
    var target = cast.currentTime + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (cast.duration > Duration.zero && target > cast.duration) {
      target = cast.duration;
    }
    ref.read(castProvider.notifier).seekTo(target);
  }

  void _onSeek(bool isCasting, Duration seekTo) {
    if (isCasting) {
      ref.read(castProvider.notifier).seekTo(seekTo);
      return;
    }

    ref.read(_provider.notifier).seekTo(seekTo);
  }

  @override
  Widget build(BuildContext context) {
    final cast = ref.watch(castProvider);
    final isCasting = cast.isCasting;

    final (position, duration) = isCasting
        ? ref.watch(castProvider.select((c) => (c.currentTime, c.duration)))
        : ref.watch(_provider.select((v) => (v.position, v.duration)));

    final videoStatus = ref.watch(_provider.select((v) => v.status));
    final isPlaying = isCasting
        ? cast.castState == CastState.playing
        : videoStatus == VideoPlaybackStatus.playing || videoStatus == VideoPlaybackStatus.buffering;
    final isFinished = !isCasting && videoStatus == VideoPlaybackStatus.completed;

    ref.listen(assetViewerProvider.select((v) => v.showingControls), (prev, showing) {
      if (showing && prev != showing) {
        _hideTimer.reset();
      }
    });
    ref.listen(_provider.select((v) => v.status), _onStatus);

    final notifier = ref.watch(_provider.notifier);
    final isLoaded = duration != Duration.zero;
    final tvMode = ref.watch(tvModeProvider);

    // Every key that reaches the controls (a remote moving between them) starts the 5 s again: they hide 5 s after the
    // last key, not under a user who is still using them
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, _) {
        _hideTimer.reset();
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
        child: Column(
          spacing: 4,
          children: [
            Row(
              children: [
                IconButton(
                  iconSize: 32,
                  padding: const EdgeInsets.all(12),
                  constraints: const BoxConstraints(),
                  icon: isFinished
                      ? const Icon(Icons.replay, color: Colors.white, shadows: VideoControls._controlShadows)
                      : AnimatedPlayPause(
                          color: Colors.white,
                          playing: isPlaying,
                          shadows: VideoControls._controlShadows,
                        ),
                  onPressed: () => _toggle(isCasting),
                ),
                // The computers' player lists the audio tracks of a video that has several
                if (CurrentPlatform.isDesktop && !isCasting)
                  const DesktopAudioTrackButton(shadows: VideoControls._controlShadows),
                // A remote without fast forward and rewind keys seeks with these: on a TV left and right go to the
                // previous or next asset. After play and pause, which OK focuses first.
                if (tvMode) ...[
                  IconButton(
                    key: const Key('video_controls_seek_back'),
                    iconSize: 32,
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(),
                    tooltip: context.t.desktop_video_seek_back,
                    icon: const Icon(Icons.replay_10, color: Colors.white, shadows: VideoControls._controlShadows),
                    onPressed: isLoaded ? () => _seekBy(isCasting, -remoteSeekStep) : null,
                  ),
                  IconButton(
                    key: const Key('video_controls_seek_forward'),
                    iconSize: 32,
                    padding: const EdgeInsets.all(12),
                    constraints: const BoxConstraints(),
                    tooltip: context.t.desktop_video_seek_forward,
                    icon: const Icon(Icons.forward_10, color: Colors.white, shadows: VideoControls._controlShadows),
                    onPressed: isLoaded ? () => _seekBy(isCasting, remoteSeekStep) : null,
                  ),
                ],
                // The audio tracks and the subtitles of the player of the phones, TVs and headsets
                if (!CurrentPlatform.isDesktop && !isCasting)
                  VideoTrackButtons(playerKey: widget.videoPlayerName, shadows: VideoControls._controlShadows),
                const Spacer(),
                IgnorePointer(
                  child: Text(
                    "${position.format()} / ${duration.format()}",
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                      shadows: VideoControls._controlShadows,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
            VideoTimeBar(
              position: position,
              duration: duration,
              tvMode: tvMode,
              onHold: notifier.hold,
              onRelease: notifier.release,
              onToggle: () => _toggle(isCasting),
              onSeek: isLoaded ? (position) => _onSeek(isCasting, position) : null,
            ),
          ],
        ),
      ),
    );
  }
}
