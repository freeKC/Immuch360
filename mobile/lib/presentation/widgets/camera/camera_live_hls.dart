// The live view on iPhone and iPad (Tapo design 3.8, step D): AVPlayer has no RTSP, so Dart pulls the camera's stream
// and makes a live HLS playlist of it on the local media bridge (TapoLiveHls), and the platform view
// (CameraLiveView.swift) plays that http://127.0.0.1 address. The camera account never leaves Dart.
//
// This controller ties the two together for one view and tells the camera page the same states as on Android:
// connecting until the first frame, playing (the Live badge), buffering while a lost stream comes back, failed with
// the reason, idle once stopped. The states of the player count only once it was given the playlist of the current
// open, so that what the previous one still reports changes nothing.
//
// If AVPlayer refuses the playlist before its first frame, it gets the playlist once more without the sound (an ALAC
// sound it cannot decode must not cost the picture), and the sound button says there is none. A stream that played
// and was lost is opened again after 1, 2, 5, 10, 20, 30 and 30 s, as on the computers; one that never showed a frame
// is not, and a refused account never is (it counts towards the camera's lockout).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_live_hls.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('CameraLiveHls');

/// The error of a camera whose stream is H.265: the tile shows its own message for it
const cameraLiveH265 = 'H.265';
const cameraLiveRefused = 'the camera refused the account';
const cameraLiveUnreachable = 'the camera does not answer';
const cameraLiveBusy = 'the camera serves enough viewers already';

class CameraLiveHlsController {
  CameraLiveHlsController({
    required this.viewId,
    required this.api,
    required this.startStream,
    required this.onEvent,
    this.retryDelays = defaultRetryDelays,
    this.firstFrameTimeout = const Duration(seconds: 25),
  });

