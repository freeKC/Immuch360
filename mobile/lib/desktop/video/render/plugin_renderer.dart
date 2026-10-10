// Renderer C of the 360 player on Windows (design 2.3, decision DP1 of 2026-10-09, docs 20-desktop-dp1.md): the
// vendored media_kit_video draws the view itself. mpv draws each frame, as for a flat video, into an intermediate
// texture of the video's size capped by a tier; one pass of the plugin draws the view from it into the player's
// texture, the one its VideoController already gives Flutter, so the page keeps the Video widget, the controller and
// the pool. Why not mpv's own renderer with a hook (renderer A): every view change went through glsl-shader-opts,
// which rebuilds mpv's passes, kept 40 to 200 MB of GPU memory per change on the RTX 4060 until the PC ran out of
// memory, and gave 11 fps on the Intel UHD (spikes 3 and 4).
//
// The rules this class keeps for the player (DP1, section 4.3):
// - the view is a uniform of the plugin's pass, sent at most once per Flutter frame however fast the drag events
//   come; nothing of mpv changes during a drag;
// - bilinear while the view moves, the sharper filter once it rests (settleDelay after the last move);
// - the output follows the window (physical pixels, at most maxOutputHeight lines from the first frame), the
//   intermediate texture follows the video and the tier only;
// - a tier changes at most once a second once a frame was drawn, since mpv then draws its frame again at the new size;
// - a paused video is redrawn by the plugin from the frame it keeps, without mpv.
//
// What V-360 calls: PluginRenderer.forController(controller), then attach before the file opens (so that the
// texture is the view from the first frame), setView on every drag, wheel or key event, setOutputSize when the
// window changes, setProjection for the 3D cycle and the 180/360 switch, setTier from the renderer probe, stats for
// the probe and the troubleshooting page, detach when the page closes or hands the player back to the pool.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

final _log = Logger('PluginRenderer');

/// The size of the intermediate texture mpv draws each frame into (DP1, section 4.3). The texture is RGBA 8 bits:
/// Flutter's texture is BGRA 8 bits anyway and mpv tone maps HDR before it draws.
enum PluginTier {
  /// The video's own size, at most 8192 wide: 66 MB for a 5.7K video, 118 MB for an 8K one. The start on a dedicated
  /// GPU.
  full(maxFrameWidth: 8192, maxFramePixels: 8192 * 4096),

  /// At most 4096 x 2048 (33.5 MB): the step down from [full]
  w4096(maxFrameWidth: 4096, maxFramePixels: 4096 * 2048),

  /// At most 2880 x 1440 (16.6 MB), the render height cap of the flat player: the start on an integrated GPU
  w2880(maxFrameWidth: 2880, maxFramePixels: 2880 * 1440);

  const PluginTier({required this.maxFrameWidth, required this.maxFramePixels});

  final int maxFrameWidth;
  final int maxFramePixels;

  /// The next tier down, null below [w2880] (renderer B or the flat player then)
  PluginTier? get lower => switch (this) {
    PluginTier.full => PluginTier.w4096,
    PluginTier.w4096 => PluginTier.w2880,
    PluginTier.w2880 => null,
  };

  /// The tier a player starts at on the GPU ANGLE names in [glRenderer] (its renderer string, "ANGLE (Intel,
  /// Intel(R) UHD Graphics ...)"): [full] on a dedicated GPU, [w2880] on an integrated one or one not recognised.
  /// DP1 assumed [w4096] for an integrated GPU; the skeleton measured on the Intel UHD of the owner's PC (2026-10-09)
  /// 22 frames a second at rest and 17 while dragging for a 5.7K video at [w4096], 27 and 19 at [w2880], and for an
  /// 8K video 21 at [w4096] against 29 at [w2880]. The RTX 4060 holds 30 at [full] for both.
  static PluginTier startFor(String? glRenderer) {
    final name = (glRenderer ?? '').toLowerCase();
    final dedicated =
        name.contains('nvidia') ||
        name.contains('geforce') ||
        name.contains('quadro') ||
        name.contains('rtx') ||
        name.contains('radeon rx') ||
        name.contains('radeon pro') ||
        name.contains('intel(r) arc') ||
        RegExp(r'\barc\b').hasMatch(name);
    return dedicated ? PluginTier.full : PluginTier.w2880;
  }
}

