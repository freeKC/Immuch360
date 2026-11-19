// Tells a media server where its user is in a film (see NetworkPlaybackReports), for one video loaded in the video
// page of the shares: start once it plays, progress every [progressInterval] while it plays and at each pause, stopped
// as the page goes or loads another file. Follows the player as VideoWatchRecorder does, beside it: the app's own
// record and the server's are kept apart, the page's resume reads the app's first.

import 'dart:async';

import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('NetworkPlaybackReporter');

class NetworkPlaybackReporter {
  NetworkPlaybackReporter({
    required this._reports,
    required this._player,
    required this.path,
    this.converted = false,
    this.progressInterval = defaultProgressInterval,
  });

  /// Every minute while it plays, as the plan of release 49 says: the server then shows the place within a minute
  static const defaultProgressInterval = Duration(seconds: 60);

  final NetworkPlaybackReports _reports;
  final VideoPlayerNotifier _player;
  final String path;
  final bool converted;
  final Duration progressInterval;

  VideoPlayerState? _last;
  bool _started = false;
  bool _stopped = false;
  bool _failureLogged = false;
  Duration _position = Duration.zero;
  Timer? _timer;
  void Function()? _removeListener;

  void start() {
    _removeListener = _player.addListener(_onState);
  }

  void _onState(VideoPlayerState state) {
    if (_stopped) {
      return;
    }
    final previous = _last;
    _last = state;
    // The state the player had as this reporter started: what the page showed before this video loaded
    if (previous == null) {
      return;
    }
    final playing = state.status == VideoPlaybackStatus.playing;
    if (playing) {
      _position = state.position;
      if (!_started) {
        _started = true;
        _send(() => _reports.playbackStarted(path, state.position, converted: converted));
      }
      _timer ??= Timer.periodic(progressInterval, (_) => _send(() => _reports.playbackProgress(path, _position)));
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (!_started) {
      return;
    }
    if (state.position > Duration.zero) {
      _position = state.position;
    }
    final wasPlaying = previous.status == VideoPlaybackStatus.playing;
    if (wasPlaying && state.status == VideoPlaybackStatus.paused) {
      _send(() => _reports.playbackProgress(path, _position, paused: true));
    }
  }

  void _send(Future<void> Function() report) {
    unawaited(
      report().catchError((Object error) {
        if (!_failureLogged) {
          _failureLogged = true;
          _log.info('The server did not take a playback report: ${error.runtimeType}');
        }
      }),
    );
  }

  /// The page goes, or loads another file: stopped at the last place it played, once
  void dispose() {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _timer?.cancel();
    _removeListener?.call();
    if (_started) {
      final last = _last;
      final position = last != null && last.position > Duration.zero ? last.position : _position;
      _send(() => _reports.playbackStopped(path, position));
    }
  }
}
