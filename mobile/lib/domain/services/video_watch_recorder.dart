import 'dart:async';

import 'package:immich_mobile/domain/models/watch_key.dart';
import 'package:immich_mobile/domain/models/watch_progress.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/watch_progress.provider.dart';

/// Resumes a film where it was left and saves where it is, for one video loaded in a page of the in-app player (the
/// asset viewer, the video page of the shares): FreeKC's rule of 31 October 2026, see WatchRule. Nothing to press:
/// the film starts where it was, [onResumed] tells the page to say so in a notice that fades, and the swipes are
/// untouched (a swipe pauses the page, which saves).
///
/// At [start], right before the page loads the video, a film whose row has a position (see resumeAt) is taken there
/// once the player is ready ([VideoPlayerNotifier.seekWhenReady]); an external player's own restore wins. Then it
/// saves every [saveInterval] while the video plays, at each pause, end or failure after it played, when an external
/// player takes the video and when one gives it back (see [VideoPositionWatcher]), and at [dispose]. Nothing is saved
/// before the video played in this page: the pages around it and the end the player reports at load never overwrite
/// a position with 0. A video that is no film keeps nothing. A film plays once whatever Looping says ([loopsWith]).
///
/// It holds the store object and the player, never a ref, so that it still saves as the page goes.
class VideoWatchRecorder implements VideoPositionWatcher {
  VideoWatchRecorder({
    required WatchProgressStore store,
    required VideoPlayerNotifier player,
    required this.key,
    required this.rule,
    Duration? duration,
    this.onResumed,
  }) : _store = store,
       _player = player,
       _knownDuration = duration != null && duration > Duration.zero ? duration : null {
    _row = store.find(key);
    final at = resumeAt(_row, rule: rule, duration: _knownDuration);
    _target = at > Duration.zero ? at : null;
  }

  /// How often a film that plays is saved: a crash or a kill loses this much at most
  static const saveInterval = Duration(seconds: 5);

  /// How near its target the position must be once it plays for the resume to have landed, see [onResumed]
  static const resumeTolerance = Duration(seconds: 3);

  final WatchProgressStore _store;
  final VideoPlayerNotifier _player;
  final WatchKey key;
  final WatchRule rule;

  /// Told once, with the position, when the film plays from where it was left
  final void Function(Duration position)? onResumed;

  /// The duration the page knew before the player: the asset's, the share's (DLNA, Plex); null when unknown
  final Duration? _knownDuration;
  WatchProgress? _row;
  Duration? _target;

  /// Whether the page set the player to loop, see [loopsWith]
  bool _loops = false;

  VideoPlayerState? _last;
  bool _played = false;
  Duration _lastPlayedPosition = Duration.zero;
  bool _durationChecked = false;
  bool _noticed = false;
  bool _disposed = false;
  Timer? _timer;
  void Function()? _removeListener;

  /// Where the film starts, null from the beginning
  Duration? get startAt => _target;

  /// Whether the page sets the player to loop with the Looping setting at [setting]: never a film whose duration is
  /// known; one whose duration only the player tells stops looping once it does
  bool loopsWith(bool setting) => _loops = setting && !rule.isFilm(_knownDuration);

  /// Follows the player from now on, and takes a film to where it was left once ready: right before the page loads
  void start() {
    _player.watcher = this;
    final target = _target;
    if (target != null) {
      _player.seekWhenReady(target);
    }
    _removeListener = _player.addListener(_onState);
  }

  void _onState(VideoPlayerState state) {
    if (_disposed) {
      return;
    }
    final previous = _last;
    _last = state;
    if (state.duration > Duration.zero && !_durationChecked) {
      _durationChecked = true;
      _onDuration(state.duration);
    }
    // The state the player had as this recorder started, heard at once: what the page showed before this video loaded
    if (previous == null) {
      return;
    }
    final playing = state.status == VideoPlaybackStatus.playing;
    if (playing) {
      _played = true;
      _lastPlayedPosition = state.position;
      _timer ??= Timer.periodic(saveInterval, (_) => _save());
      _noticeResume(state.position);
    } else {
      _timer?.cancel();
      _timer = null;
    }
    final wasRunning =
        previous.status == VideoPlaybackStatus.playing || previous.status == VideoPlaybackStatus.buffering;
    final stopped = switch (state.status) {
      VideoPlaybackStatus.paused || VideoPlaybackStatus.completed || VideoPlaybackStatus.failed => true,
      VideoPlaybackStatus.playing || VideoPlaybackStatus.buffering => false,
    };
    // The stop of an external player taking the video says nothing of where it was: saved before it, see onSuspend
    if (wasRunning && stopped && !_player.isSuspendedForExternalPlayer) {
      _save(ended: state.status == VideoPlaybackStatus.completed);
    }
  }

  /// The player told the duration: a film stops looping; a file whose duration differs from the one kept, which only
  /// a page that knew none could not tell at load, starts from the beginning
  void _onDuration(Duration duration) {
    if (_loops && rule.isFilm(duration)) {
      _loops = false;
      unawaited(_player.setLoop(false));
    }
    final row = _row;
    final resumes = _target != null && _knownDuration == null && row != null;
    if (resumes && resumeAt(row, rule: rule, duration: duration) == Duration.zero) {
      _target = null;
      _player.seekTo(Duration.zero);
    }
  }

  void _noticeResume(Duration position) {
    final target = _target;
    if (target == null || _noticed || (position - target).abs() > resumeTolerance) {
      return;
    }
    _noticed = true;
    onResumed?.call(target);
  }

  /// Saves where the video is, or [at]: a film only, once it played. [ended]: the player reached the end, which some
  /// players report at 0; the last position it played at tells.
  void _save({Duration? at, bool ended = false}) {
    final state = _last;
    if (!_played) {
      return;
    }
    final duration = state != null && state.duration > Duration.zero ? state.duration : _knownDuration;
    if (duration == null || !rule.isFilm(duration)) {
      return;
    }
    var position = at ?? state?.position ?? Duration.zero;
    if (ended && _lastPlayedPosition > position) {
      position = _lastPlayedPosition;
    }
    _store.record(key, position: position, duration: duration);
  }

  @override
  void onSuspend(Duration position) {
    if (!_disposed) {
      _save(at: position);
    }
  }

  @override
  void onHandBack(Duration position) {
    if (_disposed) {
      return;
    }
    // The external player played it: what it hands back is where the film is
    _played = true;
    _save(at: position);
  }

  @override
  Duration resumePositionAfterExternalPlayer() =>
      _disposed ? Duration.zero : resumeAt(_store.find(key), rule: rule, duration: _knownDuration ?? _last?.duration);

  /// The page goes, or loads another video: saves where it is, and follows the player no more
  void dispose() {
    if (_disposed) {
      return;
    }
    _save();
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    try {
      _removeListener?.call();
    } catch (_) {
      // The player went first: nothing to stop listening to
    }
    _removeListener = null;
    if (identical(_player.watcher, this)) {
      _player.watcher = null;
    }
  }
}
