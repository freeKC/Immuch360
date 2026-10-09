// What stands where the phones put NativeVideoPlayerView (design 2.2): the texture of a pooled media_kit player,
// drawn by the vendored media_kit_video, without media_kit's own controls (the pages keep VideoControls and
// NetworkVideoControls). It hands the pages a MediaKitVideoPlayerController through the same onViewReady the native
// view calls, after its first frame as a platform view does, and disposes it with itself, as the native view does.
//
// Without libmpv (Linux and macOS until their libs packages come in phase 4, or a Windows install whose DLL did not
// load) it shows the placeholder of phase 1, and the controller reports the load as an error, which the network page
// shows with its Retry.

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart';

class DesktopVideoView extends ConsumerStatefulWidget {
  const DesktopVideoView({super.key, required this.onViewReady, this.pool, this.resolve});

  /// Called once with the controller of the view, as NativeVideoPlayerView.onViewReady
  final void Function(NativeVideoPlayerController)? onViewReady;

  /// The pool and the source resolver, replaced by the tests; by default the app's pool, and the app's bridge and
  /// server for the sources
  final PlayerPool? pool;
  final DesktopVideoSourceResolver? resolve;

  @override
  ConsumerState<DesktopVideoView> createState() => _DesktopVideoViewState();
}

class _DesktopVideoViewState extends ConsumerState<DesktopVideoView> {
  late final MediaKitVideoPlayerController _controller;

  /// Whether this view has a player to show: libmpv loaded at start, or a pool given by a test
  late final bool _playable = desktopVideoAvailable || widget.pool != null;

  @override
  void initState() {
    super.initState();
    _controller = MediaKitVideoPlayerController(
      pool: widget.pool ?? desktopPlayerPool,
      label: 'video view',
      resolve: widget.resolve ?? (_playable ? _appResolver() : _unavailable),
    );
    // After the first frame, as the platform view calls back once it exists
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onViewReady?.call(_controller);
      }
    });
  }

  DesktopVideoSourceResolver _appResolver() {
    final bridge = ref.read(mediaBridgeProvider);
    String? endpoint() => Store.tryGet(StoreKey.serverEndpoint);
    return (source) => resolveDesktopVideoSource(
      source,
      bridge: bridge,
      serverEndpoint: endpoint(),
      // The app's client at each request: it changes with the network settings
      serverFileSystem: () => ImmichServerFileSystem(endpoint: endpoint, client: () => NetworkRepository.client),
    );
  }

  static Future<String> _unavailable(VideoSource source) async =>
      throw UnsupportedError('Video playback is not available on this computer yet');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_playable) {
      return const DesktopVideoPlaceholder();
    }
    return RepaintBoundary(
      child: ValueListenableBuilder<VideoController?>(
        valueListenable: _controller.videoController,
        builder: (context, videoController, _) => videoController == null
            ? const SizedBox.expand()
            : Video(
                // A new player (the pool gave another one) is a new texture, and a new state of the widget
                key: ObjectKey(videoController),
                controller: videoController,
                controls: NoVideoControls,
                // What is around the video shows the page behind it, as the native view on the phones
                fill: Colors.transparent,
                filterQuality: FilterQuality.medium,
                // The pages hold the wake lock and pause in the background themselves (VideoPlayerNotifier)
                wakelock: false,
                pauseUponEnteringBackgroundMode: false,
                resumeUponEnteringForegroundMode: false,
              ),
      ),
    );
  }
}
