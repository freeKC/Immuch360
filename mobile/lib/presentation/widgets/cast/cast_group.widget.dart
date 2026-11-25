// The "Cast devices" group of the "Play on..." sheet (experimental): the Chromecasts, Google TVs, Android TVs with Cast
// built in and Nest Hubs found nearby, each with what the Plex metadata says of the film there (should play, may not
// play, cannot play, with why), and the controls of the cast under way: what the device does, the title, the
// position and the duration, minus 10 s, play or pause, plus 30 s, the volume and Stop.
//
// A device that cannot play the film asks before casting ("Try anyway"). A device at the address of a linked screen
// announced nearby is left to its row in "Your screens".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/cast/cast_media.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_bar.widget.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// "HEVC video, DTS sound"
String castReasonsText(Translations t, List<CastIssue> issues) => [
  for (final issue in issues)
    switch (issue.kind) {
      CastIssueKind.container => t.cast_reason_container(name: issue.name),
      CastIssueKind.video => t.cast_reason_video(name: issue.name),
      CastIssueKind.audio => t.cast_reason_audio(name: issue.name),
      CastIssueKind.size => t.cast_reason_size,
    },
].join(', ');

/// What the device does, in one line: "Casting to Living room"
String castPhaseLine(Translations t, CastPlayback playback) {
  final device = playback.target.name;
  return switch (playback.phase) {
    CastPhase.connecting => t.cast_connecting(device: device),
    CastPhase.loading || CastPhase.buffering => t.cast_opening(device: device),
    CastPhase.playing || CastPhase.paused => t.cast_playing_on(device: device),
    CastPhase.showing => t.cast_showing_on(device: device),
    CastPhase.ended =>
      playback.request.kind == PlayKind.plex ? t.cast_ended(device: device) : t.cast_video_ended(device: device),
    CastPhase.takenOver => t.cast_taken_over(device: device),
    CastPhase.lost => t.cast_lost(device: device),
    CastPhase.failed => t.cast_failed(device: device),
  };
}

/// The sentence for an outcome other than playing; [film] for a Plex film, else a photo or a video
String castOutcomeText(
  Translations t,
  CastOutcome outcome, {
  required String device,
  required String server,
  bool film = true,
}) => switch (outcome) {
  CastOutcome.playing => t.cast_playing_on(device: device),
  CastOutcome.noNetwork => t.cast_err_no_network(device: device),
  CastOutcome.film => film ? t.cast_err_film(server: server) : t.cast_err_item(server: server),
  CastOutcome.unreachable => t.cast_err_unreachable(device: device),
  CastOutcome.launch => t.cast_err_launch(device: device),
  CastOutcome.load => film ? t.cast_err_load(device: device) : t.cast_err_load_item(device: device),
};

/// The key of the item's information for [request]
PlayOnRequest castFilmKeyOf(PlayOnRequest request) => request;

class CastGroup extends ConsumerStatefulWidget {
  const CastGroup({super.key, required this.request, required this.screenHosts});

  final PlayOnRequest request;

  /// The addresses of the linked screens announced nearby
  final Set<String> screenHosts;

  @override
  ConsumerState<CastGroup> createState() => _CastGroupState();
}

class _CastGroupState extends ConsumerState<CastGroup> {
  String? _busy;
  String? _message;
  Timer? _messageTimer;

  @override
  void dispose() {
    _messageTimer?.cancel();
    super.dispose();
  }

