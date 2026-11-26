// Spatial 2.5D of a 3D photo on the computers (release 53, lot P2): the page that opens from the viewer where a 3D
// photo shows one eye (spatial_photo_button.dart). The photo becomes a window: as the viewer moves, near things slide
// over far ones. Its depth is measured once when the photo opens (spatial_photo_render.dart); until then, and if it
// cannot be measured, the left eye shows as it is.
//
// What moves the view (viewer_position.dart), picked in the bar and kept in the settings:
// - Mouse: the pointer across the picture; leaving the window glides the view back to its centre;
// - Automatic sway: a slow back and forth, no input;
// - Keys only: the left and right arrows;
// - Head (webcam): the head tracked by the webcam (head_position_source.dart), offered when this computer has the
//   head tracker. It is the default when nothing was picked, "Use the webcam for head tracking" is on and either the
//   user already said yes on the card of the first time or a webcam is listed (listing opens none). The card shows over
//   the picture until the user answers, the camera icon while the webcam is open (HeadTrackingOverlay), and the mouse
//   moves the view whenever the head cannot (no answer yet, "Use the mouse", the webcam off in the settings, a
//   problem): the webcam opens only after the yes.
// R recenters, D shows the depth map (near bright, far dark), Escape closes. The sensitivity, the direction and the
// webcam are in Settings, Asset Viewer, Videos, Spatial 2.5D, and behind the settings button of the bar.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/spatial/head_position_source.dart';
import 'package:immich_mobile/desktop/spatial/head_tracking.dart';
import 'package:immich_mobile/desktop/spatial/spatial_head_setting.dart';
import 'package:immich_mobile/desktop/spatial/spatial_input_widgets.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_view_settings.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immuch_head_tracker/immuch_head_tracker.dart';
import 'package:logging/logging.dart';

final _log = Logger('SpatialPhotoPage');

/// The head tracker of this computer (its library loaded), null without one; a fake in the tests
final spatialHeadSourceProvider = Provider<SpatialHeadSource?>((ref) => NativeSpatialHeadSource.desktop());

/// Makes the head source of a view, over the head tracker and the app's settings; null without a head tracker
final headPositionSourceFactoryProvider = Provider<HeadPositionSource Function()?>((ref) {
  final tracker = ref.watch(spatialHeadSourceProvider);
  return tracker == null ? null : () => HeadPositionSource(store: const AppSpatialSettingsStore(), source: tracker);
}, dependencies: [spatialHeadSourceProvider]);

/// The sources the 2.5D views may use on this computer, in the order of the menu: the head first where there is a head
/// tracker
final viewerPositionSourcesProvider = Provider<Map<ViewerPositionKind, ViewerPositionSource Function()>>((ref) {
  final head = ref.watch(headPositionSourceFactoryProvider);
  return {
    ViewerPositionKind.head: ?head,
    ViewerPositionKind.mouse: MousePositionSource.new,
    ViewerPositionKind.sway: SwayPositionSource.new,
    ViewerPositionKind.keys: KeysPositionSource.new,
  };
}, dependencies: [headPositionSourceFactoryProvider]);

/// Measures the depth of a photo; replaced in the tests
final spatialPhotoDepthProvider = Provider<Future<SpatialPhotoDepth> Function(ui.Image frame, SpatialPhotoLayout)>(
  (ref) => computeSpatialPhotoDepth,
);

/// Loads the shader of the page; replaced in the tests. Loaded once, a failed load tried again next time.
final spatialPhotoProgramProvider = Provider<Future<ui.FragmentProgram> Function()>((ref) => _loadProgram);

ui.FragmentProgram? _program;

Future<ui.FragmentProgram> _loadProgram() async =>
    _program ??= await ui.FragmentProgram.fromAsset(spatialPhotoShaderAsset);

/// The name of [kind] in the menu and the settings
String viewerPositionKindLabel(ViewerPositionKind kind, Translations t) => switch (kind) {
  ViewerPositionKind.head => t.desktop_spatial_move_head,
  ViewerPositionKind.mouse => t.desktop_spatial_move_mouse,
  ViewerPositionKind.sway => t.desktop_spatial_move_sway,
  ViewerPositionKind.keys => t.desktop_spatial_move_keys,
};

/// What tells the user how to move the view with [kind]
String viewerPositionKindHint(ViewerPositionKind kind, Translations t) => switch (kind) {
  ViewerPositionKind.head => t.desktop_spatial_hint_head,
  ViewerPositionKind.mouse => t.desktop_spatial_hint_mouse,
  ViewerPositionKind.sway => t.desktop_spatial_hint_sway,
  ViewerPositionKind.keys => t.desktop_spatial_hint_keys,
};

