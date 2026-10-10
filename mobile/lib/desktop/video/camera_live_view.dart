// The live view of a Tapo camera on a computer (design 5.5, plan 2.4): the RTSP stream of the camera played by a
// pooled media_kit player (libmpv, PlayerKind.live), RTP inside the RTSP connection over TCP as on the phones, muted
// until the user turns the sound on. It stands where the phones put their platform view (CameraLiveView.kt) and tells
// the camera page the same states (CameraLiveTile): connecting, playing (the Live badge), buffering while a lost stream
// comes back, failed with the reason, idle once stopped.
//
// The address holds the camera account: FFmpeg's RTSP client reads it from the user info and answers the camera's
// Digest challenge itself. It reaches libmpv and nothing else: this file never logs it, DesktopPlayer gives it to mpv
// without media_kit's list file, and the account is registered with hidePlayerSecret before the address leaves this
// file, so that every line of mpv's log and every player error hides it, whole, decoded or quoted on its own.
//
// A stream that played and was lost (the camera restarted, the Wi-Fi dropped, the stream stopped coming) is opened
// again after 1, 2, 5, 10, 20, 30 and 30 s, about a minute and a half, before the view gives up; the last frame stays
// on screen meanwhile. A stream that never showed a frame is not opened again by itself: a refused account counts
// towards the camera's lockout, and a camera serves two viewers at most, the Tapo app included. A refusal of the
// account (RTSP 401) is never retried.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/platform/camera_live_api.g.dart';
import 'package:immich_mobile/providers/tapo/tapo_camera.provider.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('DesktopCameraLive');

/// The address libmpv plays: [url] (`rtsp://host:port/path`, without the account, as cameraRtspUrl builds it) with the
/// camera account in its user info. Each byte of the account outside the unreserved characters of RFC 3986 is
/// percent-encoded, as the phones do (cameraRtspUri in CameraLiveView.kt): FFmpeg decodes the user info before it
/// answers the Digest challenge, so any character of a password survives (a space as %20, a plus as %2B). Null for an
/// address that is not a plain rtsp:// one, or that already holds a user info.
String? cameraRtspUrlWithAccount(String url, String user, String password) {
  const prefix = 'rtsp://';
  if (!url.toLowerCase().startsWith(prefix)) {
    return null;
  }
  final rest = url.substring(prefix.length);
  final slash = rest.indexOf('/');
  final authority = slash < 0 ? rest : rest.substring(0, slash);
  if (authority.isEmpty || authority.contains('@')) {
    return null;
  }
  if (user.isEmpty) {
    return '$prefix$rest';
  }
  final userInfo = _encodeUserInfo(user) + (password.isEmpty ? '' : ':${_encodeUserInfo(password)}');
  return '$prefix$userInfo@$rest';
}

String _encodeUserInfo(String text) {
  const hex = '0123456789ABCDEF';
  final out = StringBuffer();
  for (final byte in utf8.encode(text)) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E;
    if (unreserved) {
      out.writeCharCode(byte);
    } else {
      out
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0x0F]);
    }
  }
  return out.toString();
}

/// What the live view of a computer is doing
enum CameraLiveStatus {
  /// Opening the stream: the RTSP exchange with the camera, then the first frame
  connecting,

  /// A frame of the stream is on screen and the next ones come
  live,

  /// The stream played and stopped coming: it is waited for, then opened again
  lost,

  /// Nothing plays: stopped by the page (the app away, the view gone), or given up ([CameraLiveSession.error])
  stopped,
}

/// The state of the phones' live view that the camera page shows for [status]: "Connecting to the camera" while
/// connecting or lost, the Live badge while live, and once stopped nothing, or the reason when the view gave up
CameraLiveState cameraLiveStateOf(CameraLiveStatus status, {String? error}) => switch (status) {
  CameraLiveStatus.connecting => CameraLiveState.connecting,
  CameraLiveStatus.live => CameraLiveState.playing,
  CameraLiveStatus.lost => CameraLiveState.buffering,
  CameraLiveStatus.stopped => error == null ? CameraLiveState.idle : CameraLiveState.failed,
};

/// The reasons the view gives up with, shown after "The live view did not start:" as the phones show Media3's codes
const cameraLiveUnsupportedAddress = 'unsupported address';
const cameraLiveNoPicture = 'no picture from the camera';
const cameraLiveStreamLost = 'the camera stopped sending';
const cameraLiveNoPlayer = 'no player free';