/// Which eye of a stereo frame is shown
enum PluginEye { left, right }

/// What renderer C draws: an equirectangular frame (mono, one eye of a stereo frame, 360 or 180 degrees), or the
/// stitch of a raw camera's frame from its rawProjection JSON
@immutable
class PluginProjection {
  const PluginProjection._({
    required this.kind,
    this.eye = const [0, 0, 1, 1],
    this.crop = const [0, 0, 1, 1],
    this.tracks = 1,
    this.streamsEnabled = const [1, 1],
    this.uniforms = const {},
  });

  /// An equirectangular frame in [layout], [eye] shown (the left one by default, as the phones show), over the whole
  /// sphere or, for [SphereCoverage.half], its front half with black behind (VR180)
  factory PluginProjection.equirect({
    StereoLayout layout = StereoLayout.mono,
    SphereCoverage coverage = SphereCoverage.full,
    PluginEye eye = PluginEye.left,
  }) {
    final left = layout.leftEyeRect;
    final rect = eye == PluginEye.left
        ? [left.left, left.top, left.width, left.height]
        : switch (layout) {
            StereoLayout.mono => const [0.0, 0.0, 1.0, 1.0],
            StereoLayout.topBottom => const [0.0, 0.5, 1.0, 0.5],
            StereoLayout.leftRight => const [0.5, 0.0, 0.5, 1.0],
          };
    return PluginProjection._(
      kind: ProjectionKind.equirect,
      eye: rect,
      crop: coverage == SphereCoverage.half ? const [0.25, 0.0, 0.5, 1.0] : const [0.0, 0.0, 1.0, 1.0],
    );
  }

  /// The stitch of a raw 360 video from its rawProjection JSON version 2 (RawVideoPlan.toNativeJson): a fisheye pair
  /// (Mei, equidistant, Kannala-Brandt) or a GoPro EAC pair. The frame mpv draws holds the decoded streams side by
  /// side: the one frame of a side by side file, or the tracks (or files) of the JSON's "tracks" in their order,
  /// stacked with lavfi-complex "[vidA] [vidB] hstack [vo]" (design 2.5). [streamsEnabled]: false for a stream that is
  /// not decoded (one lens mode, half of the sphere black). [streamsInFrame]: the streams the frame holds when it is
  /// not the JSON's number of tracks (1 when only the first of two tracks is decoded). Throws a [FormatException] for a
  /// JSON it cannot draw.
  factory PluginProjection.raw(
    String rawProjectionJson, {
    List<bool> streamsEnabled = const [true, true],
    int? streamsInFrame,
  }) {
    final decoded = jsonDecode(rawProjectionJson);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('rawProjection: not an object');
    }
    return PluginProjection._(
      kind: decoded['kind'] == 'eacGoPro' ? ProjectionKind.eacPair : ProjectionKind.fisheyePair,
      tracks: switch (decoded['tracks']) {
        final List<Object?> tracks when tracks.isNotEmpty => streamsInFrame ?? tracks.length,
        _ => throw const FormatException('rawProjection: no tracks'),
      },
      streamsEnabled: [for (var i = 0; i < 2; i++) (i < streamsEnabled.length && !streamsEnabled[i]) ? 0.0 : 1.0],
      uniforms: rawStitchUniforms(decoded),
    );
  }

  final ProjectionKind kind;
  final List<double> eye;
  final List<double> crop;
  final int tracks;
  final List<double> streamsEnabled;
  final Map<String, List<double>> uniforms;

  @override
  String toString() => 'PluginProjection(${kind.name}, eye $eye, crop $crop, tracks $tracks)';
}

