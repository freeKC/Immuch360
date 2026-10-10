/// Immuch360: the calls of renderer C, the 360 projection drawn by the plugin on Windows (IMMUCH360-NOTE.md, patch 6).
///
/// mpv draws each frame of the player into an intermediate texture at the video's size, capped by the tier asked
/// here; one pass of the plugin draws the view from it into the player's texture, the one its [VideoController]
/// already gives Flutter. The view changes uniforms of that pass only, never an option of mpv, and a paused video is
/// redrawn from the texture kept, without mpv. The calls take the handle of the player (`Player.handle`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the frame of the video holds
enum ProjectionKind {
  /// An equirectangular frame: mono, or stereo with one eye shown, over the whole sphere or its front half
  equirect,

  /// The two fisheye lenses of a raw 360 camera, side by side in the frame
  fisheyePair,

  /// The two EAC tracks of a GoPro .360, side by side in the frame
  eacPair,
}

/// How the plugin draws a player: the projection, its tier and the output size
@immutable
class ProjectionSetup {
  const ProjectionSetup({
    required this.kind,
    this.eye = const [0, 0, 1, 1],
    this.crop = const [0, 0, 1, 1],
    this.tracks = 1,
    this.streamsEnabled = const [1, 1],
    this.uniforms = const {},
    required this.maxFrameWidth,
    required this.maxFramePixels,
    required this.outputWidth,
    required this.outputHeight,
    required this.maxOutputHeight,
  });

  final ProjectionKind kind;

  /// [ProjectionKind.equirect]: the eye shown, x, y, width, height in fractions of the frame, top left origin
  final List<double> eye;

  /// [ProjectionKind.equirect]: the part of the sphere that eye covers, in fractions of the equirectangular frame of
  /// the whole sphere (u 0.5 ahead, v 0 up): [0, 0, 1, 1] for 360 degrees, [0.25, 0, 0.5, 1] for VR180
  final List<double> crop;

  /// The stitches: the decoded streams side by side in the frame (2 once lavfi-complex stacked two tracks)
  final int tracks;

  /// The stitches: 1 for a decoded stream, 0 for the missing one in one lens mode
  final List<double> streamsEnabled;

  /// The stitches: the uniforms of the lenses or the faces by name (RawStitchShaders.kt's names; matrices of 9
  /// values, column major)
  final Map<String, List<double>> uniforms;

  /// The tier: the intermediate texture keeps the video's shape, at most [maxFrameWidth] wide and [maxFramePixels]
  /// pixels
  final int maxFrameWidth;
  final int maxFramePixels;

  /// The output in physical pixels, at most [maxOutputHeight] lines high (the shape kept)
  final int outputWidth;
  final int outputHeight;
  final int maxOutputHeight;

  Map<String, Object?> toArguments(int handle) => {
        'handle': handle,
        'enabled': true,
        'kind': kind.index,
        'eye': Float64List.fromList(eye),
        'crop': Float64List.fromList(crop),
        'tracks': tracks,
        'streamsEnabled': Float64List.fromList(streamsEnabled),
        'uniforms': {
          for (final MapEntry(:key, :value) in uniforms.entries)
            key: Float64List.fromList(value)
        },
        'maxFrameWidth': maxFrameWidth,
        'maxFramePixels': maxFramePixels,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'maxOutputHeight': maxOutputHeight,
      };
}

/// The answer of [ProjectionOutput.enable]
@immutable
class ProjectionResult {
  const ProjectionResult({
    required this.ok,
    this.reason,
    this.clientVersion,
    this.glRenderer,
    this.outputWidth,
    this.outputHeight,
  });

  factory ProjectionResult.fromMap(Object? value) {
    final map = value is Map ? value : const {};
    return ProjectionResult(
      ok: map['ok'] == true,
      reason: map['reason'] as String?,
      clientVersion: map['clientVersion'] as int?,
      glRenderer: map['glRenderer'] as String?,
      outputWidth: map['outputWidth'] as int?,
      outputHeight: map['outputHeight'] as int?,
    );
  }

  final bool ok;

  /// Why not, when not ok: "OpenGL ES 2.0 context: renderer C needs ES 3.0", "software rendering", ...
  final String? reason;

  /// The OpenGL ES version of the player's context (3, or 2 on a Direct3D 9 or feature level 9_3 device)
  final int? clientVersion;

  /// ANGLE's renderer string: the GPU that draws ("ANGLE (Intel, Intel(R) UHD Graphics ...)")
  final String? glRenderer;
  final int? outputWidth;
  final int? outputHeight;

  @override
  String toString() =>
      'ProjectionResult(${ok ? 'ok' : 'refused: $reason'}, ES $clientVersion, $glRenderer, '
      '${outputWidth}x$outputHeight)';
}

