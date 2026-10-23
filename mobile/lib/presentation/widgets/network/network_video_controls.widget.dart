import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/extensions/duration_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_track_buttons.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_time_bar.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';

const _shadows = [Shadow(color: Colors.black87, blurRadius: 6, offset: Offset(0, 1))];

/// Play, pause and seek for the player of a video of a network share, the one of [videoPlayerProvider] under
/// [playerKey]. On a TV -10 s and +10 s buttons follow play and pause, for the remotes without fast forward and rewind
/// (left and right go to the previous or next file there, see remoteVideoArrows), and the time bar under them takes
/// the remote: left and right on it seek, faster while held (see VideoTimeBar). The audio track and subtitle menus
/// follow, for a video that has several audio tracks or subtitles (VideoTrackButtons, DesktopAudioTrackButton).
class NetworkVideoControls extends ConsumerWidget {
  const NetworkVideoControls({super.key, required this.playerKey, this.playFocusNode});

  final String playerKey;

  /// The focus of the play button, for the page to put the remote there
  final FocusNode? playFocusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = videoPlayerProvider(playerKey);
    final (position, duration, status) = ref.watch(provider.select((v) => (v.position, v.duration, v.status)));
    final notifier = ref.watch(provider.notifier);
    final isPlaying = status == VideoPlaybackStatus.playing || status == VideoPlaybackStatus.buffering;
    final isFinished = status == VideoPlaybackStatus.completed;
    final isLoaded = duration != Duration.zero;
    final tvMode = ref.watch(tvModeProvider);

    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('network_video_play_pause'),
                focusNode: playFocusNode,
                iconSize: 32,
                padding: const EdgeInsets.all(12),
                constraints: const BoxConstraints(),
                tooltip: isPlaying ? context.t.pause : context.t.play,
                icon: isFinished
                    ? const Icon(Icons.replay, color: Colors.white, shadows: _shadows)
                    : AnimatedPlayPause(color: Colors.white, playing: isPlaying, shadows: _shadows),
                onPressed: notifier.toggle,
              ),
              // The computers' player lists the audio tracks of a video that has several
              if (CurrentPlatform.isDesktop) const DesktopAudioTrackButton(shadows: _shadows),
              if (tvMode) ...[
                IconButton(
                  key: const Key('network_video_seek_back'),
                  iconSize: 32,
                  padding: const EdgeInsets.all(12),
                  constraints: const BoxConstraints(),
                  tooltip: context.t.desktop_video_seek_back,
                  icon: const Icon(Icons.replay_10, color: Colors.white, shadows: _shadows),
                  onPressed: isLoaded ? () => notifier.seekBy(-remoteSeekStep) : null,
                ),
                IconButton(
                  key: const Key('network_video_seek_forward'),
                  iconSize: 32,
                  padding: const EdgeInsets.all(12),
                  constraints: const BoxConstraints(),
                  tooltip: context.t.desktop_video_seek_forward,
                  icon: const Icon(Icons.forward_10, color: Colors.white, shadows: _shadows),
                  onPressed: isLoaded ? () => notifier.seekBy(remoteSeekStep) : null,
                ),
              ],
              // The audio tracks and the subtitles of the player of the phones, TVs and headsets
              if (!CurrentPlatform.isDesktop) VideoTrackButtons(playerKey: playerKey, shadows: _shadows),
              const Spacer(),
              IgnorePointer(
                child: Text(
                  '${position.format()} / ${duration.format()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontFeatures: [FontFeature.tabularFigures()],
                    shadows: _shadows,
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
            onToggle: notifier.toggle,
            onSeek: isLoaded ? notifier.seekTo : null,
          ),
        ],
      ),
    );
  }
}
