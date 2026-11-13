// The controller the viewer and the network page already drive (VideoPlayerNotifier and the two pages hold a
// NativeVideoPlayerController), made of a pooled media_kit player on the computers (design 2.2, "The flat player").
// Nothing of the notifier or of the pages changes: they load, play, pause, stop, seek, loop and set the volume as on
// the phones, and get the same notifications (ready, status, position, ended, error).
//
// What differs from the phones' native players, and is mapped here:
// - mpv's stop unloads the file: a play after a stop opens it again from the start, as the native players restart;
// - the pool may take the player away for another page (player_pool.dart): the position and whether the video
//   played are noted, and the next call that needs the player reopens the video there;
// - mpv says when a frame of the new file is on the texture (playback-restart): "ready" waits for it, so that a
//   reused player never shows the last frame of the previous video;
// - mpv takes a file it can no longer read (a share or a server gone, a drive pulled out) for its end: an end well
//   before the duration is reported as the error the phones give, and a load of the same video again (the Retry of
//   the network page) starts where it stopped;
// - a player whose graphics device was lost (a driver update, a GPU reset) shows no picture any more: the pool
//   replaces it, and the video opens again where it was in the new one;
// - buffering: the position stands still while mpv waits for its cache, which is how the existing controls tell a
//   stall (VideoPlayerNotifier, NetworkVideoBufferingIndicator); [buffering] gives mpv's own state as well;
// - the link: what the media bridge reads of the file (every streamed video goes through it here) and mpv's wait are
//   told as the Android player tells its own (onLinkChanged, NativeVideoLink), twice a second, so that a slow share
//   or server is never taken for a dead one while bytes arrive, and mpv's wait after a stall follows the link (the
//   rule of video_link_rule.dart); for an AV2 video the link is its decoder (av2_playback.dart), the pictures it
//   decodes a second against those the video needs, by the same rule, and a decoder that stopped fails the video
//   with its reason;
// - the companion of a resource (the AV2 decoder serving its y4m) is let go once the controller loads another video
//   or is disposed: [release];
// - audio tracks, which the phones' flat players do not offer: listed here for the audio track button of the
//   controls (desktop_audio_track_button.dart);
// - an audio track this libmpv does not decode (TrueHD in the app's builds, release 47): another track of the file
//   plays, in the same language first, when the tracks are listed and again when mpv says a decoder failed to open or
//   no track plays a while after the first frame; [audioSwitch] tells the page, which says so (film_audio_choice.dart).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/domain/services/film_player/film_audio_choice.dart';
import 'package:immich_mobile/domain/services/film_player/film_decoders.dart';
import 'package:immich_mobile/domain/services/video_link_rule.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('DesktopVideoController');

/// What a player of the computers is given for a [VideoSource]: a path of this computer or a media bridge URL (see
/// desktop_video_sources.dart). Throws when the source cannot be played here.
typedef DesktopVideoSourceResolver = Future<String> Function(VideoSource source);

/// What the media bridge measures of the reads of [resource] (a bridge URL) and the size of its file, null for a file
/// of this computer or one the bridge does not read (see LocalMediaBridge.trafficOf)
typedef DesktopVideoLinkOf = ({VideoLinkMeter meter, int? size})? Function(String resource);

/// What the decoder of [resource] says when a program of the app decodes it (the AV2 companion, av2_playback.dart):
/// the frames it decodes a second (null until measured), those the video needs, and why it stopped (null while it
/// runs); null for a resource mpv decodes itself
typedef DesktopVideoDecodingOf = ({double? fps, double needed, String? failure})? Function(String resource);

/// Lets go of what serves [resource] (the AV2 companion), once no player of the controller opens it again
typedef DesktopVideoRelease = Future<void> Function(String resource);

/// The video mpv waits for after a stall when a program of the app decodes it (the AV2 companion), [ratio] being the
/// frames it decodes a second against those the video needs: a decoder that keeps up stalls only while it starts
/// again after a seek or a loop (from the access point before the picture, nothing in the cache yet), so a second is
/// enough, mpv's own wait, where a link's rule would wait 2 to 4 s (1.6 to 3.3 s at 1.2x; plan of the AV2 videos,
/// AD2's m2); one that does not keep up waits by the rule of a link, fewer and longer pauses
int decoderResumeWaitMs(double? ratio) => ratio == null || ratio >= 1 ? 1000 : linkTargetMs(ratio, rebuffering: true);

/// What a player did about an audio track it does not decode (MediaKitVideoPlayerController.audioSwitch)
@immutable
class FilmAudioSwitch {
  const FilmAudioSwitch({required this.fromCodec, this.to, this.toIndex, this.atRunTime = false});

  /// The codec of the track it would have played ("truehd")
  final String fromCodec;

  /// The track that plays instead, and its place among the audio tracks of the file; null when it decodes none
  final DesktopAudioTrack? to;
  final int? toIndex;

  /// Found when mpv failed to open the decoder, not from the list of what it decodes
  final bool atRunTime;

  @override
  String toString() => 'FilmAudioSwitch($fromCodec to ${to?.id ?? 'none'}${atRunTime ? ', at run time' : ''})';
}

/// The player that played or loaded last: the audio track button of the controls follows it. One video plays at a
/// time on the computers, the viewer loading only the page on screen.
final activeDesktopVideo = ValueNotifier<MediaKitVideoPlayerController?>(null);

class MediaKitVideoPlayerController with ChangeNotifier implements NativeVideoPlayerController {
  /// [onScreen]: whether the page of this controller is on screen, where a job on the graphics card leaves its player
  /// alone, paused or not (PlayerPool.releaseForGraphicsJob); the 360° page tells it
  MediaKitVideoPlayerController({
    required PlayerPool pool,
    required this._resolve,
    String label = 'video',
    this.positionInterval = const Duration(milliseconds: 200),
    this._prepare,
    this._unprepare,
    this._linkOf,
    bool Function()? onScreen,
    this._decodingOf,
    this._release,
  }) {
    _lease = pool.lease(PlayerKind.playback, label: label, onSuspend: _onSuspend, onScreen: onScreen);
  }