/// One live view's player and states, apart from the widget so that the tests drive it with fake players
class CameraLiveSession {
  CameraLiveSession({
    required this._pool,
    required this.onEvent,
    this.retryDelays = defaultRetryDelays,
    this.connectTimeout = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 10),
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

  /// How often the session looks whether the stream still moves
  static const checkPeriod = Duration(seconds: 1);

  final PlayerPool _pool;

  /// Called at each change of the state the camera page shows
  final void Function(CameraLiveEvent event) onEvent;
  final List<Duration> retryDelays;

  /// Longest wait for the first frame of an open. mpv gives up on a silent camera after its own network timeout
  /// (DesktopPlayerOptions.liveTimeoutSeconds); this one also covers a camera that answers and sends no picture.
  final Duration connectTimeout;

  /// Longest time the picture may stand still while live, waiting for the stream included
  final Duration stallTimeout;

  /// The texture of the player while the session holds one, for the Video widget
  final videoController = ValueNotifier<VideoController?>(null);

  CameraLiveStatus _status = CameraLiveStatus.stopped;
  String? _error;
  bool _hasAudio = true;

  CameraLiveStatus get status => _status;

  /// Why the view gave up, null while it plays or after a plain stop
  String? get error => _error;

  /// Whether the stream has sound; true until it is known, as on the phones
  bool get hasAudio => _hasAudio;

  PlayerLease? _lease;
  PlaybackEngine? _engine;
  StreamSubscription<PlayerEvent>? _events;
  String? _address;
  bool _muted = true;

  /// Bumped at each open and stop: what an earlier one was still awaiting changes nothing
  int _generation = 0;

  /// A frame of this stream was shown since [play]: a loss is then opened again
  bool _played = false;

  /// A frame was shown since the last open
  bool _shown = false;

  /// New opens since the last frame
  int _attempts = 0;

  /// Time the picture stood still, counted by [_check]
  Duration _quiet = Duration.zero;
  Timer? _retry;
  Timer? _watch;
  bool _discarding = false;
  bool _disposed = false;

  /// Plays the stream at [url] (`rtsp://host:port/path`, without the account) with the camera account [user] and
  /// [password], in place of what played before (the switch between the HD and SD streams too)
  Future<void> play({required String url, required String user, required String password}) async {
    if (_disposed) {
      return;
    }
    // Before the address exists: no line may show the account from now on
    for (final secret in {user, password, _encodeUserInfo(user), _encodeUserInfo(password)}) {
      hidePlayerSecret(secret);
    }
    final address = cameraRtspUrlWithAccount(url, user, password);
    _played = false;
    _attempts = 0;
    if (address == null) {
      await _giveUp(cameraLiveUnsupportedAddress);
      return;
    }
    _address = address;
    _hasAudio = true;
    await _open();
  }

  /// Turns the sound on or off, now or at the next open
  void setMuted(bool muted) {
    _muted = muted;
    final engine = _engine;
    if (engine != null) {
      unawaited(_quietly(() => engine.setVolume(muted ? 0 : 1)));
    }
  }

  /// Stops the stream and gives the player back: the camera has a viewer less. [play] starts it again.
  Future<void> stop() async {
    // Told at once; the pool stops the player meanwhile
    final released = _release();
    _report(CameraLiveStatus.stopped);
    await released;
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _release();
    videoController.dispose();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _retry?.cancel();
    _retry = null;
    _shown = false;
    _quiet = Duration.zero;
    _error = null;
    _report(_played ? CameraLiveStatus.lost : CameraLiveStatus.connecting);
    _watch ??= Timer.periodic(checkPeriod, (_) => _check());
    final lease = _lease ??= _pool.lease(PlayerKind.live, label: 'camera live view', onSuspend: _suspended);
    final PlaybackEngine engine;
    try {
      engine = await lease.acquire();
    } catch (error) {
      _log.warning('The live view got no player: ${error.runtimeType}');
      if (generation == _generation) {
        await _giveUp(cameraLiveNoPlayer);
      }
      return;
    }
    if (generation != _generation || _disposed) {
      return;
    }
    _attach(engine);
    final address = _address!;
    try {
      await lease.guard(() async {
        if (!identical(lease.engine, engine) || generation != _generation) {
          return;
        }
        await engine.setVolume(_muted ? 0 : 1);
        await engine.open(address, streamed: true);
        await engine.play();
      });
    } catch (error) {
      final reason = redactPlayerText('$error');
      _log.warning('The live view could not open its stream: $reason');
      if (generation == _generation) {
        await _failed(reason);
      }
    }
  }

  void _attach(PlaybackEngine engine) {
    if (identical(_engine, engine)) {
      return;
    }
    _detach();
    _engine = engine;
    _events = engine.events.listen(_onEvent);
    engine.position.addListener(_onProgress);
    engine.buffering.addListener(_refresh);
    engine.completed.addListener(_onCompleted);
    engine.audioTracks.addListener(_onTracks);
    engine.textureLost.addListener(_onTextureLost);
    videoController.value = engine.videoController;
  }

  void _detach() {
    final engine = _engine;
    if (engine == null) {
      return;
    }
    _engine = null;
    unawaited(_events?.cancel());
    _events = null;
    engine.position.removeListener(_onProgress);
    engine.buffering.removeListener(_refresh);
    engine.completed.removeListener(_onCompleted);
    engine.audioTracks.removeListener(_onTracks);
    engine.textureLost.removeListener(_onTextureLost);
    if (!_disposed) {
      videoController.value = null;
    }
  }

  /// Whether the stream of the last open is still the one the session waits for
  bool get _opening => _engine != null && _retry == null && _status != CameraLiveStatus.stopped;

  void _onEvent(PlayerEvent event) {
    if (!_opening) {
      return;
    }
    switch (event.kind) {
      case PlayerEventKind.loaded:
        _onTracks();
      case PlayerEventKind.restarted:
        // A frame of this stream is on screen
        _shown = true;
        _played = true;
        _attempts = 0;
        _quiet = Duration.zero;
        _onTracks();
        _refresh();
      case PlayerEventKind.failed:
        unawaited(_failed(event.message ?? 'libmpv error'));
    }
  }

  void _onProgress() {
    _quiet = Duration.zero;
    _refresh();
  }

  /// Live once a frame is shown and mpv does not wait for the stream; lost while it waits after being live (the
  /// stream stalled, opened again if it stays so, see [_check])
  void _refresh() {
    if (!_opening || !_shown) {
      return;
    }
    if (!(_engine?.buffering.value ?? false)) {
      _report(CameraLiveStatus.live);
    } else if (_status == CameraLiveStatus.live) {
      _report(CameraLiveStatus.lost);
    }
  }

  void _onCompleted() {
    // The camera closed the stream (a restart, a second viewer of the Tapo app taking its place)
    if (_opening && (_engine?.completed.value ?? false)) {
      unawaited(_lose(cameraLiveStreamLost));
    }
  }

  /// Whether the stream has sound, once mpv listed its tracks (hasVideo known): DesktopPlayer sets both at once, the
  /// audio tracks last, so the sound button does not flicker at each open
  void _onTracks() {
    final engine = _engine;
    if (engine == null || !_opening || engine.hasVideo.value == null) {
      return;
    }
    final hasAudio = engine.audioTracks.value.isNotEmpty;
    if (hasAudio != _hasAudio) {
      _hasAudio = hasAudio;
      _report(_status, force: true);
    }
  }

  void _onTextureLost() {
    final engine = _engine;
    final lease = _lease;
    if (engine == null || lease == null || !engine.textureLost.value || _discarding) {
      return;
    }
    // The graphics device went (a driver update, the computer waking up): only a new player shows a picture again
    _discarding = true;
    unawaited(
      lease.discard().whenComplete(() {
        _discarding = false;
        if (!_disposed && _address != null && _status != CameraLiveStatus.stopped) {
          unawaited(_open());
        }
      }),
    );
  }

  Future<void> _suspended() async {
    _detach();
    if (_discarding) {
      return;
    }
    // Another live view took the player: this one stops, as when the app goes away
    _generation++;
    _retry?.cancel();
    _retry = null;
    _report(CameraLiveStatus.stopped);
  }

  void _check() {
    if (!_opening) {
      return;
    }
    _quiet += checkPeriod;
    if (_quiet < (_shown ? stallTimeout : connectTimeout)) {
      return;
    }
    unawaited(_shown ? _lose(cameraLiveStreamLost) : _failed(cameraLiveNoPicture));
  }

  /// The open failed or ended in an error: opened again if this stream played, else the view gives up
  Future<void> _failed(String reason) async {
    if (_retry != null || _status == CameraLiveStatus.stopped) {
      return;
    }
    if (_refused(reason) || !_played) {
      await _giveUp(reason);
    } else {
      await _lose(reason);
    }
  }

  /// FFmpeg's answer to a refused account ("method DESCRIBE failed: 401 Unauthorized"): asking again with the same
  /// account would count towards the camera's lockout
  static bool _refused(String reason) => RegExp(r'\b401\b').hasMatch(reason);

  /// The stream that played stopped coming: opened again after the next delay, or given up after the last one
  Future<void> _lose(String reason) async {
    if (_retry != null || _status == CameraLiveStatus.stopped) {
      return;
    }
    if (_attempts >= retryDelays.length) {
      await _giveUp(reason);
      return;
    }
    final delay = retryDelays[_attempts++];
    // The open that was lost is over: what it still sends changes nothing
    _generation++;
    _log.info('The live view lost its stream (${redactPlayerText(reason)}); opening it again in ${delay.inSeconds} s');
    _report(CameraLiveStatus.lost);
    _retry = Timer(delay, () {
      _retry = null;
      if (!_disposed && _status != CameraLiveStatus.stopped) {
        unawaited(_open());
      }
    });
  }

  Future<void> _giveUp(String reason) async {
    final redacted = redactPlayerText(reason);
    _log.warning('The live view stopped: $redacted');
    final released = _release();
    _report(CameraLiveStatus.stopped, error: redacted);
    await released;
  }

  /// Gives the player back to the pool, which stops it: FFmpeg ends the RTSP session and the camera has a viewer less
  Future<void> _release() async {
    _generation++;
    _retry?.cancel();
    _retry = null;
    _watch?.cancel();
    _watch = null;
    _detach();
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      await _quietly(lease.release);
    }
  }

