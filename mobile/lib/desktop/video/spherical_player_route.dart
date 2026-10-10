// The 360° video player of the computers (design 2.6): what SphericalActivity is on Android and
// SphericalVideoViewController on iOS, as a route of the app's window. DesktopSphericalVideoApi.open pushes it and
// returns at once, as the native open starts an activity.
//
// The page plays through the same pooled player and controller adapter as the flat player (a 360° video is one
// player of the pool, reused rather than made again: an 8K player decoding without copy keeps about 1.3 GB of GPU
// memory after its disposal, DP1 section 3.4), and draws through renderer C (render/plugin_renderer.dart), turned on
// before each open of the file so that the first frame is already the view. The view moves by uniforms of the
// plugin's pass only, at most once per Flutter frame however fast the mouse moves (DP1: nothing of mpv changes while
// the view moves, so no 30 a second cap is needed); a paused video is redrawn by the plugin alone.
//
// What draws, in order (render/sphere_renderer.dart): renderer C at the tier the probe kept or its GPU's start tier, a
// tier down when the probe measures that it does not keep up, then the flat frame with a message. Renderer B is not in
// the chain yet.
//
// What the page does that the phones' players do too: the 3D cycle and the 180 and 360 switch, the audio track, the
// buffering with its percentage, the switch to the server's transcoded stream when the original fails, and for a raw
// file of two streams (two tracks, or the two files of a pair) both lenses stacked in one mpv core when this computer
// keeps up, else the phones' fallback chain with their messages (raw_two_streams.dart, raw_two_stream_switch.dart).
// On close: the layout and coverage shown last go to the session through PlayerEventsHub, and
// externalPlayerClosedProvider lets the viewer behind take its video back.
//
// Nothing of a source reaches libmpv but a path of this computer or a media bridge URL: the headers of open() are
// dropped, the server's videos go through the bridge (desktop_video_sources.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/video/decoder_measure.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart';
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart';
import 'package:immich_mobile/desktop/video/raw_two_stream_switch.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/desktop/video/render/renderer_probe.dart';
import 'package:immich_mobile/desktop/video/render/sphere_renderer.dart';
import 'package:immich_mobile/desktop/video/spherical_controls.dart';
import 'package:immich_mobile/desktop/window/desktop_shortcuts.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/player_events_hub.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_keys.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:native_video_player/native_video_player.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _log = Logger('SphericalPlayer');

/// What SphericalVideoApi.open gives the player, the headers left out (see the top of this file)
@immutable
class SphericalPlayerArgs {
  const SphericalPlayerArgs({
    required this.url,
    required this.title,
    this.layout = StereoLayout.mono,
    this.coverage = SphereCoverage.full,
    this.fallbackUrl,
    this.rawProjection,
    this.errorMessage,
  });

  /// A file:// URI of this computer, a path, a media bridge URL or a URL of the Immich server
  final String url;
  final String title;
  final StereoLayout layout;
  final SphereCoverage coverage;

  /// The server's transcoded stream, played when the original fails; null when there is none
  final String? fallbackUrl;

  /// The rawProjection JSON of a raw camera file (RawVideoPlan.toNativeJson), null for an equirectangular video
  final String? rawProjection;

  /// The translated "unable to play" text the caller gave, null for the app's own
  final String? errorMessage;
}

/// The source of the controller for [url]: a file of this computer for file:// URIs and paths, else a network URL
VideoSource sphericalVideoSource(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
    return VideoSource(path: url, type: VideoSourceType.network, headers: const {});
  }
  return VideoSource(path: url, type: VideoSourceType.file, headers: const {});
}

/// The parts the tests replace: the pool and the resolver as for the flat player, renderer C for a player, mpv's
/// properties and commands, its frame rate, the version of the app the probe's result is kept for, and for raw files
/// of two streams the switch and whether a file can be read
@immutable
class SphericalPlayerDependencies {
  const SphericalPlayerDependencies({
    this.pool,
    this.resolve,
    this.pluginFor,
    this.setMpv,
    this.mpvCommand,
    this.readMpv,
    this.framesPerSecond,
    this.appVersion,
    this.pluginSupported,
    this.memoryMB,
    this.hwdecCurrent,
    this.twoStreams,
    this.readable,
    this.firstFrameTimeout,
    this.now,
  });

  final PlayerPool? pool;
  final DesktopVideoSourceResolver? resolve;

  /// Renderer C for a player, null when the player has no texture
  final PluginRenderer? Function(PlaybackEngine engine)? pluginFor;

  /// Sets an mpv property of the player (vid, hwdec, lavfi-complex, external-files)
  final Future<void> Function(PlaybackEngine engine, String name, String value)? setMpv;
  final Future<void> Function(PlaybackEngine engine, List<String> command)? mpvCommand;
  final Future<String> Function(PlaybackEngine engine, String name)? readMpv;
  final Future<double?> Function(PlaybackEngine engine)? framesPerSecond;
  final Future<String> Function()? appVersion;
  final bool? pluginSupported;
  final int? Function()? memoryMB;

