// The mini controller of a film that plays on a screen, on the phone: "Playing on Living room TV", the title, play
// or pause, minus 10 s and plus 30 s, the position the screen tells, Audio and Subtitles (the tracks the screen's
// player lists), Stop, and "Continue on this phone". The remote of the screen keeps control: what it does shows here
// at the next state. A screen that stops answering says so; the bar then only offers to close.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// "1:02:03" or "4:05"
String playPositionText(int milliseconds) {
  final total = Duration(milliseconds: milliseconds < 0 ? 0 : milliseconds);
  final hours = total.inHours;
  final minutes = total.inMinutes.remainder(60).toString().padLeft(hours > 0 ? 2 : 1, '0');
  final seconds = total.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

/// What the screen does, in one line: "Playing on Living room TV"
String remotePlayPhaseLine(Translations t, RemotePlayback playback) {
  final screen = playback.screen.name;
  if (playback.lost) {
    return t.play_bar_lost(device: screen);
  }
  final state = playback.state;
  return switch (state.phase) {
    ScreenPlayPhase.asking => t.play_bar_asking(device: screen),
    ScreenPlayPhase.opening || ScreenPlayPhase.buffering => t.play_bar_opening(device: screen),
    ScreenPlayPhase.playing || ScreenPlayPhase.paused => t.play_bar_playing_on(device: screen),
    ScreenPlayPhase.ended => t.play_bar_ended(device: screen),
    ScreenPlayPhase.idle => t.play_bar_stopped(device: screen),
    ScreenPlayPhase.failed => t.play_bar_failed(device: screen),
  };
}

/// How many of these bars are on a page: the dock at the bottom of the app keeps out of their way
/// (remote_play_dock.widget.dart)
final remotePlayBarsShownProvider = StateProvider<int>((_) => 0);

class RemotePlayBar extends ConsumerStatefulWidget {
  const RemotePlayBar({super.key, required this.playback, this.onContinueHere});

  final RemotePlayback playback;

  /// "Continue on this phone": the screen stopped, the phone's player takes the film at [position]
  final void Function(Duration position)? onContinueHere;

  @override
  ConsumerState<RemotePlayBar> createState() => _RemotePlayBarState();
}

class _RemotePlayBarState extends ConsumerState<RemotePlayBar> {
  /// The position under the finger while the slider moves
  double? _dragging;

  RemotePlaybackController get _controller => ref.read(remotePlaybackProvider.notifier);

  late final StateController<int> _shown;

  @override
  void initState() {
    super.initState();
    // Counted after the frame, and let go after the frame: the dock is an ancestor of the page
    final shown = _shown = ref.read(remotePlayBarsShownProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shown.mounted) {
        shown.state++;
      }
    });
  }

  @override
  void dispose() {
    final shown = _shown;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (shown.mounted) {
        shown.state--;
      }
    });
    super.dispose();
  }

  Future<void> _chooseTrack(PlayTrackKind kind) async {
    final t = context.t;
    final tracks = widget.playback.state.tracks.where((track) => track.kind == kind).toList();
    final chosen = await showModalBottomSheet<({String? id})>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            if (kind == PlayTrackKind.subtitle)
              ListTile(
                key: const Key('play_bar_subtitles_off'),
                title: Text(t.video_subtitles_off),
                trailing: tracks.any((track) => track.selected) ? null : const Icon(Icons.check_rounded),
                onTap: () => Navigator.of(context).pop((id: null)),
              ),
            for (final track in tracks)
              ListTile(
                title: Text(track.label),
                trailing: track.selected ? const Icon(Icons.check_rounded) : null,
                onTap: () => Navigator.of(context).pop((id: track.id)),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) {
      await _controller.track(kind, chosen.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final playback = widget.playback;
    final state = playback.state;
    final duration = state.durationMs ?? 0;
    final position = _dragging?.round() ?? state.positionMs;
    final playing = state.phase == ScreenPlayPhase.playing || state.phase == ScreenPlayPhase.buffering;
    final live = !playback.lost && !playback.ended;
    final hasAudio = state.tracks.where((track) => track.kind == PlayTrackKind.audio).length > 1;
    final hasSubtitles = state.tracks.any((track) => track.kind == PlayTrackKind.subtitle);
    return Material(
      key: const Key('remote_play_bar'),
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(ImmichSpacing.md, ImmichSpacing.sm, ImmichSpacing.md, ImmichSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.cast_connected_rounded, color: scheme.primary),
                  const SizedBox(width: ImmichSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          remotePlayPhaseLine(t, playback),
                          key: const Key('remote_play_bar_phase'),
                          style: theme.labelMedium?.copyWith(color: scheme.primary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (playback.request.title case final title?)
                          Text(title, style: theme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('remote_play_bar_close'),
                    tooltip: t.close,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: live ? null : _controller.dismiss,
                  ),
                ],
              ),
              if (duration > 0)
                Row(
                  children: [
                    Text(playPositionText(position), style: theme.labelSmall),
                    Expanded(
                      child: Slider(
                        key: const Key('remote_play_bar_position'),
                        value: position.clamp(0, duration).toDouble(),
                        max: duration.toDouble(),
                        onChanged: live ? (value) => setState(() => _dragging = value) : null,
                        onChangeEnd: (value) {
                          setState(() => _dragging = null);
                          unawaited(_controller.seekTo(Duration(milliseconds: value.round())));
                        },
                      ),
                    ),
                    Text(playPositionText(duration), style: theme.labelSmall),
                  ],
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    key: const Key('remote_play_bar_back10'),
                    tooltip: t.play_bar_back_10,
                    icon: const Icon(Icons.replay_10_rounded),
                    onPressed: live ? () => unawaited(_controller.seekBy(const Duration(seconds: -10))) : null,
                  ),
                  IconButton.filled(
                    key: const Key('remote_play_bar_play'),
                    tooltip: playing ? t.pause : t.play,
                    icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    onPressed: live ? () => unawaited(playing ? _controller.pause() : _controller.resume()) : null,
                  ),
                  IconButton(
                    key: const Key('remote_play_bar_forward30'),
                    tooltip: t.play_bar_forward_30,
                    icon: const Icon(Icons.forward_30_rounded),
                    onPressed: live ? () => unawaited(_controller.seekBy(const Duration(seconds: 30))) : null,
                  ),
                  if (hasAudio)
                    IconButton(
                      key: const Key('remote_play_bar_audio'),
                      tooltip: t.video_audio_track,
                      icon: const Icon(Icons.audiotrack_rounded),
                      onPressed: live ? () => unawaited(_chooseTrack(PlayTrackKind.audio)) : null,
                    ),
                  if (hasSubtitles)
                    IconButton(
                      key: const Key('remote_play_bar_subtitles'),
                      tooltip: t.video_subtitles,
                      icon: const Icon(Icons.subtitles_rounded),
                      onPressed: live ? () => unawaited(_chooseTrack(PlayTrackKind.subtitle)) : null,
                    ),
                  IconButton(
                    key: const Key('remote_play_bar_stop'),
                    tooltip: t.play_bar_stop,
                    icon: const Icon(Icons.stop_rounded),
                    onPressed: live ? () => unawaited(_controller.stop()) : null,
                  ),
                ],
              ),
              if (widget.onContinueHere != null)
                TextButton.icon(
                  key: const Key('remote_play_bar_continue_here'),
                  icon: const Icon(Icons.smartphone_rounded),
                  label: Text(t.play_bar_continue_here),
                  onPressed: () async {
                    final continueHere = widget.onContinueHere!;
                    final at = live ? await _controller.stop() : Duration(milliseconds: playback.state.positionMs);
                    if (!live) {
                      _controller.dismiss();
                    }
                    continueHere(at);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