  void _report(CameraLiveStatus status, {String? error, bool force = false}) {
    if (!force && status == _status && error == _error) {
      return;
    }
    if (status != _status) {
      _log.fine('Live view: ${status.name}');
    }
    _status = status;
    _error = error;
    if (_disposed) {
      return;
    }
    onEvent((state: cameraLiveStateOf(status, error: error), error: error, hasAudio: _hasAudio));
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _log.warning('A live view call failed: ${redactPlayerText('$error')}');
    }
  }
}

/// The live view of a camera on a computer, in the place of the phones' platform view (see the top of this file)
class DesktopCameraLiveView extends StatefulWidget {
  const DesktopCameraLiveView({
    super.key,
    required this.url,
    required this.user,
    required this.password,
    required this.muted,
    this.onEvent,
    this.pool,
  });

  /// `rtsp://host:port/path`, without the account (cameraRtspUrl)
  final String url;
  final String user;
  final String password;
  final bool muted;
  final ValueChanged<CameraLiveEvent>? onEvent;

  /// The app's pool by default; the tests give one of fake players
  final PlayerPool? pool;

  /// Whether this computer plays videos: libmpv was loaded at start (desktop_video_setup.dart)
  static bool get available => desktopVideoAvailable;

  @override
  State<DesktopCameraLiveView> createState() => _DesktopCameraLiveViewState();
}

