// The Spatial passes of renderer C for one player of the Spatial page (packages/media_kit_video, IMMUCH360-NOTE.md
// patch 11: SpatialOutput), kept as the 360° player keeps renderer C (render/plugin_renderer.dart). They are turned on
// before the file opens, so that the first frame is already the view at the viewpoint. The viewpoint, and for a 360°
// or VR180 stereo video the view, go to the plugin at most once per Flutter frame, the newest, and only once the plugin
// answered the previous one, however fast the head, the mouse or the keys move. The output follows the window
// (physical pixels, at most maxOutputHeight lines), merged while a border is dragged. The layout, the projection and
// the 180 or 360 switch are a new setup of the same passes: nothing of mpv changes. A paused video is redrawn by the
// plugin from the frame it keeps. A head at rest jitters by a few thousandths: a viewpoint closer than
// [SpatialPluginOutput.viewpointDeadBand] to the one sent is not sent, so that a still head costs no draw.
//
// The intermediate texture mpv draws each frame into costs GPU time before the passes start, which the passes' own
// adaptive tier does not see. For a flat video it is no larger than the eyes read from it (spatialFlatFrameCap: the
// eyes at the shape and size the window shows them, at most 1920 x 1080 each), once the video's size is known, and
// before that no larger than the window allows; for a 360° video it is the start tier of renderer C on this GPU
// (PluginTier.startFor). When the page measures that the frames do not keep up, [SpatialPluginOutput.stepDown] makes the
// frame smaller (three quarters, then half of what the eyes use; renderer C's next tier for a 360° video), then holds
// the disparity at LOW.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/desktop/video/gpu_decoders.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immuch_desktop_video/immuch_desktop_video.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('SpatialOutput');

/// The calls of the plugin, replaced in the tests
abstract class SpatialChannel {
  Future<ProjectionResult> enable(int handle, SpatialSetup setup);
  Future<ProjectionResult> disable(int handle);
  Future<bool> setViewpoint(int handle, double viewpoint);
  Future<bool> setView(int handle, PluginView view, {required bool sharp});
  Future<bool> setDebug(int handle, {required bool disparityMap});
  Future<SpatialStats?> stats(int handle, {bool probe = false});
}

class _MethodChannelSpatial implements SpatialChannel {
  const _MethodChannelSpatial();

  @override
  Future<ProjectionResult> enable(int handle, SpatialSetup setup) => SpatialOutput.enable(handle, setup);

  @override
  Future<ProjectionResult> disable(int handle) => SpatialOutput.disable(handle);

  @override
  Future<bool> setViewpoint(int handle, double viewpoint) => SpatialOutput.setViewpoint(handle, viewpoint);

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) =>
      ProjectionOutput.setView(handle, yaw: view.yaw, pitch: view.pitch, fov: view.fov, sharp: sharp);

  @override
  Future<bool> setDebug(int handle, {required bool disparityMap}) =>
      SpatialOutput.setDebug(handle, disparityMap: disparityMap);

  @override
  Future<SpatialStats?> stats(int handle, {bool probe = false}) => SpatialOutput.stats(handle, probe: probe);
}

/// How the eyes are laid out and what they hold
@immutable
class SpatialLook {
  const SpatialLook({
    this.layout = SpatialLayout.sideBySide,
    this.projection = SpatialProjection.flat,
    this.halfSphere = false,
  });

  final SpatialLayout layout;
  final SpatialProjection projection;

  /// A 360° video covering the front half of the sphere only (VR180)
  final bool halfSphere;

  @override
  bool operator ==(Object other) =>
      other is SpatialLook &&
      other.layout == layout &&
      other.projection == projection &&
      other.halfSphere == halfSphere;

  @override
  int get hashCode => Object.hash(layout, projection, halfSphere);

  @override
  String toString() => 'SpatialLook(${layout.name}, ${projection.name}${halfSphere ? ', VR180' : ''})';
}

/// What [SpatialPluginOutput.stepDown] changed
enum SpatialStepDown {
  /// The frame mpv draws is smaller
  frame,

  /// The disparity is held at LOW, without the adaptive rule
  lowQuality,
}

