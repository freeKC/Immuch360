// The mini controller of a film that plays on a screen, at the bottom of every page of the phone once the page of
// the film is gone (the Cast mini controller pattern): what the screen does, the title, the position, play or pause
// and Stop, or Close once it ended. A tap on the title opens the page of the film again, with its whole controller
// (remote_play_bar.widget.dart). Out of the way while a page shows that controller, while the keyboard is up, and
// on the big screens, which never play on another one.
//
// It sits in the builder of the app, above the navigator: no tooltip, slider nor sheet here, which need an overlay.
//
// A film cast to a Cast device (experimental) shows here the same way when no screen plays one: what the device does,
// the title, play or pause and Stop; a tap opens the "Play on" sheet of that film again, with the cast's controls.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/cast/cast_group.widget.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_bar.widget.dart';
import 'package:immich_mobile/providers/cast/cast_play.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_ui/immich_ui.dart';

/// Opens the page of the film of [playback] on this phone
typedef OpenRemoteFilm = void Function(WidgetRef ref, RemotePlayback playback);

void _openWithRouter(WidgetRef ref, RemotePlayback playback) {
  final path = playback.request.path;
  if (path != null) {
    unawaited(ref.read(appRouterProvider).push(NetworkVideoRoute(sourceId: playback.request.sourceId, path: path)));
  }
}

/// Opens the controls of the cast [playback]
typedef OpenCast = void Function(WidgetRef ref, CastPlayback playback);

void _openCastSheet(WidgetRef ref, CastPlayback playback) {
  final context = ref.read(appRouterProvider).navigatorKey.currentContext;
  if (context != null) {
    unawaited(showPlayOnSheet(context, playback.request));
  }
}

class RemotePlayDock extends ConsumerWidget {
  const RemotePlayDock({
    super.key,
    required this.child,
    this.openFilm = _openWithRouter,
    this.openCast = _openCastSheet,
  });

  /// The app: its navigator and its pages
  final Widget child;

  final OpenRemoteFilm openFilm;
  final OpenCast openCast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(remotePlaybackProvider);
    final cast = ref.watch(castPlaybackProvider);
    final pageShowsItsOwn = ref.watch(remotePlayBarsShownProvider) > 0;
    final keyboardDown = MediaQuery.viewInsetsOf(context).bottom == 0;
    final show = playback != null && !pageShowsItsOwn && keyboardDown;
    final showCast = !show && playback == null && cast != null && keyboardDown;
    // The same widgets whether the bar shows or not: the navigator under them keeps its pages
    return Column(
      children: [
        Expanded(
          child: MediaQuery.removePadding(context: context, removeBottom: show || showCast, child: child),
        ),
        if (show) _DockBar(playback: playback, onOpen: () => openFilm(ref, playback)),
        if (showCast) _CastDockBar(playback: cast, onOpen: () => openCast(ref, cast)),
      ],
    );
  }
}

/// The dock of a cast; the position moves on between two statuses of the device
class _CastDockBar extends ConsumerStatefulWidget {
  const _CastDockBar({required this.playback, required this.onOpen});

  final CastPlayback playback;
  final VoidCallback onOpen;

  @override
  ConsumerState<_CastDockBar> createState() => _CastDockBarState();
}

class _CastDockBarState extends ConsumerState<_CastDockBar> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.playback.isPlaying) {
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
    final duration = playback.durationMs ?? 0;
    final started = playback.phase == CastPhase.playing || playback.phase == CastPhase.paused;
    return Material(
      key: const Key('cast_dock'),
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (duration > 0)
              LinearProgressIndicator(
                value: (playback.positionAt(DateTime.now()) / duration).clamp(0.0, 1.0),
                minHeight: 2,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: const Key('cast_dock_open'),
                      onTap: widget.onOpen,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm, vertical: ImmichSpacing.sm),
                        child: Row(
                          children: [
                            Icon(Icons.cast_connected_rounded, color: scheme.primary),
                            const SizedBox(width: ImmichSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    castPhaseLine(t, playback),
                                    key: const Key('cast_dock_phase'),
                                    style: theme.labelMedium?.copyWith(color: scheme.primary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (playback.title.isNotEmpty)
                                    Text(
                                      playback.title,
                                      style: theme.titleSmall,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (playback.live) ...[
                    IconButton(
                      key: const Key('cast_dock_play'),
                      icon: Icon(
                        playback.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        semanticLabel: playback.isPlaying ? t.pause : t.play,
                      ),
                      onPressed: started ? (playback.isPlaying ? controller.pause : controller.play) : null,
                    ),
                    IconButton(
                      key: const Key('cast_dock_stop'),
                      icon: Icon(Icons.stop_rounded, semanticLabel: t.cast_stop),
                      onPressed: () => unawaited(controller.stop()),
                    ),
                  ] else
                    IconButton(
                      key: const Key('cast_dock_close'),
                      icon: Icon(Icons.close_rounded, semanticLabel: t.close),
                      onPressed: () => unawaited(controller.dismiss()),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DockBar extends ConsumerWidget {
  const _DockBar({required this.playback, required this.onOpen});

  final RemotePlayback playback;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final theme = context.textTheme;
    final scheme = context.colorScheme;
    final controller = ref.read(remotePlaybackProvider.notifier);
    final state = playback.state;
    final duration = state.durationMs ?? 0;
    final playing = state.phase == ScreenPlayPhase.playing || state.phase == ScreenPlayPhase.buffering;
    final live = !playback.lost && !playback.ended;
    return Material(
      key: const Key('remote_play_dock'),
      color: scheme.surfaceContainerHigh,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (duration > 0)
              LinearProgressIndicator(
                key: const Key('remote_play_dock_position'),
                value: (state.positionMs / duration).clamp(0.0, 1.0),
                minHeight: 2,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: const Key('remote_play_dock_open'),
                      onTap: playback.request.path == null ? null : onOpen,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: ImmichSpacing.sm, vertical: ImmichSpacing.sm),
                        child: Row(
                          children: [
                            Icon(Icons.cast_connected_rounded, color: scheme.primary),
                            const SizedBox(width: ImmichSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    remotePlayPhaseLine(t, playback),
                                    key: const Key('remote_play_dock_phase'),
                                    style: theme.labelMedium?.copyWith(color: scheme.primary),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (playback.request.title case final title?)
                                    Text(title, style: theme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (live) ...[
                    IconButton(
                      key: const Key('remote_play_dock_play'),
                      icon: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        semanticLabel: playing ? t.pause : t.play,
                      ),
                      onPressed: () => unawaited(playing ? controller.pause() : controller.resume()),
                    ),
                    IconButton(
                      key: const Key('remote_play_dock_stop'),
                      icon: Icon(Icons.stop_rounded, semanticLabel: t.play_bar_stop),
                      onPressed: () => unawaited(controller.stop()),
                    ),
                  ] else
                    IconButton(
                      key: const Key('remote_play_dock_close'),
                      icon: Icon(Icons.close_rounded, semanticLabel: t.close),
                      onPressed: controller.dismiss,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