/// The uniforms of the stitch pass for the rawProjection [json] (version 2), by the names of RawStitchShaders.kt and
/// with the values RawStitchUniforms.kt computes, so that the desktop draws the phones' picture: matrices column
/// major (the JSON writes them row major), lens-local intrinsics (lens i's cx minus i times the canvas square),
/// angles in radians. The half texels are left out: the pass computes them from its own texture. Throws a
/// [FormatException] for a kind, a model or a lens it does not know.
@visibleForTesting
Map<String, List<double>> rawStitchUniforms(Map<String, Object?> json) {
  if (json['version'] != 2) {
    throw FormatException('rawProjection: version ${json['version']}');
  }
  double number(Object? value, String what) => switch (value) {
    final num n => n.toDouble(),
    _ => throw FormatException('rawProjection: $what'),
  };
  double optional(Object? value) => value is num ? value.toDouble() : 0.0;
  List<double> numbers(Object? value, int length, String what) => switch (value) {
    final List<Object?> list when list.length == length => [for (final item in list) number(item, what)],
    _ => throw FormatException('rawProjection: $what'),
  };
  List<double> columnMajor(List<double> rowMajor) => [for (var i = 0; i < 9; i++) rowMajor[(i % 3) * 3 + i ~/ 3]];
  double radians(double degrees) => degrees * math.pi / 180;

  final values = <String, List<double>>{};
  switch (json['kind']) {
    case 'dualFisheye':
      final model = json['model'];
      final modelValue = switch (model) {
        'mei' => 0.0,
        'equidistant' => 1.0,
        'kannalaBrandt' => 2.0,
        _ => throw FormatException('rawProjection: model $model'),
      };
      final square = number(json['canvasSquare'], 'canvasSquare');
      final lenses = switch (json['lenses']) {
        final List<Object?> list when list.length == 2 => list,
        _ => throw const FormatException('rawProjection: lenses'),
      };
      for (final (index, item) in lenses.indexed) {
        if (item is! Map<String, Object?>) {
          throw const FormatException('rawProjection: lens');
        }
        values['uViewToLens$index'] = columnMajor(numbers(item['viewToLens'], 9, 'viewToLens'));
        values['uIntr$index'] = [
          optional(item['fx']),
          optional(item['fy']),
          number(item['cx'], 'cx') - index * square,
          number(item['cy'], 'cy'),
        ];
        values['uK$index'] = [optional(item['k1']), optional(item['k2']), optional(item['k3']), optional(item['k4'])];
        values['uX$index'] = [optional(item['k5']), optional(item['xi']), optional(item['p1']), optional(item['p2'])];
        values['uRegion$index'] = numbers(item['region'], 4, 'region');
        values['uTexOf$index'] = [number(item['texture'], 'texture')];
        values['uEquidistantFocal$index'] = [
          model == 'equidistant'
              ? number(item['radius'], 'radius') / radians(number(item['radiusTheta'], 'radiusTheta'))
              : 0.0,
        ];
      }
      values['uModel'] = [modelValue];
      values['uSquare'] = [square];
      values['uTheta'] = [
        radians(number(json['maxTheta'], 'maxTheta')),
        radians(number(json['blendStart'], 'blendStart')),
        radians(number(json['blendEnd'], 'blendEnd')),
      ];
    case 'eacGoPro':
      final face = number(json['face'], 'face');
      final half = number(json['half'], 'half');
      final right = number(json['right'], 'right');
      values['uViewToCamera'] = columnMajor(numbers(json['viewToCamera'], 9, 'viewToCamera'));
      final faces = switch (json['faces']) {
        final List<Object?> list when list.length == 6 => list,
        _ => throw const FormatException('rawProjection: faces'),
      };
      for (final (index, item) in faces.indexed) {
        if (item is! Map<String, Object?>) {
          throw const FormatException('rawProjection: face');
        }
        // Rows right, down, forward: face * c gives the coordinates of c on the face, forward in z
        values['uFace$index'] = columnMajor([
          ...numbers(item['right'], 3, 'right'),
          ...numbers(item['down'], 3, 'down'),
          ...numbers(item['forward'], 3, 'forward'),
        ]);
        values['uFaceSlot$index'] = [number(item['texture'], 'texture'), number(item['slot'], 'slot')];
      }
      values['uEac'] = [face, half, number(json['overlap'], 'overlap'), number(json['middle'], 'middle')];
      values['uEacRight'] = [right];
      values['uTrackSize'] = [right + 2 * half, face];
    default:
      throw FormatException('rawProjection: kind ${json['kind']}');
  }
  return values;
}

