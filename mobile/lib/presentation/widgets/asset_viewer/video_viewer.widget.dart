import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/desktop_video_placeholder.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_failure_panel.widget.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/resume_notice.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/apple_spatial.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/is_motion_video_playing.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/original_download.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
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

  /// Whether a film resumes where it was left and keeps where it is (see VideoWatchRecorder): the asset viewer only;
  /// the memories, the slideshow and the motion photos play from the start as before
  final bool watchProgress;

  const NativeVideoViewer({
    super.key,
    required this.asset,
    this.localFilePath,
    required this.image,
    this.isCurrent = false,
    this.loopOverride,
    this.watchProgress = false,
  });

  @override
  ConsumerState<NativeVideoViewer> createState() => NativeVideoViewerState();
}

class NativeVideoViewerState extends ConsumerState<NativeVideoViewer> with WidgetsBindingObserver {
  static final _log = Logger('NativeVideoViewer');

  NativeVideoPlayerController? _controller;

  /// The source of the video: made again when the user forces another file of it in its details
  @visibleForTesting
  late Future<VideoSource?> videoSource;
  Timer? _loadTimer;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;
  // What to tell the user about the file chosen for a server video, once the video is the one on screen
  VideoSourceNotice? _sourceNotice;
  // Why nothing the server has decodes on the device: the video fails at once, play tries it anyway
  VideoSourceRefusal? _refusal;
  // The file the user forced for this server video when its source was made, see videoSourceOverridesProvider
  VideoSourceKind? _forced;
  // The server video whose original is downloaded before it plays (see OriginalDownloads): an original from a server
  // that cannot stream it. Null for any other video
  String? _downloadFirst;
  // The download of that original under way, and whether it stopped because the video was no longer wanted (see
  // _wantsDownload) rather than for a failure: a second load of the page joins it
  Future<({File? file, bool unwanted})>? _downloadRun;
  // Counts the sources made (see _createSource): a load that waited for a download gives up once another source took
  // the place of its own (a file forced in the details), and a second load of the same source leaves it to the first
  int _sourceGeneration = 0;
  int? _waitingGeneration;
  // The video whose downloaded original this viewer has loaded, given back when it goes (see OriginalDownloads.hold),
  // to the downloads kept with it: no ref is read once the viewer goes
  ({String videoId, OriginalDownloads downloads})? _heldDownload;
  // The percent of that download while it runs, null otherwise
  final _downloadPercent = ValueNotifier<int?>(null);
  // Where the video plays from, for the logs, and whether that is the server, for the failure panel
  String _sourceLabel = 'no source yet';
  bool _fromServer = false;
  // Resumes a film and saves where it is, for the video loaded (see widget.watchProgress)
  VideoWatchRecorder? _recorder;

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(widget.asset.id).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    videoSource = _createSource();
    ref.listenManual(videoPlayerProvider(widget.asset.id).select((s) => s.status), _onStatus);
    ref.listenManual(videoSourceOverridesProvider, (_, overrides) => _onForced(overrides));
    if (CurrentPlatform.isDesktop) {
      ref.listenManual(externalPlayerClosedProvider, (_, _) => unawaited(_onExternalPlayerClosed()));
    }
  }

  /// A computer's 360° player closed: what resumed does on a phone
  Future<void> _onExternalPlayerClosed() async {
    await _notifier.resumeAfterExternalPlayer();
    _downloadAgain();
    if (mounted && _notifier.takePlayOnForeground()) {
      await _notifier.play();
    }
  }

  /// A download of the original that an external player cut (see [_wantsDownload]) starts again once the video is
  /// back on screen, as when the page opens
  void _downloadAgain() {
    if (mounted && widget.isCurrent && _downloadFirst != null) {
      unawaited(_loadVideo());
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
    // Where the film is, as the viewer closes
    _recorder?.dispose();
    _recorder = null;
    _removeListeners();
    final held = _heldDownload;
    if (held != null) {
      unawaited(held.downloads.release(held.videoId));
    }
    _downloadPercent.dispose();
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
          _downloadAgain();
        }
        if (!mounted) {
          return;
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

  /// The video id of the asset on the server, the motion part of a live photo included; null for a file only on the
  /// device
  String? get _serverVideoId {
    final asset = widget.asset;
    return (asset is RemoteAsset ? asset.livePhotoVideoId : null) ?? asset.remoteId;
  }

  /// The user forced another file of this video in its details: its source is made again and plays from the start
  Future<void> _onForced(Map<String, VideoSourceKind> overrides) async {
    final videoId = _serverVideoId;
    if (videoId == null || overrides[videoId] == _forced || !mounted) {
      return;
    }
    _log.info('${widget.asset.name}: ${overrides[videoId]} forced, its source made again');
    videoSource = _createSource();
    final source = await videoSource;
    if (source == null || !mounted || _controller == null) {
      return;
    }
    await _apply(source, play: true);
  }

  /// Plays a video from the device as it is, with a word before it plays when the device cannot decode it ([file]
  /// beyond its decoders, see chooseVideoSource): it may still play
  Future<void> _noticeLocalFile(BaseAsset asset, File file) async {
    try {
      final probe = await ref.read(sphericalProbeServiceProvider).probe(asset, localFile: file);
      final verdict = await ref.read(videoSourceServiceProvider).verdict(probe);
      _sourceNotice = chooseVideoSource(
        policy: ref.read(appConfigProvider).viewer.videoSourcePolicy,
        original: VideoCandidate.of(probe, verdict),
        fromServer: false,
      ).notice;
    } catch (error) {
      _log.info('No decoder check for ${asset.name}: $error');
    }
  }

  Future<VideoSource?> _createSource() async {
    if (!mounted) {
      return null;
    }
    _sourceGeneration++;
    _sourceNotice = null;
    _refusal = null;
    _downloadFirst = null;

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

        _sourceLabel = 'the file given to the viewer';
        await _noticeLocalFile(videoAsset, file);
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
          _sourceLabel = 'the copy on the device';
          await _noticeLocalFile(localAsset, file);
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

      // The original or the server's transcoded stream, decodability first, then as the settings say, or the file the
      // user forced in the details. This player has no stream to fall back to: the choice is made here, before it
      // loads (the H.264 copy at 5760 x 2880 of 30 October, which a Quest 3 cannot decode, would stall for 10 s)
      final policy = ref.read(appConfigProvider).viewer.videoSourcePolicy;
      final probes = ref.read(sphericalProbeServiceProvider);
      final videoSources = ref.read(videoSourceServiceProvider);
      final videoId = remoteAsset.livePhotoVideoId ?? remoteAsset.id;
      _forced = ref.read(videoSourceOverridesProvider)[videoId];
      final probe = policy.readsTheFile ? await probes.probe(remoteAsset) : null;
      final source = await videoSources.serverSource(
        videoId: videoId,
        policy: policy,
        probe: probe,
        probeOriginal: () => probes.probe(remoteAsset),
        forced: _forced,
        width: remoteAsset.livePhotoVideoId == null ? remoteAsset.width : null,
        height: remoteAsset.livePhotoVideoId == null ? remoteAsset.height : null,
      );
      if (!mounted) {
        return null;
      }
      ref.read(chosenVideoSourcesProvider.notifier).record(videoId, source);
      // An original from a server that cannot stream it (no Range, the MP4 index at the end), whatever chose it (the
      // decoders, the settings, the details): downloaded once the video is on screen, rather than read to its end by
      // the player before its first frame, as the immersive viewer does. A refused video loads nothing
      if (source.kind == VideoSourceKind.original && source.refusal == null) {
        final streams = await ref.read(originalDownloadsProvider).streams(videoId);
        if (!mounted) {
          return null;
        }
        _downloadFirst = streams ? null : videoId;
      }
      _sourceNotice = source.notice;
      _refusal = source.refusal;
      _fromServer = true;
      _sourceLabel = source.url.endsWith('/original') ? 'the server original' : 'the server transcoded stream';
      _log.info(
        '${videoAsset.name} plays from $_sourceLabel under $policy'
        '${_forced != null ? ', $_forced forced' : ''}${_refusal != null ? ', refused: $_refusal' : ''}',
      );

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

  void _onTracksChanged() {
    if (mounted) {
      _notifier.onNativeTracksChanged();
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

  /// The native player could not play the video: the viewer says why instead of loading forever. The message goes
  /// back to null, so that the same error after a retry is heard again.
  void _onPlaybackError() {
    final controller = _controller;
    final message = controller?.onError.value;
    if (!mounted || controller == null || message == null) {
      return;
    }
    scheduleMicrotask(() => controller.onError.value = null);
    _notifier.onNativeError(message);
  }

  void _onStatus(VideoPlaybackStatus? previous, VideoPlaybackStatus status) {
    if (status != VideoPlaybackStatus.failed || previous == VideoPlaybackStatus.failed) {
      return;
    }
    final failure = _notifier.failure;
    final why = failure?.kind == VideoFailureKind.stalled
        ? 'nothing played for ${VideoPlayerNotifier.stallTimeout.inSeconds} s'
        : failure?.message;
    _log.warning('${widget.asset.name} does not play from $_sourceLabel: $why');
    unawaited(_logFile());
  }

  /// What the file of a video that does not play is, and what the decoders of the device say of it, for the Logs page:
  /// the panel shows the same, but a TV user may only be able to share the logs
  Future<void> _logFile() async {
    final asset = widget.asset;
    try {
      final probes = ref.read(sphericalProbeServiceProvider);
      final sources = ref.read(videoSourceServiceProvider);
      final probe = await probes.probe(asset);
      final verdict = await sources.verdict(probe);
      final file = probe == null
          ? 'unknown file'
          : '${probe.codecs ?? probe.codec} ${probe.codedWidth} x ${probe.codedHeight} at ${probe.frameRate} fps, '
                '${probe.videoBitRate ?? probe.declaredBitRate ?? probe.mediaBitRate} bit/s';
      final decoders = verdict == null
          ? 'no decoder verdict'
          : 'decodes here: ${verdict.supported}, hardware: ${verdict.hardware}, '
                'largest ${verdict.maxWidth} x ${verdict.maxHeight}, ${verdict.reason ?? 'no reason given'}';
      _log.info('${asset.name}: $file; $decoders');
    } catch (error) {
      _log.info('No file details for ${asset.name}: $error');
    }
  }

  void _removeListeners() {
    _controller?.onError.removeListener(_onPlaybackError);
    _controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    _controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    _controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    _controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
    _controller?.onTracksChanged.removeListener(_onTracksChanged);
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
    await _apply(source);
  }

  /// Whether the original of [videoId] is still to download: the video is on screen, its source still downloads it,
  /// and no external player took it (the immersive viewer downloads it on its own, see suspendForExternalPlayer)
  bool _wantsDownload(String videoId, VideoPlayerNotifier notifier) =>
      mounted && widget.isCurrent && _downloadFirst == videoId && !notifier.isSuspendedForExternalPlayer;

  /// Downloads the original of [videoId] with its progress on screen (see OriginalDownloads), until it is no longer
  /// wanted (see [_wantsDownload])
  Future<({File? file, bool unwanted})> _startDownload(String videoId) {
    _downloadPercent.value = 0;
    final notifier = _notifier;
    var unwanted = false;
    late final Future<({File? file, bool unwanted})> run;
    run = ref
        .read(originalDownloadsProvider)
        .download(
          videoId,
          onProgress: (percent) {
            if (mounted) {
              _downloadPercent.value = percent;
            }
          },
          isWanted: () {
            final wanted = _wantsDownload(videoId, notifier);
            unwanted = unwanted || !wanted;
            return wanted;
          },
        )
        .then((file) => (file: file, unwanted: unwanted))
        .whenComplete(() {
          if (identical(_downloadRun, run)) {
            _downloadRun = null;
          }
          if (mounted) {
            _downloadPercent.value = null;
          }
        });
    return run;
  }

  /// The source of the original of [videoId], downloaded first (see [_startDownload]) for the source made at
  /// [generation]: the file once it is whole; [remote] after a failure (no size, an HTTP error), the original then
  /// streaming; null when nothing is to load: the video is no longer on screen or plays in an external player (the
  /// next load of the page downloads again), another source took the place of this one, or another load of it waits
  Future<VideoSource?> _downloaded(String videoId, int generation, VideoSource remote) async {
    if (_waitingGeneration == generation) {
      return null;
    }
    _waitingGeneration = generation;
    try {
      while (true) {
        final run = await (_downloadRun ??= _startDownload(videoId));
        if (!mounted || generation != _sourceGeneration) {
          return null;
        }
        final file = run.file;
        if (file != null) {
          final downloads = ref.read(originalDownloadsProvider)..hold(videoId);
          _heldDownload = (videoId: videoId, downloads: downloads);
          _sourceLabel = 'the server original, downloaded';
          return await VideoSource.init(
            path: CurrentPlatform.isAndroid ? file.uri.toString() : file.path,
            type: VideoSourceType.file,
          );
        }
        if (!run.unwanted) {
          return remote;
        }
        // Stopped for a page that was left, and wanted again before the stop: once more
        if (!_wantsDownload(videoId, _notifier)) {
          return null;
        }
      }
    } finally {
      if (_waitingGeneration == generation) {
        _waitingGeneration = null;
      }
    }
  }

  /// Loads [source] in the player, playing it at once when [play] (a file the user forced): what the decoder check
  /// found is told first, once, when the video is the one on screen (the pages around it prepare their video too); a
  /// video nothing on the server decodes fails at once instead of loading, play trying it anyway; an original that
  /// cannot stream is downloaded first, and loads only once it is whole, for the video still on screen.
  Future<void> _apply(VideoSource remoteSource, {bool play = false}) async {
    final generation = _sourceGeneration;
    var source = remoteSource;
    final notice = _sourceNotice;
    _sourceNotice = null;
    if (notice != null) {
      // A transient word: the player keeps the screen
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(notice.message(context.t))));
    }

    // Grab refs to prevent reading after dispose
    final loopVideo = widget.loopOverride ?? ref.read<bool>(loopVideoProvider);
    final localNotifier = _notifier;

    final refusal = _refusal;
    if (refusal != null) {
      localNotifier.refuse(source, refusal);
      return;
    }
    final downloadFirst = _downloadFirst;
    if (downloadFirst != null) {
      final downloaded = await _downloaded(downloadFirst, generation, source);
      if (downloaded == null || !mounted) {
        return;
      }
      source = downloaded;
    }
    // A film resumes where it was left, once ready, and plays once whatever Looping says
    final recorder = await _startRecorder(localNotifier);
    if (!mounted) {
      return;
    }
    await localNotifier.load(source);
    await localNotifier.setLoop(!widget.asset.isMotionPhoto && (recorder?.loopsWith(loopVideo) ?? loopVideo));
    await localNotifier.setVolume(1);
    if (play) {
      await localNotifier.play();
    }
  }

  /// The recorder of the video about to load in [notifier], in place of the one of the video before: none outside the
  /// asset viewer, nor for a motion photo
  Future<VideoWatchRecorder?> _startRecorder(VideoPlayerNotifier notifier) async {
    _recorder?.dispose();
    _recorder = null;
    final asset = widget.asset;
    if (!widget.watchProgress || !asset.isVideo || asset.isMotionPhoto) {
      return null;
    }
    final store = ref.read(watchProgressProvider.notifier);
    final rule = ref.read(watchRuleProvider);
    await VideoWatchRecorder.storeReady(store);
    if (!mounted) {
      return null;
    }
    // Another load may have started its own meanwhile (a file forced in the details)
    _recorder?.dispose();
    return _recorder = VideoWatchRecorder(
      store: store,
      player: notifier,
      key: WatchKey.ofAsset(asset),
      rule: rule,
      duration: asset.durationMs == null ? null : asset.duration,
      onResumed: _onResumed,
    )..start();
  }

  /// The film plays from where it was left: the viewer says so for a few seconds (see ResumeNotice)
  void _onResumed(Duration position) {
    if (mounted && widget.isCurrent) {
      ref.read(resumeNoticeProvider.notifier).show(position);
    }
  }

  /// Gives the viewer [controller] as its native player would once its view is ready: for the tests, which have no
  /// platform view
  @visibleForTesting
  void attachController(NativeVideoPlayerController controller) => _initController(controller);

  void _initController(NativeVideoPlayerController nc) {
    if (_controller != null || !mounted) {
      return;
    }

    _notifier.attachController(nc);

    nc.onPlaybackPositionChanged.addListener(_onPlaybackPositionChanged);
    nc.onPlaybackStatusChanged.addListener(_onPlaybackStatusChanged);
    nc.onPlaybackReady.addListener(_onPlaybackReady);
    nc.onPlaybackEnded.addListener(_onPlaybackEnded);
    nc.onError.addListener(_onPlaybackError);
    nc.onTracksChanged.addListener(_onTracksChanged);

    _controller = nc;

    if (widget.isCurrent) {
      unawaited(_loadVideo());
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCasting = ref.watch(castProvider.select((c) => c.isCasting));
    final status = ref.watch(videoPlayerProvider(widget.asset.id).select((v) => v.status));
    final failure = status == VideoPlaybackStatus.failed ? _notifier.failure : null;
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
            // The original downloaded before it plays, see _download
            ValueListenableBuilder<int?>(
              valueListenable: _downloadPercent,
              builder: (context, percent, _) => percent == null
                  ? const SizedBox.shrink()
                  : Center(
                      child: Column(
                        key: const Key('video_original_download'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(value: percent / 100),
                          const SizedBox(height: 12),
                          Text(
                            context.t.immersive_downloading_original(percent: percent),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
            ),
            if (status == VideoPlaybackStatus.failed && failure != null)
              Positioned.fill(
                child: VideoFailurePanel(asset: widget.asset, failure: failure, fromServer: _fromServer),
              ),
          ],
        ],
      ),
    );
  }
}