/// The largest frame the plugin's passes read without losing a pixel of the eyes: a flat stereo frame of [videoWidth] x
/// [videoHeight] (null before the video's size is known), laid out as [layout], shown in a box of [outputSize]
/// physical pixels at most [maxOutputHeight] lines high, each eye at most [maxEyePixels], scaled by [scale] (the steps
/// down). Never more than the plugin's own default (two eyes of 1920 x 1080).
///
/// The plugin keeps the frame's shape and scales it by the smaller of maxFrameWidth over its width and the square root
/// of maxFramePixels over its pixels. The eyes need their columns and their lines: an eye stored squeezed (half side by
/// side) needs twice the columns it has, which the frame then keeps at its own size. Without the video's size, the eyes
/// may be squeezed: twice the box's width, four eyes' pixels.
({int maxFrameWidth, int maxFramePixels}) spatialFlatFrameCap({
  required SpatialLayout layout,
  required Size outputSize,
  required int maxOutputHeight,
  int? videoWidth,
  int? videoHeight,
  double scale = 1,
  int maxEyePixels = SpatialPluginOutput.maxEyePixels,
}) {
  const defaultWidth = 3840;
  const defaultPixels = 3840 * 2160;
  var boxWidth = math.max(2.0, outputSize.width);
  var boxHeight = math.max(2.0, outputSize.height);
  if (maxOutputHeight > 0 && boxHeight > maxOutputHeight) {
    boxWidth = boxWidth * maxOutputHeight / boxHeight;
    boxHeight = maxOutputHeight.toDouble();
  }
  final width = videoWidth ?? 0;
  final height = videoHeight ?? 0;
  if (width <= 0 || height <= 0) {
    final eyePixels = math.min(boxWidth * boxHeight, maxEyePixels.toDouble());
    return (
      maxFrameWidth: math.max(16, math.min(defaultWidth, (2 * boxWidth * scale).ceil())),
      maxFramePixels: math.max(256, math.min(defaultPixels, (4 * eyePixels * scale * scale).ceil())),
    );
  }
  // The eye's shape as the plugin shows it (SpatialRenderer's DisplayAspect), letterboxed in the box
  final frameAspect = width / height;
  final squeezed = frameAspect >= 1.3 && frameAspect <= 1.95;
  final sideBySide = layout == SpatialLayout.sideBySide || layout == SpatialLayout.sideBySideSwapped;
  final topBottom = layout == SpatialLayout.topBottom || layout == SpatialLayout.topBottomSwapped;
  final eyeAspect = squeezed
      ? frameAspect
      : sideBySide
      ? frameAspect / 2
      : topBottom
      ? frameAspect * 2
      : frameAspect;
  var eyeWidth = boxWidth;
  var eyeHeight = boxHeight;
  if (boxWidth / boxHeight > eyeAspect) {
    eyeWidth = boxHeight * eyeAspect;
  } else {
    eyeHeight = boxWidth / eyeAspect;
  }
  final eyeScale = math.min(1.0, math.sqrt(maxEyePixels / (eyeWidth * eyeHeight)));
  eyeWidth *= eyeScale;
  eyeHeight *= eyeScale;
  // The columns and lines of one eye in the frame
  final columns = sideBySide ? width / 2 : width.toDouble();
  final lines = topBottom ? height / 2 : height.toDouble();
  final needed = math.min(1.0, math.max(eyeWidth / columns, eyeHeight / lines)) * scale;
  final frameWidth = (width * needed).ceil();
  final frameHeight = (height * needed).ceil();
  return (
    maxFrameWidth: math.max(16, math.min(defaultWidth, frameWidth)),
    maxFramePixels: math.max(256, math.min(defaultPixels, frameWidth * frameHeight)),
  );
}

/// The Spatial passes for one player, see the top of this file
class SpatialPluginOutput {
  SpatialPluginOutput({
    required this._handle,
    this._setMpvProperty,
    SpatialChannel? channel,
    this._adapter,
    this.maxOutputHeight = PluginRenderer.defaultMaxOutputHeight,
    this.resizeDelay = const Duration(milliseconds: 100),
    this.settleDelay = const Duration(milliseconds: 150),
  }) : _channel = channel ?? const _MethodChannelSpatial();

  /// The passes for the player of [controller]: its texture becomes the view once [attach] answers
  factory SpatialPluginOutput.forController(
    VideoController controller, {
    int maxOutputHeight = PluginRenderer.defaultMaxOutputHeight,
  }) {
    final player = controller.player;
    return SpatialPluginOutput(
      handle: () async {
        // The plugin knows the player once its controller made the texture
        await controller.platform.future;
        return player.handle;
      },
      setMpvProperty: (name, value) async {
        final native = player.platform;
        if (native is NativePlayer) {
          await native.setProperty(name, value);
        }
      },
      adapter: DesktopGpuDecoders.adapter,
      maxOutputHeight: maxOutputHeight,
    );
  }