  /// How often the link is told while a streamed video is open
  static const linkInterval = Duration(milliseconds: 500);

  final DesktopVideoLinkOf? _linkOf;
  final DesktopVideoDecodingOf? _decodingOf;
  final DesktopVideoRelease? _release;
  Timer? _linkTimer;
  int? _resumeWaitMs;

  /// Whether the meter of the video opened last still has to start its clock of progress from the open, see [_tellLink]
  bool _linkOpened = false;

  /// How often the position is passed on while the video plays: the slider and the stall detection of the controls
  /// (700 ms) need a few a second, not mpv's one per frame
  final Duration positionInterval;

  /// How long "ready" waits for the frame size once a frame is shown, for a file whose video track mpv sizes late
  static const readyWithoutSize = Duration(seconds: 2);

  /// How far before its duration a video may end and still count as ended, at least: the last frame of a file is a
  /// frame or so before the duration its container declares, and a stop further back is a file that could not be read
  /// on. One hundredth of the duration when that is more, for a duration FFmpeg estimates (a stream without index).
  static const endTolerance = Duration(seconds: 2);

  final DesktopVideoSourceResolver _resolve;
  late final PlayerLease _lease;

  /// Run on the player before each open of a file, once the player is this controller's: the 360° player turns its
  /// renderer on there, so that the first frame of the file is already drawn by it (spherical_player_route.dart).
  /// [_unprepare] undoes it before the player leaves this controller (the pool takes it, the controller is
  /// disposed), so that the next page gets a player as the pool gives it.
  final Future<void> Function(PlaybackEngine engine)? _prepare;
  final Future<void> Function(PlaybackEngine engine)? _unprepare;

  @override
  final onPlaybackReady = ChangeNotifier();

  @override
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(PlaybackStatus.stopped);

  @override
  final onPlaybackPositionChanged = ValueNotifier<int>(0);

  @override
  final onPlaybackSpeedChanged = ValueNotifier<double>(1);

  @override
  final onVolumeChanged = ValueNotifier<double>(0);

  @override
  final onPlaybackEnded = ChangeNotifier();

  @override
  final onError = ValueNotifier<String?>(null);

  /// The track API of the Android player, never used here: the computers list their audio tracks with [audioTracks]
  /// (DesktopAudioTrackButton) and their subtitles with [subtitleTracks] (DesktopSubtitleTrackButton)
  @override
  final onTracksChanged = ChangeNotifier();

  @override
  final onLinkChanged = ValueNotifier<NativeVideoLink?>(null);

  final _videoController = ValueNotifier<VideoController?>(null);
  final _buffering = ValueNotifier(false);
  final _audioTracks = ValueNotifier<List<DesktopAudioTrack>>(const []);
  final _audioTrack = ValueNotifier<String?>(null);
  final _subtitleTracks = ValueNotifier<List<DesktopSubtitleTrack>>(const []);
  final _subtitleTrack = ValueNotifier<String?>(null);
  final _externalSubtitles = ValueNotifier<List<VideoSubtitle>>(const []);
  final _decoding = ValueNotifier<({String? hwdec, VideoFrameSize? size})>((hwdec: null, size: null));
  final _audioSwitch = ValueNotifier<FilmAudioSwitch?>(null);

  /// The audio codecs this player does not decode (film_decoders.dart): TrueHD and MLP in the Quest's libmpv, nothing
  /// on the computers. The tests set their own.
  static Set<String> missingAudioCodecs = libmpvMissingAudioOn(
    android: defaultTargetPlatform == TargetPlatform.android,
  );

  /// How long after the first frame a video whose audio track mpv dropped (a decoder that did not open) is taken for
  /// one without sound
  static const silentAudioAfter = Duration(seconds: 8);

  /// The codecs whose decoder mpv failed to open during this video
  final _failedAudioCodecs = <String>{};

  /// The audio track asked last (mpv's own choice at the open, a menu, a pick of this controller): mpv plays none once
  /// its decoder failed to open, and this tells which one it was
  String? _wantedAudioId;

  /// The tracks whose failure was handled since the last pick in the menu: a switch is made once per failure
  final _handledAudioFailures = <String>{};
  bool _audioChecked = false;
  Timer? _silenceTimer;
  StreamSubscription<String>? _audioFailures;

  /// The texture the view draws, null while the controller holds no player
  ValueListenable<VideoController?> get videoController => _videoController;

  /// mpv waits for its cache
  ValueListenable<bool> get buffering => _buffering;

  /// The audio tracks of the file, none until it is open
  ValueListenable<List<DesktopAudioTrack>> get audioTracks => _audioTracks;

  /// The id of the audio track that plays
  ValueListenable<String?> get audioTrack => _audioTrack;

  /// The subtitle tracks of the open file, with the side files of [externalSubtitles] added to it so far
  ValueListenable<List<DesktopSubtitleTrack>> get subtitleTracks => _subtitleTracks;

  /// The id of the subtitle track shown, null for none
  ValueListenable<String?> get subtitleTrack => _subtitleTrack;

  /// The side files of subtitles of the video (VideoSource.subtitles), which the player reads only once picked
  /// ([selectExternalSubtitle])
  ValueListenable<List<VideoSubtitle>> get externalSubtitles => _externalSubtitles;

  /// How mpv decodes the video of the player held now (PlaybackEngine.hwdec) and the size of its frames, for the Video
  /// decoding line of the details (desktop_video_decoding_tile.dart); nothing while no player is held
  ValueListenable<({String? hwdec, VideoFrameSize? size})> get decoding => _decoding;

  /// The last time this player played another audio track than the one it would have played, because it does not
  /// decode that one, or found it decodes none of the file's tracks; null for none since the load
  ValueListenable<FilmAudioSwitch?> get audioSwitch => _audioSwitch;

