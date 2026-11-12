import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:async/async.dart';
import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:immich_mobile/desktop/video/av2_gate.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/media_bridge.service.dart';
import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';
import 'package:immich_mobile/domain/services/play_on_screen/play_link_messages.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/raw/raw_video_plan.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/video_link_rule.dart';
import 'package:immich_mobile/domain/services/video_watch_recorder.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tracks.dart';
import 'package:immich_mobile/presentation/actions/watch_progress.action.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_failure_panel.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_track_buttons.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_status.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_upload.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_buffering.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/network_video_controls.widget.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/play_on.sheet.dart';
import 'package:immich_mobile/presentation/widgets/play_on_screen/remote_play_bar.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_back_button.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_seek_series.dart';
import 'package:immich_mobile/presentation/widgets/watch_progress/resume_notice.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/local_session.provider.dart';
import 'package:immich_mobile/providers/infrastructure/media_bridge.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/network/film_downloads.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('NetworkVideoPage');

/// A video of a share and its media bridge URL
typedef _Video = ({NetworkEntry entry, Uri url});

/// Whether [error], a message of the native player, says that what it got is no video it knows: Media3's
/// UnrecognizedInputFormatException, "None of the available extractors (...) could read the stream", whose list of
/// obfuscated names tells the user nothing
bool isUnrecognizedVideoError(String error) =>
    error.contains('None of the available extractors') || error.contains('UnrecognizedInputFormat');

/// Whether [error], a message of the native player, is a fault of its own reader of the file rather than of the file or
/// the share: Media3 wraps what a loader throws unexpectedly as "Unexpected" and the name of the exception, and its checkNotNull
/// reads "Attempt to invoke virtual method 'java.lang.Class java.lang.Object.getClass()' on a null object reference"
/// once minified. Seen on 11 November 2026 on a Dolby Vision profile 5 MKV film on the Quest (Media3 1.10.0).
bool isPlayerReaderFault(String error) => RegExp(r'^\s*Unexpected [A-Za-z]+(Exception|Error)\b').hasMatch(error);

/// The line of the logs about a file of a share that the player did not recognize as a video: the kind of share, the
/// type and the size the share gave, and the first bytes the media bridge sent ([head], null when they could not be
/// read), so that a report tells an HTML page, an empty answer or a format the player lacks apart
String unrecognizedVideoReport({
  required String name,
  required NetworkSourceType shareType,
  required NetworkEntry entry,
  required Uint8List? head,
}) {
  final bytes = head == null
      ? 'not readable'
      : head.isEmpty
      ? 'none'
      : head.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
  return 'The player does not recognize $name as a video: ${shareType.name} share, listed as '
      '${entry.guessedMimeType}, ${entry.size ?? 'unknown'} bytes, first bytes sent: $bytes';
}

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
/// The app bar and the controls hide 5 s after they show while the video plays, and 5 s after the last key; a tap
/// toggles them.
///
/// With a remote control, a keyboard or a game pad (see [NetworkVideoPageState._onKey]): up and down reach the app bar
/// and the controls. On a TV, left and right go to the previous or next file of [folder] whatever the video does, OK
/// shows the controls with play and pause focused, any other key but Back and the volume shows them, they also hide
/// while the video loads and show at its end, and Back hides them before it leaves. Elsewhere OK pauses or plays, left
/// and right seek while it plays and go to the previous or next file while it is paused.
@RoutePage()
class NetworkVideoPage extends ConsumerStatefulWidget {
  const NetworkVideoPage({super.key, required this.sourceId, required this.path, this.folder, this.startAt});

  final String sourceId;

  /// Absolute inside the share, "/" separated, starting with "/"
  final String path;

  /// The photos and videos of the folder the video was opened from, null when it was opened on its own
  final NetworkFolderMedia? folder;

  /// Where the first load starts, in place of where the film was left: the position a phone sent with "Play on the
  /// TV" (screen_player.provider.dart)
  final Duration? startAt;

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

  /// The share, which tells whether the file reads at any position (see [readsAnywhere]); null until it is open
  NetworkFileSystem? _shareFileSystem;

  /// The kind of share, for the logs; null until the share is open
  NetworkSourceType? _shareType;

  /// The copy of the film on this device plays instead of the share (see [_offlineVideo]): the id it is served under
  /// by the media bridge, and that bridge
  String? _offlineId;
  MediaBridge? _offlineBridge;

  NativeVideoPlayerController? _controller;
  bool _isVideoReady = false;
  bool _shouldPlayOnForeground = true;
  bool _showControls = true;

  /// What the native player reported when it could not play the video: its words, or the failure of the share the
  /// media bridge met for it (a Plex server that stopped answering, a film whose file the server cannot read)
  Object? _playerError;

  /// Whether the page waits for the first bytes of a Plex film for longer than [waitingNoticeAfter] (see
  /// [_waitForPlexStart]): it says so, with Cancel
  bool _waitingForServer = false;

  /// Completed by Cancel, or when the page goes: stops the wait for the first bytes
  Completer<void>? _startCancel;

  /// After how long the wait for the first bytes of a Plex film is told
  static const waitingNoticeAfter = Duration(seconds: 2);

  /// The frame size, once the native player read it: the 3D layout is guessed from it
  ({int width, int height})? _videoSize;

  /// Resumes a film and saves where it is, for the video loaded (see VideoWatchRecorder)
  VideoWatchRecorder? _recorder;

  /// The tracks of a film of a Plex server: its subtitle files, the names Plex gives its tracks, and the pick written
  /// back (see PlexFilmTracks); null for any other video
  PlexFilmTracks? _plexTracks;

