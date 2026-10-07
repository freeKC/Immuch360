import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_buffering.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_controls.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_back_button.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('NetworkVideoPage');

/// A video of a share and its media bridge URL
typedef _Video = ({NetworkEntry entry, Uri url});

/// A video of a network share, played straight from it through the media bridge, with play, pause and seek. A video
/// whose file declares a 360° projection gets a 360° button, which opens the native 360° player, or the immersive
/// viewer on a Meta Quest; a stereoscopic one a Spatial 2.5D button on a phone where the setting is on. Both are in
/// the menu for any other video. The immersive viewer goes from there to the previous and next 360° photos and
/// videos of [folder]. The menu also sends the video to the Immich server, when there is one.
///
/// A raw video of a 360° camera (Insta360 .insv, GoPro .360, DJI .osv) is 360° by its name: the players map it on the
/// sphere with the rawProjection JSON of its plan (see RawVideoResolver), the calibration read from the share, the
/// other file of a split pair looked for next to it. One that does not open says why when its 360° button is pressed.
///
/// With a remote control, a keyboard or a game pad (see [NetworkVideoPageState._onKey]): OK pauses or plays, left and
/// right seek while it plays and go to the previous or next file of [folder] while it is paused, up and down reach the
/// app bar and the controls. On a TV, Back hides the controls before it leaves.
@RoutePage()
class NetworkVideoPage extends ConsumerStatefulWidget {
  const NetworkVideoPage({super.key, required this.sourceId, required this.path, this.folder});

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;

  /// The photos and videos of the folder the video was opened from, null when it was opened on its own
  final NetworkFolderMedia? folder;

  @override
  ConsumerState<NetworkVideoPage> createState() => NetworkVideoPageState();
}

class NetworkVideoPageState extends ConsumerState<NetworkVideoPage> with WidgetsBindingObserver {
  late Future<_Video> _video = _load();

  /// What the player plays: the media bridge URL of the video, null when it could not be had
  @visibleForTesting
  late Future<VideoSource?> videoSource = _sourceOf(_video);

  /// What the file declares, null until read
  NetworkMediaInfo? _info;

  /// Reads the file straight from the share, for the plan of a raw video; null until the share is open
  ByteRangeReader? _shareReader;

  NativeVideoPlayerController? _controller;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;
  bool _showControls = true;

  /// What the native player reported when it could not play the video
  String? _playerError;

  /// The frame size, once the native player read it: the 3D layout is guessed from it
  ({int width, int height})? _videoSize;

  /// The page itself, which takes the keys of a remote while no button has the focus
  final _rootFocus = FocusNode(debugLabel: 'Network video');

  /// Around the app bar, and around its actions: where Up goes
  final _appBarFocus = FocusNode(debugLabel: 'Network video app bar', canRequestFocus: false, skipTraversal: true);
  final _actionsFocus = FocusNode(debugLabel: 'Network video actions', canRequestFocus: false, skipTraversal: true);

  /// The play button of the controls: where Down goes
  final _playFocus = FocusNode(debugLabel: 'Network video play');

  /// Around the view of an error (the video could not be had, or not played): where Down and OK go then, to Retry,
  /// since there are no controls and nothing plays
  final _errorFocus = FocusNode(debugLabel: 'Network video error', canRequestFocus: false, skipTraversal: true);

  /// "Paused: the arrows go to the previous or next item" shows once per run of the app
  static bool _pausedHintShown = false;