  /// mpv's hwdec-current, for the troubleshooting page
  final Future<String?> Function(PlaybackEngine engine)? hwdecCurrent;

  /// The switch of a raw file of two streams (raw_two_stream_switch.dart)
  final TwoStreamSwitch Function()? twoStreams;

  /// Whether a file can be read: the LRV copy next to a raw file, the other file of a pair (rawUrlReadable)
  final Future<bool> Function(String url)? readable;

  /// How long two stacked streams may take to show their first frame before the next step of the chain is taken
  final Duration? firstFrameTimeout;

  /// The clock of the measure of two stacked streams
  final DateTime Function()? now;
}

class DesktopSphericalPlayerPage extends ConsumerStatefulWidget {
  const DesktopSphericalPlayerPage({
    super.key,
    required this.args,
    this.dependencies = const SphericalPlayerDependencies(),
  });

  final SphericalPlayerArgs args;
  final SphericalPlayerDependencies dependencies;

  /// The route DesktopSphericalVideoApi pushes
  static Route<void> route(SphericalPlayerArgs args) => PageRouteBuilder<void>(
    settings: const RouteSettings(name: routeName),
    pageBuilder: (context, _, _) => DesktopSphericalPlayerPage(args: args),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  static const routeName = 'DesktopSphericalPlayer';

  @override
  ConsumerState<DesktopSphericalPlayerPage> createState() => DesktopSphericalPlayerPageState();
}

@visibleForTesting
class DesktopSphericalPlayerPageState extends ConsumerState<DesktopSphericalPlayerPage> with TickerProviderStateMixin {
  late final MediaKitVideoPlayerController _controller;
  late final ExternalPlayerClosed _closedSignal;
  final _visibility = SphericalControlsVisibility();
  final _rootFocus = FocusNode(debugLabel: '360 video');
  late final RendererProbe _probe;

  late ProjectionParams _params;
  ViewAngles _view = const ViewAngles();

  /// What draws now, null until the first open decided it
  SphereRendering? _rendering;
  PluginRenderer? _renderer;
  PlaybackEngine? _rendererEngine;
  SphereRendererSettings _settings = const SphereRendererSettings();

  /// Why the probe went down a tier, kept with the tier it then keeps
  String? _stepDownReason;
  String? _appVersion;

  /// What tells the user why the view is flat, or that one lens shows: under the controls
  String? _notice;

  /// The players whose mpv options a raw file changed (vid, hwdec, lavfi-complex, external-files): given back to the
  /// pool as it gave them
  final _rawOptionsSet = Expando<bool>('raw options');

  /// A raw file of two streams, or with an LRV copy: its streams, its fallback chain and the step playing now
  RawStreams? _raw;
  RawPlaybackChain? _chain;
  RawStep? _step;
  late final TwoStreamSwitch _switch = (_deps.twoStreams ?? TwoStreamSwitch.new)();
  TwoStreamSampler? _sampler;
  Timer? _firstFrameTimer;

  /// The other file of a stacked pair, as the player reads it (a path, or a bridge URL)
  String? _externalResolved;
  bool _stepping = false;

  /// The physical size of the output, the window's
  Size? _outputSize;

  bool _usingFallback = false;
  bool _ready = false;
  bool _closed = false;
  String? _error;
  int? _bufferingPercent;
  StreamSubscription<double>? _bufferingSubscription;
  VideoController? _bufferingSource;
  bool _muted = false;

  // The view moves on after a drag, as on the 360° photo viewer, and the arrows turn it while held
  late final Ticker _inertia = createTicker(_onInertiaTick);
  Offset _inertiaVelocity = Offset.zero;
  Duration _lastInertiaTick = Duration.zero;
  late final Ticker _keyTurn = createTicker(_onKeyTurnTick);
  final _heldArrows = <LogicalKeyboardKey, Duration>{};
  Duration _keyTurnNow = Duration.zero;

  /// The view now, for the tests
  @visibleForTesting
  ViewAngles get view => _view;

  @visibleForTesting
  SphereRendering? get rendering => _rendering;

  @visibleForTesting
  ProjectionParams get params => _params;

  @visibleForTesting
  MediaKitVideoPlayerController get controller => _controller;

  /// The step of a raw file's chain playing now, for the tests
  @visibleForTesting
  RawStep? get rawStep => _step;

  SphericalPlayerDependencies get _deps => widget.dependencies;