class _DesktopCameraLiveViewState extends State<DesktopCameraLiveView> with WidgetsBindingObserver {
  late final CameraLiveSession _session = CameraLiveSession(pool: widget.pool ?? desktopPlayerPool, onEvent: _tell);

  void _tell(CameraLiveEvent event) {
    void tell() {
      if (mounted) {
        widget.onEvent?.call(event);
      }
    }

    // A state that changes while the camera page builds (a play from initState or didUpdateWidget) reaches the page
    // once the frame is built: it sets its state on it
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduleMicrotask(tell);
    } else {
      tell();
    }
  }

  /// Stopped while the app was away: played again when it comes back
  bool _away = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _play();
  }

  void _play() {
    _session.setMuted(widget.muted);
    unawaited(_session.play(url: widget.url, user: widget.user, password: widget.password));
  }

  @override
  void didUpdateWidget(DesktopCameraLiveView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.user != widget.user || oldWidget.password != widget.password) {
      _play();
    } else if (oldWidget.muted != widget.muted) {
      _session.setMuted(widget.muted);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera serves two viewers at most: none is held while the window is minimised or the app is away
    switch (state) {
      case AppLifecycleState.resumed:
        if (_away) {
          _away = false;
          _play();
        }
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        // A view that gave up stays so until the page opens again: a refused account is not tried at each restore
        if (!_away && _session.error == null) {
          _away = true;
          unawaited(_session.stop());
        }
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_session.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    child: IgnorePointer(
      child: ColoredBox(
        color: Colors.black,
        child: ValueListenableBuilder<VideoController?>(
          valueListenable: _session.videoController,
          builder: (context, controller, _) => controller == null
              ? const SizedBox.expand()
              : Video(
                  // A new player (after a lost graphics device) is a new texture, and a new state of the widget
                  key: ObjectKey(controller),
                  controller: controller,
                  controls: NoVideoControls,
                  fill: Colors.black,
                  filterQuality: FilterQuality.medium,
                  // A camera page is looked at, not watched: the screen may sleep as on the phones
                  wakelock: false,
                  pauseUponEnteringBackgroundMode: false,
                  resumeUponEnteringForegroundMode: false,
                ),
        ),
      ),
    ),
  );
}