  void _say(String message) {
    _messageTimer?.cancel();
    setState(() => _message = message);
    _messageTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() => _message = null);
      }
    });
  }

  bool get _film => widget.request.kind == PlayKind.plex;

  Future<void> _cast(CastTarget target, CastFormatCheck? check) async {
    final t = context.t;
    if (!await confirmPrivatePlayOn(context, widget.request, target.name) || !mounted) {
      return;
    }
    if (check != null && check.support == CastSupport.no) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          key: const Key('cast_cannot_dialog'),
          title: Text(
            widget.request.isPhoto
                ? t.cast_cannot_title_photo(device: target.name)
                : _film
                ? t.cast_cannot_title(device: target.name)
                : t.cast_cannot_title_item(device: target.name),
          ),
          content: Text(
            widget.request.isPhoto
                ? t.cast_cannot_body_photo(reasons: castReasonsText(t, check.reasons))
                : _film
                ? t.cast_cannot_body(reasons: castReasonsText(t, check.reasons))
                : t.cast_cannot_body_item(reasons: castReasonsText(t, check.reasons)),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(t.cancel)),
            TextButton(
              key: const Key('cast_try_anyway'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t.cast_try_anyway),
            ),
          ],
        ),
      );
      if (go != true || !mounted) {
        return;
      }
    }
    setState(() => _busy = target.id);
    final outcome = await ref.read(castPlaybackProvider.notifier).cast(target, widget.request);
    if (!mounted) {
      return;
    }
    setState(() => _busy = null);
    if (outcome != CastOutcome.playing) {
      _say(castOutcomeText(t, outcome, device: target.name, server: widget.request.serverName, film: _film));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final discovery = ref.watch(castDevicesProvider);
    final rows = castRowsOf(discovery.devices, widget.screenHosts);
    final info = ref.watch(castFilmInfoProvider(castFilmKeyOf(widget.request)));
    final cast = ref.watch(castPlaybackProvider);
    final message = _message;
    return Column(
      key: const Key('cast_group'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(ImmichSpacing.sm, ImmichSpacing.md, ImmichSpacing.sm, 0),
          child: Text(t.cast_group_title, style: theme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm, vertical: ImmichSpacing.xs),
          child: Text(_film ? t.cast_group_hint : t.cast_group_hint_item, style: theme.bodySmall),
        ),
        if (cast != null) CastControls(playback: cast),
        for (final target in rows) _row(context, target, info.whenOrNull(data: (film) => film), info.isLoading, cast),
        if (rows.isEmpty)
          ListTile(
            key: const Key('cast_status'),
            leading: discovery.searching
                ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3))
                : const Icon(Icons.cast_rounded),
            title: Text(discovery.searching ? t.cast_searching : t.cast_none, style: theme.bodyMedium),
          ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.all(ImmichSpacing.sm),
            child: Text(
              message,
              key: const Key('cast_message'),
              style: theme.bodyMedium?.copyWith(color: scheme.primary),
            ),
          ),
      ],
    );
  }

  Widget _row(BuildContext context, CastTarget target, CastFilmInfo? film, bool checking, CastPlayback? cast) {
    final t = context.t;
    final scheme = context.colorScheme;
    final photo = film?.photo ?? false;
    final version = film == null || photo ? null : castVersionFor(film, castProfileOf(target.model));
    final check = photo ? film?.photoCheck : version?.check;
    final verdict = photo
        ? (check == null ? t.cast_shows_photo : t.cast_cannot_show(reasons: castReasonsText(t, check.reasons)))
        : switch (check?.support) {
            null => checking ? (_film ? t.cast_checking : t.cast_checking_item) : null,
            CastSupport.yes => _film ? t.cast_plays : t.cast_plays_video,
            CastSupport.maybe => t.cast_may_not_play(reasons: castReasonsText(t, check!.reasons)),
            CastSupport.no => t.cast_cannot_play(reasons: castReasonsText(t, check!.reasons)),
          };
    final model = target.model;
    final lines = [
      if (model != null && model != target.name) model,
      ?verdict,
      if (version?.converted ?? false) t.cast_converted_version,
      if (film?.flat360 ?? false) t.cast_flat_360,
    ];
    final busy = _busy == target.id;
    final current = cast != null && cast.live && cast.target.id == target.id;
    return ListTile(
      isThreeLine: lines.length > 1,
      key: ValueKey('cast_${target.id}'),
      leading: Icon(current ? Icons.cast_connected_rounded : Icons.cast_rounded),
      title: Text(target.name),
      subtitle: lines.isEmpty
          ? null
          : Text(lines.join('\n'), style: check?.support == CastSupport.no ? TextStyle(color: scheme.error) : null),
      trailing: busy ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)) : null,
      onTap: _busy == null ? () => unawaited(_cast(target, check)) : null,
    );
  }
}