  /// Where the passes exist: renderer C of the vendored media_kit_video, on Windows only
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// The largest eye the passes read (the phones' MAX_EYE_PIXELS, kMaxEyePixels of the plugin)
  static const maxEyePixels = 1920 * 1080;

  /// The frame of a flat video at each step down: a share of the size the eyes use
  static const flatFrameScales = [1.0, 0.75, 0.5];

  /// A viewpoint closer than this to the one sent is not sent: a fraction of a pixel at these disparities
  static const viewpointDeadBand = 0.002;

  final Future<int> Function() _handle;
  final Future<void> Function(String name, String value)? _setMpvProperty;
  final SpatialChannel _channel;
  final Future<GpuAdapter?> Function()? _adapter;

  /// The most lines of the output; the shape of the box is kept
  final int maxOutputHeight;

  /// Window size changes closer than this are merged: each new size is a new texture of the player
  final Duration resizeDelay;

  /// After the last move of a 360° view, the sharper filter of a view at rest
  final Duration settleDelay;

  int? _handleValue;
  SpatialLook _look = const SpatialLook();
  Size _outputSize = const Size(1280, 720);
  PluginTier? _frameTier;
  Size? _videoSize;
  int _flatStep = 0;
  bool _forcedLow = false;

  // The plugin's counts of draws since the previous read, kept for each reader of [stats] until it reads them
  final _drawSums = <Object, _DrawSum>{};
  bool _attached = false;
  bool _disposed = false;
  String? _glRenderer;

  // The viewpoint and the view: the newest asked, the last sent, and whether a send waits for a frame or the plugin
  double _viewpoint = 0.5;
  double? _sentViewpoint;
  PluginView _view = const PluginView();
  bool _viewSharp = true;
  PluginView? _sentView;
  bool? _sentSharp;
  bool _frameScheduled = false;
  bool _sending = false;
  Timer? _resize;
  Timer? _settle;

  // enable, setLook, the output size and detach go to the plugin one after the other
  Future<void> _queue = Future.value();

  bool get attached => _attached;
  SpatialLook get look => _look;
  String? get glRenderer => _glRenderer;

  /// The viewpoint asked last: 0 the left camera, 1 the right one
  double get viewpoint => _viewpoint;

  /// The viewpoint sent to the plugin last, null before the passes attached
  double? get sentViewpoint => _sentViewpoint;

  /// The steps down taken: of the frame (flat), renderer C's tier (360°), and whether the disparity is held at LOW
  int get flatStep => _flatStep;
  PluginTier? get frameTier => _frameTier;
  bool get forcedLow => _forcedLow;

  /// Whether [stepDown] has something left to change
  bool get canStepDown {
    if (!_forcedLow) {
      return true;
    }
    return _look.projection == SpatialProjection.equirect
        ? _frameTier?.lower != null
        : _flatStep < flatFrameScales.length - 1;
  }

  /// Turns the passes on for the player with [look], into a box of [outputSize] physical pixels, from [viewpoint]
  /// (and [view] for a 360° video). Call it before the file opens. Answers whether the passes draw; when not, the
  /// player shows the frame as it is.
  Future<ProjectionResult> attach({
    required SpatialLook look,
    required Size outputSize,
    double viewpoint = 0.5,
    PluginView view = const PluginView(),
  }) {
    final done = Completer<ProjectionResult>();
    _enqueue(() async {
      if (_disposed) {
        done.complete(const ProjectionResult(ok: false, reason: 'disposed'));
        return;
      }
      final handle = _handleValue ??= await _handle();
      _look = look;
      _outputSize = outputSize;
      // A new file is measured afresh
      _videoSize = null;
      _flatStep = 0;
      _forcedLow = false;
      _viewpoint = viewpoint.clamp(0.0, 1.0);
      _view = view;
      _viewSharp = true;
      // The frame mpv draws keeps the video's shape exactly, as renderer C's pages ask
      await _setMpvProperty?.call('keepaspect', 'no');
      var result = await _channel.enable(handle, _setup(viewpoint: _viewpoint));
      if (result.ok && look.projection == SpatialProjection.equirect && _frameTier == null) {
        // A 360° frame takes renderer C's tier of this GPU once the plugin made its context; no frame is drawn yet,
        // and the passes are compiled once, so the change costs little
        final tier = PluginTier.startFor(result.glRenderer, adapter: await _gpuAdapter());
        _frameTier = tier;
        result = await _channel.enable(handle, _setup(viewpoint: _viewpoint));
      }
      if (!result.ok) {
        _log.warning('the Spatial passes were refused: ${result.reason}');
        _attached = false;
        await _setMpvProperty?.call('keepaspect', 'yes');
        done.complete(result);
        return;
      }
      _attached = true;
      _glRenderer = result.glRenderer;
      _sentViewpoint = _viewpoint;
      _sentView = null;
      _sentSharp = null;
      _scheduleSend();
      _log.info('Spatial passes: $look, ${result.glRenderer}, ${result.outputWidth}x${result.outputHeight}');
      done.complete(result);
    }, onError: (error) => done.complete(ProjectionResult(ok: false, reason: '$error')));
    return done.future;
  }

