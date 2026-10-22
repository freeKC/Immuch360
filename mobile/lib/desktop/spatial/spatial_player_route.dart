// The Spatial 2.5D player of the computers (study feasibility-windows-spatial.md, sections 3.3 to 3.5): what
// SpatialVideoActivity is on Android and SpatialVideoViewController on iOS, as a route of the app's window.
// DesktopSpatialVideoApi.open pushes it and returns at once, as the native open starts an activity.
//
// The video plays through the pooled player and controller adapter of the other players, drawn by the Spatial passes
// of renderer C (spatial_plugin_output.dart), turned on before each open of the file. The viewpoint, 0 the left camera
// to 1 the right one, comes from the head through the webcam (head_tracking.dart: the phones' One Euro filter and
// HeadViewpoint on the samples, read once per Flutter frame, a frame being asked for at each sample and at each frame
// while the viewpoint eases, and sent to the plugin at most once per frame), or from the mouse over the picture
// ("Follow the mouse", for a computer without a webcam), or from the slider and the arrow keys alone. The slider and
// the keys also take over from the head or the mouse, until Recenter (R) gives the viewpoint back to them.
// The webcam runs only while this page shows with head tracking chosen: it closes when the page closes, when the
// window is minimised, when Windows is locked or its display is off (session_presence.dart; the window is then only
// inactive), and opens again when they come back; it closes when tracking is turned off. Windows asks nothing before a
// desktop app opens the webcam: the first time, the page says what the webcam is for and asks ("Use the webcam" or
// "Follow the mouse") before it opens it. Camera access turned off for desktop apps gives the privacy message with the
// button of the Windows settings; the webcam is then not tried again until the user comes back from those settings or
// turns tracking on again. With the system's reduced motion the page opens on the slider. A 360° or VR180 stereo video
// turns with a drag, as in the 360° player.
//
// The passes' own adaptive tier sees the GPU time of the passes only, not mpv drawing the frame nor the decoder. The
// page measures what the 360° player measures (render/renderer_probe.dart: the frames drawn against the video's rate
// over the first seconds of playback): a shortfall the decoder causes plays the server's transcoded stream when there
// is one; otherwise the passes step down (a smaller frame for mpv, then the disparity held at LOW) and are measured
// again; at the lowest step, below 0.6 of the rate, the video plays flat with the message.
// On close, whoever opened it hears where the video was, whether it played, and the layout and projection shown last
// (the SpatialVideoEvents of the phones), and externalPlayerClosedProvider lets the viewer behind take its video back.
//
// Nothing of a source reaches libmpv but a path of this computer or a media bridge URL: the headers of open() are
// dropped, the server's videos go through the bridge, as in the 360° player.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_controls.dart';
import 'package:immich_mobile/desktop/spatial/spatial_plugin_output.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart';
import 'package:immich_mobile/desktop/video/render/renderer_probe.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart';
import 'package:immich_mobile/desktop/video/spherical_player_route.dart'
    show mpvHwdecCurrent, mpvProperty, mpvVideoFramesPerSecond, sphericalVideoSource;
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/desktop/window/session_presence.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv show SpatialLayout, SpatialProjection, SpatialStats;
import 'package:media_kit_video/media_kit_video.dart' hide SpatialLayout, SpatialProjection, SpatialStats;
import 'package:native_video_player/native_video_player.dart';
import 'package:url_launcher/url_launcher.dart';

final _log = Logger('SpatialPlayer');

/// The Settings page of Windows where camera access for desktop apps is turned on
final cameraPrivacySettings = Uri.parse(cameraPrivacySettingsUri);

/// The Settings page of Windows with the cameras, where Windows Studio Effects automatic framing is turned off
final cameraSettings = Uri.parse('ms-settings:camera');

/// What SpatialVideoApi.open gives the player, the headers and the labels left out (see the top of this file)
@immutable
class SpatialPlayerArgs {
  const SpatialPlayerArgs({
    required this.url,
    required this.title,
    this.layout = SpatialStereoLayout.auto,
    this.projection = SpatialProjection.flat,
    this.start = Duration.zero,
    this.autoplay = true,
    this.debugOverlay = false,
    this.fallbackUrl,
  });

  /// The args of a request of the viewers (spatial_viewer.dart)
  factory SpatialPlayerArgs.of(SpatialOpenRequest request) => SpatialPlayerArgs(
    url: request.url,
    title: request.title,
    layout: request.layout,
    projection: request.projection,
    start: Duration(milliseconds: request.startPositionMs < 0 ? 0 : request.startPositionMs),
    autoplay: request.autoplay,
    debugOverlay: request.debugOverlay,
    fallbackUrl: request.fallbackUrl,
  );

  /// A file:// URI of this computer, a path, a media bridge URL or a URL of the Immich server
  final String url;
  final String title;
  final SpatialStereoLayout layout;
  final SpatialProjection projection;
  final Duration start;
  final bool autoplay;

  /// The troubleshooting setting: the figures of the passes and of the tracker, the disparity map, the slider always
  final bool debugOverlay;

  /// The server's transcoded stream, played when the original fails; null when there is none
  final String? fallbackUrl;
}

/// What the page tells when it closes: as SpatialVideoEvents.closed of the phones
typedef SpatialClosedCallback =
    void Function(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection);

/// The parts the tests replace: the pool and the resolver as for the other players, the passes for a player, the
/// webcams, the settings file, and the opening of the Windows settings
@immutable
class SpatialPlayerDependencies {
  const SpatialPlayerDependencies({
    this.pool,
    this.resolve,
    this.outputFor,
    this.headSource,
    this.loadSettings,
    this.saveSettings,
    this.openUri,
    this.statsInterval,
    this.framesPerSecond,
    this.hwdecCurrent,
    this.readMpv,
    this.memoryMB,
    this.probeWindow,
    this.probeInterval,
    this.away,
  });

  final PlayerPool? pool;
  final DesktopVideoSourceResolver? resolve;

  /// The Spatial passes for a player, null when the player has no texture
  final SpatialPluginOutput? Function(PlaybackEngine engine)? outputFor;

  /// The webcams; null in the record means the app's tracker (NativeSpatialHeadSource.windows)
  final SpatialHeadSource? Function()? headSource;
  final Future<DesktopSpatialSettings> Function()? loadSettings;
  final Future<void> Function(DesktopSpatialSettings settings)? saveSettings;
  final Future<bool> Function(Uri uri)? openUri;

