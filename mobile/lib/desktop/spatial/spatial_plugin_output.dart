// The Spatial passes of renderer C for one player of the Spatial page (packages/media_kit_video, IMMUCH360-NOTE.md
// patch 11: SpatialOutput), kept as the 360° player keeps renderer C (render/plugin_renderer.dart). They are turned on
// before the file opens, so that the first frame is already the view at the viewpoint. The viewpoint, and for a 360°
// or VR180 stereo video the view, go to the plugin at most once per Flutter frame, the newest, and only once the plugin
// answered the previous one, however fast the head, the mouse or the keys move. The output follows the window
// (physical pixels, at most maxOutputHeight lines), merged while a border is dragged. The layout, the projection and
// the 180 or 360 switch are a new setup of the same passes: nothing of mpv changes. A paused video is redrawn by the
// plugin from the frame it keeps.
// The intermediate texture is the plugin's default for a flat video (two eyes of 1920 x 1080, the most the passes
// read), and for a 360° video the start tier of renderer C on this GPU (PluginTier.startFor).

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

  /// Another layout, projection or coverage for the same video: a new setup of the same passes, nothing of mpv
  Future<bool> setLook(SpatialLook look) {
    if (look == _look) {
      return Future.value(_attached);
    }
    return _change(() async {
      if (look.projection != _look.projection) {
        _frameTier = look.projection == SpatialProjection.equirect ? (_frameTier ?? PluginTier.w2880) : null;
      }
      _look = look;
      return _enable();
    });
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

  /// What the passes did since the previous call
  Future<SpatialStats?> stats({bool probe = false}) async {
    final handle = _handleValue;
    if (handle == null || !_attached || _disposed) {
      return null;
    }
    try {
      return await _channel.stats(handle, probe: probe);
    } catch (error) {
      _log.fine('Spatial stats not read: $error');
      return null;
    }
  }

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
    return SpatialSetup(
      layout: _look.layout,
      projection: _look.projection,
      halfSphere: _look.halfSphere,
      viewpoint: viewpoint,
      maxFrameWidth: tier?.maxFrameWidth ?? 3840,
      maxFramePixels: tier?.maxFramePixels ?? 3840 * 2160,
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

  bool get _pending =>
      _viewpoint != _sentViewpoint ||
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
      if (viewpoint != _sentViewpoint) {
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
