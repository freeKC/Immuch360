// Spatial 2.5D of a 3D video on the computers (release 53, lot S1): what SpatialVideoActivity is on Android and
// SpatialVideoViewController on iOS, as a route of the app's window. DesktopSpatialVideoApi.open pushes it and returns
// at once, as the native open starts an activity.
//
// The video plays through the pooled player and controller adapter of the other players of the computers. Its frames
// are drawn by the Spatial passes of the video plugin (package:media_kit_video, SpatialOutput: renderer C in OpenGL
// ES on Windows, Metal on macOS), turned on before each open of the file, so that the first frame is already the view:
// the two eyes, the disparity found by block matching both ways, checked and blended over time, then the view at the
// viewpoint, 0 the left camera to 1 the right one. Linux has no such renderer yet: the page is not offered there
// (desktop_spatial_video_api.dart).
//
// The viewpoint comes from the same sources as the 3D photos (viewer_position.dart): the head through the webcam
// (head_position_source.dart, with its card of the first time, its icon and its messages; the mouse while the head
// cannot be used), the mouse across the picture, an automatic sway, or the arrow keys. The view applies the
// sensitivity, the direction and the glides of the photo page (spatial_viewpoint.dart), and sends the viewpoint to the
// plugin at most once per Flutter frame, only once the plugin answered the previous one, and not for a change under
// [SpatialVideoPageState.viewpointDeadBand]: a still head costs no draw. A paused video is redrawn by the plugin from
// the frame it keeps. A 360° or VR180 3D video turns with a drag and zooms with the wheel, as in the 360° player.
//
// The layout picked in the bar is a new setup of the same passes: nothing of mpv changes. On close, whoever opened the
// page hears where the video was, whether it played, and the layout and projection shown last (the SpatialVideoEvents
// of the phones), and externalPlayerClosedProvider lets the viewer behind take its video back.
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
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/spatial_input_widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_page.dart'
    show spatialStartKind, viewerPositionKindHint, viewerPositionKindLabel, viewerPositionSourcesProvider;
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/desktop_video_setup.dart';
import 'package:immich_mobile/desktop/video/desktop_video_view.dart' show desktopAppVideoResolver;
import 'package:immich_mobile/desktop/video/external_player_closed.provider.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/desktop/video/player_pool.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart' show ViewAngles;
import 'package:immich_mobile/desktop/video/spherical_controls.dart' show SphericalControlsVisibility;
import 'package:immich_mobile/desktop/video/spherical_player_route.dart' show sphericalVideoSource;
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:native_video_player/native_video_player.dart';

final _log = Logger('SpatialVideoPage');

/// Where the plugin draws the Spatial passes of a video: renderer C on Windows, Metal on macOS. Linux has neither yet.
bool get spatialVideoRendererExists => !kIsWeb && (Platform.isWindows || Platform.isMacOS);