  /// How often the troubleshooting figures are read
  final Duration? statsInterval;

  /// The video's frame rate, mpv's decoder in use and an mpv property of a player (the measure of the frames)
  final Future<double?> Function(PlaybackEngine engine)? framesPerSecond;
  final Future<String?> Function(PlaybackEngine engine)? hwdecCurrent;
  final Future<String> Function(PlaybackEngine engine, String name)? readMpv;

  /// The process's memory in MiB, for the measure
  final int? Function()? memoryMB;

  /// The playback measured before a verdict, and how often the counts are read (RendererProbeLimits by default)
  final Duration? probeWindow;
  final Duration? probeInterval;

  /// True while nobody can be in front of the computer (Windows locked, display off): the webcam closes
  final ValueListenable<bool>? away;
}

/// The eye layout the passes draw for [selected], the user's or the viewer's choice. Auto, which the phones resolve
/// with what the file declares and then the frame shape, is the frame shape here (SpatialVideoActivity.guessedLayout):
/// a 360° video has two 2:1 eyes, stacked they make a square, side by side a 4:1 frame; a VR180 video two square eyes,
/// stacked a 1:2 frame; a flat video 0.8 to 0.95 wide for one high is two full eyes stacked; anything else side by
/// side.
mkv.SpatialLayout spatialEyeLayout(
  SpatialStereoLayout selected, {
  int? width,
  int? height,
  SpatialProjection projection = SpatialProjection.flat,
}) {
  switch (selected) {
    case SpatialStereoLayout.sideBySide:
      return mkv.SpatialLayout.sideBySide;
    case SpatialStereoLayout.topBottom:
      return mkv.SpatialLayout.topBottom;
    case SpatialStereoLayout.sideBySideSwapped:
      return mkv.SpatialLayout.sideBySideSwapped;
    case SpatialStereoLayout.topBottomSwapped:
      return mkv.SpatialLayout.topBottomSwapped;
    case SpatialStereoLayout.none:
      return mkv.SpatialLayout.none;
    case SpatialStereoLayout.auto:
      break;
  }
  if (width == null || height == null || width <= 0 || height <= 0) {
    return mkv.SpatialLayout.sideBySide;
  }
  final ratio = width / height;
  return switch (projection) {
    SpatialProjection.equirectangular when ratio >= 0.9 && ratio <= 1.1 => mkv.SpatialLayout.topBottom,
    SpatialProjection.equirectangular180 when ratio >= 0.45 && ratio <= 0.55 => mkv.SpatialLayout.topBottom,
    SpatialProjection.flat when ratio >= 0.8 && ratio <= 0.95 => mkv.SpatialLayout.topBottom,
    _ => mkv.SpatialLayout.sideBySide,
  };
}

/// The viewpoint of the mouse at [fraction] of the picture's width, kept within the head's range
double mouseViewpoint(double fraction) =>
    HeadViewpoint.minViewpoint + (HeadViewpoint.maxViewpoint - HeadViewpoint.minViewpoint) * fraction.clamp(0.0, 1.0);

class DesktopSpatialPlayerPage extends ConsumerStatefulWidget {
  const DesktopSpatialPlayerPage({
    super.key,
    required this.args,
    this.onClosed,
    this.dependencies = const SpatialPlayerDependencies(),
  });

  final SpatialPlayerArgs args;
  final SpatialClosedCallback? onClosed;
  final SpatialPlayerDependencies dependencies;

  /// The route DesktopSpatialVideoApi pushes
  static Route<void> route(SpatialPlayerArgs args, {SpatialClosedCallback? onClosed}) => PageRouteBuilder<void>(
    settings: const RouteSettings(name: routeName),
    pageBuilder: (context, _, _) => DesktopSpatialPlayerPage(args: args, onClosed: onClosed),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  static const routeName = 'DesktopSpatialPlayer';

  @override
  ConsumerState<DesktopSpatialPlayerPage> createState() => DesktopSpatialPlayerPageState();
}

@visibleForTesting
class DesktopSpatialPlayerPageState extends ConsumerState<DesktopSpatialPlayerPage> with WidgetsBindingObserver {
  late final MediaKitVideoPlayerController _controller;
  late final ExternalPlayerClosed _closedSignal;
  late final SpatialHeadTracking _tracking;
  late final RendererProbe _probe;
  late final ValueListenable<bool> _away;
  final _visibility = SphericalControlsVisibility();
  final _rootFocus = FocusNode(debugLabel: 'Spatial video');

  SpatialPluginOutput? _output;
  PlaybackEngine? _outputEngine;

  DesktopSpatialSettings _settings = const DesktopSpatialSettings();
  bool _settingsLoaded = false;

  /// What moves the viewpoint on this page (the settings', or the slider under reduced motion)
  SpatialViewpointSource _source = SpatialViewpointSource.head;

  late SpatialStereoLayout _layout = widget.args.layout;
  late SphereCoverage? _coverage = sphereCoverageOfSpatialProjection(widget.args.projection);
  ViewAngles _view = const ViewAngles();

  /// The slider's and the arrow keys' viewpoint, and whether it holds over the head or the mouse
  double _manualViewpoint = 0.5;
  bool _manualHold = false;
  bool _draggingViewpoint = false;

  /// The mouse's viewpoint in "Follow the mouse", null until it moved over the picture
  double? _mouseViewpoint;

  /// The viewpoint sent last, for the slider
  double _viewpoint = 0.5;

  /// A frame is asked for the head's viewpoint: at each sample, and at each frame while the viewpoint eases
  bool _headFrameScheduled = false;

  /// The window was minimised, or Windows locked, while the webcam ran or was about to: it opens again when they come
  /// back
  bool _resumeTracking = false;

  /// The card of the first time shows: what the webcam is for, and whether to use it
  bool _askCamera = false;

  /// The steps down the measure took, and why the last one; the verdicts of the measure, for the tests
  int _stepDowns = 0;
  String? _stepDownReason;
  final _measures = <String>[];

  /// The user went to the camera settings from the privacy message: the webcam is tried again on the way back, once
  /// the window lost the focus to them and got it back
  bool _retryAfterSettings = false;
  bool _leftForSettings = false;