  /// Another layout, projection or coverage for the same video: a new setup of the same passes, nothing of mpv.
  /// [videoSize]: the size of the video's frame once known, which sets the frame a flat video is drawn into.
  Future<bool> setLook(SpatialLook look, {Size? videoSize}) {
    final size = videoSize == null || videoSize.isEmpty ? _videoSize : videoSize;
    if (look == _look && size == _videoSize) {
      return Future.value(_attached);
    }
    return _change(() async {
      if (look.projection != _look.projection) {
        _frameTier = look.projection == SpatialProjection.equirect ? (_frameTier ?? PluginTier.w2880) : null;
      }
      _look = look;
      _videoSize = size;
      return _enable();
    });
  }

  /// A step down when the frames do not keep up: a smaller frame for mpv (flat: [flatFrameScales]; 360°: renderer C's
  /// next tier), then the disparity held at LOW. Null when nothing is left to change, or the plugin refused.
  Future<SpatialStepDown?> stepDown() {
    final done = Completer<SpatialStepDown?>();
    _enqueue(() async {
      if (_disposed || !_attached) {
        done.complete(null);
        return;
      }
      SpatialStepDown? step;
      if (_look.projection == SpatialProjection.equirect) {
        final lower = _frameTier?.lower;
        if (lower != null) {
          _frameTier = lower;
          step = SpatialStepDown.frame;
        }
      } else if (_flatStep < flatFrameScales.length - 1) {
        _flatStep++;
        step = SpatialStepDown.frame;
      }
      if (step == null && !_forcedLow) {
        _forcedLow = true;
        step = SpatialStepDown.lowQuality;
      }
      if (step == null) {
        done.complete(null);
        return;
      }
      final setup = _setup();
      _log.info(
        'Spatial passes a step down: ${step.name}, frame at most ${setup.maxFrameWidth} wide and '
        '${setup.maxFramePixels} pixels, ${setup.quality.name}${setup.adaptiveQuality ? ', adaptive' : ''}',
      );
      done.complete(await _enable() ? step : null);
    }, onError: (_) => done.complete(null));
    return done.future;
  }

  /// The viewpoint, 0 the left camera to 1 the right one. However often this is called, the plugin gets at most one
  /// per Flutter frame, the newest.
  void setViewpoint(double viewpoint) {
    if (_disposed) {
      return;
    }
    _viewpoint = viewpoint.clamp(0.0, 1.0);
    _scheduleSend();
  }

  /// The view of a 360° or VR180 video. [moving]: part of a drag or a wheel turn, drawn bilinear, the sharper filter
  /// [settleDelay] after the last move
  void setView(PluginView view, {bool moving = true}) {
    if (_disposed) {
      return;
    }
    _view = view;
    _settle?.cancel();
    if (moving) {
      _viewSharp = false;
      _settle = Timer(settleDelay, () {
        _viewSharp = true;
        _scheduleSend();
      });
    } else {
      _viewSharp = true;
    }
    _scheduleSend();
  }

  /// The window's new size in physical pixels, sent after [resizeDelay] without a newer one
  void setOutputSize(Size size) {
    if (_disposed || size == _outputSize) {
      return;
    }
    _outputSize = size;
    _resize?.cancel();
    _resize = Timer(resizeDelay, () => unawaited(_change(_enable)));
  }