  /// Whether this player decodes the audio codec [codec] (FFmpeg's name, as mpv lists the track): not one of
  /// [missingAudioCodecs], nor one whose decoder failed to open during this video
  bool decodesAudio(String codec) {
    final canonical = canonicalAudioCodec(codec.trim().toLowerCase());
    return !missingAudioCodecs.contains(canonical) && !_failedAudioCodecs.contains(canonical);
  }

  /// The player held now, for the measurement harness and the tests
  @visibleForTesting
  PlaybackEngine? get engine => _engine;

  /// The language last picked in the audio track menu, chosen first for the next videos of the session
  static String? preferredAudioLanguage;

  VideoSource? _videoSource;
  VideoInfo? _videoInfo;
  double _speed = 1;
  double _volume = 0;
  bool _loop = false;

  /// What the player opens for [_videoSource]; null before a load succeeded
  String? _resource;

  /// The file was closed by [stop] or a failure: a play or a seek opens it again
  bool _unloaded = false;

  /// Where the video was when the pool took the player away, see [_onSuspend]
  ({Duration position, bool playing})? _resumeAt;

  /// Where a video stopped when its file could no longer be read, see [_onCompleted]: a load of the same source
  /// starts there
  ({String path, Duration position})? _stoppedEarly;

  /// The load after [_stoppedEarly] reports "paused" once ready, so that play goes on from there rather than "ended",
  /// which the controls would replay from the start
  bool _pausedWhenReady = false;

  PlaybackEngine? _engine;
  StreamSubscription<PlayerEvent>? _events;

  /// From the load to the first frame, and from a seek to the frame after it: the times the log gives
  final _loadWatch = Stopwatch();
  Stopwatch? _seekWatch;

  /// Changed by every load and stop: what an older one started is not taken for the current video
  int _generation = 0;
  bool _ready = false;
  bool _restarted = false;
  bool _audioChosen = false;

  /// What the user picked in the subtitle menu for this video: a track of the file by its id, a side file, or none
  /// (both null); null before any pick, mpv's own choice then. Picked again once the file opens again (the pool took
  /// the player, a replay), which drops the side files added.
  ({String? id, VideoSubtitle? external})? _subtitleChoice;

  /// The side files added to the file open now, by their address: each is added once per open
  final _addedSubtitles = <String>{};
  Timer? _readyTimer;
  Timer? _positionTimer;
  bool _positionPending = false;
  bool _disposed = false;

  PlaybackStatus get _status => onPlaybackStatusChanged.value;

  int get _position => onPlaybackPositionChanged.value;

  @override
  VideoSource? get videoSource => _videoSource;

  @override
  VideoInfo? get videoInfo => _videoInfo;

  @override
  PlaybackInfo? get playbackInfo {
    final duration = _videoInfo?.duration ?? 0;
    return PlaybackInfo(
      status: _status,
      position: _position,
      positionFraction: duration > 0 ? _position / duration : 0,
      speed: _speed,
      volume: _volume,
      error: onError.value,
    );
  }

  /// Loads [videoSource] paused at its start, or at [startAt]: the 360° player opens another file of the same video
  /// where the previous one was (the next step of a raw file's fallback chain, raw_two_streams.dart)
  @override
  Future<void> loadVideoSource(VideoSource videoSource, {Duration? startAt}) async {
    final stoppedEarly = _stoppedEarly;
    _stoppedEarly = null;
    final start =
        startAt ??
        (stoppedEarly != null && stoppedEarly.path == videoSource.path ? stoppedEarly.position : Duration.zero);
    await stop();
    _loadWatch
      ..reset()
      ..start();
    _seekWatch = null;
    final generation = ++_generation;
    _letGo(_resource);
    _videoSource = null;
    _videoInfo = null;
    _resource = null;
    _resumeAt = null;
    _audioChosen = false;
    _audioChecked = false;
    _failedAudioCodecs.clear();
    _handledAudioFailures.clear();
    _wantedAudioId = null;
    _audioSwitch.value = null;
    _silenceTimer?.cancel();
    _subtitleChoice = null;
    _externalSubtitles.value = const [];
    _pausedWhenReady = start > Duration.zero;
    onLinkChanged.value = null;
    _resumeWaitMs = null;
    // A load that fails the same way twice is still told to the page
    onError.value = null;
    final String resource;
    try {
      resource = await _resolve(videoSource);
    } catch (error) {
      _fail(generation, 'This video cannot be played on the computer: ${redactPlayerText('$error')}');
      return;
    }
    if (_disposed || generation != _generation) {
      // Loaded again or disposed meanwhile: nobody opens it
      _letGo(resource);
      return;
    }
    _resource = resource;
    _videoSource = videoSource;
    // Bridge URLs already, which mpv reads as they are
    _externalSubtitles.value = List.unmodifiable(videoSource.subtitles);
    final engine = await _engineForUse();
    if (engine == null || generation != _generation) {
      return;
    }
    await _open(engine, generation, start);
  }

  @override
  Future<void> play() async {
    final engine = await _engineForUse();
    if (engine == null) {
      return;
    }
    if (_unloaded && !await _open(engine, _generation, Duration.zero)) {
      return;
    }
    if (!await _onEngine(engine, engine.play)) {
      return;
    }
    onPlaybackStatusChanged.value = PlaybackStatus.playing;
    await setPlaybackSpeed(_speed);
    activeDesktopVideo.value = this;
  }

