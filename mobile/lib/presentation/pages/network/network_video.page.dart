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
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_resource_options.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_viewer_labels.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/spatial_media.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/services/film_player/film_player_choice.dart';
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
import 'package:immich_mobile/infrastructure/mpv/android_mpv.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_file_system.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_film_streams.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_films.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_tracks.dart';
import 'package:immich_mobile/infrastructure/network/plex/plex_transcode.dart';
import 'package:immich_mobile/presentation/actions/watch_progress.action.dart';
import 'package:immich_mobile/presentation/pages/network/network_browser.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/spatial_viewer.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_failure_panel.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_track_buttons.widget.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/view_360.dart';
import 'package:immich_mobile/presentation/widgets/network/film_download.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/film_player_menu.widget.dart';
import 'package:immich_mobile/presentation/widgets/network/mpv_video_view.dart';
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
import 'package:immich_mobile/providers/network/film_player.provider.dart';
import 'package:immich_mobile/providers/network/network_connections.provider.dart';
import 'package:immich_mobile/providers/network/network_sources.provider.dart';
import 'package:immich_mobile/providers/network/network_upload.provider.dart';
import 'package:immich_mobile/providers/play_on_screen/phone_play.provider.dart';
import 'package:immich_mobile/providers/raw/raw_video.provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';
import 'package:logging/logging.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('NetworkVideoPage');

/// A video of a share, the media bridge URL of its file, and what the player plays: the file itself, or the server's
/// conversion of it (a Plex film, see film_player_choice.dart)
typedef _Video = ({NetworkEntry entry, Uri url, Uri playUrl});

/// Whether [error], a message of the native player, says that what it got is no video it knows: Media3's
/// UnrecognizedInputFormatException, "None of the available extractors (...) could read the stream", whose list of
/// obfuscated names tells the user nothing
bool isUnrecognizedVideoError(String error) =>
    error.contains('None of the available extractors') || error.contains('UnrecognizedInputFormat');

// The errors of a player that say the link or the server failed, not the player: the next player would wait for
// the same server (Media3's HttpDataSource, "Response code: 500", a refused or reset connection, a timeout)
final _linkError = RegExp(
  r'response code|httpdatasource|unable to connect|connection|timed? ?out|unknownhost|socket|network|eof',
  caseSensitive: false,
);