  /// The waits before each new open of a lost stream; the view gives up after the last
  static const defaultRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
    Duration(seconds: 30),
  ];

  final int viewId;
  final CameraLiveApi api;
  final LiveHlsStarter startStream;

  /// Called at each change of the state the camera page shows
  final void Function(CameraLiveEvent event) onEvent;
  final List<Duration> retryDelays;

  /// Longest wait for the first frame once the player has the playlist
  final Duration firstFrameTimeout;

  ({String host, int port, String user, String password, bool hd})? _source;
  bool _muted = true;

  /// AVPlayer refused the playlist with its sound: the video alone from now on
  bool _videoOnly = false;
  LiveHlsStream? _stream;

  /// Bumped at each open and stop: what an earlier one was still awaiting changes nothing
  int _generation = 0;

  /// The player has the playlist of the current open: its states count
  bool _playerActive = false;

  /// A frame of this source was shown since [play]: a loss is then opened again
  bool _shown = false;

  /// A frame was shown since the last open
  bool _shownThisOpen = false;
  int _attempts = 0;
  Timer? _retry;
  Timer? _firstFrame;

  /// Whether the playlist has sound (true until known), and whether the player plays it
  bool _streamAudio = true;
  bool _playerAudio = true;
  CameraLiveEvent? _last;
  bool _disposed = false;

  /// Plays the stream of the camera at [host] (HD or SD) with the camera account, in place of what played before
  void play({
    required String host,
    required int port,
    required String user,
    required String password,
    required bool hd,
  }) {
    if (_disposed) {
      return;
    }
    _source = (host: host, port: port, user: user, password: password, hd: hd);
    _shown = false;
    _attempts = 0;
    unawaited(_open(lost: false));
  }

  void setMuted(bool muted) {
    _muted = muted;
    if (_playerActive) {
      unawaited(_call(() => api.setMuted(viewId, muted)));
    }
  }

  /// Stops the stream and the player (the app away, the view gone): the camera has a viewer less
  void stop() {
    _generation++;
    _cancelTimers();
    _playerActive = false;
    unawaited(_releaseStream());
    unawaited(_call(() => api.stop(viewId)));
    _report(CameraLiveState.idle);
  }

  /// Stops as [stop] does, without telling the page: it is going too
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    stop();
  }

  /// A state of the platform view
  void onPlayerEvent(CameraLiveEvent event) {
    if (!_playerActive || _disposed) {
      return;
    }
    _playerAudio = event.hasAudio;
    switch (event.state) {
      case CameraLiveState.playing:
        _shown = true;
        _shownThisOpen = true;
        _attempts = 0;
        _firstFrame?.cancel();
        _report(CameraLiveState.playing);
      case CameraLiveState.connecting || CameraLiveState.buffering:
        _report(_shownThisOpen || _shown ? CameraLiveState.buffering : CameraLiveState.connecting);
      case CameraLiveState.failed:
        _playerFailed(event.error ?? 'AVPlayer error');
      case CameraLiveState.idle:
        break;
    }
  }

  Future<void> _open({required bool lost}) async {
    final generation = ++_generation;
    _cancelTimers();
    _playerActive = false;
    _shownThisOpen = false;
    // The camera serves two viewers at most: the previous stream goes first
    await _releaseStream();
    if (generation != _generation || _disposed) {
      return;
    }
    _streamAudio = !_videoOnly;
    _playerAudio = true;
    _report(lost ? CameraLiveState.buffering : CameraLiveState.connecting);
    final source = _source!;
    final stream = _stream = startStream(
      host: source.host,
      port: source.port,
      path: source.hd ? tapoRtspHdPath : tapoRtspSdPath,
      user: source.user,
      password: source.password,
      withAudio: !_videoOnly,
    );
    final Uri url;
    try {
      url = await stream.start();
    } catch (error) {
      if (generation != _generation) {
        return;
      }
      _stream = null;
      final (reason, retry) = _reasonOf(error);
      _log.warning('The live stream did not start: $reason');
      await _failed(reason, retry: retry);
      return;
    }
    if (generation != _generation || _disposed) {
      await stream.stop();
      return;
    }
    _streamAudio = stream.hasAudio;
    unawaited(
      stream.ended.then((reason) {
        if (generation == _generation) {
          unawaited(_failed(reason, retry: true));
        }
      }),
    );
    await _call(() => api.setSource(viewId, CameraLiveSource(url: url.toString(), isHls: true)));
    if (generation != _generation) {
      return;
    }
    // From here, the states of the player are those of this playlist
    _playerActive = true;
    await _call(() => api.setMuted(viewId, _muted));
    _firstFrame = Timer(firstFrameTimeout, () {
      if (generation == _generation && !_shownThisOpen) {
        _playerFailed(tapoLiveNoPicture);
      }
    });
    _report(_last?.state ?? CameraLiveState.connecting, force: true);
  }

  /// The player gave up: before its first frame with the sound, once more without it
  void _playerFailed(String reason) {
    _log.warning('The live player failed: $reason');
    if (!_shownThisOpen && _streamAudio && !_videoOnly) {
      _videoOnly = true;
      unawaited(_open(lost: _shown));
      return;
    }
    unawaited(_failed(reason, retry: true));
  }

  /// A stream that showed frames is opened again after the next delay; one that never did, or a refusal, gives up
  Future<void> _failed(String reason, {required bool retry}) async {
    final generation = ++_generation;
    _cancelTimers();
    _playerActive = false;
    await _releaseStream();
    if (generation != _generation || _disposed) {
      return;
    }
    if (retry && _shown && _attempts < retryDelays.length) {
      final delay = retryDelays[_attempts++];
      _log.info('The live view lost its stream ($reason); opening it again in ${delay.inSeconds} s');
      _report(CameraLiveState.buffering);
      _retry = Timer(delay, () {
        if (generation == _generation && !_disposed) {
          unawaited(_open(lost: true));
        }
      });
      return;
    }
    _report(CameraLiveState.failed, error: reason);
  }

  /// The reason the state line shows, and whether a stream that played is opened again after it
  static (String, bool) _reasonOf(Object error) {
    if (error is! TapoCameraException) {
      return ('${error.runtimeType}', true);
    }
    return switch (error.kind) {
      TapoErrorKind.wrongPassword => (cameraLiveRefused, false),
      TapoErrorKind.h265 => (cameraLiveH265, false),
      TapoErrorKind.busy => (cameraLiveBusy, true),
      TapoErrorKind.unreachable => (
        error.detail == tapoLiveStreamLost ? tapoLiveStreamLost : cameraLiveUnreachable,
        true,
      ),
      TapoErrorKind.unsupported => (error.detail ?? 'unsupported stream', error.detail == tapoLiveNoPicture),
      _ => (error.kind.name, true),
    };
  }

  Future<void> _releaseStream() async {
    final stream = _stream;
    _stream = null;
    if (stream != null) {
      try {
        await stream.stop();
      } catch (error) {
        _log.fine('The live stream did not stop cleanly: ${error.runtimeType}');
      }
    }
  }

  void _cancelTimers() {
    _retry?.cancel();
    _retry = null;
    _firstFrame?.cancel();
    _firstFrame = null;
  }

  void _report(CameraLiveState state, {String? error, bool force = false}) {
    final event = (state: state, error: error, hasAudio: _streamAudio && _playerAudio);
    if (!force && event == _last) {
      return;
    }
    _last = event;
    if (!_disposed) {
      onEvent(event);
    }
  }

  /// A failure of the platform side is logged with its code only
  static Future<void> _call(Future<void> Function() call) async {
    try {
      await call();
    } on PlatformException catch (error) {
      _log.warning('The live view refused a call: ${error.code}');
    } catch (error) {
      _log.warning('The live view refused a call: ${error.runtimeType}');
    }
  }
}