  @override
  Future<void> pause() async {
    _resumeAt = _resumeAt == null ? null : (position: _resumeAt!.position, playing: false);
    await _engine?.pause();
    if (_status == PlaybackStatus.playing) {
      onPlaybackStatusChanged.value = PlaybackStatus.paused;
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    _ready = false;
    _restarted = false;
    _silenceTimer?.cancel();
    _linkTimer?.cancel();
    _linkTimer = null;
    _readyTimer?.cancel();
    _positionTimer?.cancel();
    _positionTimer = null;
    _positionPending = false;
    final engine = _engine;
    if (engine != null && !_unloaded) {
      // After an open still running, never before it: the file would stay open
      await _onEngine(engine, engine.stop);
    }
    _unloaded = true;
    _buffering.value = false;
    _stallWatch = null;
    onPlaybackPositionChanged.value = 0;
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
  }

  @override
  Future<bool> isPlaying() async => _status == PlaybackStatus.playing && (_engine?.playing.value ?? false);

  @override
  Future<void> seekTo(int milliseconds) async {
    final duration = _videoInfo?.duration ?? 0;
    final position = math.max(0, math.min(milliseconds, duration));
    final suspended = _lease.isSuspended;
    final engine = await _engineForUse(resumeAt: suspended ? Duration(milliseconds: position) : null);
    if (engine == null) {
      return;
    }
    if (_unloaded) {
      await _open(engine, _generation, Duration(milliseconds: position));
    } else if (!suspended) {
      _seekWatch = Stopwatch()..start();
      await engine.seek(Duration(milliseconds: position));
    }
    if (_status != PlaybackStatus.playing) {
      onPlaybackPositionChanged.value = position;
    }
  }

  @override
  Future<void> seekForward(int milliseconds) {
    final duration = _videoInfo?.duration ?? 0;
    return seekTo(math.min(_position + milliseconds, duration));
  }

  @override
  Future<void> seekBackward(int milliseconds) => seekTo(math.max(_position - milliseconds, 0));

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (_status == PlaybackStatus.playing) {
      await _engine?.setRate(speed);
    }
    _speed = speed;
    onPlaybackSpeedChanged.value = speed;
  }

  @override
  Future<void> setVolume(double volume) async {
    await _engine?.setVolume(volume);
    _volume = volume;
    onVolumeChanged.value = volume;
  }

  @override
  Future<void> setLoop(bool loop) async {
    _loop = loop;
    await _engine?.setLoop(loop);
  }

  @override
  Future<List<NativeVideoTrack>> getTracks({String? locale}) async => const [];

  @override
  Future<bool> selectTrack(NativeVideoTrack track) async => false;

  @override
  Future<void> disableTracks(NativeVideoTrackType type) async {}

  /// Plays the audio track [id] of [audioTracks], and prefers its language for the next videos. A track this player
  /// does not decode gives its place to another one, which [audioSwitch] tells.
  Future<void> selectAudioTrack(String id) async {
    final track = _audioTracks.value.where((track) => track.id == id).firstOrNull;
    if (track == null) {
      return;
    }
    preferredAudioLanguage = track.language ?? preferredAudioLanguage;
    // A new pick: a failure of its decoder is handled again, and told again
    _handledAudioFailures.clear();
    final codec = track.codec;
    if (codec != null && !decodesAudio(codec)) {
      _audioSwitch.value = null;
      _checkAudio(id, atRunTime: false);
      return;
    }
    _wantedAudioId = id;
    await _engine?.setAudioTrack(id);
  }

  /// Plays another audio track when this player does not decode [wantedId] (null for the one mpv plays, else the
  /// file's default), in the same language first (pickFilmAudio), and tells it in [audioSwitch], once per pick
  void _checkAudio(String? wantedId, {required bool atRunTime}) {
    final engine = _engine;
    final tracks = _audioTracks.value;
    if (engine == null || tracks.isEmpty) {
      return;
    }
    final wanted = wantedId == null ? -1 : tracks.indexWhere((track) => track.id == wantedId);
    final pick = pickFilmAudio(
      [
        for (final track in tracks)
          FilmAudioTrack(codec: track.codec, language: track.language, isDefault: track.isDefault ?? false),
      ],
      wanted: wanted >= 0 ? wanted : null,
      decodes: decodesAudio,
    );
    final from = pick.from;
    if (pick.outcome == FilmAudioOutcome.kept || from == null) {
      return;
    }
    final fromCodec = tracks[from].codec ?? '';
    final index = pick.index;
    final to = index == null ? null : tracks[index];
    final told = _audioSwitch.value;
    if (to != null) {
      _wantedAudioId = to.id;
      if (engine.audioTrack.value != to.id) {
        unawaited(engine.setAudioTrack(to.id));
      }
    }
    if (told != null && told.to?.id == to?.id && told.fromCodec == fromCodec) {
      return;
    }
    _log.info(
      to == null
          ? 'No audio track of the video is decoded here ($fromCodec first)'
          : 'Audio track ${to.id} (${to.codec}) plays: $fromCodec is not decoded here'
                '${atRunTime ? ' (its decoder did not open)' : ''}',
    );
    _audioSwitch.value = FilmAudioSwitch(fromCodec: fromCodec, to: to, toIndex: index, atRunTime: atRunTime);
  }

  /// mpv could not open the decoder of [codec]: noted for this video, and when it was the track asked, another one
  /// plays (once per pick)
  void _onAudioDecoderFailure(String codec) {
    final canonical = canonicalAudioCodec(codec.trim().toLowerCase());
    _failedAudioCodecs.add(canonical);
    final wanted = _wantedAudioId ?? _engine?.audioTrack.value;
    final track = _audioTracks.value.where((track) => track.id == wanted).firstOrNull;
    final trackCodec = track?.codec;
    if (trackCodec != null && canonicalAudioCodec(trackCodec.trim().toLowerCase()) != canonical) {
      // Another track than the one asked
      return;
    }
    if (!_handledAudioFailures.add(wanted ?? '')) {
      return;
    }
    _log.info('mpv could not open the decoder of the audio ($canonical)');
    _checkAudio(wanted, atRunTime: true);
  }

  /// [silentAudioAfter] after the first frame: a file with audio tracks of which mpv plays none, the one asked having
  /// been dropped (its decoder failed without a line of the log reaching here), is handled as that failure
  void _checkSilence(int generation) {
    final engine = _engine;
    if (_disposed || _unloaded || generation != _generation || engine == null) {
      return;
    }
    if (_audioTracks.value.isEmpty || engine.audioTrack.value != null) {
      return;
    }
    final wanted = _audioTracks.value.where((track) => track.id == _wantedAudioId).firstOrNull;
    final codec = wanted?.codec;
    if (codec != null) {
      _onAudioDecoderFailure(codec);
    }
  }