/// A view of the sphere: [yaw] and [pitch] in degrees (yaw positive to the right of the frame's centre, pitch
/// positive up, the longitude and latitude of the photo sphere), [fov] the vertical field of view in degrees
@immutable
class PluginView {
  const PluginView({this.yaw = 0, this.pitch = 0, this.fov = 90});

  final double yaw;
  final double pitch;
  final double fov;

  @override
  bool operator ==(Object other) => other is PluginView && other.yaw == yaw && other.pitch == pitch && other.fov == fov;

  @override
  int get hashCode => Object.hash(yaw, pitch, fov);

  @override
  String toString() => 'PluginView($yaw, $pitch, $fov)';
}

/// The calls of the plugin, so that the tests give their own (ProjectionOutput's static calls otherwise)
abstract interface class PluginChannel {
  Future<ProjectionResult> enable(int handle, ProjectionSetup setup);
  Future<ProjectionResult> disable(int handle);
  Future<bool> setView(int handle, PluginView view, {required bool sharp});
  Future<ProjectionStats?> stats(int handle, {bool probe = false});
}

class _MethodChannelPlugin implements PluginChannel {
  const _MethodChannelPlugin();

  @override
  Future<ProjectionResult> enable(int handle, ProjectionSetup setup) => ProjectionOutput.enable(handle, setup);

  @override
  Future<ProjectionResult> disable(int handle) => ProjectionOutput.disable(handle);

  @override
  Future<bool> setView(int handle, PluginView view, {required bool sharp}) =>
      ProjectionOutput.setView(handle, yaw: view.yaw, pitch: view.pitch, fov: view.fov, sharp: sharp);

  @override
  Future<ProjectionStats?> stats(int handle, {bool probe = false}) => ProjectionOutput.stats(handle, probe: probe);
}

/// The answer of [PluginRenderer.attach]: whether renderer C draws the player, and if not why (the probe then tries
/// renderer B, then the flat player)
@immutable
class PluginAttach {
  const PluginAttach({required this.ok, this.reason, this.tier, this.glRenderer, this.outputSize});

  final bool ok;
  final String? reason;
  final PluginTier? tier;

  /// The GPU that draws, as ANGLE names it: for the troubleshooting page
  final String? glRenderer;
  final Size? outputSize;

  @override
  String toString() => ok ? 'PluginAttach(${tier?.name}, $glRenderer, $outputSize)' : 'PluginAttach(refused: $reason)';
}