  /// Whether the tracks Plex has for the account were picked in the player, once per load
  bool _plexChoiceApplied = false;

  /// The film resumed where it was left, said for a few seconds (see ResumeNotice)
  ResumeNoticeEvent? _resumeNotice;

  /// [NetworkVideoPage.startAt] was used: a Retry resumes as usual
  bool _startAtUsed = false;

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

  /// Hides the app bar and the controls [videoControlsHideAfter] after they show, or after the last key, while the
  /// video plays
  late final RestartableTimer _hideTimer;

  /// The key of the player of this page in [videoPlayerProvider]
  String get _playerKey => 'network:${widget.sourceId}:${widget.path}';

  VideoPlayerNotifier get _notifier => ref.read(videoPlayerProvider(_playerKey).notifier);

  String get _name => widget.path.split('/').last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hideTimer = RestartableTimer(videoControlsHideAfter, _onHideTimer);
    HardwareKeyboard.instance.addHandler(_onAnyKey);
    // Back on a TV depends on where the focus is
    _appBarFocus.addListener(_onAppBarFocus);
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onAnyKey);
    _hideTimer.cancel();
    _detectTimer?.cancel();
    // Where the film is, as the page goes: Back, or the previous or next file in its place
    _recorder?.dispose();
    _recorder = null;
    _plexTracks?.dispose();
    _plexTracks = null;
    _cancelStartWait();
    _removeListeners();
    _appBarFocus.removeListener(_onAppBarFocus);
    final offlineId = _offlineId;
    if (offlineId != null) {
      _offlineBridge?.unregisterGenerated(offlineId);
    }
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

  /// Every key starts the 5 s again, wherever it goes: the bars hide 5 s after the last key, never under a user who is
  /// still using the remote or the keyboard
  bool _onAnyKey(KeyEvent event) {
    if (event is! KeyUpEvent) {
      _hideTimer.reset();
    }
    return false;
  }

  void _onHideTimer() {
    if (!mounted || !_showControls) {
      return;
    }
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      // Under a menu of the app bar: 5 s once it closes
      _hideTimer.reset();
      return;
    }
    // Paused or ended they stay, until it plays again (a change of status starts the 5 s again). A TV also hides them
    // while the video loads: a slow network would keep them there for ever.
    final status = ref.read(videoPlayerProvider(_playerKey)).status;
    final plays =
        status == VideoPlaybackStatus.playing || (status == VideoPlaybackStatus.buffering && ref.read(tvModeProvider));
    if (!plays || _playerError != null) {
      return;
    }
    // A button of the bars had the focus: the page takes it back, so that the next key of a remote is not lost
    final barsHadFocus = _rootFocus.hasFocus && !_rootFocus.hasPrimaryFocus;
    setState(() => _showControls = false);
    if (barsHadFocus) {
      _rootFocus.requestFocus();
    }
  }

  /// Shows or hides the app bar and the controls; shown, they hide 5 s later while the video plays
  void _setControls(bool show) {
    if (show) {
      _hideTimer.reset();
    }
    if (_showControls != show) {
      setState(() => _showControls = show);
    }
  }

  /// A change of the video's status starts the 5 s again; on a TV the controls show when it reaches its end, with the
  /// replay button (a video just loaded is reported ended too, at its start, which does not count)
  void _onStatus(VideoPlaybackStatus? previous, VideoPlaybackStatus status) {
    _hideTimer.reset();
    if (status == VideoPlaybackStatus.completed &&
        previous != VideoPlaybackStatus.completed &&
        ref.read(tvModeProvider) &&
        ref.read(videoPlayerProvider(_playerKey)).position > Duration.zero) {
      _setControls(true);
    }
  }

  /// Whether the folder the video was opened from has another photo or video before or after it
  bool get _hasNeighbours =>
      networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, -1) != null ||
      networkFolderNeighbourRoute(widget.sourceId, widget.folder, widget.path, 1) != null;

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
  /// belong to the focused button. In place of a video that could not be had or played, Down and OK go to Retry. Left,
  /// right and OK follow [remoteVideoArrows] and [remoteVideoOkFocusesControls]; on a TV any key but those that go to
  /// another file, Back and the volume shows the controls ([remoteKeyShowsVideoControls]).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final press = isRemotePress(event);
    final tvMode = ref.read(tvModeProvider);
    if (tvMode && press && remoteKeyShowsVideoControls(key)) {
      _setControls(true);
    }
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
        if (remoteVideoOkFocusesControls(tvMode: tvMode)) {
          // A second OK presses play and pause
          _showControlsAndFocus(top: false);
        } else {
          _setPlaying(!_isPlaying);
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final step = key == LogicalKeyboardKey.arrowRight ? 1 : -1;
      final arrows = remoteVideoArrows(tvMode: tvMode, playing: _isPlaying, hasNeighbours: _hasNeighbours);
      if (arrows == RemoteVideoArrows.seek) {
        // Shared with the controls, which show the step of the last press (see RemoteSeekSeries)
        final series = tvMode ? ref.read(remoteSeekSeriesProvider(_playerKey)) : null;
        if (series != null && press) {
          // A TV: further at each press of a quick series
          _seekBy(series.press(forward: step > 0));
        } else if (event is! KeyUpEvent) {
          // Held, it keeps seeking, 10 s per repeat; the next press starts a new series
          series?.end();
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

  /// Plays, or pauses and shows the controls. A video at its end plays from the start.
  void _setPlaying(bool play) {
    final notifier = _notifier;
    if (!play) {
      unawaited(notifier.pause());
      _setControls(true);
      return;
    }
    if (ref.read(videoPlayerProvider(_playerKey)).status == VideoPlaybackStatus.completed) {
      unawaited(notifier.restart());
    } else {
      unawaited(notifier.play());
    }
  }

  void _seekBy(Duration delta) {
    _notifier.seekBy(delta);
    _setControls(true);
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
    _setControls(true);
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
    _setControls(false);
    _rootFocus.requestFocus();
  }

  Future<_Video> _load() async {
    // Read before the first await: the page may be gone by then
    final connections = ref.read(networkConnectionsProvider);
    final service = ref.read(networkMediaServiceProvider);
    final client = ref.read(networkBridgeClientProvider);
    // A film downloaded to this device plays from there, with or without the server (request 5 of the Plex films
    // study): its watch progress is the one of the film on the share, by the same entry
    final offline = await _offlineVideo(service, client);
    if (offline != null) {
      return offline;
    }
    final fileSystem = await connections.fileSystem(widget.sourceId);
    _shareType = fileSystem.source.type;
    final bridge = ref.read(mediaBridgeProvider);
    final entry = await fileSystem.stat(widget.path);
    // A Plex film: its first bytes before the player, which gives up long before a server slow to start one
    if (fileSystem is PlexFileSystem) {
      await _waitForPlexStart(fileSystem);
    }
    final url = await connections.mediaUrl(widget.sourceId, widget.path);
    // A film of a Plex server: its subtitle files and the names of its tracks, before the player is given the film
    final tracks = await _plexTracksOf(fileSystem, bridge);
    _plexTracks?.dispose();
    _plexTracks = tracks;
    _plexChoiceApplied = false;
    if (!mounted) {
      tracks?.dispose();
      _plexTracks = null;
    }
    _shareReader = networkFileReader(fileSystem, widget.path);
    _shareFileSystem = fileSystem;
    // What the file declares is read once the player has what it needs to play, not beside its first reads: on a slow
    // share the two read the index of the file at once (3.6 MB for a two hour film), and the film started later. A
    // page whose native player is not there a second later reads it at once
    _detectLater = () => _detect(service, entry, httpRangeReader(client, url));
    _detectTimer?.cancel();
    _detectTimer = Timer(detectWithoutPlayer, () {
      _detectTimer = null;
      _detectWhenIdle(now: _controller == null);
    });
    return (entry: entry, url: url);
  }

  /// The whole copy of the film on this device, served by the media bridge under a random id like the generated media,
  /// with the entry the share listed when it was copied; null when there is none
  Future<_Video?> _offlineVideo(NetworkMediaService service, http.Client client) async {
    // A Plex film, or a film of a server removed since, whose copy stays on the device
    final source = ref.read(networkSourceProvider(widget.sourceId));
    if (source != null && !filmDownloadSourceType(source.type)) {
      return null;
    }
    final downloads = ref.read(filmDownloadsProvider.notifier);
    final bridge = ref.read(mediaBridgeProvider);
    final File? copy;
    try {
      copy = await downloads.completedCopy(widget.sourceId, widget.path);
    } catch (error) {
      _log.fine('The copies on this device could not be read: ${error.runtimeType}');
      return null;
    }
    if (copy == null || !mounted) {
      return null;
    }
    final film = ref.read(filmDownloadsProvider).of(widget.sourceId, widget.path);
    if (film == null) {
      return null;
    }
    await bridge.start();
    final id = _offlineId ??= 'film-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    final dot = film.fileName.lastIndexOf('.');
    final name = 'film${dot > 0 ? film.fileName.substring(dot).toLowerCase() : ''}';
    final entry = film.entry;
    bridge.registerGenerated(id, _DownloadedFilm(copy, name, entry.guessedMimeType));
    _offlineBridge = bridge;
    final url = bridge.urlFor(id, '/$name');
    _shareReader = null;
    _shareFileSystem = null;
    _log.info('Playing the copy of the film on this device');
    _detectLater = () => _detect(service, entry, httpRangeReader(client, url));
    _detectTimer?.cancel();
    _detectTimer = Timer(detectWithoutPlayer, () {
      _detectTimer = null;
      _detectWhenIdle(now: _controller == null);
    });
    return (entry: entry, url: url);
  }

  /// Reads what the file declares (see [_detect]), set by [_load] and run once by [_detectWhenIdle]
  Future<void> Function()? _detectLater;

  /// Whether what the file declares waits to be read, see [_detectWhenIdle]: for the tests
  @visibleForTesting
  bool get detectPending => _detectLater != null;
  Timer? _detectTimer;

  /// Longest wait for the player before what the file declares is read anyway
  static const detectWait = Duration(seconds: 15);

  /// How long the page waits for its native player before it reads what the file declares without it
  static const detectWithoutPlayer = Duration(seconds: 1);

  /// Runs [_detectLater] once the player is ready and its link no longer loads, or [detectWait] after the load,
  /// whichever comes first
  void _detectWhenIdle({bool now = false}) {
    final detect = _detectLater;
    if (detect == null || !mounted) {
      return;
    }
    final link = _controller?.onLinkChanged.value;
    final idle = _isVideoReady && (link == null || !link.loading);
    if (!now && !idle) {
      _detectTimer ??= Timer(detectWait, () => _detectWhenIdle(now: true));
      return;
    }
    _detectLater = null;
    _detectTimer?.cancel();
    _detectTimer = null;
    unawaited(detect());
  }

  /// Logs what the player got of a file it did not recognize as a video (see [unrecognizedVideoReport])
  Future<void> _logUnrecognized() async {
    // Read before the first await: the page may be gone by then
    final client = ref.read(networkBridgeClientProvider);
    final shareType = _shareType;
    final _Video video;
    try {
      video = await _video;
    } catch (_) {
      return;
    }
    Uint8List? head;
    try {
      head = await httpRangeReader(client, video.url)(0, 16);
      if (head.length > 16) {
        head = Uint8List.sublistView(head, 0, 16);
      }
    } catch (error) {
      _log.fine('Could not read the head of $_name: $error');
    }
    if (shareType != null) {
      _log.warning(unrecognizedVideoReport(name: _name, shareType: shareType, entry: video.entry, head: head));
    }
  }

  // Through the media bridge, with range requests, like the players read the file
  Future<void> _detect(NetworkMediaService service, NetworkEntry entry, ByteRangeReader read) async {
    final info = await service.detect(entry, read, thorough: true);
    if (info != null && mounted) {
      setState(() => _info = info);
    }
  }

  Future<VideoSource?> _sourceOf(Future<_Video> video) async {
    try {
      final url = (await video).url;
      return await VideoSource.init(
        path: url.toString(),
        type: VideoSourceType.network,
        // The subtitle files beside a Plex film, served by the bridge
        subtitles: _plexTracks?.subtitles ?? const [],
      );
    } catch (_) {
      // The page shows why
      return null;
    }
  }

  /// The tracks of the Plex film at the page's path (see PlexFilmTracks); null for any other video, and when Plex
  /// does not tell them within [plexTracksWait]: the film then plays with the tracks of its file only
  Future<PlexFilmTracks?> _plexTracksOf(NetworkFileSystem fileSystem, MediaBridge bridge) async {
    if (fileSystem is! PlexFileSystem) {
      return null;
    }
    final item = fileSystem.itemAt(widget.path);
    if (item == null) {
      return null;
    }
    try {
      final details = await fileSystem.filmDetails(item.ratingKey).timeout(plexTracksWait);
      final part = details.partOf(item.partId);
      if (part == null || part.streams.isEmpty) {
        return null;
      }
      return await PlexFilmTracks.load(PlexFileSystemTracks(fileSystem), part, bridge).timeout(plexTracksWait);
    } catch (error) {
      _log.info('The tracks of the Plex film are not known: ${error.runtimeType}');
      return null;
    }
  }

  /// Waits for the first bytes of the Plex film of the page (PlexFileSystem.waitForFirstBytes): a server that just
  /// mounted its films again takes over a minute to send them, which the player would take for a failure. Past
  /// [waitingNoticeAfter] the page says it waits for the server, with Cancel. A failure goes to the page as the
  /// failure of the load: the server stopped answering, or cannot read the file.
  Future<void> _waitForPlexStart(PlexFileSystem fileSystem) async {
    _cancelStartWait();
    final cancel = _startCancel = Completer<void>();
    final notice = Timer(waitingNoticeAfter, () {
      if (mounted && identical(_startCancel, cancel)) {
        setState(() => _waitingForServer = true);
      }
    });
    final watch = Stopwatch()..start();
    try {
      await fileSystem.waitForFirstBytes(widget.path, cancel: cancel.future);
    } finally {
      notice.cancel();
      if (identical(_startCancel, cancel)) {
        _startCancel = null;
      }
      if (watch.elapsed > waitingNoticeAfter) {
        _log.info('The Plex server sent the start of the film after ${watch.elapsed.inSeconds} s');
      }
      if (mounted && _waitingForServer) {
        setState(() => _waitingForServer = false);
      }
    }
  }

  void _cancelStartWait() {
    final cancel = _startCancel;
    _startCancel = null;
    if (cancel != null && !cancel.isCompleted) {
      cancel.complete();
    }
  }

  /// Cancel of the wait for the server: the wait stops and the page goes
  void _onCancelStartWait() {
    _cancelStartWait();
    unawaited(context.maybePop());
  }

  /// The failure of the share the media bridge met for the video of the page lately, null when none
  NetworkFileSystemException? _bridgeFailure() {
    final bridge = ref.read(mediaBridgeProvider);
    return bridge is LocalMediaBridge ? bridge.recentFailure(widget.sourceId, widget.path) : null;
  }

  /// Longest wait for what Plex tells of the tracks of a film before it plays
  static const plexTracksWait = Duration(seconds: 4);

  /// Picks the audio track and the subtitles Plex has for the account (chosen in a Plex app, or in this one before),
  /// once per load, when the player lists them: the film starts as it does in Plex
  Future<void> _applyPlexChoice() async {
    final tracks = _plexTracks;
    if (tracks == null || _plexChoiceApplied) {
      return;
    }
    final listed = await _notifier.tracks();
    if (!mounted || listed.isEmpty || _plexChoiceApplied || !identical(tracks, _plexTracks)) {
      return;
    }
    _plexChoiceApplied = true;
    final audio = listed.where((track) => track.type == NativeVideoTrackType.audio).toList();
    final text = listed.where((track) => track.type == NativeVideoTrackType.text).toList();
    final audioRefs = videoTrackRefs(audio);
    final selectedAudio = tracks.selectedAudio;
    if (selectedAudio != null) {
      final index = audioRefs.indexWhere((ref) => tracks.streamOf(ref)?.id == selectedAudio.id);
      if (index >= 0 && !audio[index].selected) {
        await _notifier.selectTrack(audio[index]);
      }
    }
    final subtitle = tracks.selectedSubtitle;
    if (subtitle != null && !text.any((track) => track.selected)) {
      final textRefs = videoTrackRefs(text);
      final index = textRefs.indexWhere(
        (ref) => subtitle.isSidecar ? ref.sidecarId == subtitle.sidecarId : ref.ordinal == subtitle.ordinal,
      );
      if (index >= 0 && (subtitle.isSidecar || tracks.streamOf(textRefs[index]) != null)) {
        await _notifier.selectTrack(text[index]);
      }
    }
  }

  void _retry() {
    // Retry leaves with the error: the page takes the keys again
    if (_errorFocus.hasFocus) {
      _rootFocus.requestFocus();
    }
    _detectTimer?.cancel();
    _detectTimer = null;
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
        // Back from the native 360° player or the immersive viewer, if one was opened on this video. A computer's
        // 360° player is a route of the window, which may still be open at a focus change: its closing ends the
        // suspension there (externalPlayerClosedProvider)
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

  /// Gives the page [controller] as its native player would once its view is ready: for the tests, which have no
  /// platform view
  @visibleForTesting
  void attachController(NativeVideoPlayerController controller) => _initController(controller);

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
    controller.onTracksChanged.addListener(_onTracksChanged);
    controller.onLinkChanged.addListener(_onLinkChanged);
    _controller = controller;
    ref.listenManual(videoPlayerProvider(_playerKey).select((v) => v.status), _onFailure);
    unawaited(_loadVideo());
  }

  void _onLinkChanged() {
    final link = _controller?.onLinkChanged.value;
    if (mounted && link != null) {
      _notifier.onNativeLinkChanged(link);
      _detectWhenIdle();
    }
  }

  void _removeListeners() {
    final controller = _controller;
    controller?.onPlaybackPositionChanged.removeListener(_onPlaybackPositionChanged);
    controller?.onPlaybackStatusChanged.removeListener(_onPlaybackStatusChanged);
    controller?.onPlaybackReady.removeListener(_onPlaybackReady);
    controller?.onPlaybackEnded.removeListener(_onPlaybackEnded);
    controller?.onError.removeListener(_onPlayerError);
    controller?.onTracksChanged.removeListener(_onTracksChanged);
    controller?.onLinkChanged.removeListener(_onLinkChanged);
  }

  Future<void> _loadVideo() async {
    final source = await videoSource;
    if (source == null || !mounted) {
      return;
    }
    // Known already: the source was made from it
    final NetworkEntry entry;
    try {
      entry = (await _video).entry;
    } catch (_) {
      // A Retry made the source again meanwhile, and the page shows why it failed
      return;
    }
    if (!mounted) {
      return;
    }
    // Read before the first await: the page may be gone by then
    final loop = ref.read(loopVideoProvider);
    final notifier = _notifier;
    // The position a phone sent wins over where the film was left: the recorder finds a restore waiting
    final startAt = widget.startAt;
    if (startAt != null && !_startAtUsed) {
      _startAtUsed = true;
      notifier.seekWhenReady(startAt);
    }
    // A film resumes where it was left, once ready, and plays once whatever Looping says
    final recorder = await _startRecorder(notifier, entry);
    if (recorder == null) {
      return;
    }
    await notifier.load(source);
    await notifier.setLoop(recorder.loopsWith(loop));
    await notifier.setVolume(1);
  }

  /// The recorder of [entry], about to load in [notifier], in place of the one of a load before (Retry); null once the
  /// page is gone
  Future<VideoWatchRecorder?> _startRecorder(VideoPlayerNotifier notifier, NetworkEntry entry) async {
    _recorder?.dispose();
    _recorder = null;
    final store = ref.read(watchProgressProvider.notifier);
    final rule = ref.read(watchRuleProvider);
    await VideoWatchRecorder.storeReady(store);
    if (!mounted) {
      return null;
    }
    // Another load may have started its own meanwhile
    _recorder?.dispose();
    final durationMs = entry.durationMs;
    return _recorder = VideoWatchRecorder(
      store: store,
      player: notifier,
      key: WatchKey.ofEntry(entry),
      rule: rule,
      // What a media server tells (DLNA, Plex); else the player tells it once ready
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
      onResumed: _onResumed,
    )..start();
  }

  /// The film plays from where it was left: the page says so for a few seconds
  void _onResumed(Duration position) {
    if (mounted) {
      setState(() => _resumeNotice = ResumeNoticeEvent(position, (_resumeNotice?.serial ?? 0) + 1));
    }
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
    _detectWhenIdle();
    // A video that becomes ready behind another app or an external player would play there unseen
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden) {
      return;
    }
    // Opened again while the film plays on a screen from this phone: the mini controller is in charge, the phone's
    // player waits for Continue on this phone
    final remote = ref.read(remotePlaybackProvider);
    if (remote != null && remote.playsOnScreen(widget.sourceId, widget.path)) {
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

  void _onTracksChanged() {
    if (mounted) {
      _notifier.onNativeTracksChanged();
      unawaited(_applyPlexChoice());
    }
  }

  void _onPlayerError() {
    final controller = _controller;
    final error = controller?.onError.value;
    if (controller != null && error != null && mounted) {
      _log.warning('Could not play $_name: $error');
      // The media bridge answered the player an error for a failure of the share ("Response code: 500" is all the
      // player tells): the page says what the share met, with Retry, rather than the player's words
      final shareFailure = _bridgeFailure();
      // The extractor list of Media3 tells the user nothing: a sentence, and what the player got in the logs. An error
      // the native player put in the words of the app (NativePlaybackError) is said in ours, never as its token
      final unrecognized = shareFailure == null && isUnrecognizedVideoError(error);
      final readerFault = shareFailure == null && isPlayerReaderFault(error);
      final Object shown =
          shareFailure ??
          (readerFault
              ? context.t.network_video_reader_fault
              : unrecognized
              ? context.t.network_video_unrecognized
              : NativePlaybackError.parse(error) != null
              ? _nativeErrorText(error)
              : error);
      setState(() => _playerError = shown);
      if (unrecognized) {
        unawaited(_logUnrecognized());
      }
      // Failed, not playing: the remote goes to the next file. Back to null, so that the same error after Retry is
      // heard again
      _notifier.onNativeError(error);
      scheduleMicrotask(() => controller.onError.value = null);
    }
  }

  /// An error of the native player in the words of the failure panel of the viewer: the cause, else its title
  String _nativeErrorText(String error) {
    final text = describeVideoFailure(
      VideoPlaybackFailure(VideoFailureKind.error, error),
      null,
      context.t,
      fromServer: false,
      locale: context.locale.toLanguageTag(),
    );
    return text.cause ?? text.title;
  }

  /// A wait that is no error: the share stopped sending (the page says so where it says "Buffering", and the video
  /// plays on by itself once the share answers), or, where the player tells nothing of its link, nothing played for
  /// [VideoPlayerNotifier.fallbackStallTimeout]. Neither stays once the video moves.
  void _onFailure(VideoPlaybackStatus? previous, VideoPlaybackStatus status) {
    if (status != VideoPlaybackStatus.failed || previous == VideoPlaybackStatus.failed || !mounted) {
      return;
    }
    switch (_notifier.failure?.kind) {
      case VideoFailureKind.dead:
        _log.warning('$_name: nothing arrived for ${VideoLinkRule.deadAfter.inSeconds} s, the player keeps trying');
      case VideoFailureKind.stalled:
        _log.warning('Nothing of $_name played for ${VideoPlayerNotifier.fallbackStallTimeout.inSeconds} s');
      default:
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
      share: _shareFileSystem,
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
      // The viewer carries on from where the page's player is, unless it reached the end, and a film the page did not
      // play yet from where it was left: read right before openImmersiveUrl stops the player, nothing awaited in between
      final start = _immersiveStart(video);
      try {
        await openImmersiveUrl(
          ref,
          request: request,
          stereoLabels: stereoLabels,
          startPosition: start.position,
          startNotice: start.notice,
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
            // Asked once the plan read the share: a server tells at its first reads whether it honours ranges
            readsAnywhere: () => readsAnywhere(_shareFileSystem, video.entry),
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
    // A share has no smaller stream: a file beyond the decoders of the device opens no player that would load forever
    // unless the user still wants to try
    if (plan == null && mounted) {
      final probe = _info?.probe;
      final verdict = await ref.read(videoSourceServiceProvider).verdict(probe);
      if (verdict != null && !verdict.supported) {
        _log.warning('$_name is beyond the decoders of this device: ${verdict.reason}');
        if (!mounted || !await confirmUndecodableVideo(context, probe, verdict, fromServer: false)) {
          return;
        }
      }
    }
    if (!mounted) {
      return;
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
      plan: plan,
    );
    if (!opened) {
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  /// Where the immersive viewer starts [video]: where the page's player is, unless it reached the end, else where a film
  /// was left, with its notice (see ImmersiveWatch)
  ({Duration position, String? notice}) _immersiveStart(_Video video) {
    final playback = ref.read(videoPlayerProvider(_playerKey));
    final durationMs = video.entry.durationMs;
    return readImmersiveWatch(ref).startFrom(
      playback.status == VideoPlaybackStatus.completed ? Duration.zero : playback.position,
      key: WatchKey.ofEntry(video.entry),
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    );
  }

  /// How [video] packs its eyes when its name says it holds two (see guessFlatStereoFormat), its frame told by the
  /// player once known; null for any other video
  FlatStereoFormat? _flatFormat(_Video video) => guessFlatStereoFormat(
    fileName: video.entry.name,
    width: _videoSize?.width,
    height: _videoSize?.height,
    isVideo: true,
  );

  /// Opens [video], a flat 3D video packed as [format], on the flat video screen of the immersive viewer of a Meta
  /// Quest, from where the page's player is unless it reached the end. It plays on its own there; once the viewer
  /// closes, the page's player takes it back where the viewer left it (see [SingleVideoImmersiveNavigator]).
  Future<void> _openFlat3d(_Video video, FlatStereoFormat format) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final errorMessage = context.t.immersive_viewer_open_failed;
    final stereoLabels = stereoPhotoViewerLabels(context.t);
    final request = ImmersiveRequest(
      url: video.url.toString(),
      isVideo: true,
      title: video.entry.name,
      view: stereoPhotoSphereView,
      stereoPair: Flat3dRequest(format).toJsonString(),
    );
    final player = _notifier;
    // Read right before openImmersiveUrl stops the player, nothing awaited in between
    final start = _immersiveStart(video);
    try {
      await openImmersiveUrl(
        ref,
        request: request,
        stereoLabels: stereoLabels,
        startPosition: start.position,
        startNotice: start.notice,
        player: player,
        navigator: SingleVideoImmersiveNavigator(
          request: request,
          player: player,
          watch: readImmersiveWatch(ref),
          watchKey: WatchKey.ofEntry(video.entry),
        ),
      );
    } catch (error) {
      _log.warning('Could not open $_name in 3D: $error');
      messenger?.showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  /// The film as "Play on..." sends it: the Plex server, the rating key, where the phone's player is and its tracks;
  /// null for a file of another share, or one the connection does not know the key of
  PlayOnRequest? _playOnRequest() {
    final fileSystem = _shareFileSystem;
    final playback = ref.read(videoPlayerProvider(_playerKey));
    final tracks = _notifier.lastTracks;
    final audio = tracks.where((track) => track.type == NativeVideoTrackType.audio && track.selected).firstOrNull;
    final text = tracks.where((track) => track.type == NativeVideoTrackType.text && track.selected).firstOrNull;
    final hasText = tracks.any((track) => track.type == NativeVideoTrackType.text);
    return PlayOnRequest.of(
      source: ref.read(networkSourceProvider(widget.sourceId)),
      fileSystem: fileSystem is PlexFileSystem ? fileSystem : null,
      path: widget.path,
      title: _name,
      offsetMs: playback.status == VideoPlaybackStatus.completed ? 0 : playback.position.inMilliseconds,
      audio: audio?.language == null ? null : PlayTrackChoice(language: audio!.language),
      subtitle: text?.language != null
          ? PlayTrackChoice(language: text!.language)
          : (hasText ? const PlayTrackChoice(off: true) : null),
    );
  }

  /// "Play on...": the sheet of the linked screens; the phone's player pauses once the film plays on one
  Future<void> _playOn() async {
    final request = _playOnRequest();
    if (request == null) {
      return;
    }
    final playing = await showPlayOnSheet(context, request);
    if (playing && mounted) {
      await _notifier.pause();
    }
  }

  /// "Continue on this phone": the screen stopped at [position], the phone's player goes on from there
  void _continueHere(Duration position) {
    final notifier = _notifier;
    notifier.seekTo(position);
    unawaited(notifier.play());
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
    ref.listen(videoPlayerProvider(_playerKey).select((v) => v.status), _onStatus);
    final isHorizonOs = ref.watch(isHorizonOsProvider).valueOrNull;
    final can360 = (isHorizonOs ?? false) || ref.watch(panorama360VideoSupportedProvider);
    // Like in the asset viewer: an experimental setting, on phones only, never while the platform check is pending
    // A TV has no front camera for Spatial 2.5D, and is a viewer: nothing is sent from it
    final tvMode = ref.watch(tvModeProvider);
    final canSpatial =
        !tvMode && isHorizonOs == false && ref.watch(appConfigProvider.select((c) => c.viewer.spatial25d));
    // The flat 3D videos told by their file name on a Meta Quest, experimental and on by default (Settings, Advanced)
    final flat3dByName = isHorizonOs == true && ref.watch(appConfigProvider.select((c) => c.viewer.flat3dByName));
    final canUpload = !tvMode && ref.watch(hasServerProvider);
    final canPlayOn = !tvMode && isHorizonOs == false && !CurrentPlatform.isDesktop;
    // The film plays on a screen from this page: the mini controller in place of the controls
    final remote = ref.watch(
      remotePlaybackProvider.select(
        (playback) => playback != null && playback.isOf(widget.sourceId, widget.path) ? playback : null,
      ),
    );
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
        // A video whose name says it holds two eyes (_SBS, _HSBS, _LR, _TB, _OU, Half-SBS...) and that is not 360°:
        // "View in 3D", on the flat video screen of the immersive viewer
        final flatFormat = video != null && flat3dByName && !is360 ? _flatFormat(video) : null;
        // Play from the start and Mark as not watched, for a film (see watchActionsFor). The entries only, which a record
        // compares by value: the save of the film every 5 s while it plays rebuilds nothing here
        final watchKey = video == null ? null : WatchKey.ofEntry(video.entry);
        final watchRule = ref.watch(watchRuleProvider);
        // Download to this device, a Plex film on a screen that copies films (see filmDownloadMenuItems)
        final canDownload = video != null && canDownloadFilm(ref, widget.sourceId, video.entry);
        final watchActions = watchKey == null
            ? (restart: false, unwatch: false)
            : ref.watch(watchProgressProvider.select((rows) => watchActionsFor(rows.find(watchKey), watchRule)));

        final appBar = AppBar(
          backgroundColor: Colors.black38,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          // On a TV, Back on the app bar only hides it: the Back button leaves the page itself
          leading: tvMode ? remoteBackButton(context) : null,
          // The title of a Plex film rather than its file name, which a screen reader says too
          title: Text(
            video?.entry.shownName ?? _name,
            key: const Key('network_video_title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
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
                  if (video != null && flatFormat != null)
                    IconButton(
                      key: const Key('apple_spatial_view_3d'),
                      icon: const Icon(Icons.view_in_ar_rounded),
                      tooltip: context.t.apple_spatial_view_3d,
                      onPressed: () => unawaited(_openFlat3d(video, flatFormat)),
                    ),
                  if (video != null && canSpatial && isStereo)
                    IconButton(
                      icon: const Icon(Icons.threed_rotation_rounded),
                      tooltip: context.t.spatial_2_5d,
                      onPressed: () => unawaited(_openSpatial(video)),
                    ),
                  // Played from the copy on this device
                  if (_offlineId != null)
                    Tooltip(
                      key: const Key('network_video_offline'),
                      message: context.t.film_download_offline,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.offline_pin_rounded),
                      ),
                    ),
                  // Play on a linked screen: a Plex film, from a phone or a tablet (a TV, the Quest and the computers
                  // are the screens)
                  if (video != null && canPlayOn && _shareType == NetworkSourceType.plex)
                    IconButton(
                      key: const Key('network_video_play_on'),
                      icon: const Icon(Icons.cast_rounded),
                      tooltip: context.t.play_on_title,
                      onPressed: () => unawaited(_playOn()),
                    ),
                  if (video != null &&
                      (menu360 ||
                          menuSpatial ||
                          canUpload ||
                          canDownload ||
                          watchActions.restart ||
                          watchActions.unwatch))
                    PopupMenuButton<void>(
                      tooltip: context.t.more,
                      itemBuilder: (context) => [
                        if (watchActions.restart && watchKey != null)
                          PopupMenuItem<void>(
                            key: const Key('network_video_play_from_start'),
                            onTap: () => playFromStart(ref.read(watchProgressProvider.notifier), watchKey, _notifier),
                            child: ListTile(
                              leading: const Icon(Icons.replay_rounded),
                              title: Text(context.t.video_play_from_start),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        if (watchActions.unwatch && watchKey != null)
                          PopupMenuItem<void>(
                            key: const Key('network_video_mark_unwatched'),
                            onTap: () => ref.read(watchProgressProvider.notifier).markUnwatched(watchKey),
                            child: ListTile(
                              leading: const Icon(Icons.remove_done_rounded),
                              title: Text(context.t.video_mark_unwatched),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
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
                        // The page's own context: the sheet and the dialog open once the menu is gone
                        if (canDownload) ...filmDownloadMenuItems(this.context, ref, video.entry),
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

        // The app bar goes with the controls over a video, and stays over a video that could not be had or played
        final showAppBar = _showControls || video == null || _playerError != null;
        return Scaffold(
          backgroundColor: Colors.black,
          extendBodyBehindAppBar: true,
          appBar: PreferredSize(
            preferredSize: appBar.preferredSize,
            child: Focus(
              focusNode: _appBarFocus,
              onKeyEvent: _onAppBarKey,
              child: IgnorePointer(
                ignoring: !showAppBar,
                // Hidden, its buttons must not take the focus either: an arrow of a remote would land on them
                child: ExcludeFocus(
                  excluding: !showAppBar,
                  child: AnimatedOpacity(opacity: showAppBar ? 1 : 0, duration: Durations.short2, child: appBar),
                ),
              ),
            ),
          ),
          bottomNavigationBar: remote == null ? null : RemotePlayBar(playback: remote, onContinueHere: _continueHere),
          body: video != null
              // Immuch360 Desktop: an AV2 file plays once its decoder is there, its setting on and its speed told
              // (lib/desktop/video/av2_gate.dart); a phone says it plays on the computers
              ? Av2ShareGate(
                  file: networkMediaKey(video.entry),
                  child: _buildPlayer(remote: remote != null),
                )
              : snapshot.connectionState != ConnectionState.done
              ? (_waitingForServer
                    ? Focus(
                        focusNode: _errorFocus,
                        child: NetworkLoadingView(
                          color: Colors.white70,
                          message: context.t.plex_film_waiting_for_server,
                          detail: context.t.plex_film_waiting_for_server_detail,
                          onCancel: _onCancelStartWait,
                        ),
                      )
                    : const NetworkLoadingView(color: Colors.white70))
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

  /// [remote]: the film plays on a screen, whose mini controller replaces the controls
  Widget _buildPlayer({bool remote = false}) {
    // https://github.com/flutter/flutter/issues/97499: iOS platform views are only disposed in frames containing
    // platform views. The player leaves the tree as soon as the route transitions away, as in the asset viewer.
    final isRouteActive = ModalRoute.of(context)?.isActive ?? true;
    final error = _playerError;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _setControls(!_showControls),
      child: Stack(
        children: [
          if (isRouteActive)
            Positioned.fill(
              child: IgnorePointer(
                child: Visibility.maintain(
                  visible: _isVideoReady,
                  // A platform view must never take the focus: the keys of a remote would go to the native view
                  child: ExcludeFocus(
                    // The computers play through media_kit (lib/desktop/video), with a controller of the same type
                    child: CurrentPlatform.isDesktop
                        ? DesktopVideoView(onViewReady: _initController)
                        : NativeVideoPlayerView(onViewReady: _initController),
                  ),
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
            // "Buffering…" while the video loads, and while it stalls (its position stands still as it plays), with
            // what the link brings against what the video needs, and a share that stopped sending
            Positioned.fill(
              child: IgnorePointer(
                child: NetworkVideoBufferingIndicator(
                  playerKey: _playerKey,
                  loading: !_isVideoReady,
                  link: _notifier.link,
                ),
              ),
            ),
          // Where a film resumed, for a few seconds (see ResumeNotice): it takes no touch nor key
          Positioned(
            top: MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
            left: 0,
            right: 0,
            child: Center(child: ResumeNotice(notice: _resumeNotice)),
          ),
          if (_showControls && error == null && !remote)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: NetworkVideoControls(
                  playerKey: _playerKey,
                  playFocusNode: _playFocus,
                  // The names Plex gives the tracks of a film, and the pick written back to it
                  trackNaming: _plexTracks,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The copy of a film on this device, as the media bridge serves it: one file under one name
class _DownloadedFilm extends GeneratedMedia {
  _DownloadedFilm(this._file, this._name, this._contentType);

  final File _file;
  final String _name;
  final String _contentType;

  @override
  GeneratedFile? file(String name) => name == _name ? GeneratedFile.disk(_file, _contentType) : null;
}