/// Whether [error], what a player reported for a film, hands the film to the next player (nextFilmPlayer): a decoder
/// that refused or gave no picture, a file the player did not recognize, or any failure before the film ever played,
/// but never a failure of the link or of the server, nor a link that stalled
bool filmErrorHandsOver(String error, {required bool played}) {
  final native = NativePlaybackError.parse(error);
  if (native != null) {
    return native.kind == NativePlaybackErrorKind.decoder || native.kind == NativePlaybackErrorKind.noFrame;
  }
  if (isUnrecognizedVideoError(error)) {
    return true;
  }
  return !played && !_linkError.hasMatch(error);
}

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

  /// What the native player reported when it could not play the video
  String? _playerError;

  /// The frame size, once the native player read it: the 3D layout is guessed from it
  ({int width, int height})? _videoSize;

  /// Resumes a film and saves where it is, for the video loaded (see VideoWatchRecorder)
  VideoWatchRecorder? _recorder;

  /// The tracks of a film of a Plex server: its subtitle files, the names Plex gives its tracks, and the pick written
  /// back (see PlexFilmTracks); null for any other video
  PlexFilmTracks? _plexTracks;

  /// Whether the tracks Plex has for the account were picked in the player, once per load
  bool _plexChoiceApplied = false;

  /// The file of a Plex film, its place among the versions and files of the film, and what its streams are, for the
  /// choice of its player; null for any other video and when Plex did not tell
  PlexFilmPart? _plexPart;
  ({int mediaIndex, int partIndex}) _plexPlace = (mediaIndex: 0, partIndex: 0);

  /// Who plays the film (film_player_choice.dart): the device's player for every video but a Plex film that it cannot
  /// decode, on Android
  FilmPlayerKind _player = FilmPlayerKind.device;

  /// The players that failed on this film, and the one the next load must use (a hand over or the menu), null to
  /// choose again
  final Set<FilmPlayerKind> _failedPlayers = {};
  FilmPlayerKind? _nextPlayer;

  /// The player asked in the menu of this page, over Settings, null for the setting
  FilmPlayerPreference? _askedPlayer;

  /// Bumped at each change of player: the view of the player is made again
  int _playerGeneration = 0;

  /// The player is chosen again (a hand over, a pick in the menu): no view of a player until it is known
  bool _choosing = false;

  /// The server's conversion of the film that plays, served by the media bridge under [_conversionId]
  PlexConversion? _conversion;
  String? _conversionId;
  MediaBridge? _conversionBridge;

  /// Whether this build plays with libmpv, once asked
  bool _mpvAvailable = false;

  /// Whether the failure listener of the player status is set (once per page)
  bool _failureListened = false;

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
    _removeListeners();
    _appBarFocus.removeListener(_onAppBarFocus);
    final offlineId = _offlineId;
    if (offlineId != null) {
      _offlineBridge?.unregisterGenerated(offlineId);
    }
    _endConversion();
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
      await _chooseOfflinePlayer();
      return offline;
    }
    final fileSystem = await connections.fileSystem(widget.sourceId);
    _shareType = fileSystem.source.type;
    final bridge = ref.read(mediaBridgeProvider);
    final entry = await fileSystem.stat(widget.path);
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
    final playUrl = await _choosePlayer(fileSystem, bridge, url);
    // What the file declares is read once the player has what it needs to play, not beside its first reads: on a slow
    // share the two read the index of the file at once (3.6 MB for a two hour film), and the film started later. A
    // page whose native player is not there a second later reads it at once
    _detectLater = () => _detect(service, entry, httpRangeReader(client, url));
    _detectTimer?.cancel();
    _detectTimer = Timer(detectWithoutPlayer, () {
      _detectTimer = null;
      _detectWhenIdle(now: _controller == null);
    });
    return (entry: entry, url: url, playUrl: playUrl);
  }

  /// The player of the film (see film_player_choice.dart) and what it plays: the file at [url], or the server's
  /// conversion. A Plex film on Android only; any other video, and the computers, keep the player they had.
  Future<Uri> _choosePlayer(NetworkFileSystem fileSystem, MediaBridge bridge, Uri url) async {
    // Read before the first await: the page may be gone by then
    final players = ref.read(filmPlayersProvider);
    final viewer = ref.read(appConfigProvider).viewer;
    final preference = _askedPlayer ?? viewer.filmPlayer;
    final isPlex = fileSystem is PlexFileSystem;
    final conversion = isPlex && viewer.plexConversion;
    _endConversion();
    if (CurrentPlatform.isDesktop || !Platform.isAndroid) {
      _setPlayer(FilmPlayerKind.device);
      return url;
    }
    _mpvAvailable = await players.mpvAvailable();
    final FilmPlayerKind kind;
    final forced = _nextPlayer;
    if (forced != null) {
      kind = forced;
    } else if (isPlex) {
      final part = _plexPart;
      final choice = await players.choose(
        part == null ? null : filmStreamsOfPlexPart(part),
        preference: preference,
        conversion: conversion,
      );
      _log.info(choice.logLine);
      kind = choice.kind;
    } else {
      kind = preference == FilmPlayerPreference.mpv && _mpvAvailable ? FilmPlayerKind.mpv : FilmPlayerKind.device;
    }
    if (kind == FilmPlayerKind.serverConversion && fileSystem is PlexFileSystem) {
      final converted = await _startConversion(fileSystem, bridge, players);
      if (converted != null) {
        _setPlayer(FilmPlayerKind.serverConversion);
        return converted;
      }
      // The server cannot convert it: the best of the others
      _failedPlayers.add(FilmPlayerKind.serverConversion);
      _setPlayer(
        _mpvAvailable && !_failedPlayers.contains(FilmPlayerKind.mpv) ? FilmPlayerKind.mpv : FilmPlayerKind.device,
      );
      return url;
    }
    _setPlayer(kind == FilmPlayerKind.serverConversion ? FilmPlayerKind.device : kind);
    return url;
  }

  /// The copy of a film on this device: the device's player, or libmpv when asked or after the device's player failed
  /// on it; never the server's conversion
  Future<void> _chooseOfflinePlayer() async {
    final players = ref.read(filmPlayersProvider);
    final preference = _askedPlayer ?? ref.read(appConfigProvider).viewer.filmPlayer;
    _endConversion();
    if (CurrentPlatform.isDesktop || !Platform.isAndroid) {
      _setPlayer(FilmPlayerKind.device);
      return;
    }
    _mpvAvailable = await players.mpvAvailable();
    final forced = _nextPlayer;
    final mpv = _mpvAvailable && (forced == FilmPlayerKind.mpv || preference == FilmPlayerPreference.mpv);
    _setPlayer(mpv ? FilmPlayerKind.mpv : FilmPlayerKind.device);
  }

  /// The player of the load under way is [kind]: its view is made (again when it changed)
  void _setPlayer(FilmPlayerKind kind) {
    if (!mounted || (kind == _player && !_choosing)) {
      return;
    }
    setState(() {
      if (kind != _player) {
        _player = kind;
        _playerGeneration++;
      }
      _choosing = false;
    });
  }

  /// Asks the Plex server to convert the film, and serves the conversion through the media bridge: its playlist's
  /// URL there, null when the server cannot convert it or does not answer
  Future<Uri?> _startConversion(PlexFileSystem fileSystem, MediaBridge bridge, FilmPlayers players) async {
    try {
      final audioCodecs = await players.conversionAudioCodecs();
      // From the start of the film: the converted stream keeps the film's times, and the player seeks where the film
      // resumes, as for the file
      final conversion = await fileSystem.conversionOf(
        widget.path,
        mediaIndex: _plexPlace.mediaIndex,
        partIndex: _plexPlace.partIndex,
        audioCodecs: audioCodecs,
      );
      if (conversion == null || !mounted) {
        unawaited(conversion?.stop());
        return null;
      }
      await bridge.start();
      final id = 'conversion-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      bridge.registerGenerated(id, conversion);
      _conversion = conversion;
      _conversionId = id;
      _conversionBridge = bridge;
      final url = bridge.urlFor(id, '/${PlexConversion.playlistName}');
      // libmpv opens the segments the playlist names only with access-references on, which every player has off
      // (DesktopPlayerOptions.common): this playlist names the bridge's files only (renameHlsSegments)
      desktopResourceOptions[url.toString()] = const {'access-references': 'yes'};
      _conversionUrl = url.toString();
      return url;
    } catch (error) {
      _log.warning('The Plex server did not convert the film: ${error.runtimeType}');
      return null;
    }
  }

  /// The playlist address of the conversion, for the options libmpv opens it with
  String? _conversionUrl;

  /// Stops the server's conversion and takes it off the bridge
  void _endConversion() {
    final url = _conversionUrl;
    if (url != null) {
      desktopResourceOptions.remove(url);
      _conversionUrl = null;
    }
    final id = _conversionId;
    if (id != null) {
      _conversionBridge?.unregisterGenerated(id);
    }
    unawaited(_conversion?.stop());
    _conversion = null;
    _conversionId = null;
    _conversionBridge = null;
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
    return (entry: entry, url: url, playUrl: url);
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
      final url = (await video).playUrl;
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
    _plexPart = null;
    _plexPlace = (mediaIndex: 0, partIndex: 0);
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
      _plexPart = part;
      _plexPlace = plexPartPlace(details, item.partId);
      if (part == null || part.streams.isEmpty) {
        return null;
      }
      return await PlexFilmTracks.load(PlexFileSystemTracks(fileSystem), part, bridge).timeout(plexTracksWait);
    } catch (error) {
      _log.info('The tracks of the Plex film are not known: ${error.runtimeType}');
      return null;
    }
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
    final controller = _controller;
    if (controller is MediaKitVideoPlayerController) {
      return _applyPlexChoiceToMpv(controller, tracks);
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

  /// The tracks Plex has for the account, picked in libmpv once it lists the tracks of the file: the audio track by its
  /// place among the audio tracks of the file, the subtitles by the id of their side file or by their place among the
  /// subtitles of the file, as the menus of the controls name them (DesktopAudioTrackButton,
  /// DesktopSubtitleTrackButton)
  Future<void> _applyPlexChoiceToMpv(MediaKitVideoPlayerController controller, PlexFilmTracks tracks) async {
    final audio = controller.audioTracks.value;
    if (audio.isEmpty || _plexChoiceApplied) {
      return;
    }
    _plexChoiceApplied = true;
    final selectedAudio = tracks.selectedAudio;
    if (selectedAudio != null) {
      for (final (index, track) in audio.indexed) {
        if (tracks.streamOf(desktopAudioTrackRef(track, index))?.id == selectedAudio.id) {
          if (track.id != controller.audioTrack.value) {
            await controller.selectAudioTrack(track.id);
          }
          break;
        }
      }
    }
    final subtitle = tracks.selectedSubtitle;
    if (subtitle == null || controller.subtitleTrack.value != null) {
      return;
    }
    if (subtitle.isSidecar) {
      final external = controller.externalSubtitles.value.where((file) => file.id == subtitle.sidecarId).firstOrNull;
      if (external != null) {
        await controller.selectExternalSubtitle(external);
      }
      return;
    }
    final embedded = controller.subtitleTracks.value.where((track) => !track.isExternal).toList();
    final ordinal = subtitle.ordinal;
    if (ordinal != null && ordinal >= 0 && ordinal < embedded.length) {
      await controller.selectSubtitleTrack(embedded[ordinal].id);
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
    if (controller is MediaKitVideoPlayerController) {
      // libmpv lists its tracks itself (the menus of the controls read them there)
      controller.audioTracks.addListener(_onTracksChanged);
      controller.subtitleTracks.addListener(_onTracksChanged);
    }
    _controller = controller;
    if (!_failureListened) {
      _failureListened = true;
      ref.listenManual(videoPlayerProvider(_playerKey).select((v) => v.status), _onFailure);
    }
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
    if (controller is MediaKitVideoPlayerController) {
      controller.audioTracks.removeListener(_onTracksChanged);
      controller.subtitleTracks.removeListener(_onTracksChanged);
    }
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
      if (_handOver(error)) {
        scheduleMicrotask(() => controller.onError.value = null);
        return;
      }
      // The extractor list of Media3 tells the user nothing: a sentence, and what the player got in the logs. An error
      // the native player put in the words of the app (NativePlaybackError) is said in ours, never as its token
      final unrecognized = isUnrecognizedVideoError(error);
      final shown = unrecognized
          ? context.t.network_video_unrecognized
          : NativePlaybackError.parse(error) != null
          ? _nativeErrorText(error)
          : error;
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

  /// Hands the film to the next player when [error] says the player that failed cannot play it (filmErrorHandsOver):
  /// the device's player to libmpv, libmpv to the server's conversion. Only for a film the app chooses the player of
  /// (Automatic), on Android; false when the error stays
  bool _handOver(String error) {
    final preference = _askedPlayer ?? ref.read(appConfigProvider).viewer.filmPlayer;
    if (preference != FilmPlayerPreference.automatic || CurrentPlatform.isDesktop || !Platform.isAndroid) {
      return false;
    }
    final isPlex = _shareType == NetworkSourceType.plex && _offlineId == null;
    final next = nextFilmPlayer(
      _player,
      tried: _failedPlayers,
      mpvAvailable: _mpvAvailable,
      conversion: isPlex && ref.read(appConfigProvider).viewer.plexConversion,
    );
    if (next == null || !filmErrorHandsOver(error, played: _isVideoReady)) {
      return false;
    }
    _log.info('The ${_player.name} player failed on the film, ${next.name} takes over');
    _failedPlayers.add(_player);
    final t = context.t;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 4),
        content: Text(next == FilmPlayerKind.mpv ? t.film_player_now_mpv : t.film_player_now_conversion),
      ),
    );
    _changePlayer(next);
    return true;
  }

  /// Plays the film again with [kind], or with the player chosen again when null (a pick in the menu)
  void _changePlayer(FilmPlayerKind? kind) {
    _nextPlayer = kind;
    _removeListeners();
    _controller = null;
    _detectTimer?.cancel();
    _detectTimer = null;
    setState(() {
      _isVideoReady = false;
      _playerError = null;
      _playerGeneration++;
      _choosing = true;
      _video = _load();
      videoSource = _sourceOf(_video);
    });
  }

  /// The player picked in the menu of the page, for this film
  void _askPlayer(FilmPlayerPreference preference) {
    if (preference == (_askedPlayer ?? ref.read(appConfigProvider).viewer.filmPlayer) && _askedPlayer != null) {
      return;
    }
    _askedPlayer = preference;
    _failedPlayers.clear();
    _changePlayer(null);
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
      final around =
          widget.folder?.around(video.entry, video.url) ?? (items: [(entry: video.entry, url: video.url)], index: 0);
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
    // The player of a film, on a build with libmpv (the Meta Quest build of release 46): Automatic, Device or mpv
    final canChoosePlayer = !CurrentPlatform.isDesktop && (ref.watch(androidMpvAvailableProvider).valueOrNull ?? false);
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
                  // Converted by the Plex server (film_player_choice.dart)
                  if (_conversionId != null && _player == FilmPlayerKind.serverConversion)
                    Tooltip(
                      key: const Key('network_video_converted'),
                      message: context.t.film_player_converted,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.dns_outlined),
                      ),
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
                          canChoosePlayer ||
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
                        // The player of the film: Automatic, Device or mpv (film_player_menu.widget.dart)
                        if (canChoosePlayer)
                          filmPlayerMenuItem(
                            this.context,
                            asked: _askedPlayer ?? ref.read(appConfigProvider).viewer.filmPlayer,
                            playing: _player,
                            onPicked: _askPlayer,
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

  /// Whether libmpv plays the film: it was chosen, or the server converts it on a build that has libmpv
  bool get _playsWithMpv =>
      _player == FilmPlayerKind.mpv || (_player == FilmPlayerKind.serverConversion && _mpvAvailable);

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
          if (isRouteActive && !_choosing)
            Positioned.fill(
              child: IgnorePointer(
                child: Visibility.maintain(
                  visible: _isVideoReady,
                  // A platform view must never take the focus: the keys of a remote would go to the native view
                  child: ExcludeFocus(
                    // A new view at each change of player (film_player_choice.dart)
                    child: KeyedSubtree(
                      key: ValueKey(('player', _playerGeneration)),
                      // The computers play through media_kit (lib/desktop/video), with a controller of the same type;
                      // libmpv plays the films the device cannot decode on the Meta Quest, and there the server's
                      // conversion too (mpv reads HLS, Media3 of the app has no HLS module)
                      child: CurrentPlatform.isDesktop
                          ? DesktopVideoView(onViewReady: _initController)
                          : _playsWithMpv
                          ? MpvVideoView(onViewReady: _initController)
                          : NativeVideoPlayerView(onViewReady: _initController),
                    ),
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
                  // libmpv lists its tracks itself: the menus of the computers, on its controller
                  mpvController: _controller is MediaKitVideoPlayerController && !CurrentPlatform.isDesktop
                      ? _controller! as MediaKitVideoPlayerController
                      : null,
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