  /// Shows the subtitle track [id] of [subtitleTracks], none for null
  Future<void> selectSubtitleTrack(String? id) async {
    final track = id == null ? null : _subtitleTracks.value.where((track) => track.id == id).firstOrNull;
    if (id != null && track == null) {
      return;
    }
    final subtitle = track?.external == null
        ? null
        : _externalSubtitles.value.where((subtitle) => subtitle.uri == track!.external).firstOrNull;
    _subtitleChoice = subtitle != null ? (id: null, external: subtitle) : (id: id, external: null);
    await _engine?.setSubtitleTrack(id);
  }

  /// Shows [subtitle], one of [externalSubtitles]: the player reads it the first time, then shows its track
  Future<void> selectExternalSubtitle(VideoSubtitle subtitle) async {
    _subtitleChoice = (id: null, external: subtitle);
    final engine = _engine;
    if (engine != null && !_unloaded) {
      await _showExternal(engine, subtitle);
    }
  }

  /// The track [subtitle] became once added to the open file, null before
  DesktopSubtitleTrack? subtitleTrackOf(VideoSubtitle subtitle) =>
      _subtitleTracks.value.where((track) => track.external == subtitle.uri).firstOrNull;

  Future<void> _showExternal(PlaybackEngine engine, VideoSubtitle subtitle) async {
    final added = subtitleTrackOf(subtitle);
    if (added != null) {
      await engine.setSubtitleTrack(added.id);
      return;
    }
    if (!_addedSubtitles.add(subtitle.uri)) {
      // Being added: its track shows once mpv read it
      return;
    }
    try {
      await engine.addExternalSubtitle(subtitle.uri, title: subtitle.label, language: subtitle.language);
    } catch (error) {
      _addedSubtitles.remove(subtitle.uri);
      _log.warning('The side file of subtitles could not be added: ${redactPlayerText('$error')}');
    }
  }

  /// The pick of the subtitle menu again, in a file that opened again
  void _restoreSubtitle(PlaybackEngine engine) {
    final choice = _subtitleChoice;
    if (choice == null) {
      return;
    }
    final external = choice.external;
    unawaited(
      _onEngine(engine, () => external != null ? _showExternal(engine, external) : engine.setSubtitleTrack(choice.id)),
    );
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _generation++;
    _readyTimer?.cancel();
    _silenceTimer?.cancel();
    _positionTimer?.cancel();
    _linkTimer?.cancel();
    final engine = _engine;
    final resource = _resource;
    _unbind();
    if (identical(activeDesktopVideo.value, this)) {
      activeDesktopVideo.value = null;
    }
    // The player goes back to the pool, stopped, and as the pool gave it; the notifiers stay, as the phones'
    // controller leaves them, since the pages remove their listeners after the view that disposes this
    unawaited(() async {
      if (engine != null) {
        // After an open still running: its prepare may turn the 360° renderer on or set mpv's options for a raw file
        // once this was called, and undone before it, they would stay on the player the pool parks for the next page
        await _lease.guard(() => _undoPrepare(engine));
      }
      await _lease.release();
      // After the player let go of it: the companion stops with nothing reading
      _letGo(resource);
    }());
    super.dispose();
  }

  /// Lets go of what serves [resource], when something does (see [_release])
  void _letGo(String? resource) {
    final release = _release;
    if (resource == null || release == null) {
      return;
    }
    unawaited(
      release(resource).catchError((Object error, StackTrace stackTrace) {
        _log.warning('What served a video could not be let go', error, stackTrace);
      }),
    );
  }

  /// The player for a call, taken from the pool when needed. After a suspension the video opens again where it was,
  /// or at [resumeAt] (a seek), and plays on if it played. Null without a video or once disposed.
  Future<PlaybackEngine?> _engineForUse({Duration? resumeAt}) async {
    if (_disposed || _resource == null) {
      return null;
    }
    final wasSuspended = _lease.isSuspended;
    final PlaybackEngine engine;
    try {
      engine = await _lease.acquire();
    } catch (error) {
      _log.warning('No player for the video: $error');
      return null;
    }
    if (_disposed) {
      return null;
    }
    if (!identical(_lease.engine, engine)) {
      // Another page took it before this one used it (both asked at once): taken back at the next call
      return null;
    }
    if (!identical(engine, _engine)) {
      _bind(engine);
    }
    final resume = _resumeAt;
    _resumeAt = null;
    if (wasSuspended && resume != null && !_unloaded) {
      if (await _open(engine, _generation, resumeAt ?? resume.position) &&
          resume.playing &&
          await _onEngine(engine, engine.play)) {
        onPlaybackStatusChanged.value = PlaybackStatus.playing;
      }
    }
    return engine;
  }

  /// Opens the video of this controller at [start] in [engine], with the volume and the loop of the page. False when
  /// nothing was opened: the controller was disposed, stopped or loaded again meanwhile, or the pool took the player.
  Future<bool> _open(PlaybackEngine engine, int generation, Duration start) {
    final resource = _resource;
    if (resource == null) {
      return Future.value(false);
    }
    _unloaded = false;
    _ready = false;
    _restarted = false;
    // Opened again from its start or elsewhere (a replay, a seek): the place where the file stopped is no longer used
    _stoppedEarly = null;
    // Checked before each call, the page may have gone or the pool taken the player while the previous one ran: an
    // open that came after the pool's stop would leave the file held by a parked player
    bool current() => !_disposed && generation == _generation && identical(_lease.engine, engine);
    return _lease.guard(() async {
      try {
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await engine.setVolume(_volume);
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await engine.setLoop(_loop);
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        await _prepare?.call(engine);
        if (!current()) {
          return _openDropped(engine, generation, start);
        }
        // The side files added to the file before are gone with it
        _addedSubtitles.clear();
        await engine.open(resource, start: start, streamed: resource.startsWith('http'));
        _startLink();
        return true;
      } catch (error) {
        _fail(generation, 'The video could not be opened: ${redactPlayerText('$error')}');
        return false;
      }
    });
  }