  /// The disparity map of the left eye instead of the view, for the troubleshooting overlay
  Future<bool> setDebug({required bool disparityMap}) => _change(() async {
    final handle = _handleValue;
    if (!_attached || handle == null) {
      return false;
    }
    return _channel.setDebug(handle, disparityMap: disparityMap);
  });

  /// What the passes did since [reader]'s previous call. The plugin counts the draws since anyone read them: here
  /// they are kept for every reader, so that the troubleshooting figures, the measure of the page and a test each get
  /// all of them.
  Future<SpatialStats?> stats({bool probe = false, Object reader = _defaultReader}) async {
    final handle = _handleValue;
    if (handle == null || !_attached || _disposed) {
      return null;
    }
    SpatialStats? stats;
    try {
      stats = await _channel.stats(handle, probe: probe);
    } catch (error) {
      _log.fine('Spatial stats not read: $error');
    }
    _drawSums.putIfAbsent(reader, _DrawSum.new);
    if (stats != null) {
      for (final sum in _drawSums.values) {
        sum.add(stats.draws);
      }
    }
    final sum = _drawSums[reader]!;
    if (stats == null) {
      return null;
    }
    final draws = sum.take(stats.draws);
    return _withDraws(stats, draws);
  }

  static const _defaultReader = Object();

  /// The player's texture shows the video's frame again; the passes can be attached again
  Future<void> detach() {
    _resize?.cancel();
    _settle?.cancel();
    final done = Completer<void>();
    _enqueue(() async {
      if (_attached) {
        _attached = false;
        final handle = _handleValue;
        if (handle != null) {
          await _channel.disable(handle);
        }
        await _setMpvProperty?.call('keepaspect', 'yes');
      }
      done.complete();
    }, onError: (_) => done.complete());
    return done.future;
  }

  /// [detach], and no call afterwards
  Future<void> dispose() async {
    await detach();
    _disposed = true;
  }

  SpatialSetup _setup({double? viewpoint}) {
    final tier = _frameTier;
    final flat = spatialFlatFrameCap(
      layout: _look.layout,
      outputSize: _outputSize,
      maxOutputHeight: maxOutputHeight,
      videoWidth: _videoSize?.width.round(),
      videoHeight: _videoSize?.height.round(),
      scale: flatFrameScales[_flatStep],
    );
    final equirect = _look.projection == SpatialProjection.equirect;
    return SpatialSetup(
      layout: _look.layout,
      projection: _look.projection,
      halfSphere: _look.halfSphere,
      quality: _forcedLow ? SpatialQuality.low : SpatialQuality.medium,
      adaptiveQuality: !_forcedLow,
      viewpoint: viewpoint,
      maxFrameWidth: equirect ? (tier?.maxFrameWidth ?? 3840) : flat.maxFrameWidth,
      maxFramePixels: equirect ? (tier?.maxFramePixels ?? 3840 * 2160) : flat.maxFramePixels,
      outputWidth: math.max(1, _outputSize.width.round()),
      outputHeight: math.max(1, _outputSize.height.round()),
      maxOutputHeight: maxOutputHeight,
    );
  }

  Future<GpuAdapter?> _gpuAdapter() async {
    final adapter = _adapter;
    if (adapter == null) {
      return null;
    }
    try {
      return await adapter().timeout(PluginRenderer.adapterTimeout, onTimeout: () => null);
    } catch (error) {
      _log.fine('GPU adapter not known, the start tier follows the name: $error');
      return null;
    }
  }

  Future<bool> _enable() async {
    final handle = _handleValue;
    if (!_attached || handle == null) {
      return false;
    }
    final result = await _channel.enable(handle, _setup());
    if (!result.ok) {
      _log.warning('the Spatial passes refused a change: ${result.reason}');
    }
    return result.ok;
  }

  Future<bool> _change(Future<bool> Function() action) {
    final done = Completer<bool>();
    _enqueue(() async => done.complete(_disposed ? false : await action()), onError: (_) => done.complete(false));
    return done.future;
  }

  void _enqueue(Future<void> Function() action, {required void Function(Object error) onError}) {
    _queue = _queue.then((_) async {
      try {
        await action();
      } catch (error, stack) {
        _log.warning('Spatial passes call failed', error, stack);
        onError(error);
      }
    });
  }

  bool get _viewpointPending {
    final sent = _sentViewpoint;
    return sent == null || (_viewpoint - sent).abs() >= viewpointDeadBand;
  }

