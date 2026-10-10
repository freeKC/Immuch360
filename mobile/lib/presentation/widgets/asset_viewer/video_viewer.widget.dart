import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

/// Tells the user that [asset], an Apple spatial video, plays one eye here: no player of the app shows its second
/// layer (MV-HEVC), on any device. Once per video in the session (see [AppleSpatialService.takeVideoNotice]), for
/// nothing else, and not once the viewer of [context] is gone; true when it told.
Future<bool> noticeAppleSpatialVideo(BuildContext context, AppleSpatialService spatial, BaseAsset asset) async {
  final info = await spatial.detect(asset);
  // A video swiped away meanwhile tells nothing, and keeps its notice for when it plays again
  if (!context.mounted || info?.kind != AppleSpatialKind.multiviewVideo || !spatial.takeVideoNotice(asset)) {
    return false;
  }
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.apple_spatial_video_2d_notice)));
  return true;
}

class NativeVideoViewer extends ConsumerStatefulWidget {
  final BaseAsset asset;
  final String? localFilePath;
  final bool isCurrent;
  final Widget image;

  /// Overrides the user's configured loop video setting
  final bool? loopOverride;

  const NativeVideoViewer({
    super.key,
    required this.asset,
    this.localFilePath,
    required this.image,
    this.isCurrent = false,
    this.loopOverride,
  });

  @override
  ConsumerState<NativeVideoViewer> createState() => NativeVideoViewerState();
}

class NativeVideoViewerState extends ConsumerState<NativeVideoViewer> with WidgetsBindingObserver {
  static final _log = Logger('NativeVideoViewer');