  /// An open left undone because the pool took the player: the video opens at [start] in the next one
  bool _openDropped(PlaybackEngine engine, int generation, Duration start) {
    if (!_disposed && generation == _generation && !identical(_lease.engine, engine)) {
      _resumeAt ??= (position: start, playing: false);
    }
    return false;
  }

  /// Runs [action] on [engine] after what the lease runs before it, when the lease still holds [engine]; false when it
  /// does not (the pool took it: the action would reach another page's video)
  Future<bool> _onEngine(PlaybackEngine engine, Future<void> Function() action) => _lease.guard(() async {
    if (!identical(_lease.engine, engine)) {
      return false;
    }
    await action();
    return true;
  });

  /// Called by the pool before it gives the player to another page: where the video was, to come back to it
  Future<void> _onSuspend() async {
    final engine = _engine;
    if (engine != null && !_unloaded) {
      // An open the pool cut short already noted where it was to start
      _resumeAt ??= (position: engine.position.value, playing: _status == PlaybackStatus.playing);
    }
    if (engine != null) {
      await _undoPrepare(engine);
    }
    _unbind();
    if (_status == PlaybackStatus.playing) {
      onPlaybackStatusChanged.value = PlaybackStatus.paused;
    }
  }

  Future<void> _undoPrepare(PlaybackEngine engine) async {
    try {
      await _unprepare?.call(engine);
    } catch (error, stackTrace) {
      _log.warning('Could not give the player back as the pool gave it', error, stackTrace);
    }
  }

  /// The texture of the player can no longer show a picture: the pool replaces the player, and the video opens again
  /// where it was, playing if it played
  void _onTextureLost() {
    final engine = _engine;
    if (engine == null || !engine.textureLost.value || _disposed) {
      return;
    }
    unawaited(_replacePlayer());
  }

  Future<void> _replacePlayer() async {
    await _lease.discard();
    if (!_disposed && !_unloaded) {
      await _engineForUse();
    }
  }

  void _bind(PlaybackEngine engine) {
    _unbind();
    _engine = engine;
    engine.position.addListener(_onPosition);
    engine.duration.addListener(_checkReady);
    engine.videoSize.addListener(_checkReady);
    engine.hasVideo.addListener(_checkReady);
    engine.completed.addListener(_onCompleted);
    engine.textureLost.addListener(_onTextureLost);
    engine.buffering.addListener(_onBuffering);
    engine.audioTracks.addListener(_onAudioTracks);
    engine.audioTrack.addListener(_onAudioTrack);
    engine.subtitleTracks.addListener(_onSubtitleTracks);
    engine.subtitleTrack.addListener(_onSubtitleTrack);
    engine.hwdec.addListener(_onDecoding);
    engine.videoSize.addListener(_onDecoding);
    _events = engine.events.listen(_onEvent);
    _audioFailures = engine.audioDecoderFailures.listen(_onAudioDecoderFailure);
    _videoController.value = engine.videoController;
    _onDecoding();
    // Lost while another page held it, or before: no change comes to tell it
    if (engine.textureLost.value) {
      _onTextureLost();
    }
  }

  void _unbind() {
    final engine = _engine;
    if (engine == null) {
      return;
    }
    engine.position.removeListener(_onPosition);
    engine.duration.removeListener(_checkReady);
    engine.videoSize.removeListener(_checkReady);
    engine.hasVideo.removeListener(_checkReady);
    engine.completed.removeListener(_onCompleted);
    engine.textureLost.removeListener(_onTextureLost);
    engine.buffering.removeListener(_onBuffering);
    engine.audioTracks.removeListener(_onAudioTracks);
    engine.audioTrack.removeListener(_onAudioTrack);
    engine.subtitleTracks.removeListener(_onSubtitleTracks);
    engine.subtitleTrack.removeListener(_onSubtitleTrack);
    engine.hwdec.removeListener(_onDecoding);
    engine.videoSize.removeListener(_onDecoding);
    unawaited(_events?.cancel());
    _events = null;
    unawaited(_audioFailures?.cancel());
    _audioFailures = null;
    _engine = null;
    _videoController.value = null;
    _buffering.value = false;
    _decoding.value = (hwdec: null, size: null);
    _stallWatch = null;
  }

  void _onEvent(PlayerEvent event) {
    switch (event.kind) {
      case PlayerEventKind.loaded:
        final engine = _engine;
        if (engine != null && !_unloaded) {
          _restoreSubtitle(engine);
        }
        // Opened again (the pool took the player, a replay): mpv chose its own track again, which is checked again
        _audioChecked = false;
      case PlayerEventKind.restarted:
        final seek = _seekWatch;
        if (seek != null && _restarted && !_unloaded) {
          _seekWatch = null;
          _log.fine('A frame ${seek.elapsedMilliseconds} ms after a seek');
        }
        if (!_restarted && !_unloaded) {
          _log.fine('The first frame ${_loadWatch.elapsedMilliseconds} ms after the load');
          _restarted = true;
          _readyTimer?.cancel();
          _readyTimer = Timer(readyWithoutSize, () => _announceReady(force: true));
          final generation = _generation;
          _silenceTimer?.cancel();
          _silenceTimer = Timer(silentAudioAfter, () => _checkSilence(generation));
          _checkReady();
        }
      case PlayerEventKind.failed:
        // A file libmpv cannot open, before "ready". Once a file plays, mpv 0.39 takes a read error for its end and
        // sends no failure: see [_onCompleted]
        if (!_unloaded) {
          final message = event.message ?? 'The video could not be played';
          final resource = _resource;
          if (resource != null && _decodingOf?.call(resource) != null) {
            unawaited(_failAfterDecoder(_generation, resource, message));
          } else {
            _fail(_generation, message);
          }
        }
    }
  }

