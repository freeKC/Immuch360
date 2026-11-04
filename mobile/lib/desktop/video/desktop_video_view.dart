// What stands where the phones put NativeVideoPlayerView (design 2.2): the texture of a pooled media_kit player,
// drawn by the vendored media_kit_video, without media_kit's own controls (the pages keep VideoControls and
// NetworkVideoControls). It hands the pages a MediaKitVideoPlayerController through the same onViewReady the native
// view calls, after its first frame as a platform view does, and disposes it with itself, as the native view does.
//
// Without libmpv (Linux and macOS until their libs packages come in phase 4, or a Windows install whose DLL did not
// load) the viewer shows the placeholder of phase 1 in its place ([DesktopVideoView.available]); on the network page
// the view shows it, hidden until a video is ready, and the controller reports the load as an error, which the page
// shows with its Retry.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/ai/creator/desktop_conversion_tools.dart';
import 'package:immich_mobile/desktop/ai/hardware_gate.dart';
import 'package:immich_mobile/desktop/network/immich_server_file_system.dart';
import 'package:immich_mobile/desktop/platform/desktop_local_image_api.dart';
import 'package:immich_mobile/desktop/video/av2_decoding.dart';
import 'package:immich_mobile/desktop/video/av2_playback.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/desktop_video_sources.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/domain/models/ai_immersive/ai_components_manifest.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
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

  /// Whether this computer plays videos: libmpv was loaded at start (desktop_video_setup.dart)
  static bool get available => desktopVideoAvailable;

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
      resolve: widget.resolve ?? (_playable ? desktopAppVideoResolver(ref) : _unavailable),
      linkOf: widget.resolve == null ? desktopAppVideoLink(ref) : null,
      decodingOf: widget.resolve == null ? desktopAppVideoDecoding(ref) : null,
      release: widget.resolve == null ? desktopAppVideoRelease(ref) : null,
    );
    // After the first frame, as the platform view calls back once it exists
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onViewReady?.call(_controller);
      }
    });
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

/// What the app's media bridge measures of the reads of a video it serves (see LocalMediaBridge.trafficOf)
DesktopVideoLinkOf desktopAppVideoLink(WidgetRef ref) {
  final bridge = ref.read(mediaBridgeProvider);
  return (resource) {
    final url = Uri.tryParse(resource);
    return bridge is LocalMediaBridge && url != null ? bridge.trafficOf(url) : null;
  };
}

/// What the app's players are given for a source: through the app's media bridge and the server the app uses, and
/// the AV2 companion for an AV2 video (see desktop_video_sources.dart)
DesktopVideoSourceResolver desktopAppVideoResolver(WidgetRef ref) {
  final bridge = ref.read(mediaBridgeProvider);
  final av2 = ref.read(av2PlaybacksProvider);
  String? endpoint() => Store.tryGet(StoreKey.serverEndpoint);
  return (source) => resolveDesktopVideoSource(
    source,
    bridge: bridge,
    serverEndpoint: endpoint(),
    // The app's client at each request: it changes with the network settings
    serverFileSystem: () => ImmichServerFileSystem(endpoint: endpoint, client: () => NetworkRepository.client),
    av2: av2,
  );
}

/// What the decoder of an AV2 video tells the link of its player (Av2Playbacks.decodingOf)
DesktopVideoDecodingOf desktopAppVideoDecoding(WidgetRef ref) => ref.read(av2PlaybacksProvider).decodingOf;

/// The companion of an AV2 video stops once its player lets go of it (Av2Playbacks.release)
DesktopVideoRelease desktopAppVideoRelease(WidgetRef ref) => ref.read(av2PlaybacksProvider).release;

/// The AV2 videos of the app (av2_playback.dart): the companion of the AV2 decoder installed for this computer,
/// started by the session of the AI programs (its journal, the job object, immuch360-run), while "AV2 videos
/// (experimental)" is on; the speeds it measures kept with the decoder measures. Made at the start of the window, so
/// that the thumbnails of the library and of the shares find it (Av2Playbacks.app): the library's frame grab of an AV2
/// video goes through it (DesktopLocalImageApi.av2FrameGrab), and the "Video decoding" line follows the session the
/// player plays (activeAv2Decoding).
final av2PlaybacksProvider = Provider<Av2Playbacks>((ref) {
  final platform = aiPlatformOf(Abi.current());
  final component = platform == null
      ? null
      : aiComponents
            .where((entry) => entry.features.contains(AiFeature.av2Video) && entry.platforms.contains(platform))
            .firstOrNull;
  final bridge = ref.read(mediaBridgeProvider);
  final playbacks = Av2Playbacks(
    companion: () async {
      if (component == null) {
        return null;
      }
      final main = await ref.read(aiComponentsServiceProvider).verifiedFile(component);
      return main == null ? null : av2CompanionFilesIn(main.path);
    },
    runner: (launcher) => ref.read(aiProcessSessionProvider).runner(linuxLauncher: launcher),
    enabled: () => SettingsRepository.instance.appConfig.viewer.av2Videos,
    decoderVersion: component?.version ?? '',
    loadMeasure: DecoderMeasureStore.shared.av2Speed,
    recordMeasure: DecoderMeasureStore.shared.recordAv2Speed,
    parentPid: pid,
    bridge: bridge is LocalMediaBridge ? bridge.fileOf : null,
    threads: av2ThreadsFrom(Platform.environment),
  );
  Av2Playbacks.app = playbacks;
  DesktopLocalImageApi.av2FrameGrab = DesktopLocalImageApi.appVideoFrame;
  final decoding = Av2DecodingFollower(playbacks.playing, activeAv2Decoding);
  ref.onDispose(() {
    if (identical(Av2Playbacks.app, playbacks)) {
      Av2Playbacks.app = null;
      DesktopLocalImageApi.av2FrameGrab = null;
    }
    decoding.dispose();
    unawaited(playbacks.releaseAll());
  });
  return playbacks;
});