/// The kind the page opens with: the one picked in the settings when this computer has it, else the head when
/// [headByDefault] and this computer has it, else the mouse
ViewerPositionKind spatialStartKind(
  ViewerPositionKind? picked,
  Iterable<ViewerPositionKind> available, {
  bool headByDefault = false,
}) {
  if (picked != null && available.contains(picked)) {
    return picked;
  }
  return headByDefault && available.contains(ViewerPositionKind.head)
      ? ViewerPositionKind.head
      : ViewerPositionKind.mouse;
}

/// Where the depth of the photo stands
enum SpatialDepthState { measuring, ready, failed }

/// See the top of this file
class SpatialPhotoPage extends ConsumerStatefulWidget {
  const SpatialPhotoPage({
    super.key,
    required this.image,
    required this.layout,
    required this.title,
    this.estimatedRelief = false,
    this.clock = spatialClock,
  });

  /// The whole frame of the photo, both eyes
  final ImageProvider image;
  final SpatialPhotoLayout layout;

  /// The name of the photo, in the bar
  final String title;

  /// Its relief was estimated by AI from one photo: the honesty label shows under it
  final bool estimatedRelief;

  /// The monotonic clock of the views; a fake one in the tests
  final Duration Function() clock;

  static const routeName = 'SpatialPhoto';

  static Route<void> route({
    required ImageProvider image,
    required SpatialPhotoLayout layout,
    required String title,
    bool estimatedRelief = false,
  }) => PageRouteBuilder<void>(
    settings: const RouteSettings(name: routeName),
    pageBuilder: (context, _, _) =>
        SpatialPhotoPage(image: image, layout: layout, title: title, estimatedRelief: estimatedRelief),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );

  @override
  ConsumerState<SpatialPhotoPage> createState() => _SpatialPhotoPageState();
}

class _SpatialPhotoPageState extends ConsumerState<SpatialPhotoPage> with SingleTickerProviderStateMixin {
  ImageStream? _stream;
  late final _listener = ImageStreamListener(_onImage, onError: _onImageError);
  ImageInfo? _info;
  bool _imageFailed = false;

  ui.FragmentProgram? _shader;
  SpatialPhotoDepth? _depth;
  SpatialDepthState _depthState = SpatialDepthState.measuring;
  bool _shaderFailed = false;

  /// Counts the frames sent to the depth, so that the result of an older one is dropped
  int _depthRun = 0;

  late ViewerPositionKind _kind;
  ViewerPositionSource? _source;
  StreamSubscription<ViewerPosition>? _subscription;

  /// With the head: the mouse, which moves the view while the head cannot ([HeadPositionSource.usable] false)
  MousePositionSource? _fallback;
  StreamSubscription<ViewerPosition>? _fallbackSubscription;
  bool _headUsable = false;