  /// How long a failure of mpv on a video a program of the app decodes waits for that program's own end, which names
  /// the reason: a companion that dies before mpv loaded its y4m makes mpv fail at once ("libmpv: loading failed", 20
  /// ms after the kill in the review of lot AD3), its end comes a moment later
  static const decoderFailureWait = Duration(seconds: 1);
  static const _decoderFailurePoll = Duration(milliseconds: 50);

  /// Fails the video with the reason of its decoder when that decoder stops within [decoderFailureWait], else with
  /// mpv's [message]
  Future<void> _failAfterDecoder(int generation, String resource, String message) async {
    for (var waited = Duration.zero; waited < decoderFailureWait; waited += _decoderFailurePoll) {
      if (_decodingOf?.call(resource)?.failure != null) {
        break;
      }
      await Future<void>.delayed(_decoderFailurePoll);
      if (_disposed || generation != _generation || _unloaded) {
        // Another video, a stop, or the link's own look at the decoder (_tellDecoder) said it first
        return;
      }
    }
    final failure = _decodingOf?.call(resource)?.failure;
    _fail(generation, failure == null ? message : 'The AV2 decoder stopped on this video: $failure');
  }

  void _checkReady() => _announceReady(force: false);

  /// Tells the page that the video is ready once a frame of it is shown and its duration and size are known (the
  /// size: unless mpv does not tell it within [readyWithoutSize])
  void _announceReady({required bool force}) {
    final engine = _engine;
    if (_ready || !_restarted || _unloaded || engine == null) {
      return;
    }
    final duration = engine.duration.value;
    final size = engine.videoSize.value;
    final sized = size != null || engine.hasVideo.value == false;
    if (duration <= Duration.zero || (!sized && !force)) {
      return;
    }
    _ready = true;
    _readyTimer?.cancel();
    _videoInfo = VideoInfo.fromJson({
      'width': size?.width ?? 0,
      'height': size?.height ?? 0,
      'duration': duration.inMilliseconds,
    });
    if (_pausedWhenReady) {
      _pausedWhenReady = false;
      if (_status == PlaybackStatus.stopped) {
        onPlaybackStatusChanged.value = PlaybackStatus.paused;
      }
    }
    activeDesktopVideo.value = this;
    onPlaybackReady.notifyListeners();
  }

  void _onPosition() {
    if (!_ready || _unloaded) {
      return;
    }
    if (positionInterval <= Duration.zero) {
      _sendPosition();
      return;
    }
    if (_positionTimer != null) {
      // Passed on when the interval ends, the last one of a burst too (where the video paused, for instance)
      _positionPending = true;
      return;
    }
    _sendPosition();
    _positionTimer = Timer(positionInterval, _positionIntervalEnded);
  }

  void _positionIntervalEnded() {
    _positionTimer = null;
    if (_positionPending) {
      _positionPending = false;
      _sendPosition();
      _positionTimer = Timer(positionInterval, _positionIntervalEnded);
    }
  }

  void _sendPosition() {
    final engine = _engine;
    if (engine == null || !_ready || _unloaded) {
      return;
    }
    onPlaybackPositionChanged.value = engine.position.value.inMilliseconds;
  }

  void _onCompleted() {
    final engine = _engine;
    if (engine == null || !engine.completed.value || !_ready || _unloaded) {
      return;
    }
    _sendPosition();
    final position = engine.position.value;
    final duration = engine.duration.value;
    final tolerance = duration ~/ 100 > endTolerance ? duration ~/ 100 : endTolerance;
    final decoderFailure = _decoderFailure();
    if (decoderFailure != null) {
      // The decoder of the app stopped (the AV2 companion): its reason, rather than a file that could not be read
      _failDecoder(engine, decoderFailure);
      return;
    }
    if (duration > Duration.zero && position < duration - tolerance) {
      // mpv 0.39 takes a read error for the end of the file, after FFmpeg's reconnects too, plays what it had, and
      // stops there (keep-open) without a failure: the share, the server or the drive went away
      final path = _videoSource?.path;
      _fail(_generation, 'The video stopped before its end: its file could no longer be read');
      if (path != null) {
        _stoppedEarly = (path: path, position: position);
      }
      // The decoder and the connection are let go; the position stays on the page
      unawaited(_onEngine(engine, engine.stop));
      return;
    }
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
    onPlaybackEnded.notifyListeners();
  }

  /// From the start of a stall (mpv waiting for its cache once the video played), for the log
  Stopwatch? _stallWatch;

  void _onBuffering() {
    final buffering = _engine?.buffering.value ?? false;
    _buffering.value = buffering;
    if (buffering && _ready && _stallWatch == null) {
      _stallWatch = Stopwatch()..start();
    } else if (!buffering && _stallWatch != null) {
      _log.fine('A stall of ${_stallWatch!.elapsedMilliseconds} ms');
      _stallWatch = null;
    }
  }

  void _onAudioTracks() {
    final tracks = _engine?.audioTracks.value ?? const [];
    _audioTracks.value = tracks;
    // The language picked last, once per video, when the file has it and does not play it already
    final language = preferredAudioLanguage;
    if (!_audioChosen && tracks.length >= 2 && language != null) {
      _audioChosen = true;
      final track = tracks.where((track) => track.language == language).firstOrNull;
      if (track != null && track.id != _engine?.audioTrack.value) {
        _wantedAudioId = track.id;
        unawaited(_engine?.setAudioTrack(track.id));
      }
    }
    // Once per video, when the tracks are known: a track this player does not decode gives its place
    if (!_audioChecked && tracks.isNotEmpty) {
      _audioChecked = true;
      _checkAudio(_wantedAudioId ?? _engine?.audioTrack.value, atRunTime: false);
    }
  }