/// What SpatialVideoApi.open gives the page, the headers and the labels left out (see the top of this file)
@immutable
class SpatialVideoArgs {
  const SpatialVideoArgs({
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
  factory SpatialVideoArgs.of(SpatialOpenRequest request) => SpatialVideoArgs(
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

  /// The troubleshooting setting: the figures of the passes over the picture
  final bool debugOverlay;

  /// The server's transcoded stream, played when the original fails; null when there is none
  final String? fallbackUrl;
}

/// What the page tells when it closes: as SpatialVideoEvents.closed of the phones
typedef SpatialVideoClosed =
    void Function(int positionMs, bool wasPlaying, SpatialStereoLayout layout, SpatialProjection projection);

/// The calls of the passes on the plugin's channel, replaced in the tests
abstract class SpatialPassesChannel {
  Future<mkv.ProjectionResult> enable(int handle, mkv.SpatialSetup setup);
  Future<mkv.ProjectionResult> disable(int handle);
  Future<bool> setViewpoint(int handle, double viewpoint);
  Future<bool> setView(int handle, ViewAngles view, {required bool sharp});
  Future<bool> setDebug(int handle, {required bool disparityMap});
  Future<mkv.SpatialStats?> stats(int handle, {bool probe = false});
}

class PluginSpatialPasses implements SpatialPassesChannel {
  const PluginSpatialPasses();

  @override
  Future<mkv.ProjectionResult> enable(int handle, mkv.SpatialSetup setup) => mkv.SpatialOutput.enable(handle, setup);

  @override
  Future<mkv.ProjectionResult> disable(int handle) => mkv.SpatialOutput.disable(handle);

  @override
  Future<bool> setViewpoint(int handle, double viewpoint) => mkv.SpatialOutput.setViewpoint(handle, viewpoint);

  @override
  Future<bool> setView(int handle, ViewAngles view, {required bool sharp}) =>
      mkv.ProjectionOutput.setView(handle, yaw: view.yaw, pitch: view.pitch, fov: view.fov, sharp: sharp);

  @override
  Future<bool> setDebug(int handle, {required bool disparityMap}) =>
      mkv.SpatialOutput.setDebug(handle, disparityMap: disparityMap);

  @override
  Future<mkv.SpatialStats?> stats(int handle, {bool probe = false}) => mkv.SpatialOutput.stats(handle, probe: probe);
}

/// The parts the tests replace: the pool and the resolver as for the other players, the passes, the player's handle
/// and the clock of the views
@immutable
class SpatialVideoDependencies {
  const SpatialVideoDependencies({
    this.pool,
    this.resolve,
    this.passes,
    this.handleOf,
    this.setMpv,
    this.clock,
    this.statsInterval,
  });

  final PlayerPool? pool;
  final DesktopVideoSourceResolver? resolve;
  final SpatialPassesChannel? passes;

  /// The plugin's handle of a player, null for a player without a texture
  final Future<int?> Function(PlaybackEngine engine)? handleOf;

  /// Sets an mpv property of a player (keepaspect)
  final Future<void> Function(PlaybackEngine engine, String name, String value)? setMpv;

  /// The monotonic clock of the views (spatialClock by default)
  final Duration Function()? clock;

  /// How often the troubleshooting figures are read
  final Duration? statsInterval;
}

/// The handle the plugin knows a player by, once its controller made the texture
Future<int?> pluginHandleOf(PlaybackEngine engine) async {
  final controller = engine.videoController;
  if (controller == null) {
    return null;
  }
  await controller.platform.future;
  return controller.player.handle;
}

/// Sets the mpv property [name] of the player of [engine]
Future<void> pluginSetMpv(PlaybackEngine engine, String name, String value) async {
  final native = engine.videoController?.player.platform;
  if (native is NativePlayer) {
    await native.setProperty(name, value);
  }
}

/// The sources the video page may use: those of the photos, with the head tracked by the webcam first when the
/// photos' list does not hold it yet. Replaced in the tests.
final spatialVideoPositionSourcesProvider = Provider<Map<ViewerPositionKind, ViewerPositionSource Function()>>((ref) {
  final photos = ref.watch(viewerPositionSourcesProvider);
  if (photos.containsKey(ViewerPositionKind.head)) {
    return photos;
  }
  return {ViewerPositionKind.head: HeadPositionSource.app, ...photos};
});

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

/// The name of [layout] in the layout menu (the phones' labels)
String spatialLayoutLabel(SpatialStereoLayout layout, Translations t) => switch (layout) {
  SpatialStereoLayout.auto => t.spatial_layout_auto,
  SpatialStereoLayout.sideBySide => t.spatial_layout_side_by_side,
  SpatialStereoLayout.topBottom => t.spatial_layout_top_bottom,
  SpatialStereoLayout.sideBySideSwapped => t.spatial_layout_side_by_side_swapped,
  SpatialStereoLayout.topBottomSwapped => t.spatial_layout_top_bottom_swapped,
  SpatialStereoLayout.none => t.spatial_layout_none,
};

/// See the top of this file
class SpatialVideoPage extends ConsumerStatefulWidget {
  const SpatialVideoPage({
    super.key,
    required this.args,
    this.onClosed,
    this.dependencies = const SpatialVideoDependencies(),
  });

  final SpatialVideoArgs args;
  final SpatialVideoClosed? onClosed;
  final SpatialVideoDependencies dependencies;

  static const routeName = 'SpatialVideo';

  /// The route DesktopSpatialVideoApi pushes
  static Route<void> route(SpatialVideoArgs args, {SpatialVideoClosed? onClosed}) => PageRouteBuilder<void>(
    settings: const RouteSettings(name: routeName),
    pageBuilder: (context, _, _) => SpatialVideoPage(args: args, onClosed: onClosed),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  @override
  ConsumerState<SpatialVideoPage> createState() => SpatialVideoPageState();
}

@visibleForTesting
class SpatialVideoPageState extends ConsumerState<SpatialVideoPage> with SingleTickerProviderStateMixin {
  /// A viewpoint closer than this to the one sent is not sent: a head at rest jitters by a few thousandths
  static const viewpointDeadBand = 0.002;

  /// How long the output waits for the window to stop changing size before the passes get the new box
  static const resizeDelay = Duration(milliseconds: 120);

  late final MediaKitVideoPlayerController _controller;
  late final ExternalPlayerClosed _closedSignal;
  late final SpatialPassesChannel _passes;
  final _visibility = SphericalControlsVisibility();
  final _rootFocus = FocusNode(debugLabel: 'Spatial video');

  late SpatialStereoLayout _layout = widget.args.layout;
  late final SpatialProjection _projection = widget.args.projection;
  ViewAngles _view = const ViewAngles();

  PlaybackEngine? _engine;
  int? _handle;

  /// The passes draw the player's texture
  bool _drawing = false;

  /// The passes refused: the frame shows as mpv draws it, with the message
  bool _flat = false;

  /// The box of the output in physical pixels, the window's, and the one the passes were given last
  Size? _outputSize;
  Size? _sentSize;
  Timer? _resizeTimer;

  // What moves the view
  late ViewerPositionKind _kind;
  ViewerPositionSource? _source;
  StreamSubscription<ViewerPosition>? _subscription;

  /// The pointer over the picture, the view's source in the mouse mode and while the head cannot be used
  final _mouse = MousePositionSource();
  StreamSubscription<ViewerPosition>? _mouseSubscription;
  final _viewpoint = SpatialViewpoint(followTime: Duration.zero);
  late final Ticker _ticker = createTicker(_onTick);

  /// The viewpoint the plugin has, the one waiting for its answer, and whether a call is on its way
  double _sent = spatialViewpointCentre;
  double? _waiting;
  bool _sending = false;

  /// The view of a 360° video waiting for the plugin, and whether a call is on its way
  ViewAngles? _waitingView;
  bool _sendingView = false;

  bool _showDisparity = false;
  bool _ready = false;
  bool _closed = false;
  bool _usingFallback = false;
  String? _error;
  bool _muted = false;
  Timer? _statsTimer;
  mkv.SpatialStats? _stats;

  SpatialVideoDependencies get _deps => widget.dependencies;

  Duration _now() => (_deps.clock ?? spatialClock)();

  @visibleForTesting
  MediaKitVideoPlayerController get controller => _controller;

  /// What moves the view now
  @visibleForTesting
  ViewerPositionKind get kind => _kind;

  /// The viewpoint the plugin was sent last
  @visibleForTesting
  double get sentViewpoint => _sent;

  @visibleForTesting
  bool get drawing => _drawing;

  @visibleForTesting
  bool get flat => _flat;

  @visibleForTesting
  SpatialStereoLayout get layout => _layout;

  @visibleForTesting
  ViewAngles get view => _view;

  /// The head source while the head moves the view, null otherwise
  HeadPositionSource? get _head {
    final source = _source;
    return source is HeadPositionSource ? source : null;
  }

  /// Whether the pointer moves the view now: the mouse mode, or the head mode while the head cannot be used
  bool get _mouseMoves {
    if (_kind == ViewerPositionKind.mouse) {
      return true;
    }
    final head = _head;
    return head != null && !head.usable;
  }

  @override
  void initState() {
    super.initState();
    // Read now: the page reports its closing from dispose too, where the providers are no longer read
    _closedSignal = ref.read(externalPlayerClosedProvider.notifier);
    _passes = _deps.passes ?? const PluginSpatialPasses();
    _controller = MediaKitVideoPlayerController(
      pool: _deps.pool ?? desktopPlayerPool,
      resolve: _deps.resolve ?? desktopAppVideoResolver(ref),
      label: 'Spatial video',
      prepare: _prepare,
      unprepare: _unprepare,
      onScreen: () => mounted && !_closed,
    );
    _controller.onPlaybackReady.addListener(_onReady);
    _controller.onPlaybackStatusChanged.addListener(_onStatus);
    _controller.onError.addListener(_onError);
    _controller.decoding.addListener(_onDecoding);
    _mouseSubscription = _mouse.positions.listen(_onMouse);
    final config = ref.read(appConfigProvider).viewer;
    final kinds = ref.read(spatialVideoPositionSourcesProvider).keys;
    final start = spatialStartKind(config.spatialMoveWith, kinds);
    // The photos' rule, then the first kind this computer has when it has no mouse source
    _kind = kinds.contains(start) || kinds.isEmpty ? start : kinds.first;
    _useSource(_kind);
    if (widget.args.debugOverlay) {
      _statsTimer = Timer.periodic(_deps.statsInterval ?? const Duration(seconds: 1), (_) => unawaited(_readStats()));
    }
    unawaited(_open(widget.args.url, start: widget.args.start));
  }

  @override
  void dispose() {
    _reportClosed();
    _ticker.dispose();
    _resizeTimer?.cancel();
    _statsTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_mouseSubscription?.cancel());
    _head?.removeListener(_onHead);
    unawaited(_source?.close());
    unawaited(_mouse.close());
    _controller.onPlaybackReady.removeListener(_onReady);
    _controller.onPlaybackStatusChanged.removeListener(_onStatus);
    _controller.onError.removeListener(_onError);
    _controller.decoding.removeListener(_onDecoding);
    // The adapter's unprepare turns the passes off before the player goes back to the pool
    _controller.dispose();
    _visibility.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  Future<void> _open(String url, {Duration start = Duration.zero}) async {
    try {
      await _controller.loadVideoSource(sphericalVideoSource(url), startAt: start);
    } catch (error) {
      _log.warning('The video did not open: $error');
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  // MARK: the passes

  /// Before each open of the file on [engine]: the passes on, so that its first frame is already the view
  Future<void> _prepare(PlaybackEngine engine) async {
    if (!mounted) {
      return;
    }
    final handle = await (_deps.handleOf ?? pluginHandleOf)(engine);
    if (!mounted) {
      return;
    }
    if (handle == null) {
      _showFlat('no texture');
      return;
    }
    _engine = engine;
    _handle = handle;
    final setMpv = _deps.setMpv ?? pluginSetMpv;
    // The frame mpv draws keeps the video's shape exactly, as renderer C's pages ask: mpv's own letterbox would leave
    // a row or a column of black where the frame's size was rounded
    await setMpv(engine, 'keepaspect', 'no');
    final setup = _setup();
    final result = await _passes.enable(handle, setup);
    if (!mounted) {
      // The page closed during the call, after the adapter's unprepare: the passes off again, so that the pool does
      // not keep the player with them on
      await _passes.disable(handle);
      await setMpv(engine, 'keepaspect', 'yes');
      return;
    }
    if (!result.ok) {
      _log.info('The Spatial passes refused: ${result.reason}');
      await setMpv(engine, 'keepaspect', 'yes');
      _showFlat(result.reason ?? 'refused');
      return;
    }
    _log.info('Spatial passes on ${result.glRenderer}, ${result.outputWidth} x ${result.outputHeight}');
    _sentSize = Size(setup.outputWidth.toDouble(), setup.outputHeight.toDouble());
    setState(() {
      _drawing = true;
      _flat = false;
    });
    if (_projection != SpatialProjection.flat) {
      await _passes.setView(handle, _view, sharp: true);
    }
    if (_showDisparity) {
      await _passes.setDebug(handle, disparityMap: true);
    }
  }

  /// After the player played for this page: the passes off, before the pool keeps it
  Future<void> _unprepare(PlaybackEngine engine) async {
    final handle = _handle;
    if (handle == null || !identical(engine, _engine)) {
      return;
    }
    _handle = null;
    _engine = null;
    _drawing = false;
    await _passes.disable(handle);
    // The pool keeps the player as the other pages want it
    await (_deps.setMpv ?? pluginSetMpv)(engine, 'keepaspect', 'yes');
  }

  void _showFlat(String reason) {
    _log.info('The 3D video plays as it is: $reason');
    if (mounted) {
      setState(() {
        _flat = true;
        _drawing = false;
      });
    }
  }

  /// The setup of the passes for the layout, the projection and the box of now
  mkv.SpatialSetup _setup() {
    final box = _outputSize ?? const Size(1280, 720);
    final size = _controller.decoding.value.size;
    return mkv.SpatialSetup(
      layout: spatialEyeLayout(_layout, width: size?.width, height: size?.height, projection: _projection),
      projection: _projection == SpatialProjection.flat ? mkv.SpatialProjection.flat : mkv.SpatialProjection.equirect,
      halfSphere: _projection == SpatialProjection.equirectangular180,
      viewpoint: _sent,
      outputWidth: box.width.round().clamp(2, 16384),
      outputHeight: box.height.round().clamp(2, 16384),
      maxOutputHeight: DesktopPlayerOptions.maxRenderHeight,
    );
  }

  /// A new setup of the same passes: the layout, or the box
  Future<void> _applySetup() async {
    final handle = _handle;
    if (handle == null || !_drawing) {
      return;
    }
    final setup = _setup();
    final result = await _passes.enable(handle, setup);
    if (!mounted || handle != _handle) {
      return;
    }
    if (!result.ok) {
      _showFlat(result.reason ?? 'refused');
      return;
    }
    _sentSize = Size(setup.outputWidth.toDouble(), setup.outputHeight.toDouble());
  }

  void _onOutputSize(Size size) {
    if (size == _outputSize) {
      return;
    }
    _outputSize = size;
    _resizeTimer?.cancel();
    if (size == _sentSize) {
      return;
    }
    _resizeTimer = Timer(resizeDelay, () => unawaited(_applySetup()));
  }

  /// The video's size is known: an Auto layout is the frame's shape (spatialEyeLayout)
  void _onDecoding() {
    if (_layout == SpatialStereoLayout.auto) {
      unawaited(_applySetup());
    }
  }

  // MARK: what moves the view

  void _useSource(ViewerPositionKind kind) {
    final factory = ref.read(spatialVideoPositionSourcesProvider)[kind];
    if (factory == null) {
      return;
    }
    unawaited(_subscription?.cancel());
    _head?.removeListener(_onHead);
    unawaited(_source?.close());
    final source = factory();
    _source = source;
    _kind = kind;
    if (source is HeadPositionSource) {
      source.addListener(_onHead);
    }
    _followTimeChanged();
    _subscription = source.positions.listen(_onPosition);
    final latest = source.latest;
    if (latest != null) {
      _onPosition(latest);
    }
  }

  /// The view follows the source in use: the head smooths itself, the mouse is followed within its time
  void _followTimeChanged() {
    _viewpoint.followTime = _mouseMoves ? _mouse.followTime : (_source?.followTime ?? Duration.zero);
  }

  void _onHead() {
    _followTimeChanged();
    if (mounted) {
      setState(() {});
    }
  }

  void _onPosition(ViewerPosition position) {
    if (_mouseMoves && _kind != ViewerPositionKind.mouse) {
      // The head cannot be used: the mouse moves the view instead
      return;
    }
    _add(position);
  }

  void _onMouse(ViewerPosition position) {
    if (_mouseMoves) {
      _add(position);
    }
  }

  void _add(ViewerPosition position) {
    _viewpoint.add(position, _now());
    if (!_ticker.isActive) {
      unawaited(_ticker.start());
    }
  }

  void _onTick(Duration _) {
    final now = _now();
    _sendViewpoint(_viewpoint.valueAt(now));
    if (!_viewpoint.movingAt(now) && _kind != ViewerPositionKind.sway) {
      _ticker.stop();
    }
  }

  /// The newest viewpoint to the plugin, one call at a time
  void _sendViewpoint(double viewpoint) {
    if ((viewpoint - (_waiting ?? _sent)).abs() < viewpointDeadBand) {
      return;
    }
    _waiting = viewpoint;
    unawaited(_flushViewpoint());
  }

  Future<void> _flushViewpoint() async {
    if (_sending) {
      return;
    }
    _sending = true;
    try {
      while (_waiting != null && mounted) {
        final viewpoint = _waiting!;
        _waiting = null;
        final handle = _handle;
        _sent = viewpoint;
        if (handle != null && _drawing) {
          await _passes.setViewpoint(handle, viewpoint);
        }
      }
    } finally {
      _sending = false;
    }
  }

  void _pick(ViewerPositionKind kind) {
    if (kind == _kind) {
      return;
    }
    setState(() => _useSource(kind));
    unawaited(ref.read(settingsProvider).write(.viewerSpatialMoveWith, kind));
  }

  void _recenter() {
    _source?.recenter();
    if (_mouseMoves) {
      _mouse.recenter();
    }
  }

  void _nudge(int steps) {
    final source = _source;
    if (source is KeysPositionSource) {
      source.nudge(steps);
    }
  }

  // MARK: the view of a 360° video

  void _setView(ViewAngles view, {required bool sharp}) {
    if (_projection == SpatialProjection.flat) {
      return;
    }
    setState(() => _view = view);
    _waitingView = view;
    unawaited(_flushView(sharp: sharp));
  }

  Future<void> _flushView({required bool sharp}) async {
    if (_sendingView) {
      return;
    }
    _sendingView = true;
    try {
      while (_waitingView != null && mounted) {
        final view = _waitingView!;
        _waitingView = null;
        final handle = _handle;
        if (handle != null && _drawing) {
          await _passes.setView(handle, view, sharp: sharp);
        }
      }
    } finally {
      _sendingView = false;
    }
  }

  // MARK: playback

  void _onReady() {
    if (_ready || !mounted) {
      return;
    }
    setState(() => _ready = true);
    if (widget.args.autoplay) {
      unawaited(_controller.play());
    }
  }

  void _onStatus() {
    if (!mounted) {
      return;
    }
    final playing = _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing;
    _visibility.playing = playing;
    setState(() {});
  }

  void _onError() {
    final error = _controller.onError.value;
    if (error == null || !mounted) {
      return;
    }
    final fallback = widget.args.fallbackUrl;
    if (fallback != null && !_usingFallback) {
      _log.info('The original failed ($error): the transcoded stream');
      final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value);
      setState(() => _usingFallback = true);
      unawaited(_open(fallback, start: position));
      return;
    }
    setState(() => _error = error);
  }

  Future<void> _playPause() async {
    if (await _controller.isPlaying()) {
      await _controller.pause();
    } else {
      await _controller.play();
    }
  }

  Future<void> _toggleMute() async {
    final muted = !_muted;
    setState(() => _muted = muted);
    await _controller.setVolume(muted ? 0 : 1);
  }

  Future<void> _toggleDisparity() async {
    final show = !_showDisparity;
    setState(() => _showDisparity = show);
    final handle = _handle;
    if (handle != null && _drawing) {
      await _passes.setDebug(handle, disparityMap: show);
    }
  }

  void _pickLayout(SpatialStereoLayout layout) {
    if (layout == _layout) {
      return;
    }
    setState(() => _layout = layout);
    unawaited(_applySetup());
  }

  Future<void> _readStats() async {
    final handle = _handle;
    if (handle == null || !_drawing) {
      return;
    }
    final stats = await _passes.stats(handle);
    if (mounted && stats != null) {
      setState(() => _stats = stats);
    }
  }

  /// The page closes: whoever opened it hears where the video was, and the viewer behind takes its video back
  void _reportClosed() {
    if (_closed) {
      return;
    }
    _closed = true;
    final position = _controller.onPlaybackPositionChanged.value;
    final playing = _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing;
    widget.onClosed?.call(position, playing, _layout, _projection);
    // After the frame: a provider does not change while the widget tree is being finalised
    final signal = _closedSignal;
    unawaited(Future.microtask(signal.raise));
  }

  void _close() {
    unawaited(Navigator.of(context).maybePop());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    _visibility.activity();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyK) {
      if (event is KeyDownEvent) {
        unawaited(_playPause());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyR) {
      _recenter();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyD && event is KeyDownEvent) {
      unawaited(_toggleDisparity());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM && event is KeyDownEvent) {
      unawaited(_toggleMute());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowRight) {
      final step = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      if (_kind == ViewerPositionKind.keys) {
        _nudge(step);
      } else {
        final position = _controller.onPlaybackPositionChanged.value;
        unawaited(_controller.seekTo((position + step * 5000).clamp(0, 1 << 40)));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // MARK: the page

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final viewer = ref.watch(appConfigProvider.select((config) => config.viewer));
    _viewpoint
      ..sensitivity = viewer.spatialSensitivity.clamp(spatialSensitivityMin, spatialSensitivityMax) / 100
      ..reverse = viewer.spatialReverse;
    final kinds = ref.watch(spatialVideoPositionSourcesProvider).keys.toList();
    final head = _head;
    final playing = _controller.onPlaybackStatusChanged.value == PlaybackStatus.playing;

    final String? notice = _flat
        ? t.desktop_spatial_video_flat
        : _usingFallback
        ? t.desktop_video_360_transcoded
        : null;

    return Focus(
      focusNode: _rootFocus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          onHover: (_) => _visibility.activity(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final ratio = MediaQuery.devicePixelRatioOf(context);
                  final physical = Size(constraints.maxWidth * ratio, constraints.maxHeight * ratio);
                  if (physical.width > 0 && physical.height > 0) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        _onOutputSize(physical);
                      }
                    });
                  }
                  return Listener(
                    onPointerSignal: (event) {
                      if (event is PointerScrollEvent && _projection != SpatialProjection.flat) {
                        _setView(_view.zoomed(event.scrollDelta.dy > 0 ? 1.1 : 1 / 1.1), sharp: true);
                      }
                    },
                    child: MouseRegion(
                      onHover: (event) => _mouse.pointerAt(event.localPosition, constraints.biggest),
                      onExit: (_) => _mouse.pointerLeft(),
                      child: GestureDetector(
                        // The whole picture, the black bars of the letterbox included
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_playPause()),
                        onPanStart: _projection == SpatialProjection.flat ? null : (_) => _visibility.dragStarted(),
                        onPanUpdate: _projection == SpatialProjection.flat
                            ? null
                            : (details) => _setView(_view.dragged(details.delta, constraints.maxHeight), sharp: false),
                        onPanEnd: _projection == SpatialProjection.flat
                            ? null
                            : (_) {
                                _visibility.dragEnded();
                                _setView(_view, sharp: true);
                              },
                        child: _video(),
                      ),
                    ),
                  );
                },
              ),
              // Under the top bar and above the controls: its icon, its card and its messages
              if (head != null)
                Padding(
                  padding: const EdgeInsets.only(top: 56, bottom: 88),
                  child: HeadTrackingOverlay(source: head),
                ),
              if (_error != null)
                Center(
                  child: Text(
                    t.spatial_open_failed,
                    key: const Key('spatial_video_error'),
                    style: const TextStyle(color: Colors.white70),
                  ),
                )
              else if (!_ready)
                const Center(child: CircularProgressIndicator()),
              ListenableBuilder(
                listenable: _visibility,
                builder: (context, _) => IgnorePointer(
                  ignoring: !_visibility.visible,
                  child: AnimatedOpacity(
                    opacity: _visibility.visible ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Positioned(top: 0, left: 0, right: 0, child: _topBar(t, kinds)),
                        Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar(t, playing, notice)),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.args.debugOverlay && _stats != null)
                Positioned(
                  left: 12,
                  top: 64,
                  child: _StatsText(stats: _stats!, kind: _kind),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _video() {
    if (!desktopVideoAvailable && _deps.pool == null) {
      return const SizedBox.expand();
    }
    return ValueListenableBuilder<mkv.VideoController?>(
      valueListenable: _controller.videoController,
      builder: (context, videoController, _) {
        if (videoController == null) {
          return const SizedBox.expand(key: Key('spatial_video_no_texture'));
        }
        return mkv.Video(
          key: ObjectKey(videoController),
          controller: videoController,
          controls: mkv.NoVideoControls,
          // The output has the shape of one eye (a flat video) or of the window (a 360° one): letterboxed
          fit: BoxFit.contain,
          fill: Colors.black,
          filterQuality: FilterQuality.medium,
          wakelock: true,
          pauseUponEnteringBackgroundMode: false,
          resumeUponEnteringForegroundMode: false,
        );
      },
    );
  }

  Widget _topBar(Translations t, List<ViewerPositionKind> kinds) {
    final mouseInstead = _kind == ViewerPositionKind.head && _mouseMoves;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('spatial_video_close'),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            onPressed: _close,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.args.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
                Text(
                  viewerPositionKindHint(mouseInstead ? ViewerPositionKind.mouse : _kind, t),
                  key: const Key('spatial_video_hint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          PopupMenuButton<ViewerPositionKind>(
            key: const Key('spatial_video_move_with'),
            tooltip: t.desktop_spatial_move_with,
            initialValue: _kind,
            onSelected: _pick,
            itemBuilder: (context) => [
              for (final kind in kinds)
                PopupMenuItem(
                  key: Key('spatial_video_move_${kind.name}'),
                  value: kind,
                  child: Text(viewerPositionKindLabel(kind, t)),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.threed_rotation_rounded, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(viewerPositionKindLabel(_kind, t), style: const TextStyle(color: Colors.white)),
                ],
              ),
            ),
          ),
          PopupMenuButton<SpatialStereoLayout>(
            key: const Key('spatial_video_layout'),
            tooltip: t.spatial_layout,
            initialValue: _layout,
            onSelected: _pickLayout,
            itemBuilder: (context) => [
              for (final layout in SpatialStereoLayout.values)
                PopupMenuItem(
                  key: Key('spatial_video_layout_${layout.name}'),
                  value: layout,
                  child: Text(spatialLayoutLabel(layout, t)),
                ),
            ],
            icon: const Icon(Icons.view_column_rounded, color: Colors.white),
          ),
          IconButton(
            key: const Key('spatial_video_recenter'),
            icon: const Icon(Icons.center_focus_strong_rounded, color: Colors.white),
            tooltip: t.spatial_recenter,
            onPressed: _recenter,
          ),
          IconButton(
            key: const Key('spatial_video_depth'),
            isSelected: _showDisparity,
            icon: const Icon(Icons.layers_outlined, color: Colors.white),
            selectedIcon: const Icon(Icons.layers_rounded, color: Colors.white),
            tooltip: t.desktop_spatial_depth_view,
            onPressed: () => unawaited(_toggleDisparity()),
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(Translations t, bool playing, String? notice) {
    final position = Duration(milliseconds: _controller.onPlaybackPositionChanged.value);
    final duration = Duration(milliseconds: _controller.videoInfo?.duration ?? 0);
    final total = duration.inMilliseconds.toDouble();
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xCC000000), Color(0x00000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                notice,
                key: const Key('spatial_video_notice'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ValueListenableBuilder<int>(
            valueListenable: _controller.onPlaybackPositionChanged,
            builder: (context, milliseconds, _) => Row(
              children: [
                IconButton(
                  key: const Key('spatial_video_play'),
                  icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                  onPressed: () => unawaited(_playPause()),
                ),
                Text(
                  _time(Duration(milliseconds: milliseconds)),
                  style: const TextStyle(color: Colors.white),
                ),
                Expanded(
                  child: Slider(
                    key: const Key('spatial_video_seek'),
                    value: total <= 0 ? 0 : milliseconds.clamp(0, total).toDouble(),
                    max: total <= 0 ? 1 : total,
                    onChanged: total <= 0 ? null : (value) => unawaited(_controller.seekTo(value.round())),
                  ),
                ),
                Text(_time(duration > position ? duration : position), style: const TextStyle(color: Colors.white)),
                IconButton(
                  key: const Key('spatial_video_mute'),
                  icon: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: Colors.white),
                  onPressed: () => unawaited(_toggleMute()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _time(Duration time) {
  final seconds = (time.inSeconds % 60).toString().padLeft(2, '0');
  final minutes = time.inMinutes % 60;
  final hours = time.inHours;
  return hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds' : '$minutes:$seconds';
}

/// The troubleshooting figures of the passes
class _StatsText extends StatelessWidget {
  const _StatsText({required this.stats, required this.kind});

  final mkv.SpatialStats stats;
  final ViewerPositionKind kind;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
    child: Padding(
      padding: const EdgeInsets.all(6),
      child: Text(
        [
          '${stats.draws.glRenderer ?? ''} ${stats.stereo ? 'stereo' : 'one eye'} ${stats.quality.name}',
          'draws ${stats.renderFps.toStringAsFixed(1)}/s, depth ${stats.disparityFps.toStringAsFixed(1)}/s',
          'GPU ${stats.renderMs.toStringAsFixed(2)} ms, map ${stats.disparityWidth} x ${stats.disparityHeight}',
          'eye ${stats.eyeWidth} x ${stats.eyeHeight}, out ${stats.drawnWidth} x ${stats.drawnHeight}',
          'viewpoint ${stats.viewpoint.toStringAsFixed(3)} (${kind.name})',
        ].join('\n'),
        key: const Key('spatial_video_stats'),
        style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
      ),
    ),
  );
}