  bool get _pending =>
      _viewpointPending ||
      (_look.projection == SpatialProjection.equirect && (_view != _sentView || _viewSharp != _sentSharp));

  /// One viewpoint and one view per Flutter frame at most: the newest when the frame comes, and only once the plugin
  /// answered the previous ones, so that they never pile up on the platform thread
  void _scheduleSend() {
    if (_frameScheduled || !_attached || _disposed || !_pending) {
      return;
    }
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      unawaited(_send());
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> _send() async {
    final handle = _handleValue;
    if (_sending || handle == null || !_attached || _disposed) {
      return;
    }
    _sending = true;
    try {
      final viewpoint = _viewpoint;
      if (_viewpointPending) {
        // Counted as sent before the answer: a call that fails is not sent again at every frame
        _sentViewpoint = viewpoint;
        await _channel.setViewpoint(handle, viewpoint);
      }
      if (_look.projection == SpatialProjection.equirect) {
        final view = _view;
        final sharp = _viewSharp;
        if (view != _sentView || sharp != _sentSharp) {
          _sentView = view;
          _sentSharp = sharp;
          await _channel.setView(handle, view, sharp: sharp);
        }
      }
    } catch (error) {
      _log.fine('Spatial viewpoint not sent: $error');
    } finally {
      _sending = false;
    }
    if (_pending) {
      _scheduleSend();
    }
  }
}

/// The draws the plugin counted for one reader of [SpatialPluginOutput.stats] since its previous read; the times of
/// the newest [keptTimes] draws only, for a reader that reads seldom
class _DrawSum {
  static const keptTimes = 600;

  int frames = 0;
  int redraws = 0;
  int failed = 0;
  final frameMs = <double>[];
  final redrawMs = <double>[];
  final mpvMs = <double>[];
  final viewMs = <double>[];

  void add(ProjectionStats draws) {
    frames += draws.frames;
    redraws += draws.redraws;
    failed += draws.failed;
    frameMs.addAll(draws.frameMs);
    redrawMs.addAll(draws.redrawMs);
    mpvMs.addAll(draws.mpvMs);
    viewMs.addAll(draws.viewMs);
    for (final times in [frameMs, redrawMs, mpvMs, viewMs]) {
      if (times.length > keptTimes) {
        times.removeRange(0, times.length - keptTimes);
      }
    }
  }

  /// The counts kept, on the rest of [latest], and nothing kept afterwards
  ProjectionStats take(ProjectionStats latest) {
    final draws = ProjectionStats(
      enabled: latest.enabled,
      frames: frames,
      redraws: redraws,
      failed: failed,
      frameMs: List.unmodifiable(frameMs),
      redrawMs: List.unmodifiable(redrawMs),
      lockedMs: latest.lockedMs,
      sizeMs: latest.sizeMs,
      mpvMs: List.unmodifiable(mpvMs),
      viewMs: List.unmodifiable(viewMs),
      frameWidth: latest.frameWidth,
      frameHeight: latest.frameHeight,
      outputWidth: latest.outputWidth,
      outputHeight: latest.outputHeight,
      error: latest.error,
      glRenderer: latest.glRenderer,
      probe: latest.probe,
    );
    frames = 0;
    redraws = 0;
    failed = 0;
    frameMs.clear();
    redrawMs.clear();
    mpvMs.clear();
    viewMs.clear();
    return draws;
  }
}

SpatialStats _withDraws(SpatialStats stats, ProjectionStats draws) => SpatialStats(
  draws: draws,
  spatial: stats.spatial,
  stereo: stats.stereo,
  quality: stats.quality,
  renderFps: stats.renderFps,
  disparityFps: stats.disparityFps,
  renderMs: stats.renderMs,
  disparityWidth: stats.disparityWidth,
  disparityHeight: stats.disparityHeight,
  eyeWidth: stats.eyeWidth,
  eyeHeight: stats.eyeHeight,
  viewpoint: stats.viewpoint,
  requestedViewpoint: stats.requestedViewpoint,
  gpuTimer: stats.gpuTimer,
  halfFloatMaps: stats.halfFloatMaps,
  spatialDraws: stats.spatialDraws,
  disparityRuns: stats.disparityRuns,
  settleRuns: stats.settleRuns,
  qualityChanges: stats.qualityChanges,
  drawnWidth: stats.drawnWidth,
  drawnHeight: stats.drawnHeight,
  showDisparity: stats.showDisparity,
  probeRow: stats.probeRow,
);