  @override
  void initState() {
    super.initState();
    // Read now: the page reports its closing from dispose too, where the providers are no longer read
    _closedSignal = ref.read(externalPlayerClosedProvider.notifier);
    _params = ProjectionParams(layout: widget.args.layout, coverage: widget.args.coverage);
    try {
      _params = ProjectionParams.fromOpen(
        layout: widget.args.layout,
        coverage: widget.args.coverage,
        rawProjection: widget.args.rawProjection,
      );
    } on FormatException catch (error) {
      // The phones' players refuse such a JSON too; the frame then shows flat, as recorded
      _log.warning('rawProjection not usable, the video plays flat: $error');
      _rendering = const SphereRendering.flat(FlatReason.refused);
    }
    _probe = RendererProbe(
      stats: () async => _renderer?.stats(),
      targetFramesPerSecond: () async {
        final engine = _rendererEngine;
        return engine == null ? null : (_deps.framesPerSecond ?? _mpvFramesPerSecond)(engine);
      },
      memoryMB: _deps.memoryMB ?? () => ProcessInfo.currentRss ~/ (1 << 20),
      measuring: () =>
          _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing && !_controller.buffering.value,
    );
    _controller = MediaKitVideoPlayerController(
      pool: _deps.pool ?? desktopPlayerPool,
      resolve: _deps.resolve ?? desktopAppVideoResolver(ref),
      label: '360 video',
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
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _settings = await SphereRendererStore.load();
      _appVersion = await (_deps.appVersion ?? _packageVersion)();
    } catch (error) {
      _log.warning('360° renderer settings not read: $error');
    }
    if (!mounted) {
      return;
    }
    await _controller.setVolume(1);
    var url = widget.args.url;
    final step = await _firstRawStep();
    if (!mounted) {
      return;
    }
    if (step != null) {
      _step = step;
      url = step.url;
      _log.info('Raw file: $step');
    }
    await _controller.loadVideoSource(sphericalVideoSource(url));
  }

  /// The first step of a raw file of two streams (see raw_two_streams.dart), null for any other video
  Future<RawStep?> _firstRawStep() async {
    final RawStreams? raw;
    try {
      raw = (_rendering?.isFlat ?? false) ? null : _params.rawStreams;
    } on FormatException catch (error) {
      _log.warning('rawProjection tracks not usable: $error');
      return null;
    }
    if (raw == null || !raw.twoStreams) {
      return null;
    }
    _raw = raw;
    final chain = _chain = RawPlaybackChain(raw: raw, url: widget.args.url, fallbackUrl: widget.args.fallbackUrl);
    // Looked for while the original opens: a share may take a moment to answer, and only a failure needs it
    unawaited(
      findLowResolutionCopy(widget.args.url, readable: _deps.readable ?? rawUrlReadable).then(
        (found) => chain.lowResolutionUrl = found,
        onError: (Object error) => _log.info('No LRV copy looked for: $error'),
      ),
    );
    TwoStreamChoice choice;
    try {
      choice = await _switch.choose(raw);
    } catch (error) {
      choice = (hwdec: TwoStreamPaths.software, reason: 'the switch failed ($error), software tried');
    }
    return chain.initial(choice);
  }

  static Future<String> _packageVersion() async {
    final info = await PackageInfo.fromPlatform();
    return '${info.version}+${info.buildNumber}';
  }

  static Future<double?> _mpvFramesPerSecond(PlaybackEngine engine) async {
    final native = engine.videoController?.player.platform;
    if (native is! NativePlayer) {
      return null;
    }
    for (final name in const ['container-fps', 'estimated-vf-fps']) {
      final value = double.tryParse(await native.getProperty(name));
      if (value != null && value > 0) {
        return value;
      }
    }
    return null;
  }

  static Future<String?> _mpvHwdec(PlaybackEngine engine) async {
    final native = engine.videoController?.player.platform;
    return native is NativePlayer ? native.getProperty('hwdec-current') : null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The window before the first layout: the output is right from the first frame (DP1, the double resize of 2a)
    _outputSize ??= _physicalSize(MediaQuery.sizeOf(context));
  }

  Size _physicalSize(Size logical) {
    final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return Size((logical.width * ratio).roundToDouble(), (logical.height * ratio).roundToDouble());
  }