  /// The problem whose message the user closed
  SpatialTrackingProblem? _dismissedProblem;
  bool _framingDismissed = false;
  bool _wasLostTooLong = false;

  /// The passes refused: the video plays as it is, with the message
  bool _flat = false;
  bool _drawing = false;

  /// What tells the user something of the video (flat, transcoded): under the controls
  String? _notice;

  bool _usingFallback = false;
  bool _ready = false;
  bool _closed = false;
  String? _error;
  int? _bufferingPercent;
  StreamSubscription<double>? _bufferingSubscription;
  VideoController? _bufferingSource;
  bool _muted = false;
  Size? _outputSize;

  // The troubleshooting figures
  Timer? _statsTimer;
  mkv.SpatialStats? _stats;
  bool _showDisparity = false;

  SpatialPlayerDependencies get _deps => widget.dependencies;

  @visibleForTesting
  MediaKitVideoPlayerController get controller => _controller;

  @visibleForTesting
  SpatialHeadTracking get tracking => _tracking;

  @visibleForTesting
  SpatialViewpointSource get source => _source;

  @visibleForTesting
  double get viewpoint => _viewpoint;

  @visibleForTesting
  bool get drawing => _drawing;

  @visibleForTesting
  SpatialStereoLayout get layout => _layout;

  /// The passes of the player, null while none is attached
  @visibleForTesting
  SpatialPluginOutput? get output => _output;

  /// How many times the measure of the frames took the passes a step down
  @visibleForTesting
  int get stepDowns => _stepDowns;

  /// Each verdict of the measure of the frames, with what it measured
  @visibleForTesting
  List<String> get measures => List.unmodifiable(_measures);