/// The controls of a cast: in the sheet, and in the sheet the dock opens
class CastControls extends ConsumerStatefulWidget {
  const CastControls({super.key, required this.playback});

  final CastPlayback playback;

  @override
  ConsumerState<CastControls> createState() => _CastControlsState();
}

class _CastControlsState extends ConsumerState<CastControls> {
  Timer? _tick;
  double? _dragging;
  double? _volume;

  @override
  void initState() {
    super.initState();
    // The position between two statuses of the device is counted here
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.playback.isPlaying && _dragging == null) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final playback = widget.playback;
    final controller = ref.read(castPlaybackProvider.notifier);
    final position = playback.positionAt(DateTime.now());
    final duration = playback.durationMs ?? 0;
    final live = playback.live;
    final started = playback.phase == CastPhase.playing || playback.phase == CastPhase.paused;
    final shown = _dragging ?? (duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0);
    final volume = _volume ?? playback.volume;
    return Card(
      key: const Key('cast_controls'),
      margin: const EdgeInsets.symmetric(vertical: ImmichSpacing.sm),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(ImmichSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              castPhaseLine(t, playback),
              key: const Key('cast_controls_phase'),
              style: theme.labelMedium?.copyWith(color: scheme.primary),
            ),
            if (playback.title.isNotEmpty)
              Text(playback.title, style: theme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (duration > 0) ...[
              Slider(
                key: const Key('cast_controls_position'),
                value: shown,
                onChanged: started ? (value) => setState(() => _dragging = value) : null,
                onChangeEnd: started
                    ? (value) {
                        setState(() => _dragging = null);
                        controller.seekTo(Duration(milliseconds: (value * duration).round()));
                      }
                    : null,
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    playPositionText(_dragging == null ? position : (_dragging! * duration).round()),
                    key: const Key('cast_controls_time'),
                    style: theme.labelMedium,
                  ),
                  Text(playPositionText(duration), style: theme.labelMedium),
                ],
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (live) ...[
                  IconButton(
                    key: const Key('cast_controls_back'),
                    icon: Icon(Icons.replay_10_rounded, semanticLabel: t.play_bar_back_10),
                    onPressed: started ? () => controller.seekBy(const Duration(seconds: -10)) : null,
                  ),
                  IconButton.filledTonal(
                    key: const Key('cast_controls_play'),
                    iconSize: 32,
                    icon: Icon(
                      playback.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      semanticLabel: playback.isPlaying ? t.pause : t.play,
                    ),
                    onPressed: started ? (playback.isPlaying ? controller.pause : controller.play) : null,
                  ),
                  IconButton(
                    key: const Key('cast_controls_forward'),
                    icon: Icon(Icons.forward_30_rounded, semanticLabel: t.play_bar_forward_30),
                    onPressed: started ? () => controller.seekBy(const Duration(seconds: 30)) : null,
                  ),
                  IconButton(
                    key: const Key('cast_controls_stop'),
                    icon: Icon(Icons.stop_rounded, semanticLabel: t.cast_stop),
                    onPressed: () => unawaited(controller.stop()),
                  ),
                ] else
                  TextButton.icon(
                    key: const Key('cast_controls_close'),
                    icon: const Icon(Icons.close_rounded),
                    label: Text(t.close),
                    onPressed: () => unawaited(controller.dismiss()),
                  ),
              ],
            ),
            if (live && volume != null)
              Row(
                children: [
                  Icon(
                    playback.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                    semanticLabel: t.cast_volume,
                  ),
                  Expanded(
                    child: Slider(
                      key: const Key('cast_controls_volume'),
                      value: volume.clamp(0.0, 1.0),
                      onChanged: (value) => setState(() => _volume = value),
                      onChangeEnd: (value) {
                        setState(() => _volume = null);
                        controller.setVolume(value);
                      },
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