  /// Before each open of the file in a player: renderer C on, or the flat frame (see the top of this file)
  Future<void> _prepare(PlaybackEngine engine) async {
    final step = _step;
    if (step != null) {
      await _prepareRawStep(engine, step);
      if (_step?.mode == RawMode.unstitched) {
        return;
      }
    }
    final rendering = _rendering;
    if (rendering != null && rendering.isFlat) {
      return;
    }
    final first = firstRendering(_settings, pluginSupported: _deps.pluginSupported ?? PluginRenderer.supported);
    if (first != null && first.isFlat) {
      _showFlat(first.flatReason!);
      return;
    }
    if (!identical(engine, _rendererEngine)) {
      _renderer = (_deps.pluginFor ?? _pluginForEngine)(engine);
      _rendererEngine = engine;
    }
    final renderer = _renderer;
    if (renderer == null) {
      _showFlat(FlatReason.unsupported);
      return;
    }
    final PluginProjection projection;
    try {
      projection = _params.toPlugin(frame: _step?.frame);
    } on FormatException catch (error) {
      _log.warning('The raw file cannot be stitched here, it plays flat: $error');
      _showFlat(FlatReason.refused);
      return;
    }
    final attached = await renderer.attach(
      projection: projection,
      outputSize: _outputSize ?? const Size(1280, 720),
      tier: first?.tier ?? rendering?.tier,
      view: _view.toPlugin(),
    );
    if (!attached.ok) {
      _log.info('Renderer C refused: ${attached.reason}');
      _showFlat(FlatReason.refused);
      return;
    }
    var now = SphereRendering.plugin(attached.tier!);
    if (first == null && rendering == null) {
      // Automatic, first open: what the probe kept for this GPU and this version, else the GPU's start tier
      now = tierAfterAttach(
        _settings,
        startTier: attached.tier!,
        glRenderer: attached.glRenderer,
        appVersion: _appVersion ?? '',
      );
      if (now.isFlat) {
        await renderer.detach();
        _showFlat(FlatReason.tooSlow);
        return;
      }
      if (now.tier != attached.tier && !await renderer.setTier(now.tier!)) {
        now = SphereRendering.plugin(attached.tier!);
      }
    }
    _setRendering(now);
    if (_step?.mode == RawMode.stacked) {
      // Two stacked streams are measured first: a computer that does not decode them in time would take the
      // renderer's tier down for every 360° video (the renderer probe starts once the stack keeps up)
      _watchStack(engine, _step!);
    } else {
      _startProbe();
    }
  }

  Future<void> _setMpv(PlaybackEngine engine, String name, String value) async {
    final set = _deps.setMpv;
    if (set != null) {
      return set(engine, name, value);
    }
    final native = engine.videoController?.player.platform;
    if (native is NativePlayer) {
      await native.setProperty(name, value);
    }
  }

  Future<void> _mpvCommand(PlaybackEngine engine, List<String> command) async {
    final run = _deps.mpvCommand;
    if (run != null) {
      return run(engine, command);
    }
    final native = engine.videoController?.player.platform;
    if (native is NativePlayer) {
      await native.command(command);
    }
  }

  Future<String> _readMpv(PlaybackEngine engine, String name) async {
    final read = _deps.readMpv;
    if (read != null) {
      return read(engine, name);
    }
    final native = engine.videoController?.player.platform;
    return native is NativePlayer ? native.getProperty(name) : '';
  }

  /// mpv as [step] of a raw file of two streams wants it, before its file opens: both streams stacked by lavfi-complex
  /// (the other file of a pair as an external track) through the step's decoding path, or one stream alone, or the
  /// frame as the camera recorded it; and the step's notice. A failure here is the step's failure.
  Future<void> _prepareRawStep(PlaybackEngine engine, RawStep step) async {
    final raw = _raw;
    _stopStackWatch();
    _rawOptionsSet[engine] = true;
    try {
      var hwdec = DesktopPlayerOptions.hwdec;
      var graph = '';
      var vid = 'auto';
      String? external;
      switch (step.mode) {
        case RawMode.stacked:
          final path = step.hwdec ?? await _switch.startPath();
          if (step.hwdec == null) {
            _step = step.withHwdec(path);
          }
          hwdec = path;
          graph = raw!.hstackGraph;
          final second = step.externalUrl;
          if (second != null) {
            // The other file of a pair goes through the same resolver as the file: a server URL becomes the bridge's
            try {
              external = await (_deps.resolve ?? desktopAppVideoResolver(ref))(sphericalVideoSource(second));
            } catch (error) {
              // Not a file this computer plays: the file opened plays its own lens, as when the other cannot be read
              _log.info('The other file of the pair cannot be played here: ${redactPlayerText('$error')}');
              final next = _chain?.afterFailure(step, externalReadable: false);
              if (next != null && next.url == step.url) {
                _step = next;
                await _prepareRawStep(engine, next);
                return;
              }
            }
          }
        case RawMode.oneLens:
          vid = '${raw!.videoTrackAlone(step.streams.single)}';
        case RawMode.stitched || RawMode.unstitched:
          break;
      }
      _externalResolved = external;
      // The graph and the external file of a previous step go before anything else: mpv applies them to the next file
      await _setMpv(engine, 'lavfi-complex', '');
      await _setMpv(engine, 'external-files', '');
      await _setMpv(engine, 'hwdec', hwdec);
      await _setMpv(engine, 'vid', vid);
      if (external != null) {
        // One entry, appended as it is: a list option would split a URL at its colons on Linux and macOS
        await _mpvCommand(engine, ['change-list', 'external-files', 'append', external]);
      }
      if (graph.isNotEmpty) {
        await _setMpv(engine, 'lavfi-complex', graph);
      }
    } catch (error) {
      _log.warning('mpv refused the options of $step: ${redactPlayerText('$error')}');
    }
    if (!mounted) {
      return;
    }
    final t = context.t;
    final track = step.mode == RawMode.oneLens ? raw!.tracks[step.streams.single] : null;
    _setNotice(switch (step.notice) {
      RawNotice.oneLensDecoder => t.raw_video_one_lens_decoder(
        codec: track?.codec ?? '?',
        width: '${track?.width ?? '?'}',
        height: '${track?.height ?? '?'}',
      ),
      RawNotice.oneLensFile => t.raw_video_one_lens_file,
      RawNotice.lowResolutionCopy => t.raw_video_low_resolution_copy,
      RawNotice.unstitched => t.raw_video_unstitched,
      // The server's transcoded pair, stacked like the originals: the word every 360° video gets for it
      null when step.fromFallback => t.desktop_video_360_transcoded,
      null => null,
    });
    if (step.mode == RawMode.unstitched) {
      // The frame as the camera recorded it: no stitch, renderer C off
      _probe.stop();
      if (identical(engine, _rendererEngine)) {
        await _renderer?.detach();
      }
      _setRendering(const SphereRendering.flat(FlatReason.refused));
    } else if (step.mode == RawMode.stacked) {
      _firstFrameTimer = Timer(_deps.firstFrameTimeout ?? const Duration(seconds: 15), _onStackSilent);
    }
  }

