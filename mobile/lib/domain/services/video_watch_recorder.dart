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
/// The state of the player says nothing of where the film is while an external player has it, nor once it handed it
/// back, until the player is ready again: the in-app player loads it again at 0 (Media3's setMediaItem) and goes to
/// the position handed back only then. A save meanwhile keeps that position (see [_save]). Nor before the rows of
/// the database are in memory: nothing is saved before, and a film that did not really start resumes then.
///
/// It holds the store object and the player, never a ref, so that it still saves as the page goes.
class VideoWatchRecorder implements VideoPositionWatcher {
  VideoWatchRecorder({
    required this._store,
    required this._player,
    required this.key,
    required this.rule,
    Duration? duration,
    this.onResumed,
  }) : _knownDuration = duration != null && duration > Duration.zero ? duration : null {
    _row = _store.find(key);
    // The duration of the row is the player's of the viewing before: the one the page knew (the server's probe of the
    // original, a media server's listing) may differ from it, the player's is compared once it tells it (_onDuration)
    final at = resumeAt(_row, rule: rule);
    _target = at > Duration.zero ? at : null;
    if (!_store.isLoaded) {
      unawaited(_store.loaded.then((_) => _onRowsLoaded()));
    }
  }

  /// How often a film that plays is saved: a crash or a kill loses this much at most
  static const saveInterval = Duration(seconds: 5);

  /// How near its target the position must be once it plays for the resume to have landed, see [onResumed]
  static const resumeTolerance = Duration(seconds: 3);

  /// Longest a page waits for the rows of the database before it loads a video (see [storeReady])
  static const storeWait = Duration(seconds: 2);

  /// Completes once [store] holds the rows of its database, [storeWait] at most: a recorder made before finds no row,
  /// saves nothing until they come and takes the film where it was left then (see [_onRowsLoaded]). Read once at the
  /// start of the app, so at once ever after.
  static Future<void> storeReady(WatchProgressStore store) => store.loaded.timeout(storeWait, onTimeout: () {});

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

  /// Whether the page set the player to loop, see [loopsWith], and what the Looping setting said
  bool _loops = false;
  bool _loopSetting = false;

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
  /// known; the duration the player tells, once it does, decides (see [_onDuration])
  bool loopsWith(bool setting) {
    _loopSetting = setting;
    return _loops = setting && !rule.isFilm(_playerDuration ?? _knownDuration);
  }

  /// The duration of the video as the player tells it, null before
  Duration? get _playerDuration {
    final duration = _last?.duration;
    return duration != null && duration > Duration.zero ? duration : null;
  }

  /// Follows the player from now on, and takes a film to where it was left once ready: right before the page loads.
  /// The restore of an external player waiting wins: the film goes where that player left it, with no notice.
  void start() {
    _player.watcher = this;
    final target = _target;
    if (target != null && !_player.seekWhenReady(target)) {
      _target = null;
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

  /// The player told the duration: a film stops looping (a video the page took for one loops as set); a file whose
  /// duration differs from the one kept (see resumeAt: the row has the player's own duration) starts from the
  /// beginning. Heard as the player becomes ready, before the seek to where the film was left goes: taken back then.
  void _onDuration(Duration duration) {
    final loops = _loopSetting && !rule.isFilm(duration);
    if (loops != _loops) {
      _loops = loops;
      unawaited(_player.setLoop(loops));
    }
    final row = _row;
    if (_target != null && row != null && resumeAt(row, rule: rule, duration: duration) == Duration.zero) {
      _target = null;
      if (!_player.cancelSeekWhenReady()) {
        // The seek went already: back to the start
        _player.seekTo(Duration.zero);
      }
    }
  }

  void _noticeResume(Duration position) {
    final target = _target;
    if (target == null || _noticed) {
      return;
    }
    if ((position - target).abs() <= resumeTolerance) {
      _noticed = true;
      onResumed?.call(target);
    } else if (_player.isReady && _player.pendingRestorePosition == null) {
      // It plays elsewhere ("Play from the start" before it played, the user's seek): no notice when it passes there
      _target = null;
    }
  }

  /// The rows of the database came after this recorder started (a slow start of the app, see [storeReady]): a film
  /// that did not really start here yet goes where it was left, with its notice
  void _onRowsLoaded() {
    if (_disposed) {
      return;
    }
    _row = _store.find(key);
    final at = resumeAt(_row, rule: rule, duration: _playerDuration);
    if (at <= Duration.zero || _player.isSuspendedForExternalPlayer || _player.pendingRestorePosition != null) {
      return;
    }
    if (!_player.isReady) {
      if (_player.seekWhenReady(at)) {
        _target = at;
      }
      return;
    }
    final position = _last?.position ?? Duration.zero;
    if (position < watchStartMargin(_playerDuration ?? _row!.duration)) {
      _target = at;
      _player.seekTo(at);
    }
  }

  /// Saves where the video is, or [at]: a film only, once it played, and once the rows of the database are in memory
  /// (a save before would be kept over the row of the film). [ended]: the player reached the end, which some players
  /// report at 0; the last position it played at tells. [later]: right after the current frame, for a page that goes,
  /// which may not change a provider while the widget tree is being taken down.
  ///
  /// While an external player has the video, nothing: that player tells where it is ([onHandBack], the reports of the
  /// immersive viewer). Once it handed the video back, the player goes there only once ready again, at 0 until then:
  /// the position it goes to is where the film is.
  void _save({Duration? at, bool ended = false, bool later = false}) {
    if (!_played || !_store.isLoaded) {
      return;
    }
    final duration = _playerDuration ?? _knownDuration;
    if (duration == null || !rule.isFilm(duration)) {
      return;
    }
    if (at == null && _player.isSuspendedForExternalPlayer) {
      return;
    }
    final position = at ?? _player.pendingRestorePosition ?? _stopPosition(ended: ended);
    final store = _store;
    if (later) {
      scheduleMicrotask(() => store.record(key, position: position, duration: duration));
    } else {
      store.record(key, position: position, duration: duration);
    }
  }

  /// Where the player stopped: the last position it played at for an end reported at 0
  Duration _stopPosition({required bool ended}) {
    final position = _last?.position ?? Duration.zero;
    return ended && _lastPlayedPosition > position ? _lastPlayedPosition : position;
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
    _lastPlayedPosition = position;
    _save(at: position);
  }

  @override
  Duration resumePositionAfterExternalPlayer() =>
      _disposed ? Duration.zero : resumeAt(_store.find(key), rule: rule, duration: _playerDuration);

  /// The page goes, or loads another video: saves where it is, right after the current frame, and follows the player
  /// no more
  void dispose() {
    if (_disposed) {
      return;
    }
    _save(later: true);
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