  void _onAudioTrack() {
    final engine = _engine;
    final id = engine?.audioTrack.value;
    _audioTrack.value = id;
    // None once mpv dropped a track whose decoder failed: the one asked stays known
    if (id == null || engine == null) {
      return;
    }
    // mpv's own choice told after the switch (its choice at the open, a file opened again): the track that replaced it
    final codec = _audioTracks.value.where((track) => track.id == id).firstOrNull?.codec;
    final replacement = _audioSwitch.value?.to;
    if (_audioChecked && codec != null && !decodesAudio(codec) && replacement != null && replacement.id != id) {
      unawaited(engine.setAudioTrack(replacement.id));
      return;
    }
    _wantedAudioId = id;
  }

  void _onSubtitleTracks() => _subtitleTracks.value = _engine?.subtitleTracks.value ?? const [];

  void _onSubtitleTrack() => _subtitleTrack.value = _engine?.subtitleTrack.value;

  void _onDecoding() => _decoding.value = (hwdec: _engine?.hwdec.value, size: _engine?.videoSize.value);

  /// Why the decoder of the app that decodes the open video stopped, null when it runs or mpv decodes the video
  String? _decoderFailure() {
    final resource = _resource;
    return resource == null ? null : _decodingOf?.call(resource)?.failure;
  }

  /// The decoder of the app stopped on the video: the video fails with its reason, the player lets go of it
  void _failDecoder(PlaybackEngine engine, String reason) {
    _fail(_generation, 'The AV2 decoder stopped on this video: $reason');
    unawaited(_onEngine(engine, engine.stop));
  }

  /// Tells the link of the streamed video open, every [linkInterval] until it is stopped (see [_tellLink])
  void _startLink() {
    _linkTimer?.cancel();
    _linkTimer = null;
    final resource = _resource;
    if ((_linkOf == null && _decodingOf == null) || resource == null || !resource.startsWith('http')) {
      return;
    }
    _linkOpened = true;
    _linkTimer = Timer.periodic(linkInterval, (_) => _tellLink());
  }

  /// What the bridge brought of the file against what the video needs, and whether mpv waits: before the first frame,
  /// or for its cache after a stall. mpv's wait after a stall follows the link (see linkTargetMs).
  void _tellLink() {
    final engine = _engine;
    final resource = _resource;
    if (_disposed || _unloaded || engine == null || resource == null) {
      return;
    }
    final decoding = _decodingOf?.call(resource);
    if (decoding != null) {
      _tellDecoder(engine, decoding);
      return;
    }
    final traffic = _linkOf?.call(resource);
    if (traffic == null) {
      return;
    }
    final meter = traffic.meter;
    if (_linkOpened) {
      // The bridge keeps one meter per file across the opens: what it counted before this one is not this open's wait
      _linkOpened = false;
      meter.restart();
    }
    final stalled = _ready && engine.buffering.value;
    final waiting = !_ready || stalled;
    final rate = meter.rate();
    final durationMs = engine.duration.value.inMilliseconds;
    final size = traffic.size;
    final need = size != null && durationMs > 0 ? size * 1000 ~/ durationMs : null;
    final ratio = rate != null && need != null && need > 0 ? rate / (need * _speed) : null;
    final ahead = engine.buffered.value - engine.position.value;
    final aheadMs = ahead > Duration.zero ? ahead.inMilliseconds : 0;
    onLinkChanged.value = NativeVideoLink(
      waiting: waiting,
      rebuffering: stalled,
      aheadMs: aheadMs,
      bytesPerSecond: rate,
      neededBytesPerSecond: need,
      sinceProgressMs: meter.sinceProgress()?.inMilliseconds,
      targetMs: waiting ? linkTargetMs(ratio, rebuffering: stalled) : 0,
      loading: waiting || aheadMs < (DesktopPlayerOptions.streamedCacheSeconds - 5) * 1000,
      receivedBytes: meter.receivedBytes,
      network: meter.started,
    );
    final resumeMs = linkTargetMs(ratio, rebuffering: true);
    if (ratio != null && resumeMs != _resumeWaitMs) {
      _resumeWaitMs = resumeMs;
      unawaited(_onEngine(engine, () => engine.setResumeWait(Duration(milliseconds: resumeMs))));
    }
  }

  /// The link of a video a program of the app decodes (the AV2 companion): its frames a second against those the
  /// video needs at its speed, the rule of a network for the start, [decoderResumeWaitMs] after a stall (plan of the
  /// AV2 videos, section 1.4)
  void _tellDecoder(PlaybackEngine engine, ({double? fps, double needed, String? failure}) decoding) {
    final failure = decoding.failure;
    if (failure != null) {
      _failDecoder(engine, failure);
      return;
    }
    final stalled = _ready && engine.buffering.value;
    final waiting = !_ready || stalled;
    final fps = decoding.fps;
    final needed = decoding.needed * _speed;
    final ratio = fps != null && needed > 0 ? fps / needed : null;
    final ahead = engine.buffered.value - engine.position.value;
    final aheadMs = ahead > Duration.zero ? ahead.inMilliseconds : 0;
    onLinkChanged.value = NativeVideoLink(
      waiting: waiting,
      rebuffering: stalled,
      aheadMs: aheadMs,
      targetMs: waiting ? (stalled ? decoderResumeWaitMs(ratio) : linkTargetMs(ratio, rebuffering: false)) : 0,
      loading: waiting || aheadMs < (DesktopPlayerOptions.streamedCacheSeconds - 5) * 1000,
      framesPerSecond: fps,
      neededFramesPerSecond: needed,
    );
    final resumeMs = decoderResumeWaitMs(ratio);
    if (ratio != null && resumeMs != _resumeWaitMs) {
      _resumeWaitMs = resumeMs;
      unawaited(_onEngine(engine, () => engine.setResumeWait(Duration(milliseconds: resumeMs))));
    }
  }

  void _fail(int generation, String message) {
    if (_disposed || generation != _generation) {
      return;
    }
    _log.warning(message);
    _linkTimer?.cancel();
    _linkTimer = null;
    _unloaded = true;
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
    onError.value = message;
  }
}