  /// Measures the stacked playback of [engine] (raw_two_stream_switch.dart)
  void _watchStack(PlaybackEngine engine, RawStep step) {
    final raw = _raw;
    final hwdec = step.hwdec;
    if (raw == null || hwdec == null) {
      return;
    }
    final track = raw.largest;
    unawaited(() async {
      final question = await _switch.question(raw);
      if (!mounted || !identical(_step, step)) {
        return;
      }
      _sampler?.dispose();
      _sampler = TwoStreamSampler(
        engine,
        (name) => _readMpv(engine, name),
        gpu: question.gpu,
        codec: question.codec ?? track.codec ?? '',
        width: track.width ?? 0,
        height: track.height ?? 0,
        hwdec: hwdec,
        onMeasure: (measure) => unawaited(_onStackMeasure(step, measure)),
        now: _deps.now,
      );
    }());
  }

  void _stopStackWatch() {
    _sampler?.dispose();
    _sampler = null;
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
  }

  Future<void> _onStackMeasure(RawStep step, DecodeMeasure measure) async {
    await _switch.record(measure);
    if (!mounted || !identical(_step, step)) {
      return;
    }
    if (measure.smooth) {
      _startProbe();
      return;
    }
    final next = _chain?.afterSlowStack(step, await _switch.choose(_raw!, frameRate: measure.frameRate));
    if (next != null && mounted && identical(_step, step)) {
      await _goTo(next);
    }
  }

  /// Two stacked streams showed no frame in time (a graph mpv could not build, a libmpv without hstack): the step
  /// failed
  void _onStackSilent() {
    _firstFrameTimer = null;
    if (!mounted || _ready || _controller.buffering.value || _step?.mode != RawMode.stacked) {
      return;
    }
    _log.info('Two stacked streams showed no frame in time');
    unawaited(_onRawFailure());
  }

  /// The step playing failed: the next step of the chain, else the error
  Future<void> _onRawFailure() async {
    final step = _step;
    final chain = _chain;
    if (step == null || chain == null || _stepping) {
      return;
    }
    var externalReadable = true;
    final external = _externalResolved;
    if (step.mode == RawMode.stacked && external != null) {
      externalReadable = await (_deps.readable ?? rawUrlReadable)(external);
    }
    final next = chain.afterFailure(step, externalReadable: externalReadable);
    if (!mounted || !identical(_step, step)) {
      return;
    }
    if (next == null) {
      setState(() => _error = widget.args.errorMessage ?? context.t.errors.unable_to_play_video);
      return;
    }
    await _goTo(next);
  }

  /// Plays [next] from where the video is now, in the same player (RawPlanner's rule on the phones: a new plan is a
  /// new open from the current position)
  Future<void> _goTo(RawStep next) async {
    _log.info('Raw file: $next');
    _stopStackWatch();
    _stepping = true;
    try {
      final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value);
      _step = next;
      _ready = false;
      _error = null;
      await _controller.loadVideoSource(sphericalVideoSource(next.url), startAt: position);
    } finally {
      _stepping = false;
    }
  }

  static PluginRenderer? _pluginForEngine(PlaybackEngine engine) {
    final videoController = engine.videoController;
    return videoController == null
        ? null
        : PluginRenderer.forController(videoController, maxOutputHeight: DesktopPlayerOptions.maxRenderHeight);
  }

  /// Before the player leaves this page: renderer C off, mpv's choice of video track back
  Future<void> _unprepare(PlaybackEngine engine) async {
    _probe.stop();
    if (identical(engine, _rendererEngine)) {
      await _renderer?.detach();
      _renderer = null;
      _rendererEngine = null;
    }
    if (_rawOptionsSet[engine] ?? false) {
      _rawOptionsSet[engine] = false;
      _stopStackWatch();
      await _setMpv(engine, 'lavfi-complex', '');
      await _setMpv(engine, 'external-files', '');
      await _setMpv(engine, 'hwdec', DesktopPlayerOptions.hwdec);
      await _setMpv(engine, 'vid', 'auto');
    }
  }