  /// The key of the player of this page in [videoPlayerProvider]
  String get _playerKey => 'network:${widget.sourceId}:${widget.path}';

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(_playerKey).notifier);

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Back on a TV depends on where the focus is
    _appBarFocus.addListener(_onAppBarFocus);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeListeners();
    _appBarFocus.removeListener(_onAppBarFocus);
    _rootFocus.dispose();
    _appBarFocus.dispose();
    _actionsFocus.dispose();
    _playFocus.dispose();
    _errorFocus.dispose();
    super.dispose();
  }

  void _onAppBarFocus() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Down from a button of the app bar goes to Retry in place of a video that could not be had or played, else to the
  /// controls, which it shows, as from the page itself
  KeyEventResult _onAppBarKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    if (isRemotePress(event)) {
      final retry = _errorFocus.traversalDescendants.firstOrNull;
      if (retry != null) {
        retry.requestFocus();
      } else {
        // The page itself until the play button shows (not while the video loads)
        _rootFocus.requestFocus();
        _showControlsAndFocus(top: false);
      }
    }
    return KeyEventResult.handled;
  }

  bool get _isPlaying {
    final status = ref.read(videoPlayerProvider(_playerKey)).status;
    return status == VideoPlaybackStatus.playing || status == VideoPlaybackStatus.buffering;
  }

  /// The keys of a remote control, a keyboard or a game pad. Media keys (play, pause, fast forward, rewind, next,
  /// previous) work wherever the focus is on the page; the arrows and OK only while the page itself has it, else they
  /// belong to the focused button. In place of a video that could not be had or played, Down and OK go to Retry.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final press = isRemotePress(event);
    if (remotePlayPauseKeys.contains(key)) {
      if (press) {
        _setPlaying(remotePlayPauseWantsPlay(key, isPlaying: _isPlaying));
      }
      return KeyEventResult.handled;
    }
    if (remoteSeekForwardKeys.contains(key) || remoteSeekBackwardKeys.contains(key)) {
      if (event is! KeyUpEvent) {
        _seekBy(remoteSeekForwardKeys.contains(key) ? remoteSeekStep : -remoteSeekStep);
      }
      return KeyEventResult.handled;
    }
    if (remoteNextItemKeys.contains(key) || remotePreviousItemKeys.contains(key)) {
      if (press) {
        _openNeighbour(remoteNextItemKeys.contains(key) ? 1 : -1);
      }
      return KeyEventResult.handled;
    }
    if (!node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final retry = _errorFocus.traversalDescendants.firstOrNull;
    if (retry != null && (remoteOkKeys.contains(key) || key == LogicalKeyboardKey.arrowDown)) {
      if (press) {
        retry.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (remoteOkKeys.contains(key)) {
      if (press) {
        _setPlaying(!_isPlaying);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final step = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      if (_isPlaying) {
        // Held, it keeps seeking
        if (event is! KeyUpEvent) {
          _seekBy(remoteSeekStep * step);
        }
      } else if (press) {
        _openNeighbour(step);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (press) {
        _showControlsAndFocus(top: true);
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (press) {
        _showControlsAndFocus(top: false);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Plays, or pauses and shows the controls (Play TV criterion TV-PC). A video at its end plays from the start.
  void _setPlaying(bool play) {
    final notifier = _notifier;
    if (!play) {
      unawaited(notifier.pause());
      setState(() => _showControls = true);
      _showPausedHint();
      return;
    }
    if (ref.read(videoPlayerProvider(_playerKey)).status == VideoPlaybackStatus.completed) {
      unawaited(notifier.restart());
    } else {
      unawaited(notifier.play());
    }
  }

  /// Once: paused, the arrows no longer seek but go to the next file, when there is one
  void _showPausedHint() {
    if (_pausedHintShown || !ref.read(tvModeProvider) || widget.folder == null) {
      return;
    }
    _pausedHintShown = true;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.t.tv_paused_arrows_hint)));
  }

  void _seekBy(Duration delta) {
    final playback = ref.read(videoPlayerProvider(_playerKey));
    var target = playback.position + delta;
    if (target < Duration.zero) {
      target = Duration.zero;
    }
    if (playback.duration > Duration.zero && target > playback.duration) {
      target = playback.duration;
    }
    _notifier.seekTo(target);
    setState(() => _showControls = true);
  }

  /// The previous or next photo or video of the folder, in place of this page: a TV user does not go back to the grid
  /// between files. Nothing without a folder.
  void _openNeighbour(int step) {
    final route = networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, step);
    if (route != null) {
      unawaited(context.replaceRoute(route));
    }
  }

  /// Shows the controls and focuses the app bar ([top]) or the play button
  void _showControlsAndFocus({required bool top}) {
    setState(() => _showControls = true);
    // The play button is in the tree from the next frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final target = top
          ? _actionsFocus.traversalDescendants.firstOrNull ?? _appBarFocus.traversalDescendants.firstOrNull
          : _playFocus;
      target?.requestFocus();
    });
  }

  /// Back on a TV, while the controls show or the app bar has the focus: they hide, and the page takes the keys again
  void _hideControls() {
    setState(() => _showControls = false);
    _rootFocus.requestFocus();
  }

  Future<_Video> _load() async {
    // Read before the first await: the page may be gone by then
    final connections = ref.read(networkConnectionsProvider);
    final service = ref.read(networkMediaServiceProvider);
    final client = ref.read(networkBridgeClientProvider);
    final fileSystem = await connections.fileSystem(widget.sourceId);
    final entry = await fileSystem.stat(widget.path);
    final url = await connections.mediaUrl(widget.sourceId, widget.path);
    _shareReader = networkFileReader(fileSystem, widget.path);
    unawaited(_detect(service, entry, httpRangeReader(client, url)));
    return (entry: entry, url: url);
  }

  // Through the media bridge, with range requests, like the players read the file
  Future<void> _detect(NetworkMediaService service, NetworkEntry entry, ByteRangeReader read) async {
    final info = await service.detect(entry, read, thorough: true);
    if (info != null && mounted) {
      setState(() => _info = info);
    }
  }

  static Future<VideoSource?> _sourceOf(Future<_Video> video) async {
    try {
      final url = (await video).url;
      return await VideoSource.init(path: url.toString(), type: VideoSourceType.network);
    } catch (_) {
      // The page shows why
      return null;
    }
  }

  void _retry() {
    // Retry leaves with the error: the page takes the keys again
    if (_errorFocus.hasFocus) {
      _rootFocus.requestFocus();
    }
    setState(() {
      _video = _load();
      videoSource = _sourceOf(_video);
      _playerError = null;
    });
    if (_controller != null) {
      unawaited(_loadVideo());
    }
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.resumed:
        // Back from the native 360° player or the immersive viewer, if one was opened on this video
        await _notifier.resumeAfterExternalPlayer();
        // Read first, so that it is used up even when the video plays anyway. Back from the Spatial 2.5D player,
        // a video that it left playing but that became ready in the background waits for this to play.
        final playAfterExternalPlayer = _notifier.takePlayOnForeground();
        if (_shouldPlayOnForeground || playAfterExternalPlayer) {
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

  void _initController(NativeVideoPlayerController controller) {
    if (_controller != null || !mounted) {
      return;
    }
    _notifier.attachController(controller);
    controller.onPlaybackPositionChanged.addListener(_onPlaybackPositionChanged);
    controller.onPlaybackStatusChanged.addListener(_onPlaybackStatusChanged);
    controller.onPlaybackReady.addListener(_onPlaybackReady);
    controller.onPlaybackEnded.addListener(_onPlaybackEnded);
    controller.onError.addListener(_onPlayerError);
    _controller = controller;
    unawaited(_loadVideo());
  }

  void _removeListeners() {
    final controller = _controller;
    controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
    controller?.onError.removeListener(_onPlayerError);
  }

  Future<void> _loadVideo() async {
    final source = await videoSource;
    if (source == null || !mounted) {
      return;
    }
    // Read before the first await: the page may be gone by then
    final loop = ref.read(appConfigProvider).viewer.loopVideo;
    final notifier = _notifier;
    await notifier.load(source);
    await notifier.setLoop(loop);
    await notifier.setVolume(1);
  }

  Future<void> _onPlaybackReady() async {
    if (!mounted) {
      return;
    }
    _notifier.onNativePlaybackReady();
    final videoInfo = _controller?.videoInfo;
    if (videoInfo != null && videoInfo.width > 0 && videoInfo.height > 0) {
      setState(() => _videoSize = (width: videoInfo.width, height: videoInfo.height));
    }
    // Called again when more data loads: only the first time may play
    if (_isVideoReady) {
      return;
    }
    setState(() => _isVideoReady = true);
    // A video that becomes ready behind another app or an external player would play there unseen
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden) {
      return;
    }
    if (ref.read(appConfigProvider).viewer.autoPlayVideo) {
      await _notifier.play();
    }
  }

  void _onPlaybackEnded() {
    if (mounted) {
      _notifier.onNativePlaybackEnded();
    }
  }

  void _onPlaybackPositionChanged() {
    if (mounted) {
      _notifier.onNativePositionChanged();
    }
  }

  void _onPlaybackStatusChanged() {
    if (mounted) {
      _notifier.onNativeStatusChanged();
    }
  }

  void _onPlayerError() {
    final error = _controller?.onError.value;
    if (error != null && mounted) {
      _log.warning('Could not play $_name: $error');
      setState(() => _playerError = error);
    }
  }

  /// How the 360° viewers show the video: what it declares, else guesses from its frame size and its name
  SphereView _sphereView(_Video video) => (_info ?? const NetworkMediaInfo()).sphereView(
    video.entry.name,
    width: _videoSize?.width,
    height: _videoSize?.height,
  );

  /// What kind of raw video of a 360° camera it is, by its name; null for any other video
  RawMediaKind? _rawKind(_Video video) => _info?.rawKind ?? rawMediaKindOfName(video.entry.name, isVideo: true);

  /// Whether the video looks stereoscopic: it declares two eyes, or its frame shape or its name tell (see
  /// [guessSpatialLayout]). A raw video has two lenses or six cube faces, not two eyes.
  bool _isStereo(_Video video) {
    final info = _info;
    if (_rawKind(video) != null) {
      return false;
    }
    if (info?.declaresStereo ?? false) {
      return true;
    }
    final coverage = (info?.is360 ?? false) ? _sphereView(video).coverage : null;
    return guessSpatialLayout(
          width: _videoSize?.width,
          height: _videoSize?.height,
          fileName: video.entry.name,
          projection: coverage?.toSpatialProjection() ?? SpatialProjection.flat,
        ) !=
        SpatialStereoLayout.auto;
  }

  Future<void> _open360(_Video video) async {
    final isHorizonOs = await ref.read(isHorizonOsProvider.future);
    if (!mounted) {
      return;
    }
    final view = _sphereView(video);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final t = context.t;
    final rawKind = _rawKind(video);
    final read = _shareReader ?? httpRangeReader(ref.read(networkBridgeClientProvider), video.url);
    // The other file of a split pair, in the folder the page was opened from, else in a listing of its folder
    final siblings = shareSiblingFinder(
      entry: video.entry,
      folder: widget.folder?.around(video.entry, video.url).items,
      connections: ref.read(networkConnectionsProvider),
      bridgeClient: ref.read(networkBridgeClientProvider),
      media: ref.read(networkMediaServiceProvider),
    );
    if (isHorizonOs) {
      final errorMessage = t.immersive_viewer_open_failed;
      final stereoLabels = sphereViewerLabels(t);
      final ImmersiveRequest request;
      try {
        request = rawKind != null
            ? await RawImmersiveMedia.read(
                ref,
                forAssets: false,
              ).sharedMedia(video.entry, video.url, read: read, probe: _info?.probe, siblings: siblings)
            : ImmersiveRequest(url: video.url.toString(), isVideo: true, title: video.entry.name, view: view);
      } on RawVideoUnsupportedException catch (error) {
        _log.info('$_name does not open in 360°: $error');
        showRawVideoUnsupported(messenger, t, error);
        return;
      } catch (error) {
        _log.warning('Could not read the calibration of $_name: $error');
        messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
        return;
      }
      if (!mounted) {
        return;
      }
      final player = _notifier;
      final around = widget.folder?.around(video.entry, video.url) ?? (items: [video], index: 0);
      // Given the request too: the video shows again as it opens now, whatever its file declares
      final navigator = FolderImmersiveNavigator.read(
        ref,
        items: around.items,
        index: around.index,
        request: request,
        player: player,
      );
      // The viewer carries on from where the page's player is, unless it reached the end: read right before
      // openImmersiveUrl stops the player, nothing awaited in between
      final playback = ref.read(videoPlayerProvider(_playerKey));
      try {
        await openImmersiveUrl(
          ref,
          request: request,
          stereoLabels: stereoLabels,
          startPosition: playback.status == VideoPlaybackStatus.completed ? Duration.zero : playback.position,
          player: player,
          navigator: navigator,
        );
      } catch (error) {
        _log.warning('Could not open the immersive viewer: $error');
        messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
      }
      return;
    }
    final errorMessage = t.errors.unable_to_play_video;
    RawVideoPlan? plan;
    if (rawKind != null) {
      final resolver = ref.read(rawVideoResolverProvider);
      final videoSources = ref.read(videoSourceServiceProvider);
      try {
        plan = await resolver.resolve(
          kind: rawKind,
          input: RawVideoInput(
            name: video.entry.name,
            key: rawShareKey(video.entry),
            url: video.url.toString(),
            open: () async => (size: video.entry.size, read: read, close: () async {}),
            probe: _info?.probe,
            width: _videoSize?.width,
            height: _videoSize?.height,
          ),
          findSibling: siblings,
        );
      } on RawVideoUnsupportedException catch (error) {
        _log.info('$_name does not open in 360°: $error');
        showRawVideoUnsupported(messenger, t, error);
        return;
      } catch (error) {
        _log.warning('Could not prepare $_name for the 360° player: $error');
        messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
        return;
      }
      await warnOfTwoRawStreams(plan, videoSources, messenger, t);
      if (!mounted) {
        return;
      }
    }
    final opened = await openSphericalVideoUrl(
      context,
      ref,
      url: plan?.url ?? video.url.toString(),
      title: video.entry.name,
      layout: view.layout,
      coverage: view.coverage,
      player: _notifier,
      fallbackUrl: plan?.fallbackUrl,
      rawProjection: plan?.toNativeJson(),
    );
    if (!opened) {
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  Future<void> _openSpatial(_Video video) async {
    final playback = ref.read(videoPlayerProvider(_playerKey));
    final wasPlaying =
        playback.status == VideoPlaybackStatus.playing || playback.status == VideoPlaybackStatus.buffering;
    final info = _info;
    await openSpatialVideoUrl(
      context,
      ref,
      url: video.url.toString(),
      title: video.entry.name,
      width: _videoSize?.width,
      height: _videoSize?.height,
      coverage: (info?.is360 ?? false) ? _sphereView(video).coverage : null,
      declaredStereo: info?.declaresStereo ?? false,
      startPosition: playback.position,
      autoplay: wasPlaying,
      player: _notifier,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched so that the player lives as long as the page
    ref.watch(videoPlayerProvider(_playerKey).select((v) => v.status));
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull;
    final can360 = (isHorizonOs ?? false) || ref.watch(panorama360VideoSupportedProvider);
    // Like in the asset viewer: an experimental setting, on phones only, never while the platform check is pending
    // A TV has no front camera for Spatial 2.5D, and is a viewer: nothing is sent from it
    final tvMode = ref.watch(tvModeProvider);
    final canSpatial =
        !tvMode && isHorizonOs == false && ref.watch(appConfigProvider.select((c) => c.viewer.spatial25d));
    final canUpload = !tvMode && ref.watch(hasServerProvider);
    final isUploading = ref.watch(networkUploadProvider.select((upload) => upload.isRunning));
    // The page covers the screen, under the app bar too: from the menu, Left would land on it rather than on the Back
    // button. Out of the directional moves while the app bar has the focus (set here, not while the focus changes);
    // Down and Back leave the app bar.
    _rootFocus.skipTraversal = _appBarFocus.hasFocus;

    final page = FutureBuilder<_Video>(
      future: _video,
      builder: (context, snapshot) {
        final video = snapshot.data;
        // A raw video is 360° by its name; whether it opens is known when its 360° button is pressed
        final isRaw = video != null && _rawKind(video) != null;
        final is360 = (_info?.is360 ?? false) || isRaw;
        final isStereo = video != null && _isStereo(video);
        final menu360 = can360 && !is360;
        final menuSpatial = canSpatial && !isStereo;

        final appBar = AppBar(
          backgroundColor: Colors.black38,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          // On a TV, Back on the app bar only hides it: the Back button leaves the page itself
          leading: tvMode ? remoteBackButton(context) : null,
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            Focus(
              focusNode: _actionsFocus,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (video != null && can360 && is360)
                    IconButton(
                      icon: const Icon(Icons.threesixty_rounded),
                      tooltip: '360°',
                      onPressed: () => unawaited(_open360(video)),
                    ),
                  if (video != null && canSpatial && isStereo)
                    IconButton(
                      icon: const Icon(Icons.threed_rotation_rounded),
                      tooltip: context.t.spatial_2_5d,
                      onPressed: () => unawaited(_openSpatial(video)),
                    ),
                  if (video != null && (menu360 || menuSpatial || canUpload))
                    PopupMenuButton<void>(
                      tooltip: context.t.more,
                      itemBuilder: (context) => [
                        if (menu360)
                          PopupMenuItem<void>(
                            onTap: () => unawaited(_open360(video)),
                            child: ListTile(
                              leading: const Icon(Icons.threesixty_rounded),
                              title: Text(context.t.view_as_360),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (menuSpatial)
                          PopupMenuItem<void>(
                            onTap: () => unawaited(_openSpatial(video)),
                            child: ListTile(
                              leading: const Icon(Icons.threed_rotation_rounded),
                              title: Text(context.t.spatial_2_5d),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (canUpload)
                          PopupMenuItem<void>(
                            // One upload from the shares at a time
                            enabled: !isUploading,
                            onTap: () =>
                                unawaited(uploadNetworkEntries(this.context, ref, widget.sourceId, [video.entry])),
                            child: ListTile(
                              leading: const Icon(Icons.backup_outlined),
                              title: Text(context.t.network_upload_action),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        );

        return Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: PreferredSize(
            preferredSize: appBar.preferredSize,
            child: Focus(focusNode: _appBarFocus, onKeyEvent: _onAppBarKey, child: appBar),
          ),
          body: video != null
              ? _buildPlayer()
              : snapshot.connectionState != ConnectionState.done
              ? const NetworkLoadingView(color: Colors.white70)
              : Focus(
                  focusNode: _errorFocus,
                  child: NetworkErrorView(
                    error: snapshot.error ?? 'unknown error',
                    onRetry: _retry,
                    color: Colors.white70,
                  ),
                ),
        );
      },
    );

    return PopScope(
      // On a TV, Back first hides the controls and leaves the app bar, then leaves the page
      canPop: !tvMode || (!_showControls && !_appBarFocus.hasFocus),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _hideControls();
        }
      },
      child: Focus(focusNode: _rootFocus, autofocus: true, onKeyEvent: _onKey, child: page),
    );
  }

  Widget _buildPlayer() {
    // https://github.com/flutter/flutter/issues/97499: iOS platform views are only disposed in frames containing
    // platform views. The player leaves the tree as soon as the route transitions away, as in the asset viewer.
    final isRouteActive = ModalRoute.of(context)?.isActive ?? true;
    final error = _playerError;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _showControls = !_showControls),
      child: Stack(
        children: [
          if (isRouteActive)
            Positioned.fill(
              child: IgnorePointer(
                child: Visibility.maintain(
                  visible: _isVideoReady,
                  // A platform view must never take the focus: the keys of a remote would go to the native view
                  child: ExcludeFocus(child: NativeVideoPlayerView(onViewReady: _initController)),
                ),
              ),
            ),
          if (error != null)
            Positioned.fill(
              child: Focus(
                focusNode: _errorFocus,
                child: NetworkErrorView(error: error, onRetry: _retry, color: Colors.white70),
              ),
            )
          else
            // "Buffering…" while the video loads, and while it stalls (its position stands still as it plays)
            Positioned.fill(
              child: IgnorePointer(
                child: NetworkVideoBufferingIndicator(playerKey: _playerKey, loading: !_isVideoReady),
              ),
            ),
          if (_showControls && error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: NetworkVideoControls(playerKey: _playerKey, playFocusNode: _playFocus),
              ),
            ),
        ],
      ),
    );
  }
}