/// What the plugin drew since the previous [ProjectionOutput.stats] of the same player
@immutable
class ProjectionStats {
  const ProjectionStats({
    required this.enabled,
    required this.frames,
    required this.redraws,
    required this.failed,
    required this.frameMs,
    required this.redrawMs,
    required this.lockedMs,
    this.sizeMs = const [],
    this.mpvMs = const [],
    this.viewMs = const [],
    required this.frameWidth,
    required this.frameHeight,
    this.outputWidth,
    this.outputHeight,
    this.error,
    this.glRenderer,
    this.probe,
  });

  factory ProjectionStats.fromMap(Map<Object?, Object?> map) {
    List<double> times(Object? value) => switch (value) {
          final List<Object?> list => [
              for (final item in list) (item as num).toDouble()
            ],
          _ => const [],
        };
    final probe = map['probe'];
    final error = map['error'] as String?;
    return ProjectionStats(
      enabled: map['enabled'] == true,
      frames: map['frames'] as int? ?? 0,
      redraws: map['redraws'] as int? ?? 0,
      failed: map['failed'] as int? ?? 0,
      frameMs: times(map['frameMs']),
      redrawMs: times(map['redrawMs']),
      lockedMs: times(map['lockedMs']),
      sizeMs: times(map['sizeMs']),
      mpvMs: times(map['mpvMs']),
      viewMs: times(map['viewMs']),
      frameWidth: map['frameWidth'] as int? ?? 0,
      frameHeight: map['frameHeight'] as int? ?? 0,
      outputWidth: map['outputWidth'] as int?,
      outputHeight: map['outputHeight'] as int?,
      error: error == null || error.isEmpty ? null : error,
      glRenderer: map['glRenderer'] as String?,
      probe: probe is List ? [for (final pixel in probe) pixel as int] : null,
    );
  }

  final bool enabled;

  /// Draws with a new frame of mpv (mpv into the intermediate texture, then the view)
  final int frames;

  /// Draws of a new view from the frame kept, without mpv
  final int redraws;

  /// Draws that could not happen (no frame yet, a program that did not compile)
  final int failed;

  /// Duration of each draw with a new frame, and of each redraw, in milliseconds, on the plugin's render thread
  final List<double> frameMs;
  final List<double> redrawMs;

  /// The part of each draw during which Flutter's raster thread would wait to copy the texture
  final List<double> lockedMs;

  /// The parts of each draw with a new frame: asking mpv the video's size, mpv's render call, then the view and the
  /// GPU's end of all of it
  final List<double> sizeMs;
  final List<double> mpvMs;
  final List<double> viewMs;

  /// The intermediate texture, 0 x 0 before the first frame
  final int frameWidth;
  final int frameHeight;
  final int? outputWidth;
  final int? outputHeight;
  final String? error;
  final String? glRenderer;

  /// Five pixels of the output (centre, top, bottom, left, right), 0xAABBGGRR, when an earlier call asked for them
  final List<int>? probe;
}

/// The method calls of renderer C on the channel of media_kit_video
abstract final class ProjectionOutput {
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');

  /// Turns renderer C on for the player [handle] with [setup], or changes its setup (another output size, another
  /// tier). The texture of the player's [VideoController] becomes the view, at the output size.
  static Future<ProjectionResult> enable(
          int handle, ProjectionSetup setup) async =>
      ProjectionResult.fromMap(await _channel.invokeMethod<Object?>(
        'VideoOutputManager.SetProjection',
        setup.toArguments(handle),
      ));

  /// Turns renderer C off: the texture shows the video's frame again, as upstream draws it
  static Future<ProjectionResult> disable(int handle) async =>
      ProjectionResult.fromMap(
        await _channel.invokeMethod<Object?>('VideoOutputManager.SetProjection',
            {'handle': handle, 'enabled': false}),
      );

  /// The view: [yaw] and [pitch] in degrees (yaw positive to the right of the frame's centre, pitch positive up),
  /// [fov] the vertical field of view in degrees, [sharp] the sharper filter of a view at rest. False when the
  /// player has no video output.
  static Future<bool> setView(int handle,
          {required double yaw,
          required double pitch,
          required double fov,
          required bool sharp}) async =>
      await _channel.invokeMethod<bool>('VideoOutputManager.SetView', {
        'handle': handle,
        'yaw': yaw,
        'pitch': pitch,
        'fov': fov,
        'sharp': sharp,
      }) ??
      false;

  /// What the plugin drew since the previous call; [probe] asks for five pixels of the next draw, given by the
  /// next call. Null when the player has no video output.
  static Future<ProjectionStats?> stats(int handle,
      {bool probe = false}) async {
    final value = await _channel
        .invokeMethod<Object?>('VideoOutputManager.ProjectionStats', {
      'handle': handle,
      'probe': probe,
    });
    return value is Map ? ProjectionStats.fromMap(value) : null;
  }
}