  void _setRendering(SphereRendering rendering) {
    _rendering = rendering;
    if (mounted) {
      setState(() {});
    }
  }

  void _setNotice(String? notice) {
    if (mounted) {
      setState(() => _notice = notice);
    } else {
      _notice = notice;
    }
  }

  void _showFlat(FlatReason reason) {
    _probe.stop();
    _setRendering(SphereRendering.flat(reason));
    if (!mounted) {
      return;
    }
    final t = context.t;
    switch (reason) {
      case FlatReason.chosen:
        break;
      case FlatReason.tooSlow:
        _setNotice(t.desktop_video_360_needs_gpu);
      case FlatReason.unsupported || FlatReason.refused:
        // A raw file shows its lenses as the camera recorded them: the phones' words for it
        _setNotice(_params.isRaw ? t.raw_video_unstitched : t.desktop_video_360_flat);
    }
  }

  void _startProbe() {
    final tier = _rendering?.tier;
    if (tier == null || _renderer == null) {
      return;
    }
    _probe.start(lowestTier: tier.lower == null, onResult: _onProbe);
  }

  Future<void> _onProbe(ProbeVerdict verdict, ProbeSample sample) async {
    final current = _rendering;
    final renderer = _renderer;
    if (current == null || current.isFlat || renderer == null || !mounted) {
      return;
    }
    _log.info('Renderer probe at ${current.tier!.name}: $sample, ${verdict.name}');
    final automatic = _settings.choice == SphereRendererChoice.automatic;
    Future<void> remember(PluginTier? tier, String? reason) async {
      final gpu = renderer.glRenderer;
      final engine = _rendererEngine;
      if (!automatic || gpu == null) {
        return;
      }
      String? hwdec;
      try {
        hwdec = engine == null ? null : await (_deps.hwdecCurrent ?? _mpvHwdec)(engine);
      } catch (_) {
        // Only for the troubleshooting page
      }
      final remembered = RememberedRendering(
        appVersion: _appVersion ?? '',
        glRenderer: gpu,
        tier: tier,
        reason: reason,
        framesPerSecond: double.parse(sample.framesPerSecond.toStringAsFixed(1)),
        targetFramesPerSecond: sample.targetFramesPerSecond,
        hwdec: hwdec,
      );
      _settings = _settings.copyWith(remembered: remembered);
      await SphereRendererStore.remember(remembered);
    }

    switch (verdict) {
      case ProbeVerdict.keep:
        // A tier kept after a step down keeps the reason of that step for the troubleshooting page
        await remember(current.tier, _stepDownReason);
        if (slowAtLowestTier(sample, lowestTier: current.tier!.lower == null) && mounted) {
          _setNotice(context.t.desktop_video_360_slow_gpu);
        }
      case ProbeVerdict.stepDown || ProbeVerdict.fail:
        final next = verdict == ProbeVerdict.fail
            ? const SphereRendering.flat(FlatReason.tooSlow)
            : stepDown(current, _settings.choice);
        if (next == current) {
          // A forced tier: the user asked for it
          return;
        }
        final reason = (sample.memoryGrowthMB ?? 0) > RendererProbeLimits.memoryGrowthMB
            ? 'memory +${sample.memoryGrowthMB} MiB'
            : '${sample.framesPerSecond.toStringAsFixed(1)} of ${sample.targetFramesPerSecond} fps';
        if (next.isFlat) {
          await renderer.detach();
          await remember(null, reason);
          _showFlat(FlatReason.tooSlow);
          return;
        }
        // The plugin allows one tier change a second, and the probe measured for 5 s at least; refused, the same
        // tier is measured again
        if (await renderer.setTier(next.tier!)) {
          _stepDownReason = '${current.tier!.name}: $reason';
          _setRendering(next);
          await remember(next.tier, _stepDownReason);
        }
        _startProbe();
    }
  }

