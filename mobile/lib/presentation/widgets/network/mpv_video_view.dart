// What stands where the network page puts NativeVideoPlayerView when libmpv plays the film (the Meta Quest build of
// release 46, film_player_choice.dart): the texture of a pooled media_kit player, as the computers draw it
// (DesktopVideoView), without the computers' AV2 decoder and server sources. It hands the page a
// MediaKitVideoPlayerController through the same onViewReady, after its first frame, and disposes it with itself.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/infrastructure/mpv/android_mpv.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('MpvVideoView');

class MpvVideoView extends ConsumerStatefulWidget {
  const MpvVideoView({super.key, required this.onViewReady, this.pool, this.resolve});

  /// Called once with the controller of the view, as NativeVideoPlayerView.onViewReady
  final void Function(NativeVideoPlayerController)? onViewReady;

  /// The pool and the source resolver, replaced by the tests; by default the Quest's pool (AndroidMpv.pool), and the
  /// source's own address (a URL of the app's media bridge)
  final PlayerPool? pool;
  final DesktopVideoSourceResolver? resolve;

  @override
  ConsumerState<MpvVideoView> createState() => _MpvVideoViewState();
}

class _MpvVideoViewState extends ConsumerState<MpvVideoView> {
  late final MediaKitVideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = MediaKitVideoPlayerController(
      pool: widget.pool ?? AndroidMpv.pool,
      label: 'film',
      resolve: widget.resolve ?? (source) async => source.path,
      linkOf: widget.resolve == null ? desktopAppVideoLink(ref) : null,
    );
    _controller.decoding.addListener(_onDecoding);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onViewReady?.call(_controller);
      }
    });
  }

  String? _hwdecLogged;

  /// How mpv decodes the film, once per change, for the tests on the headset: "mediacodec-copy" is the hardware
  /// decoder, "no" FFmpeg in software
  void _onDecoding() {
    final hwdec = _controller.decoding.value.hwdec;
    if (hwdec != null && hwdec != _hwdecLogged) {
      _hwdecLogged = hwdec;
      _log.info('libmpv decodes the video with hwdec $hwdec');
    }
  }

  @override
  void dispose() {
    _controller.decoding.removeListener(_onDecoding);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<VideoController?>(
        valueListenable: _controller.videoController,
        builder: (context, videoController, _) => videoController == null
            ? const SizedBox.expand()
            : Video(
                key: ObjectKey(videoController),
                controller: videoController,
                controls: NoVideoControls,
                fill: Colors.transparent,
                filterQuality: FilterQuality.medium,
                // The page holds the wake lock and pauses in the background itself (VideoPlayerNotifier)
                wakelock: false,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: false,
              ),
      ),
    );
  }
}