  /// The user picked a source in the bar: the head found by default no longer replaces it
  bool _picked = false;
  final _viewpoint = SpatialViewpoint(followTime: Duration.zero);
  final _p = ValueNotifier<double>(spatialViewpointCentre);
  late final Ticker _ticker = createTicker(_onTick);
  bool _showDepth = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final config = ref.read(appConfigProvider).viewer;
    final kinds = ref.read(viewerPositionSourcesProvider).keys;
    // Nothing picked yet: the head when the webcam may be used and the user said yes before; without that yes, the
    // head (and its card) only once a webcam is listed, so that a computer without one is not asked
    final headCandidate =
        config.spatialMoveWith == null && config.spatialWebcam && kinds.contains(ViewerPositionKind.head);
    _kind = spatialStartKind(
      config.spatialMoveWith,
      kinds,
      headByDefault: headCandidate && config.spatialWebcamConsent,
    );
    _useSource(_kind);
    if (headCandidate && _kind != ViewerPositionKind.head) {
      unawaited(_headIfWebcam());
    }
    unawaited(_loadShader());
  }

  /// The head as the default once a webcam is listed (listing opens no webcam)
  Future<void> _headIfWebcam() async {
    final tracker = ref.read(spatialHeadSourceProvider);
    if (tracker == null) {
      return;
    }
    final List<HeadCamera> cameras;
    try {
      cameras = await tracker.cameras();
    } catch (error) {
      _log.info('The webcams were not listed: $error');
      return;
    }
    if (_disposed || _picked || _kind != ViewerPositionKind.mouse || defaultHeadCamera(cameras) == null) {
      return;
    }
    setState(() => _useSource(ViewerPositionKind.head));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key != _stream?.key) {
      _stream?.removeListener(_listener);
      _stream = stream..addListener(_listener);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    _closeSources();
    _stream?.removeListener(_listener);
    _info?.dispose();
    _depth?.dispose();
    _p.dispose();
    super.dispose();
  }

  Future<void> _loadShader() async {
    try {
      final shader = await ref.read(spatialPhotoProgramProvider)();
      if (!_disposed) {
        setState(() => _shader = shader);
      }
    } catch (error, stack) {
      _log.warning('The shader of the 2.5D photos did not load', error, stack);
      if (!_disposed) {
        setState(() => _shaderFailed = true);
      }
    }
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (_disposed) {
      info.dispose();
      return;
    }
    // A picture already in the cache comes during didChangeDependencies, which the build follows anyway
    void keep() {
      _info?.dispose();
      _info = info;
    }

    synchronousCall ? keep() : setState(keep);
    unawaited(_measure(info.image));
  }

  void _onImageError(Object error, StackTrace? stack) {
    _log.warning('The 3D photo did not open', error, stack);
    if (!_disposed) {
      setState(() => _imageFailed = true);
    }
  }

  Future<void> _measure(ui.Image frame) async {
    final run = ++_depthRun;
    if (_depth == null && _depthState != SpatialDepthState.measuring) {
      setState(() => _depthState = SpatialDepthState.measuring);
    }
    final clone = frame.clone();
    try {
      final watch = Stopwatch()..start();
      final depth = await ref.read(spatialPhotoDepthProvider)(clone, widget.layout);
      _log.info('Depth of ${frame.width} x ${frame.height} measured in ${watch.elapsedMilliseconds} ms');
      if (_disposed || run != _depthRun) {
        depth.dispose();
        return;
      }
      setState(() {
        _depth?.dispose();
        _depth = depth;
        _depthState = SpatialDepthState.ready;
      });
    } catch (error, stack) {
      _log.warning('The depth of the 3D photo could not be measured', error, stack);
      if (!_disposed && run == _depthRun && _depth == null) {
        setState(() => _depthState = SpatialDepthState.failed);
      }
    } finally {
      clone.dispose();
    }
  }

  void _useSource(ViewerPositionKind kind) {
    final factory = ref.read(viewerPositionSourcesProvider)[kind];
    if (factory == null) {
      return;
    }
    _closeSources();
    final source = factory();
    _source = source;
    _kind = kind;
    _subscription = source.positions.listen((position) => _onPosition(source, position));
    if (source is HeadPositionSource) {
      final mouse = MousePositionSource();
      _fallback = mouse;
      _fallbackSubscription = mouse.positions.listen((position) => _onPosition(mouse, position));
      _headUsable = source.usable;
      source.addListener(_onHeadChanged);
    }
    final driver = _driver!;
    _viewpoint.followTime = driver.followTime;
    final latest = driver.latest;
    if (latest != null) {
      _onPosition(driver, latest);
    }
  }

  void _closeSources() {
    unawaited(_subscription?.cancel());
    unawaited(_fallbackSubscription?.cancel());
    _subscription = null;
    _fallbackSubscription = null;
    final source = _source;
    if (source is HeadPositionSource) {
      source.removeListener(_onHeadChanged);
    }
    // The head's close releases the webcam (its light off)
    unawaited(source?.close());
    unawaited(_fallback?.close());
    _source = null;
    _fallback = null;
  }

  /// What moves the view now: the source picked, or the mouse while the head cannot
  ViewerPositionSource? get _driver {
    final source = _source;
    return source is HeadPositionSource && !source.usable ? _fallback : source;
  }

  /// The pointer's source: the mouse picked, or the mouse behind the head
  MousePositionSource? get _mouse {
    final source = _source;
    return source is MousePositionSource ? source : _fallback;
  }

  /// The head source changed (the card answered, the webcam opened or closed, a problem): the mouse takes over while
  /// the head cannot move the view, and gives the view back once it can
  void _onHeadChanged() {
    final source = _source;
    if (_disposed || source is! HeadPositionSource) {
      return;
    }
    final usable = source.usable;
    if (usable != _headUsable) {
      _headUsable = usable;
      final driver = _driver!;
      _viewpoint.followTime = driver.followTime;
      // The view starts again from the centre with the other source
      _onPosition(driver, driver.latest ?? ViewerPosition.lost(widget.clock()));
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _onPosition(ViewerPositionSource from, ViewerPosition position) {
    if (!identical(from, _driver)) {
      return;
    }
    _viewpoint.add(position, widget.clock());
    if (!_ticker.isActive) {
      unawaited(_ticker.start());
    }
  }

  void _onTick(Duration _) {
    final now = widget.clock();
    _p.value = _viewpoint.valueAt(now);
    if (!_viewpoint.movingAt(now) && _kind != ViewerPositionKind.sway) {
      _ticker.stop();
    }
  }

  void _pick(ViewerPositionKind kind) {
    if (kind == _kind) {
      return;
    }
    _picked = true;
    setState(() => _useSource(kind));
    unawaited(ref.read(settingsProvider).write(.viewerSpatialMoveWith, kind));
  }

  void _recenter() {
    _source?.recenter();
    _fallback?.recenter();
  }

  /// The settings of Spatial 2.5D over the page: the page counts as covered meanwhile, and the webcam closes
  void _openSettings() => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'SpatialSettings'),
        builder: (context) => const SpatialSettingsPage(),
      ),
    ),
  );

  void _nudge(int steps) {
    final source = _source;
    if (source is KeysPositionSource) {
      source.nudge(steps);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final viewer = ref.watch(appConfigProvider.select((config) => config.viewer));
    _viewpoint
      ..sensitivity = viewer.spatialSensitivity.clamp(spatialSensitivityMin, spatialSensitivityMax) / 100
      ..reverse = viewer.spatialReverse;
    final kinds = ref.watch(viewerPositionSourcesProvider).keys.toList();
    final info = _info;
    final ready = _depthState == SpatialDepthState.ready && _shader != null && _depth != null;

    final Widget picture;
    if (info == null) {
      picture = Center(
        child: _imageFailed
            ? Text(t.desktop_spatial_photo_unreadable, style: const TextStyle(color: Colors.white70))
            : const CircularProgressIndicator(),
      );
    } else {
      final source = _source;
      final head = source is HeadPositionSource ? source : null;
      picture = LayoutBuilder(
        builder: (context, constraints) => MouseRegion(
          onHover: (event) => _mouse?.pointerAt(event.localPosition, constraints.biggest),
          onExit: (_) => _mouse?.pointerLeft(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                key: const Key('spatial_photo_canvas'),
                size: Size.infinite,
                painter: SpatialPhotoPainter(
                  program: ready ? _shader : null,
                  frame: info.image,
                  layout: widget.layout,
                  depth: ready ? _depth : null,
                  viewpoint: _p,
                  showDepth: _showDepth,
                ),
              ),
              // The card of the first time, the camera icon while the webcam is open, the problems
              if (head != null) HeadTrackingOverlay(key: ObjectKey(head), source: head),
            ],
          ),
        ),
      );
    }

    final String status = _shaderFailed
        ? t.desktop_spatial_photo_failed
        : switch (_depthState) {
            SpatialDepthState.measuring => t.desktop_spatial_photo_measuring,
            SpatialDepthState.failed => t.desktop_spatial_photo_failed,
            SpatialDepthState.ready => viewerPositionKindHint(_driver?.kind ?? _kind, t),
          };

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop(),
        const SingleActivator(LogicalKeyboardKey.keyR): _recenter,
        const SingleActivator(LogicalKeyboardKey.keyD): () => setState(() => _showDepth = !_showDepth),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _nudge(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _nudge(1),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: const Key('spatial_photo_page'),
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            leading: IconButton(
              tooltip: t.close,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            title: Text('${t.spatial_2_5d} · ${widget.title}', maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              PopupMenuButton<ViewerPositionKind>(
                key: const Key('spatial_photo_move_with'),
                tooltip: t.desktop_spatial_move_with,
                initialValue: _kind,
                onSelected: _pick,
                itemBuilder: (context) => [
                  for (final kind in kinds)
                    CheckedPopupMenuItem(
                      key: Key('spatial_photo_move_${kind.name}'),
                      value: kind,
                      checked: kind == _kind,
                      child: Text(viewerPositionKindLabel(kind, t)),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.open_with_rounded, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(viewerPositionKindLabel(_kind, t), style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const Key('spatial_photo_recenter'),
                tooltip: t.spatial_recenter,
                icon: const Icon(Icons.center_focus_strong_rounded),
                onPressed: _recenter,
              ),
              IconButton(
                key: const Key('spatial_photo_settings'),
                tooltip: t.settings,
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettings,
              ),
              IconButton(
                key: const Key('spatial_photo_depth_view'),
                tooltip: t.desktop_spatial_depth_view,
                isSelected: _showDepth,
                icon: const Icon(Icons.layers_outlined),
                selectedIcon: const Icon(Icons.layers_rounded),
                onPressed: ready ? () => setState(() => _showDepth = !_showDepth) : null,
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(
            children: [
              Expanded(child: ClipRect(child: picture)),
              Container(
                width: double.infinity,
                color: Colors.black,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  children: [
                    if (widget.estimatedRelief)
                      Text(
                        t.ai_immersive_relief_estimated,
                        key: const Key('spatial_photo_estimated'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    Text(
                      status,
                      key: const Key('spatial_photo_status'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The settings of Spatial 2.5D, opened from the bar of the page: what moves the view, its strength and direction, the
/// webcam
class SpatialSettingsPage extends ConsumerWidget {
  const SpatialSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    key: const Key('spatial_settings_page'),
    appBar: AppBar(title: Text('${context.t.spatial_2_5d} · ${context.t.settings}')),
    body: ListView(
      children: [
        const DesktopSpatialViewSettings(),
        SpatialHeadTrackingSetting(listCameras: () => ref.read(spatialHeadSourceProvider)?.cameras()),
      ],
    ),
  );
}