  void _onReady() {
    if (_ready) {
      return;
    }
    _ready = true;
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
    // The 360° players of the phones start playing at once
    unawaited(_controller.play());
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
    final step = _step;
    if (step != null && (step.mode != RawMode.stitched || step.lowResolution)) {
      // A raw file of two streams: its own chain, the phones' order
      unawaited(_onRawFailure());
      return;
    }
    final fallback = widget.args.fallbackUrl;
    if (fallback != null && !_usingFallback) {
      // As the phones' players: the server's transcoded stream when the original cannot be played here
      _usingFallback = true;
      _ready = false;
      _setNotice(context.t.desktop_video_360_transcoded);
      unawaited(_controller.loadVideoSource(sphericalVideoSource(fallback)));
      return;
    }
    setState(() => _error = widget.args.errorMessage ?? context.t.errors.unable_to_play_video);
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

  void _setView(ViewAngles view, {required bool moving}) {
    _view = view;
    _renderer?.setView(view.toPlugin(), moving: moving);
  }

  void _setParams(ProjectionParams params) {
    if (params == _params) {
      return;
    }
    setState(() => _params = params);
    final renderer = _renderer;
    if (renderer != null && renderer.attached) {
      // Uniforms of the pass only: the 3D layout and the coverage change nothing of mpv
      unawaited(renderer.setProjection(params.toPlugin()));
    }
  }

  void _onLayout() => _setParams(_params.copyWith(layout: _params.layout.next));

  void _onCoverage() => _setParams(_params.copyWith(coverage: _params.coverage.next));

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

  void _close() => unawaited(Navigator.of(context).maybePop());

  /// The route closed: the session hears the layout and coverage shown last, and the viewer behind takes its video
  /// back
  void _reportClosed() {
    if (_closed) {
      return;
    }
    _closed = true;
    PlayerEventsHub.spherical?.closed(_params.layout, _params.coverage);
    // After the frame: a provider does not change while the widget tree is being finalised
    final signal = _closedSignal;
    unawaited(Future.microtask(signal.raise));
  }

  // Drag: the picture follows the pointer; the controls hide while it moves
  void _onPanStart(DragStartDetails details) {
    _inertia.stop();
    _visibility.dragStarted();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final height = context.size?.height ?? 0;
    _setView(_view.dragged(details.delta, height), moving: true);
  }

  void _onPanEnd(DragEndDetails details) {
    _visibility.dragEnded();
    final height = context.size?.height ?? 0;
    if (height <= 0 || desktopReducedMotion(context)) {
      _setView(_view, moving: false);
      return;
    }
    final degreesPerPixel = _view.fov / height;
    final velocity = details.velocity.pixelsPerSecond;
    _startInertia(Offset(-velocity.dx * degreesPerPixel, velocity.dy * degreesPerPixel));
  }

  void _startInertia(Offset velocity) {
    _inertiaVelocity = velocity;
    _lastInertiaTick = Duration.zero;
    _inertia.stop();
    unawaited(_inertia.start());
  }

  void _onInertiaTick(Duration elapsed) {
    final dt = (elapsed - _lastInertiaTick).inMicroseconds / 1e6;
    _lastInertiaTick = elapsed;
    if (dt <= 0) {
      return;
    }
    final step = sphereInertiaStep(_view, _inertiaVelocity, dt);
    if (step == null) {
      _inertia.stop();
      // At rest: the sharper filter
      _setView(_view, moving: false);
      return;
    }
    _inertiaVelocity = step.velocity;
    _setView(step.view, moving: true);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    final factor = wheelZoomFactor(event);
    if (factor != null) {
      // Claimed, so that nothing around the player scrolls with the same notch
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        _inertia.stop();
        _setView(_view.zoomed(factor), moving: true);
      });
    }
  }

  static const _zoomFactor = 1.25;

  static final _arrowDirections = {
    LogicalKeyboardKey.arrowLeft: const Offset(-1, 0),
    LogicalKeyboardKey.arrowRight: const Offset(1, 0),
    LogicalKeyboardKey.arrowUp: const Offset(0, 1),
    LogicalKeyboardKey.arrowDown: const Offset(0, -1),
  };

  /// The keys of design 4.2 for a 360° video; F, F11, Escape and the mouse's back button are the window's
  /// (DesktopShell), since the full screen button makes this page a viewer
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (showsControls(event)) {
      _visibility.activity();
    }
    final key = event.logicalKey;
    // A control that has the focus keeps its own keys: Space and Enter press it, the arrows move the time bar
    final onView = node.hasPrimaryFocus;
    if (_arrowDirections.containsKey(key) && (onView || event is KeyUpEvent)) {
      if (event is KeyDownEvent) {
        _startKeyTurn(key);
      } else if (event is KeyUpEvent) {
        _stopKeyTurn(key);
      }
      return KeyEventResult.handled;
    }
    final zoomIn = isRemoteZoomIn(event);
    if (zoomIn || isRemoteZoomOut(event)) {
      if (isRemotePress(event)) {
        _setView(_view.zoomed(zoomIn ? 1 / _zoomFactor : _zoomFactor), moving: false);
      }
      return KeyEventResult.handled;
    }
    if (!isRemotePress(event)) {
      return KeyEventResult.ignored;
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
      // The rule of the remote's OK: to the controls, which show
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
    if (key == LogicalKeyboardKey.end) {
      final duration = _controller.videoInfo?.duration ?? 0;
      unawaited(_controller.seekTo(duration > 1000 ? duration - 1000 : 0));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM && !isTypingText()) {
      unawaited(_toggleMute());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _startKeyTurn(LogicalKeyboardKey key) {
    _inertia.stop();
    if (_heldArrows.containsKey(key)) {
      return;
    }
    if (!_keyTurn.isActive) {
      _keyTurnNow = Duration.zero;
      unawaited(_keyTurn.start());
    }
    _heldArrows[key] = _keyTurnNow;
  }

  void _stopKeyTurn(LogicalKeyboardKey key) {
    if (!_heldArrows.containsKey(key)) {
      return;
    }
    final velocity = _keyTurnVelocity(_keyTurnNow);
    _heldArrows.remove(key);
    if (_heldArrows.isNotEmpty) {
      return;
    }
    _keyTurn.stop();
    if (desktopReducedMotion(context)) {
      _setView(_view, moving: false);
      return;
    }
    _startInertia(velocity);
  }

  Offset _keyTurnVelocity(Duration now) {
    var velocity = Offset.zero;
    for (final MapEntry(key: key, value: since) in _heldArrows.entries) {
      final speed = remoteTurnSpeed((now - since).inMicroseconds / 1e6, _view.fov);
      final direction = _arrowDirections[key]!;
      velocity += Offset(direction.dx * speed, direction.dy * speed * remotePitchFactor);
    }
    return velocity;
  }

  void _onKeyTurnTick(Duration elapsed) {
    final dt = (elapsed - _keyTurnNow).inMicroseconds / 1e6;
    _keyTurnNow = elapsed;
    if (dt <= 0) {
      return;
    }
    final velocity = _keyTurnVelocity(elapsed);
    _setView(_view.turned(velocity * dt), moving: true);
  }

  @override
  void dispose() {
    _reportClosed();
    _probe.stop();
    _stopStackWatch();
    _inertia.dispose();
    _keyTurn.dispose();
    unawaited(_bufferingSubscription?.cancel());
    _controller.onPlaybackReady.removeListener(_onReady);
    _controller.onPlaybackStatusChanged.removeListener(_onStatus);
    _controller.onPlaybackPositionChanged.removeListener(_onTick);
    _controller.onError.removeListener(_onError);
    _controller.buffering.removeListener(_onBuffering);
    _controller.videoController.removeListener(_onBuffering);
    _controller.onPlaybackEnded.removeListener(_onStatus);
    // Renderer C off and the player back to the pool, in this order (the adapter's unprepare)
    _controller.dispose();
    _visibility.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final duration = Duration(milliseconds: _controller.videoInfo?.duration ?? 0);
    final notice = _notice;
    final error = _error;
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
                cursor: _visibility.cursorHidden ? SystemMouseCursors.none : MouseCursor.defer,
                onHover: (_) => _visibility.activity(),
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      _onLayoutSize(constraints.biggest);
                      return Listener(
                        onPointerSignal: _onPointerSignal,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _onPanStart,
                          onPanUpdate: _onPanUpdate,
                          onPanEnd: _onPanEnd,
                          onTap: _visibility.toggle,
                          // Full screen, as a double click on any video of the app
                          onDoubleTap: () => unawaited(
                            ref.read(desktopFullScreenProvider.notifier).toggle(from: ModalRoute.of(context)),
                          ),
                          child: _video(),
                        ),
                      );
                    },
                  ),
                  if (error != null)
                    Center(
                      child: Text(error, style: const TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  SphericalControls(
                    visibility: _visibility,
                    model: SphericalControlsModel(
                      title: widget.args.title,
                      controller: _controller,
                      playing: _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing,
                      position: Duration(milliseconds: _controller.onPlaybackPositionChanged.value),
                      duration: duration,
                      bufferingPercent: _bufferingPercent,
                      muted: _muted,
                      layout: _params.layout,
                      coverage: _params.coverage,
                      raw: _params.isRaw,
                      onClose: _close,
                      onPlayPause: () => unawaited(_playPause()),
                      onSeek: (position) => unawaited(_controller.seekTo(position.inMilliseconds)),
                      onSkip: (step) => unawaited(_skip(step)),
                      onMute: () => unawaited(_toggleMute()),
                      onLayout: _onLayout,
                      onCoverage: _onCoverage,
                    ),
                  ),
                  if (notice != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 72,
                      child: Semantics(
                        liveRegion: true,
                        child: Center(
                          child: DecoratedBox(
                            key: const Key('spherical_notice'),
                            decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(notice, style: const TextStyle(color: Colors.white)),
                                  ),
                                  IconButton(
                                    tooltip: t.close,
                                    onPressed: () => _setNotice(null),
                                    icon: const Icon(Icons.close, color: Colors.white, size: 18),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
    // After the layout: the plugin merges the sizes of a window dragged by its border
    _renderer?.setOutputSize(size);
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
              // The view fills the window: its texture has the window's shape (renderer C), or the frame letterboxed
              // when flat
              fit: (_rendering?.isFlat ?? true) ? BoxFit.contain : BoxFit.fill,
              fill: Colors.black,
              filterQuality: FilterQuality.medium,
              wakelock: true,
              pauseUponEnteringBackgroundMode: false,
              resumeUponEnteringForegroundMode: false,
            ),
    );
  }
}