/// Renderer C for one player, see the top of this file
class PluginRenderer {
  PluginRenderer({
    required this._handle,
    this._setMpvProperty,
    PluginChannel? channel,
    this.maxOutputHeight = defaultMaxOutputHeight,
    this.settleDelay = const Duration(milliseconds: 150),
    this.resizeDelay = const Duration(milliseconds: 100),
    this.tierInterval = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _channel = channel ?? const _MethodChannelPlugin(),
       _now = now ?? DateTime.now;

  /// Renderer C for the player of [controller]: its texture becomes the view once [attach] answers
  factory PluginRenderer.forController(VideoController controller, {int maxOutputHeight = defaultMaxOutputHeight}) {
    final player = controller.player;
    return PluginRenderer(
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
      maxOutputHeight: maxOutputHeight,
    );
  }

  /// Where renderer C exists: the vendored media_kit_video draws it on Windows only (Linux and macOS in phase 4)
  static bool get supported => !kIsWeb && Platform.isWindows;

  /// The render height cap of design 2.11, the flat player's (DesktopPlayerOptions.maxRenderHeight)
  static const defaultMaxOutputHeight = 1440;

  final Future<int> Function() _handle;
  final Future<void> Function(String name, String value)? _setMpvProperty;
  final PluginChannel _channel;
  final DateTime Function() _now;

  /// The most lines of the output; the window's shape is kept
  final int maxOutputHeight;

  /// After the last move of the view, the sharper filter of a view at rest
  final Duration settleDelay;

  /// Window size changes closer than this are merged: each new size is a new texture of the player
  final Duration resizeDelay;

  /// The least time between two tier changes once a frame was drawn
  final Duration tierInterval;

  int? _handleValue;
  PluginProjection? _projection;
  PluginTier? _tier;
  Size? _outputSize;
  String? _glRenderer;
  bool _attached = false;
  bool _disposed = false;
  DateTime? _lastTierChange;

  // The view: the newest one asked, the one last sent, and whether a send waits for a frame or for the plugin
  PluginView _view = const PluginView();
  bool _viewSharp = true;
  PluginView? _sentView;
  bool? _sentSharp;
  bool _frameScheduled = false;
  bool _sending = false;
  Timer? _settle;
  Timer? _resize;

  // setProjection, setOutputSize, setTier and detach go to the plugin one after the other
  Future<void> _queue = Future.value();

  bool get attached => _attached;
  PluginTier? get tier => _tier;
  PluginProjection? get projection => _projection;
  String? get glRenderer => _glRenderer;
  PluginView get view => _view;

  /// Draws the player through renderer C from now on: [projection] at [tier] (or the start tier of the GPU when
  /// null), into an output of [outputSize] physical pixels capped at [maxOutputHeight] lines. Call it before the file
  /// opens, so that the first texture already is the view. Answers whether C draws; when not, the player is as
  /// before.
  Future<PluginAttach> attach({
    required PluginProjection projection,
    required Size outputSize,
    PluginTier? tier,
    PluginView view = const PluginView(),
  }) {
    final done = Completer<PluginAttach>();
    _enqueue(() async {
      if (_disposed) {
        done.complete(const PluginAttach(ok: false, reason: 'disposed'));
        return;
      }
      final handle = _handleValue ??= await _handle();
      _projection = projection;
      _outputSize = outputSize;
      _view = view;
      _viewSharp = true;
      // The frame mpv draws keeps the video's shape exactly: mpv's own letterbox would leave a row or a column of
      // black at the seam or at a pole, where the intermediate size was rounded
      await _setMpvProperty?.call('keepaspect', 'no');
      var chosen = tier ?? PluginTier.w2880;
      var result = await _channel.enable(handle, _setup(projection, chosen, outputSize));
      if (result.ok && tier == null) {
        // The GPU is known once the plugin made its context: a dedicated one starts at the full size. No frame is
        // drawn yet, so the change costs nothing.
        final start = PluginTier.startFor(result.glRenderer);
        if (start != chosen) {
          chosen = start;
          result = await _channel.enable(handle, _setup(projection, chosen, outputSize));
        }
      }
      if (!result.ok) {
        _log.warning('renderer C refused: ${result.reason}');
        await _setMpvProperty?.call('keepaspect', 'yes');
        done.complete(PluginAttach(ok: false, reason: result.reason, glRenderer: result.glRenderer));
        return;
      }
      _attached = true;
      _tier = chosen;
      _glRenderer = result.glRenderer;
      _lastTierChange = null;
      _sentView = null;
      _sentSharp = null;
      _scheduleViewSend();
      _log.info('renderer C: ${chosen.name}, ${result.glRenderer}, ${result.outputWidth}x${result.outputHeight}');
      done.complete(
        PluginAttach(
          ok: true,
          tier: chosen,
          glRenderer: result.glRenderer,
          outputSize: result.outputWidth == null || result.outputHeight == null
              ? null
              : Size(result.outputWidth!.toDouble(), result.outputHeight!.toDouble()),
        ),
      );
    }, onError: (error) => done.complete(PluginAttach(ok: false, reason: '$error')));
    return done.future;
  }

  /// The view. [moving]: part of a drag, a wheel turn or a held key, drawn bilinear, the sharper filter coming
  /// [settleDelay] after the last move; false for a view that rests at once. However often this is called, the plugin
  /// gets at most one view per Flutter frame, the newest.
  void setView(PluginView view, {bool moving = true}) {
    if (_disposed) {
      return;
    }
    _view = view;
    if (!_attached) {
      // Kept for the next attach, which sends it
      return;
    }
    _settle?.cancel();
    if (moving) {
      _viewSharp = false;
      _settle = Timer(settleDelay, () {
        _viewSharp = true;
        _scheduleViewSend();
      });
    } else {
      _viewSharp = true;
    }
    _scheduleViewSend();
  }

  /// Another projection for the same video (the 3D cycle, the 180 and 360 switch): uniforms of the pass only,
  /// nothing of mpv
  Future<bool> setProjection(PluginProjection projection) => _change(() async {
    _projection = projection;
    return _enable();
  });

  /// The window's new size in physical pixels: the output follows after [resizeDelay] without a new size, so that a
  /// window dragged by its border makes a few textures, not one per pixel. The intermediate texture does not change.
  void setOutputSize(Size size) {
    if (_disposed || size == _outputSize) {
      return;
    }
    _outputSize = size;
    _resize?.cancel();
    _resize = Timer(resizeDelay, () => unawaited(_change(_enable)));
  }

  /// Another tier, from the renderer probe; false (nothing done) within [tierInterval] of the previous change, since
  /// mpv then draws its frame again at the new size
  Future<bool> setTier(PluginTier tier) {
    final last = _lastTierChange;
    if (tier == _tier) {
      return Future.value(true);
    }
    if (last != null && _now().difference(last) < tierInterval) {
      return Future.value(false);
    }
    return _change(() async {
      final previous = _tier;
      _tier = tier;
      final ok = await _enable();
      if (ok) {
        _lastTierChange = _now();
      } else {
        _tier = previous;
      }
      return ok;
    });
  }

  /// What the plugin drew since the previous call; [probe] asks for five pixels of the next draw (the next call
  /// gives them)
  Future<ProjectionStats?> stats({bool probe = false}) async {
    final handle = _handleValue;
    if (handle == null || !_attached) {
      return null;
    }
    final stats = await _channel.stats(handle, probe: probe);
    if (stats != null && (stats.frames > 0 || stats.redraws > 0) && _lastTierChange == null) {
      // The first frame: from now on a tier change makes mpv draw again
      _lastTierChange = _now().subtract(tierInterval);
    }
    return stats;
  }

  /// The player's texture shows the video's frame again, as for a flat video; the renderer can attach again
  Future<void> detach() {
    _settle?.cancel();
    _resize?.cancel();
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

  ProjectionSetup _setup(PluginProjection projection, PluginTier tier, Size outputSize) => ProjectionSetup(
    kind: projection.kind,
    eye: projection.eye,
    crop: projection.crop,
    tracks: projection.tracks,
    streamsEnabled: projection.streamsEnabled,
    uniforms: projection.uniforms,
    maxFrameWidth: tier.maxFrameWidth,
    maxFramePixels: tier.maxFramePixels,
    outputWidth: math.max(1, outputSize.width.round()),
    outputHeight: math.max(1, outputSize.height.round()),
    maxOutputHeight: maxOutputHeight,
  );

  Future<bool> _enable() async {
    final handle = _handleValue;
    final projection = _projection;
    final tier = _tier;
    final size = _outputSize;
    if (!_attached || handle == null || projection == null || tier == null || size == null) {
      return false;
    }
    final result = await _channel.enable(handle, _setup(projection, tier, size));
    if (!result.ok) {
      _log.warning('renderer C refused a change: ${result.reason}');
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
        _log.warning('renderer C call failed', error, stack);
        onError(error);
      }
    });
  }

  /// One view per Flutter frame at most: the newest when the frame comes, and only once the plugin answered the
  /// previous one, so that views never pile up on the platform thread
  void _scheduleViewSend() {
    if (_frameScheduled || !_attached || _disposed) {
      return;
    }
    _frameScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _frameScheduled = false;
      unawaited(_sendView());
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  Future<void> _sendView() async {
    final handle = _handleValue;
    if (_sending || handle == null || !_attached || _disposed) {
      return;
    }
    final view = _view;
    final sharp = _viewSharp;
    if (view == _sentView && sharp == _sentSharp) {
      return;
    }
    _sending = true;
    try {
      await _channel.setView(handle, view, sharp: sharp);
      _sentView = view;
      _sentSharp = sharp;
    } catch (error) {
      _log.fine('renderer C view not sent: $error');
    } finally {
      _sending = false;
    }
    if (_view != _sentView || _viewSharp != _sentSharp) {
      _scheduleViewSend();
    }
  }
}