  NativeVideoPlayerController? _controller;
  @visibleForTesting
  late final Future<VideoSource?> videoSource;
  Timer? _loadTimer;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;
  // What to tell the user about the file chosen for a server video, once the video is the one on screen
  VideoSourceNotice? _sourceNotice;

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(widget.asset.id).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    videoSource = _createSource();
    if (CurrentPlatform.isDesktop) {
      ref.listenManual(externalPlayerClosedProvider, (_, _) => unawaited(_onExternalPlayerClosed()));
    }
  }

  /// A computer's 360° player closed: what resumed does on a phone
  Future<void> _onExternalPlayerClosed() async {
    await _notifier.resumeAfterExternalPlayer();
    if (_notifier.takePlayOnForeground()) {
      await _notifier.play();
    }
  }

  @override
  void didUpdateWidget(NativeVideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isCurrent == oldWidget.isCurrent || _controller == null) {
      return;
    }

    if (!widget.isCurrent) {
      _loadTimer?.cancel();
      unawaited(_notifier.pause());
      return;
    }

    // Prevent unnecessary loading when swiping between assets.
    _loadTimer = Timer(const Duration(milliseconds: 200), _loadVideo);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _loadTimer?.cancel();
    _removeListeners();
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        // Back from the native 360° player, if it was opened on this video. A computer's 360° player is a route of
        // the window, which may still be open at a focus change: its closing ends the suspension there
        // (externalPlayerClosedProvider)
        if (!CurrentPlatform.isDesktop) {
          await _notifier.resumeAfterExternalPlayer();
        }
        // Read first, so that it is used up even when the video plays anyway. Back from the Spatial 2.5D player,
        // a video that it left playing but that became ready in the background waits for this to play.
        final playAfterExternalPlayer = _notifier.takePlayOnForeground();
        // A computer comes back to resumed at each focus change, never through the paused below: only what an
        // external player left playing plays on there, not a video the user paused, never started or saw to its end
        if ((_shouldPlayOnForeground && !CurrentPlatform.isDesktop) || playAfterExternalPlayer) {
          await _notifier.play();
        }
      case AppLifecycleState.paused:
        _shouldPlayOnForeground = await _controller?.isPlaying() ?? true;
        if (_shouldPlayOnForeground && mounted) {
          await _notifier.pause();
        }
      default:
    }
  }

  Future<VideoSource?> _createSource() async {
    if (!mounted) {
      return null;
    }

    final videoAsset = await ref.read(assetServiceProvider).getAsset(widget.asset) ?? widget.asset;
    if (!mounted) {
      return null;
    }

    try {
      final storageRepository = ref.read(storageRepositoryProvider);
      final localFilePath = widget.localFilePath;
      if (localFilePath != null) {
        final file = File(localFilePath);
        // ignore: avoid_slow_async_io
        if (!await file.exists()) {
          throw Exception('No file found for the video');
        }

        return await VideoSource.init(
          path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
          type: VideoSourceType.file,
        );
      }

      // Attempt to retrieve LocalAsset, falling back to remote if it cannot be found
      final localAsset = await _localPlaybackAsset(videoAsset);

      if (localAsset != null) {
        final file = localAsset.isMotionPhoto
            ? await storageRepository.getMotionFileForAsset(localAsset)
            : await storageRepository.getFileForAsset(localAsset.id);

        if (!mounted) {
          return null;
        }

        // Pass a file:// URI so Android's Uri.parse doesn't
        // interpret characters like '#' as fragment identifiers.
        if (file != null) {
          return await VideoSource.init(
            path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
            type: VideoSourceType.file,
          );
        }

        if (videoAsset is! RemoteAsset) {
          throw Exception('No file found for the video');
        }
        _log.warning('Local file missing for ${videoAsset.name} (${videoAsset.localId}), playing the remote copy');
      }

      final remoteAsset = videoAsset as RemoteAsset;

      if (!context.mounted) {
        return null;
      }

      // The original or the server's transcoded stream, as the settings and the decoders of the device say. This
      // player has no stream to fall back to: when the device cannot decode the original, the choice is made here.
      final policy = ref.read(appConfigProvider).viewer.videoSourcePolicy;
      final probes = ref.read(sphericalProbeServiceProvider);
      final videoSources = ref.read(videoSourceServiceProvider);
      final probe = policy.readsTheFile ? await probes.probe(remoteAsset) : null;
      final source = await videoSources.serverSource(
        videoId: remoteAsset.livePhotoVideoId ?? remoteAsset.id,
        policy: policy,
        probe: probe,
      );
      if (!mounted) {
        return null;
      }
      _sourceNotice = source.notice;

      return await VideoSource.init(
        path: source.url,
        type: VideoSourceType.network,
        headers: ApiService.getRequestHeaders(),
      );
    } catch (error) {
      _log.severe('Error creating video source for asset ${videoAsset.name}: $error');
      return null;
    }
  }

  Future<LocalAsset?> _localPlaybackAsset(BaseAsset baseAsset) async {
    if (!baseAsset.hasLocal) {
      return null;
    }

    LocalAsset? localAsset;

    if (baseAsset is LocalAsset) {
      localAsset = baseAsset;
    } else {
      final localId = (baseAsset as RemoteAsset).localId;
      localAsset = localId != null ? await ref.read(assetServiceProvider).getLocalAsset(localId) : null;
    }

    if (localAsset == null) {
      _log.severe(
        'Invariant violation: asset ${baseAsset.name} (${baseAsset.localId}) is marked `hasLocal` but local asset could not be retrieved',
      );

      return null;
    }

    // Clients (local) may not correctly recognize a given asset as a motion photo. This allows for a scenario where both remote and local
    // have the same asset (hash), but only the remote properly recognizes it as a motion asset
    // If this scenario occurs, fall back to using the remote asset
    if (baseAsset.isMotionPhoto && !localAsset.isMotionPhoto) {
      // Platform mismatch for motion photo, use remote instead
      _log.warning(
        'Mismatched local and remote motion states on ${baseAsset.name} (${baseAsset.localId}), local = ${localAsset.isMotionPhoto}, remote = ${baseAsset.isMotionPhoto}',
      );

      return null;
    }

    return localAsset;
  }

  Future<void> _onPlaybackReady() async {
    if (!mounted || !widget.isCurrent) {
      return;
    }

    _notifier.onNativePlaybackReady();

    // onPlaybackReady may be called multiple times, usually when more data
    // loads. If this is not the first time that the player has become ready, we
    // should not autoplay.
    if (_isVideoReady) {
      return;
    }

    setState(() => _isVideoReady = true);
    unawaited(_noticeSpatialVideo());

    if (ref.read(assetViewerProvider).showingDetails) {
      return;
    }

    // A video that becomes ready behind another app or the native 360° player would play there unseen
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden) {
      return;
    }

    final autoPlayVideo = ref.read(appConfigProvider).viewer.autoPlayVideo;
    if (autoPlayVideo || widget.asset.isMotionPhoto) {
      await _notifier.play();
    }
  }

  /// Tells the user, once per video in the session, that an Apple spatial video plays one eye here (see
  /// [noticeAppleSpatialVideo])
  Future<void> _noticeSpatialVideo() async {
    final asset = widget.asset;
    try {
      await noticeAppleSpatialVideo(context, ref.read(appleSpatialServiceProvider), asset);
    } catch (error) {
      _log.info('Could not tell whether ${asset.name} is a spatial video: $error');
    }
  }

  void _onPlaybackEnded() {
    if (!mounted) {
      return;
    }

    _notifier.onNativePlaybackEnded();

    if (_controller?.playbackInfo?.status == PlaybackStatus.stopped) {
      ref.read(isPlayingMotionVideoProvider.notifier).playing = false;
    }
  }

  void _onPlaybackPositionChanged() {
    if (!mounted) {
      return;
    }
    _notifier.onNativePositionChanged();
  }

  void _onPlaybackStatusChanged() {
    if (!mounted) {
      return;
    }
    _notifier.onNativeStatusChanged();
  }

  void _removeListeners() {
    _controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    _controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    _controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    _controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
  }

  Future<void> _loadVideo() async {
    final nc = _controller;
    if (nc == null || nc.videoSource != null || !mounted) {
      return;
    }

    final source = await videoSource;
    if (source == null || !mounted) {
      return;
    }
    // Told once, when the video is the one on screen: the pages around it prepare their video too
    final notice = _sourceNotice;
    _sourceNotice = null;
    if (notice != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(notice.message(context.t))));
    }

    // Grab refs to prevent reading after dispose
    final loopVideo = widget.loopOverride ?? ref.read(appConfigProvider).viewer.loopVideo;
    final localNotifier = _notifier;

    await localNotifier.load(source);
    await localNotifier.setLoop(!widget.asset.isMotionPhoto && loopVideo);
    await localNotifier.setVolume(1);
  }

  void _initController(NativeVideoPlayerController nc) {
    if (_controller != null || !mounted) {
      return;
    }

    _notifier.attachController(nc);

    nc.onPlaybackPositionChanged.addListener(_onPlaybackPositionChanged);
    nc.onPlaybackStatusChanged.addListener(_onPlaybackStatusChanged);
    nc.onPlaybackReady.addListener(_onPlaybackReady);
    nc.onPlaybackEnded.addListener(_onPlaybackEnded);

    _controller = nc;

    if (widget.isCurrent) {
      unawaited(_loadVideo());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCasting = ref.watch(castProvider.select((c) => c.isCasting));
    final status = ref.watch(videoPlayerProvider(widget.asset.id).select((v) => v.status));
    // https://github.com/flutter/flutter/issues/97499: iOS platform views are only disposed in frames containing platform views, or on
    // the first frame after a platform view disappears. Animating this view away uses those disappearing frames. Instead, forcibly remove
    // the view from the tree when we start a route transition, which has the side effect of properly ordering the `dispose`
    final isRouteActive = ModalRoute.of(context)?.isActive ?? true;
    final showPlayer = !isCasting && isRouteActive;

    return IgnorePointer(
      child: Stack(
        children: [
          if (!_isVideoReady || widget.asset.isMotionPhoto || !showPlayer) Positioned.fill(child: widget.image),
          if (showPlayer && CurrentPlatform.isDesktop && !DesktopVideoView.available)
            // A computer without the video library (Linux and macOS until their packages come): the poster stays,
            // with the line saying so, rather than a player that never gets ready
            const Positioned.fill(child: DesktopVideoPlaceholder())
          else if (showPlayer) ...[
            Visibility.maintain(
              visible: _isVideoReady,
              // A platform view must never take the focus: the keys of a remote would go to the native view
              child: ExcludeFocus(
                // The computers play through media_kit (lib/desktop/video), with a controller of the same type
                child: CurrentPlatform.isDesktop
                    ? DesktopVideoView(onViewReady: _initController)
                    : NativeVideoPlayerView(onViewReady: _initController),
              ),
            ),
            Center(
              child: AnimatedOpacity(
                opacity: status == VideoPlaybackStatus.buffering ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: const CircularProgressIndicator(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