  /// Whether the card of the first time asks about the webcam
  @visibleForTesting
  bool get askingCamera => _askCamera;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Read now: the page reports its closing from dispose too, where the providers are no longer read
    _closedSignal = ref.read(externalPlayerClosedProvider.notifier);
    _tracking = SpatialHeadTracking(
      source: _deps.headSource != null ? _deps.headSource!() : NativeSpatialHeadSource.windows(),
    );
    _tracking
      ..addListener(_onTracking)
      ..onSample = _scheduleHeadFrame;
    _away = _deps.away ?? DesktopSessionPresence.instance.away;
    _away.addListener(_onAway);
    _probe = RendererProbe(
      stats: () async => (await _output?.stats(reader: _probeReader))?.draws,
      targetFramesPerSecond: () async {
        final engine = _outputEngine;
        return engine == null ? null : (_deps.framesPerSecond ?? mpvVideoFramesPerSecond)(engine);
      },
      memoryMB: _deps.memoryMB ?? () => ProcessInfo.currentRss ~/ (1 << 20),
      measuring: () =>
          _ready &&
          _drawing &&
          _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing &&
          !_controller.buffering.value,
      window: _deps.probeWindow ?? RendererProbeLimits.window,
      interval: _deps.probeInterval ?? RendererProbeLimits.interval,
    );
    _controller = MediaKitVideoPlayerController(
      pool: _deps.pool ?? desktopPlayerPool,
      resolve: _deps.resolve ?? desktopAppVideoResolver(ref),
      label: 'Spatial video',
      prepare: _prepare,
      unprepare: _unprepare,
    );
    _controller.onPlaybackReady.addListener(_onReady);
    _controller.onPlaybackStatusChanged.addListener(_onStatus);
    _controller.onPlaybackPositionChanged.addListener(_onTick);
    _controller.onError.addListener(_onError);
    _controller.buffering.addListener(_onBuffering);
    _controller.videoController.addListener(_onBuffering);
    _controller.onPlaybackEnded.addListener(_onStatus);
    if (widget.args.debugOverlay) {
      _statsTimer = Timer.periodic(_deps.statsInterval ?? const Duration(seconds: 1), (_) => unawaited(_readStats()));
    }
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _settings = await (_deps.loadSettings ?? DesktopSpatialSettingsStore.load)();
    } catch (error) {
      _log.warning('Spatial settings not read: $error');
    }
    if (!mounted) {
      return;
    }
    _settingsLoaded = true;
    _tracking
      ..sensitivity = _settings.sensitivity
      ..reversed = _settings.reverseHead;
    // Head coupled motion bothers some people: with the system's reduced motion the page opens on the slider
    _source = desktopReducedMotion(context) && _settings.source != SpatialViewpointSource.manual
        ? SpatialViewpointSource.manual
        : _settings.source;
    // Windows asks nothing before a desktop app opens the webcam: the first time, the page asks
    _askCamera = _source == SpatialViewpointSource.head && !_settings.cameraAgreed;
    setState(() {});
    if (_source == SpatialViewpointSource.head && !_askCamera) {
      unawaited(_startTracking());
    } else {
      // For the webcam menu: listed, none opened
      unawaited(_tracking.refreshCameras());
    }
    await _controller.setVolume(1);
    if (!mounted) {
      return;
    }
    await _controller.loadVideoSource(sphericalVideoSource(widget.args.url), startAt: widget.args.start);
  }

  Future<void> _startTracking() async {
    if (!mounted || _closed) {
      return;
    }
    if (!_present) {
      // Minimised, locked or the display off (the settings were still being read when it happened): opened when the
      // window and the session come back
      _resumeTracking = true;
      return;
    }
    _dismissedProblem = null;
    _framingDismissed = false;
    await _tracking.start(cameraId: _settings.cameraId);
  }

  /// Whether someone can see the page: the window neither minimised nor hidden, Windows neither locked nor with its
  /// display off
  bool get _present {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused &&
        state != AppLifecycleState.detached &&
        !_away.value;
  }

  /// Windows locked or its display off: the webcam closes, and opens again when they come back
  void _onAway() {
    if (_closed || !mounted) {
      return;
    }
    if (_away.value) {
      if (_tracking.cameraOpen || _tracking.state == SpatialTrackingState.starting) {
        _resumeTracking = true;
        unawaited(_tracking.stop());
      }
    } else if (_resumeTracking && _source == SpatialViewpointSource.head && _present) {
      _resumeTracking = false;
      unawaited(_startTracking());
    }
  }

  /// The answer to the card of the first time
  Future<void> _answerCamera({required bool useWebcam}) async {
    setState(() => _askCamera = false);
    if (useWebcam) {
      await _saveSettings(_settings.copyWith(cameraAgreed: true, source: SpatialViewpointSource.head));
      await _startTracking();
    } else {
      await _setSource(SpatialViewpointSource.mouse);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The window before the first layout: the output is right from the first frame
    _outputSize ??= _physicalSize(MediaQuery.sizeOf(context));
  }

  Size _physicalSize(Size logical) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return Size((logical.width * ratio).roundToDouble(), (logical.height * ratio).roundToDouble());
  }

  SpatialProjection get _projection => _coverage?.toSpatialProjection() ?? SpatialProjection.flat;

  SpatialLook _look() {
    final info = _controller.videoInfo;
    return SpatialLook(
      layout: spatialEyeLayout(_layout, width: info?.width, height: info?.height, projection: _projection),
      projection: _coverage == null ? mkv.SpatialProjection.flat : mkv.SpatialProjection.equirect,
      halfSphere: _coverage == SphereCoverage.half,
    );
  }

  /// Before each open of the file in a player: the Spatial passes on, or the frame as it is with the message
  Future<void> _prepare(PlaybackEngine engine) async {
    if (!mounted || _flat) {
      return;
    }
    if (!identical(engine, _outputEngine)) {
      _output = (_deps.outputFor ?? _outputForEngine)(engine);
      _outputEngine = engine;
    }
    final output = _output;
    if (output == null) {
      _showFlat('no texture');
      return;
    }
    final result = await output.attach(
      look: _look(),
      outputSize: _outputSize ?? const Size(1280, 720),
      viewpoint: _currentViewpoint(),
      view: _view.toPlugin(),
    );
    if (!mounted) {
      // The page closed during the attach, after the adapter's unprepare: the passes off again, so that the pool does
      // not keep the player with them on
      await _unprepare(engine);
      return;
    }
    if (!result.ok) {
      _showFlat(result.reason ?? 'refused');
      return;
    }
    setState(() => _drawing = true);
  }

  static const _probeReader = #probe;
  static const _panelReader = #panel;

  void _startProbe() {
    final output = _output;
    if (output == null || !output.attached || _flat || _closed) {
      return;
    }
    _probe.start(lowestTier: !output.canStepDown, onResult: _onProbe);
  }

  /// What the measure of the frames found (see the top of this file)
  Future<void> _onProbe(ProbeVerdict verdict, ProbeSample sample) async {
    final output = _output;
    final engine = _outputEngine;
    if (output == null || !output.attached || !mounted || _flat || _closed) {
      return;
    }
    _log.info('Spatial measure: $sample, ${verdict.name}');
    _measures.add('${verdict.name}: $sample');
    switch (verdict) {
      case ProbeVerdict.keep:
        return;
      case ProbeVerdict.refused:
        _log.warning('The Spatial passes draw nothing: ${sample.error ?? 'no error given'}');
        await output.detach();
        _showFlat('the passes draw nothing');
        return;
      case ProbeVerdict.stepDown || ProbeVerdict.fail:
        String? hwdec;
        try {
          hwdec = engine == null ? null : await (_deps.hwdecCurrent ?? mpvHwdecCurrent)(engine);
        } catch (_) {
          // Only for the decoder's share of the shortfall
        }
        if (!mounted || !identical(output, _output)) {
          return;
        }
        if (decodeLimited(sample, hwdec: hwdec) && await _playTranscodedInstead(engine, sample, hwdec)) {
          return;
        }
        final reason = '${sample.framesPerSecond.toStringAsFixed(1)} of ${sample.targetFramesPerSecond} fps';
        final step = await output.stepDown();
        if (!mounted || !identical(output, _output)) {
          return;
        }
        if (step == null) {
          if (verdict == ProbeVerdict.fail) {
            await output.detach();
            _showFlat('too slow at the lowest step: $reason');
          }
          return;
        }
        _stepDowns++;
        _stepDownReason = '${step.name}: $reason';
        _log.info('Spatial passes a step down (${step.name}) after $reason');
        setState(() {});
        _startProbe();
    }
  }

  /// The decoder does not keep up with the original: the server's transcoded stream from where the video is, with the
  /// phones' message, as the 360° player does. False when there is none or it plays already.
  Future<bool> _playTranscodedInstead(PlaybackEngine? engine, ProbeSample sample, String? hwdec) async {
    final fallback = widget.args.fallbackUrl;
    if (fallback == null || _usingFallback) {
      return false;
    }
    _usingFallback = true;
    var codec = '?';
    try {
      final name = engine == null
          ? ''
          : (await (_deps.readMpv ?? mpvProperty)(engine, 'current-tracks/video/codec')).trim();
      final mime = mimeOfMpvCodec(name);
      codec = mime != null ? videoCodecLabel(mime) : (name.isEmpty ? '?' : name.toUpperCase());
    } catch (_) {
      // Only for the message
    }
    if (!mounted) {
      return true;
    }
    _log.info('The decoding of the original does not keep up ($sample, hwdec ${hwdec ?? '?'}): transcoded stream');
    final info = _controller.videoInfo;
    _probe.stop();
    _ready = false;
    setState(
      () => _notice = context.t.video_source_switched(
        codec: codec,
        width: '${info?.width ?? '?'}',
        height: '${info?.height ?? '?'}',
      ),
    );
    final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value);
    unawaited(_controller.loadVideoSource(sphericalVideoSource(fallback), startAt: position));
    return true;
  }

  static SpatialPluginOutput? _outputForEngine(PlaybackEngine engine) {
    final videoController = engine.videoController;
    return videoController == null
        ? null
        : SpatialPluginOutput.forController(videoController, maxOutputHeight: DesktopPlayerOptions.maxRenderHeight);
  }

  /// Before the player leaves this page: the passes off
  Future<void> _unprepare(PlaybackEngine engine) async {
    if (identical(engine, _outputEngine)) {
      final output = _output;
      _output = null;
      _outputEngine = null;
      _drawing = false;
      await output?.dispose();
    }
  }

  void _showFlat(String reason) {
    _log.info('The Spatial passes do not draw here ($reason): the video plays as it is');
    _probe.stop();
    _flat = true;
    _drawing = false;
    if (mounted) {
      setState(() => _notice = context.t.desktop_spatial_flat);
    }
  }

  // The viewpoint

  /// The viewpoint now, from whatever moves it
  double _currentViewpoint() {
    if (_manualHold || _draggingViewpoint) {
      return _manualViewpoint;
    }
    return switch (_source) {
      SpatialViewpointSource.head => _tracking.viewpointNow() ?? _manualViewpoint,
      SpatialViewpointSource.mouse => _mouseViewpoint ?? 0.5,
      SpatialViewpointSource.manual => _manualViewpoint,
    };
  }

  void _applyViewpoint() {
    final viewpoint = _currentViewpoint();
    _output?.setViewpoint(viewpoint);
    if ((viewpoint - _viewpoint).abs() > 0.004 && mounted) {
      // The slider follows when it shows; otherwise nothing of the page needs a new frame
      final rebuild = _sliderVisible;
      _viewpoint = viewpoint;
      if (rebuild) {
        setState(() {});
      }
    } else {
      _viewpoint = viewpoint;
    }
  }

  /// The head's viewpoint is read once per Flutter frame: a frame is asked for at each new sample, and frame after
  /// frame while the viewpoint eases by itself (a face lost or found again); nothing runs while the head rests
  void _scheduleHeadFrame() {
    if (_headFrameScheduled || !mounted || _closed) {
      return;
    }
    if (_manualHold || _draggingViewpoint || _source != SpatialViewpointSource.head) {
      return;
    }
    if (!_tracking.isAnimating()) {
      // A head at rest jitters by a few thousandths: no frame is asked for a change the plugin would not draw
      final now = _tracking.viewpointNow();
      if (now != null && (now - _viewpoint).abs() < SpatialPluginOutput.viewpointDeadBand) {
        return;
      }
    }
    _headFrameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _headFrameScheduled = false;
      if (!mounted || _closed || !_tracking.cameraOpen) {
        return;
      }
      if (!_manualHold && !_draggingViewpoint && _source == SpatialViewpointSource.head) {
        _applyViewpoint();
      }
      if (_tracking.isAnimating()) {
        _scheduleHeadFrame();
      }
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  void _onTracking() {
    if (!mounted || _closed) {
      return;
    }
    // The head took over again after the slider was offered: it moves the viewpoint again
    if (_wasLostTooLong && !_tracking.lostTooLong && _tracking.cameraOpen) {
      _manualHold = false;
    }
    _wasLostTooLong = _tracking.lostTooLong;
    if (!_tracking.cameraOpen && _source == SpatialViewpointSource.head && !_manualHold) {
      // The head stopped: the slider takes the viewpoint where the head left it
      _manualViewpoint = _viewpoint;
      _applyViewpoint();
    }
    setState(() {});
  }

  void _setManualViewpoint(double viewpoint, {bool hold = true}) {
    _manualViewpoint = viewpoint.clamp(0.0, 1.0);
    if (hold && _source != SpatialViewpointSource.manual) {
      _manualHold = true;
    }
    _applyViewpoint();
    setState(() {});
  }

  void _nudge(double step) => _setManualViewpoint(_currentViewpoint() + step);

  /// Head tracking centres on the next face, the slider and the keys hand the viewpoint back, and a 360° video turns
  /// back to where it started
  void _recenter() {
    _tracking.recenter();
    _manualHold = false;
    if (_coverage != null) {
      _view = const ViewAngles();
      _output?.setView(_view.toPlugin(), moving: false);
    }
    _applyViewpoint();
    setState(() {});
  }

  bool get _sliderVisible =>
      widget.args.debugOverlay ||
      _draggingViewpoint ||
      _manualHold ||
      switch (_source) {
        SpatialViewpointSource.head =>
          _tracking.state == SpatialTrackingState.off ||
              _tracking.state == SpatialTrackingState.failed ||
              _tracking.lostTooLong,
        SpatialViewpointSource.mouse => false,
        SpatialViewpointSource.manual => true,
      };

  Future<void> _setSource(SpatialViewpointSource source) async {
    if (source == _source) {
      return;
    }
    _source = source;
    _manualHold = false;
    _askCamera = false;
    if (source == SpatialViewpointSource.head) {
      // Chosen in the menu: the webcam is the user's choice
      _settings = _settings.copyWith(cameraAgreed: true);
      unawaited(_startTracking());
    } else {
      await _tracking.stop();
    }
    if (!mounted) {
      return;
    }
    _applyViewpoint();
    setState(() {});
    await _saveSettings(_settings.copyWith(source: source));
  }

  Future<void> _setReversed(bool reversed) async {
    _tracking.reversed = reversed;
    setState(() {});
    await _saveSettings(_settings.copyWith(reverseHead: reversed));
  }

  Future<void> _chooseCamera(HeadCamera camera) async {
    _askCamera = false;
    _settings = _settings.copyWith(cameraId: camera.id, cameraAgreed: true);
    if (_source != SpatialViewpointSource.head || _tracking.camera != camera || !_tracking.cameraOpen) {
      _source = SpatialViewpointSource.head;
      _manualHold = false;
      await _tracking.stop();
      unawaited(_startTracking());
    }
    await _saveSettings(_settings.copyWith(source: SpatialViewpointSource.head));
    if (mounted) {
      setState(() {});
    }
  }

  void _setSensitivity(double value) {
    _tracking.sensitivity = value;
  }

  Future<void> _saveSensitivity() => _saveSettings(_settings.copyWith(sensitivity: _tracking.sensitivity));

  Future<void> _saveSettings(DesktopSpatialSettings settings) async {
    _settings = settings;
    try {
      await (_deps.saveSettings ?? DesktopSpatialSettingsStore.save)(settings);
    } catch (error) {
      _log.warning('Spatial settings not saved: $error');
    }
  }

  Future<void> _openSettings(Uri uri) async {
    if (uri == cameraPrivacySettings) {
      _retryAfterSettings = true;
    }
    try {
      await (_deps.openUri ?? launchUrl)(uri);
    } catch (error) {
      _log.warning('The settings of Windows did not open: $error');
    }
  }

  // The window

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) {
      return;
    }
    if (state != AppLifecycleState.resumed && _retryAfterSettings) {
      // The settings of Windows took the focus
      _leftForSettings = true;
    }
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached:
        // Minimised: the webcam closes (its light goes off) and opens again when the window comes back
        if (_tracking.cameraOpen || _tracking.state == SpatialTrackingState.starting) {
          _resumeTracking = true;
          unawaited(_tracking.stop());
        }
      case AppLifecycleState.inactive || AppLifecycleState.resumed:
        // Back from the settings the privacy message opened: tried once more, never in a loop
        final retry =
            state == AppLifecycleState.resumed &&
            _leftForSettings &&
            _tracking.problem == SpatialTrackingProblem.cameraOff;
        if (state == AppLifecycleState.resumed && _leftForSettings) {
          _retryAfterSettings = false;
          _leftForSettings = false;
        }
        if ((_resumeTracking || retry) && _source == SpatialViewpointSource.head) {
          _resumeTracking = false;
          unawaited(_startTracking());
        }
    }
  }

  // The video

  void _onReady() {
    if (_ready) {
      return;
    }
    _ready = true;
    // The frame shape is known: Auto may pick another layout than the one guessed without it, and the frame mpv draws
    // into takes the size the eyes use; then the frames are measured
    final output = _output;
    if (output != null && output.attached) {
      final info = _controller.videoInfo;
      final size = info == null || info.width <= 0 || info.height <= 0
          ? null
          : Size(info.width.toDouble(), info.height.toDouble());
      unawaited(output.setLook(_look(), videoSize: size));
      _startProbe();
    }
    if (widget.args.autoplay) {
      unawaited(_controller.play());
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _onStatus() {
    _visibility.playing = _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing;
    if (mounted) {
      setState(() {});
    }
  }

  void _onTick() {
    if (mounted && _visibility.visible) {
      setState(() {});
    }
  }

  void _onError() {
    final error = _controller.onError.value;
    if (error == null || !mounted) {
      return;
    }
    final fallback = widget.args.fallbackUrl;
    if (fallback != null && !_usingFallback) {
      // As the phones' players: the server's transcoded stream when the original cannot be played here
      _usingFallback = true;
      _ready = false;
      _probe.stop();
      setState(() => _notice = context.t.desktop_video_360_transcoded);
      final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value);
      unawaited(_controller.loadVideoSource(sphericalVideoSource(fallback), startAt: position));
      return;
    }
    setState(() => _error = context.t.errors.unable_to_play_video);
  }

  void _onBuffering() {
    final source = _controller.videoController.value;
    if (!identical(source, _bufferingSource)) {
      unawaited(_bufferingSubscription?.cancel());
      _bufferingSource = source;
      _bufferingSubscription = source?.player.stream.bufferingPercentage.listen((percent) {
        if (_controller.buffering.value && mounted) {
          setState(() => _bufferingPercent = percent.clamp(0, 100).round());
        }
      });
    }
    final buffering = _controller.buffering.value;
    if (mounted) {
      setState(() => _bufferingPercent = buffering ? (_bufferingPercent ?? 0) : null);
    }
  }

  Future<void> _readStats() async {
    final stats = await _output?.stats(reader: _panelReader);
    if (mounted && stats != null) {
      setState(() => _stats = stats);
    }
  }

  Future<void> _playPause() async {
    if (_controller.onPlaybackStatusChanged.value == PlaybackStatus.playing) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  Future<void> _skip(Duration step) async {
    final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value) + step;
    await _controller.seekTo(position.inMilliseconds);
  }

  Future<void> _toggleMute() async {
    _muted = !_muted;
    await _controller.setVolume(_muted ? 0 : 1);
    if (mounted) {
      setState(() {});
    }
  }

  void _setLayout(SpatialStereoLayout layout) {
    if (layout == _layout) {
      return;
    }
    setState(() => _layout = layout);
    unawaited(_output?.setLook(_look()));
  }

  void _toggleCoverage() {
    final coverage = _coverage;
    if (coverage == null) {
      return;
    }
    setState(() => _coverage = coverage.next);
    unawaited(_output?.setLook(_look()));
  }

  Future<void> _toggleDisparity() async {
    final show = !_showDisparity;
    setState(() => _showDisparity = show);
    await _output?.setDebug(disparityMap: show);
  }

  void _close() => unawaited(Navigator.of(context).maybePop());

  /// The route closed: the webcam closes, the opener hears where the video was and what was shown, and the viewer
  /// behind takes its video back
  void _reportClosed() {
    if (_closed) {
      return;
    }
    _closed = true;
    unawaited(_tracking.stop());
    final status = _controller.onPlaybackStatusChanged.value;
    final positionMs = _controller.onPlaybackPositionChanged.value;
    final wasPlaying = status == PlaybackStatus.playing || (!_ready && widget.args.autoplay && _error == null);
    try {
      widget.onClosed?.call(positionMs < 0 ? 0 : positionMs, wasPlaying, _layout, _projection);
    } catch (error, stack) {
      _log.warning('The opener of the Spatial player did not take its closing', error, stack);
    }
    // After the frame: a provider does not change while the widget tree is being finalised
    final signal = _closedSignal;
    unawaited(Future.microtask(signal.raise));
  }

  // The pointer

  void _onPanStart(DragStartDetails details) => _visibility.dragStarted();

  void _onPanUpdate(DragUpdateDetails details) {
    if (_coverage == null) {
      return;
    }
    final height = context.size?.height ?? 0;
    _view = _view.dragged(details.delta, height);
    _output?.setView(_view.toPlugin(), moving: true);
  }

  void _onPanEnd(DragEndDetails details) {
    _visibility.dragEnded();
    if (_coverage != null) {
      _output?.setView(_view.toPlugin(), moving: false);
    }
  }

  void _onPointerSignal(PointerSignalEvent event) {
    final factor = _coverage == null ? null : wheelZoomFactor(event);
    if (factor != null) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        _view = _view.zoomed(factor);
        _output?.setView(_view.toPlugin(), moving: true);
      });
    }
  }

  /// The pointer over the picture: in "Follow the mouse" it moves the viewpoint, and only the edges where the bars
  /// are show the controls; otherwise any move shows them
  void _onHover(PointerHoverEvent event, Size size) {
    if (_source != SpatialViewpointSource.mouse || size.width <= 0) {
      _visibility.activity();
      return;
    }
    final edge = size.height * 0.18;
    if (event.localPosition.dy < edge || event.localPosition.dy > size.height - edge) {
      _visibility.activity();
    }
    _mouseViewpoint = mouseViewpoint(event.localPosition.dx / size.width);
    if (!_manualHold) {
      _applyViewpoint();
    }
  }

  static const _viewpointStep = 0.05;

  /// The keys of the Spatial player: the arrows move the viewpoint, R recenters, and the 360° player's keys for the
  /// video. F, F11, Escape and the mouse's back button are the window's (DesktopShell).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (showsControls(event)) {
      _visibility.activity();
    }
    final key = event.logicalKey;
    // A control that has the focus keeps its own keys: Space and Enter press it, the arrows move the time bar
    final onView = node.hasPrimaryFocus;
    final press = event is KeyDownEvent || event is KeyRepeatEvent;
    if (onView && (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight)) {
      if (press) {
        _nudge(key == LogicalKeyboardKey.arrowLeft ? -_viewpointStep : _viewpointStep);
      }
      return KeyEventResult.handled;
    }
    if (!isRemotePress(event)) {
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyR && !isTypingText()) {
      _recenter();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space && onView) {
      unawaited(_playPause());
      return KeyEventResult.handled;
    }
    if (remotePlayPauseKeys.contains(key)) {
      final playing = _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing;
      if (remotePlayPauseWantsPlay(key, isPlaying: playing) != playing) {
        unawaited(_playPause());
      }
      return KeyEventResult.handled;
    }
    if (onView && remoteOkKeys.contains(key)) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (remoteSeekForwardKeys.contains(key)) {
      unawaited(_skip(remoteSeekStep));
      return KeyEventResult.handled;
    }
    if (remoteSeekBackwardKeys.contains(key)) {
      unawaited(_skip(-remoteSeekStep));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      unawaited(_controller.seekTo(0));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM && !isTypingText()) {
      unawaited(_toggleMute());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _away.removeListener(_onAway);
    _probe.stop();
    // The page hears nothing more of the tracking before the webcam closes below
    _tracking
      ..removeListener(_onTracking)
      ..onSample = null;
    _reportClosed();
    _statsTimer?.cancel();
    // The webcam closes in the background (its light goes off once the capture thread ended)
    _tracking.dispose();
    unawaited(_bufferingSubscription?.cancel());
    _controller.onPlaybackReady.removeListener(_onReady);
    _controller.onPlaybackStatusChanged.removeListener(_onStatus);
    _controller.onPlaybackPositionChanged.removeListener(_onTick);
    _controller.onError.removeListener(_onError);
    _controller.buffering.removeListener(_onBuffering);
    _controller.videoController.removeListener(_onBuffering);
    _controller.onPlaybackEnded.removeListener(_onStatus);
    // The passes off and the player back to the pool, in this order (the adapter's unprepare)
    _controller.dispose();
    _visibility.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  /// The message of a tracking problem the user has not closed, with its button
  SpatialMessage? _trackingMessage(Translations t) {
    final problem = _tracking.problem;
    if (_source != SpatialViewpointSource.head) {
      return null;
    }
    if (problem != null && problem != _dismissedProblem) {
      return SpatialMessage(
        key: 'problem_${problem.name}',
        text: switch (problem) {
          SpatialTrackingProblem.cameraOff => t.desktop_spatial_camera_off,
          SpatialTrackingProblem.mediaFeaturePack => t.desktop_spatial_media_feature_pack,
          SpatialTrackingProblem.noCamera => t.desktop_spatial_no_camera,
          SpatialTrackingProblem.cameraBusy => t.desktop_spatial_camera_busy,
          SpatialTrackingProblem.cameraLost => t.desktop_spatial_camera_lost,
          SpatialTrackingProblem.failed => t.desktop_spatial_tracker_failed,
        },
        action: problem == SpatialTrackingProblem.cameraOff ? t.desktop_spatial_camera_settings : null,
        onAction: problem == SpatialTrackingProblem.cameraOff
            ? () => unawaited(_openSettings(cameraPrivacySettings))
            : null,
        onClose: () => setState(() => _dismissedProblem = problem),
      );
    }
    if (_tracking.cameraOpen && _tracking.framing == AutoFramingState.stuckOn && !_framingDismissed) {
      return SpatialMessage(
        key: 'auto_framing',
        text: t.desktop_spatial_auto_framing,
        action: t.desktop_spatial_camera_settings,
        onAction: () => unawaited(_openSettings(cameraSettings)),
        onClose: () => setState(() => _framingDismissed = true),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final duration = Duration(milliseconds: _controller.videoInfo?.duration ?? 0);
    final notice = _notice;
    final error = _error;
    final info = _controller.videoInfo;
    final trackingRunning = _source == SpatialViewpointSource.head && _tracking.cameraOpen;
    final debug = widget.args.debugOverlay;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _reportClosed();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: TvFocusRing(
          child: Focus(
            focusNode: _rootFocus,
            autofocus: true,
            onKeyEvent: _onKey,
            child: ListenableBuilder(
              listenable: _visibility,
              builder: (context, child) => MouseRegion(
                cursor: _visibility.cursorHidden && _source != SpatialViewpointSource.mouse
                    ? SystemMouseCursors.none
                    : MouseCursor.defer,
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      _onLayoutSize(constraints.biggest);
                      return MouseRegion(
                        onHover: (event) => _onHover(event, constraints.biggest),
                        child: Listener(
                          onPointerSignal: _onPointerSignal,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: _onPanStart,
                            onPanUpdate: _onPanUpdate,
                            onPanEnd: _onPanEnd,
                            onTap: _visibility.toggle,
                            onDoubleTap: () => unawaited(
                              ref.read(desktopFullScreenProvider.notifier).toggle(from: ModalRoute.of(context)),
                            ),
                            child: _video(),
                          ),
                        ),
                      );
                    },
                  ),
                  if (error != null)
                    Center(
                      child: Text(error, style: const TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  SpatialControls(
                    visibility: _visibility,
                    model: SpatialControlsModel(
                      title: widget.args.title,
                      controller: _controller,
                      playing: _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing,
                      position: Duration(milliseconds: _controller.onPlaybackPositionChanged.value),
                      duration: duration,
                      bufferingPercent: _bufferingPercent,
                      muted: _muted,
                      layout: _layout,
                      autoLayout: spatialEyeLayout(
                        SpatialStereoLayout.auto,
                        width: info?.width,
                        height: info?.height,
                        projection: _projection,
                      ),
                      coverage: _coverage,
                      source: _source,
                      cameras: _tracking.cameras ?? const [],
                      camera: _tracking.camera,
                      cameraOpen: _tracking.cameraOpen,
                      trackingRunning: trackingRunning,
                      faceLost: trackingRunning && _tracking.faceLost,
                      sensitivity: _tracking.sensitivity,
                      showSlider: _sliderVisible,
                      viewpoint: _sliderVisible ? _currentViewpoint() : _viewpoint,
                      showRecenter: trackingRunning || _coverage != null || _manualHold,
                      debug: debug,
                      showDisparity: _showDisparity,
                      onClose: _close,
                      onPlayPause: () => unawaited(_playPause()),
                      onSeek: (position) => unawaited(_controller.seekTo(position.inMilliseconds)),
                      onSkip: (step) => unawaited(_skip(step)),
                      onMute: () => unawaited(_toggleMute()),
                      onLayout: _setLayout,
                      onCoverage: _toggleCoverage,
                      onSource: (source) => unawaited(_setSource(source)),
                      onCamera: (camera) => unawaited(_chooseCamera(camera)),
                      reversed: _tracking.reversed,
                      onReversed: (reversed) => unawaited(_setReversed(reversed)),
                      onSensitivity: _setSensitivity,
                      onSensitivityEnd: () => unawaited(_saveSensitivity()),
                      onViewpointStart: () => setState(() => _draggingViewpoint = true),
                      onViewpoint: (value) => _setManualViewpoint(value),
                      onViewpointEnd: () => setState(() => _draggingViewpoint = false),
                      onRecenter: _recenter,
                      onDisparity: () => unawaited(_toggleDisparity()),
                    ),
                  ),
                  if (_tracking.cameraOpen)
                    Positioned(
                      top: 60,
                      right: 14,
                      child: Tooltip(
                        message: t.desktop_spatial_camera_on,
                        child: Semantics(
                          label: t.desktop_spatial_camera_on,
                          child: const Icon(
                            Icons.videocam,
                            key: Key('spatial_camera_on'),
                            color: Colors.white70,
                            size: 18,
                            shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                          ),
                        ),
                      ),
                    ),
                  if (debug) Positioned(top: 64, left: 12, child: _debugOverlay()),
                  if (_askCamera)
                    SpatialCameraIntro(
                      onUseWebcam: () => unawaited(_answerCamera(useWebcam: true)),
                      onFollowMouse: () => unawaited(_answerCamera(useWebcam: false)),
                    ),
                  SpatialMessages(
                    messages: [
                      ?_trackingMessage(t),
                      if (notice != null)
                        SpatialMessage(key: 'notice', text: notice, onClose: () => setState(() => _notice = null)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _debugOverlay() {
    final stats = _stats;
    final sample = _tracking.latest;
    final info = _tracking.cameraOpen ? _tracking.info() : null;
    String fixed(double value, [int digits = 2]) => value.isFinite ? value.toStringAsFixed(digits) : '-';
    final lines = <String>[];
    if (stats != null) {
      final timing = stats.gpuTimer ? 'GPU timer' : 'CPU timing';
      lines
        ..add(
          '${stats.quality.name}, ${stats.renderFps.toStringAsFixed(1)} draws/s, '
          '${stats.disparityFps.toStringAsFixed(1)} estimations/s, ${stats.renderMs.toStringAsFixed(1)} ms ($timing)',
        )
        ..add(
          'disparity ${stats.disparityWidth} x ${stats.disparityHeight}, eyes ${stats.eyeWidth} x '
          '${stats.eyeHeight}, ${stats.halfFloatMaps ? 'RGBA16F' : 'RGBA8'}, ${stats.stereo ? 'stereo' : 'one eye'}',
        );
    } else {
      lines.add(_drawing ? 'passes: no figure yet' : 'passes: off');
    }
    final output = _output;
    if (stats != null && output != null) {
      final step = output.look.projection == mkv.SpatialProjection.equirect
          ? 'tier ${output.frameTier?.name ?? 'default'}'
          : 'share ${SpatialPluginOutput.flatFrameScales[output.flatStep]}';
      lines.add(
        'frame ${stats.draws.frameWidth} x ${stats.draws.frameHeight} ($step${output.forcedLow ? ', LOW held' : ''}), '
        '$_stepDowns step(s) down${_stepDownReason == null ? '' : ', last $_stepDownReason'}',
      );
    }
    lines.add('viewpoint ${fixed(_viewpoint)} (${_source.name}${_manualHold ? ', held' : ''})');
    if (sample != null) {
      final detection = (sample.detectUs / 1000).toStringAsFixed(1);
      lines.add('head x ${fixed(sample.headX)}, ${sample.state.name}, detection $detection ms');
    }
    if (info != null) {
      final fps = info.fps?.toStringAsFixed(0) ?? '?';
      lines.add(
        'webcam ${info.width} x ${info.height} ${info.nativeFourcc} $fps fps, detector ${info.detector.name}, '
        'framing ${_tracking.framing.name}',
      );
    }
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            lines.join('\n'),
            key: const Key('spatial_debug'),
            style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
          ),
        ),
      ),
    );
  }

  void _onLayoutSize(Size logical) {
    if (!logical.isFinite || logical.isEmpty) {
      return;
    }
    final size = _physicalSize(logical);
    if (size == _outputSize) {
      return;
    }
    _outputSize = size;
    _output?.setOutputSize(size);
  }

  Widget _video() {
    if (!desktopVideoAvailable && _deps.pool == null) {
      return const SizedBox.expand();
    }
    return ValueListenableBuilder<VideoController?>(
      valueListenable: _controller.videoController,
      builder: (context, videoController, _) => videoController == null
          ? const SizedBox.expand()
          : Video(
              key: ObjectKey(videoController),
              controller: videoController,
              controls: NoVideoControls,
              // A flat output takes the shape of one eye inside the window (the plugin), letterboxed here; a 360°
              // view fills the window
              fit: _coverage != null && _drawing ? BoxFit.fill : BoxFit.contain,
              fill: Colors.black,
              filterQuality: FilterQuality.medium,
              wakelock: true,
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
            ),
    );
  }

  /// Whether the settings were read, for the tests
  @visibleForTesting
  bool get settingsLoaded => _settingsLoaded;
}
