/// Immuch360: the calls of the Spatial 2.5D passes drawn by the plugin on Windows (IMMUCH360-NOTE.md, patch 11).
///
/// A stereo video is shown from a viewpoint between its two cameras, which the head of the person in front of the
/// screen moves (or the mouse, or the arrow keys). mpv draws each frame into renderer C's intermediate texture, as for
/// a 360 video (projection_output.dart), and the passes of the phones' SpatialRenderer.kt draw the view from it into
/// the player's texture, the one its [VideoController] already gives Flutter: the eyes, the disparity found by block
/// matching both ways, checked and blended over time, then the view at the viewpoint. The viewpoint changes a uniform
/// only, merged like the views of renderer C, and a paused video is redrawn from the frame kept, without mpv. The
/// calls take the handle of the player (`Player.handle`).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:media_kit_video/src/projection_output.dart';

/// Where the two eyes are in the frame, in the order of the phones' EyeLayout
enum SpatialLayout {
  /// The left eye in the left half
  sideBySide,

  /// The left eye in the top half
  topBottom,

  /// The right eye in the left half
  sideBySideSwapped,

  /// The right eye in the top half
  topBottomSwapped,

  /// One picture: shown as it is, nothing to match
  none,
}

/// What each eye holds
enum SpatialProjection {
  /// A flat picture: the output takes the shape of one eye as it shows inside the output size (a stereo frame of an
  /// ordinary shape, 4:3 to 2:1, holds squeezed eyes, which show at the frame's shape)
  flat,

  /// An equirectangular image, seen through renderer C's view ([ProjectionOutput.setView]): the whole sphere, or its
  /// front half with [SpatialSetup.halfSphere] (VR180)
  equirect,
}

/// The tier of the disparity, as on the phones: LOW 320 x 180 every 4 new frames without the left right check,
/// MEDIUM 480 x 270 every 2 frames, HIGH 640 x 360 every frame (the pixel count, at the shape of the eye). The
/// adaptive rule steps down after a second over 12 ms of GPU time, up after 5 seconds under 6 ms, and does not go
/// back to a tier it left for slowness within a minute.
enum SpatialQuality { low, medium, high }

/// How the plugin draws a player through the Spatial passes
@immutable
class SpatialSetup {
  const SpatialSetup({
    this.layout = SpatialLayout.sideBySide,
    this.projection = SpatialProjection.flat,
    this.halfSphere = false,
    this.quality = SpatialQuality.medium,
    this.adaptiveQuality = true,
    this.viewpoint,
    this.maxFrameWidth = 3840,
    this.maxFramePixels = 3840 * 2160,
    required this.outputWidth,
    required this.outputHeight,
    this.maxOutputHeight = 1440,
  });

  final SpatialLayout layout;
  final SpatialProjection projection;

  /// [SpatialProjection.equirect]: each eye covers the front half of the sphere (VR180), black behind
  final bool halfSphere;

  /// The tier the passes start at, and whether the adaptive rule may change it
  final SpatialQuality quality;
  final bool adaptiveQuality;

  /// The viewpoint to start from, as [SpatialOutput.setViewpoint]; null keeps the one set last (0.5 at first)
  final double? viewpoint;

  /// The intermediate texture mpv draws the frame into keeps the video's shape, at most [maxFrameWidth] wide and
  /// [maxFramePixels] pixels: by default two eyes of 1920 x 1080 side by side or one above the other, the largest eye
  /// the passes read (the phones' MAX_EYE_PIXELS). An equirectangular video wants renderer C's tiers (PluginTier).
  final int maxFrameWidth;
  final int maxFramePixels;

  /// The box the output fits in, in physical pixels, at most [maxOutputHeight] lines high (the shape kept)
  final int outputWidth;
  final int outputHeight;
  final int maxOutputHeight;

  Map<String, Object?> toArguments(int handle) => {
        'handle': handle,
        'enabled': true,
        'layout': layout.index,
        'projection': projection.index,
        'halfSphere': halfSphere,
        'quality': quality.index,
        'adaptive': adaptiveQuality,
        if (viewpoint != null) 'viewpoint': viewpoint!.clamp(0.0, 1.0),
        'maxFrameWidth': maxFrameWidth,
        'maxFramePixels': maxFramePixels,
        'outputWidth': outputWidth,
        'outputHeight': outputHeight,
        'maxOutputHeight': maxOutputHeight,
      };
}

/// What the Spatial passes did since the previous [SpatialOutput.stats] of the same player, with the draws of
/// renderer C in [draws]
@immutable
class SpatialStats {
  const SpatialStats({
    required this.draws,
    required this.spatial,
    required this.stereo,
    required this.quality,
    required this.renderFps,
    required this.disparityFps,
    required this.renderMs,
    required this.disparityWidth,
    required this.disparityHeight,
    required this.eyeWidth,
    required this.eyeHeight,
    required this.viewpoint,
    required this.requestedViewpoint,
    required this.gpuTimer,
    required this.halfFloatMaps,
    required this.spatialDraws,
    required this.disparityRuns,
    required this.settleRuns,
    required this.qualityChanges,
    required this.drawnWidth,
    required this.drawnHeight,
    required this.showDisparity,
    this.probeRow,
  });

  factory SpatialStats.fromMap(Map<Object?, Object?> map) {
    double number(Object? value) => (value as num?)?.toDouble() ?? 0;
    final row = map['probeRow'];
    return SpatialStats(
      draws: ProjectionStats.fromMap(map),
      spatial: map['spatial'] == true,
      stereo: map['stereo'] == true,
      quality: SpatialQuality.values[((map['quality'] as int?) ?? 1)
          .clamp(0, SpatialQuality.values.length - 1)],
      renderFps: number(map['renderFps']),
      disparityFps: number(map['disparityFps']),
      renderMs: number(map['renderMs']),
      disparityWidth: map['disparityWidth'] as int? ?? 0,
      disparityHeight: map['disparityHeight'] as int? ?? 0,
      eyeWidth: map['eyeWidth'] as int? ?? 0,
      eyeHeight: map['eyeHeight'] as int? ?? 0,
      viewpoint: number(map['viewpoint']),
      requestedViewpoint: number(map['requestedViewpoint']),
      gpuTimer: map['gpuTimer'] == true,
      halfFloatMaps: map['halfFloatMaps'] == true,
      spatialDraws: map['spatialDraws'] as int? ?? 0,
      disparityRuns: map['disparityRuns'] as int? ?? 0,
      settleRuns: map['settleRuns'] as int? ?? 0,
      qualityChanges: map['qualityChanges'] as int? ?? 0,
      drawnWidth: map['drawnWidth'] as int? ?? 0,
      drawnHeight: map['drawnHeight'] as int? ?? 0,
      showDisparity: map['showDisparity'] == true,
      probeRow: row is List ? [for (final pixel in row) pixel as int] : null,
    );
  }

  /// renderer C's side: the draws with a new frame of mpv and the redraws of the frame kept, their times, the frame,
  /// the error, the GPU, and the five pixels of the probe
  final ProjectionStats draws;

  /// Whether the player draws through the Spatial passes
  final bool spatial;

  /// Whether the passes match two eyes (false for [SpatialLayout.none], or when the disparity textures could not be
  /// made: the left eye is shown as it is)
  final bool stereo;

  /// The tier in use, which the adaptive rule may have changed
  final SpatialQuality quality;

  /// The figures of the last second of draws (SpatialRenderer.kt's SpatialStats): draws and disparity estimations a
  /// second, and the GPU time of the passes in milliseconds
  final double renderFps;
  final double disparityFps;
  final double renderMs;

  /// The disparity maps and the eye textures, 0 x 0 before the first draw
  final int disparityWidth;
  final int disparityHeight;
  final int eyeWidth;
  final int eyeHeight;

  /// The viewpoint of the last draw, and the one set last
  final double viewpoint;
  final double requestedViewpoint;

  /// The GPU time comes from timer queries (GL_EXT_disjoint_timer_query), else from the CPU around glFinish on one
  /// draw in 15
  final bool gpuTimer;

  /// The maps are RGBA16F, else RGBA8 (the disparities are encoded either way)
  final bool halfFloatMaps;

  /// Since the previous call: draws of the passes, disparity estimations, the ones that settled a paused picture,
  /// and the tier changes of the adaptive rule
  final int spatialDraws;
  final int disparityRuns;
  final int settleRuns;
  final int qualityChanges;

  /// The output of the last draw, in pixels
  final int drawnWidth;
  final int drawnHeight;

  /// The disparity map is shown instead of the view ([SpatialOutput.setDebug])
  final bool showDisparity;

  /// The middle row of the output, 0xAABBGGRR from left to right, when an earlier call asked for the probe
  final List<int>? probeRow;
}

/// The method calls of the Spatial passes on the channel of media_kit_video
abstract final class SpatialOutput {
  static const _channel = MethodChannel('com.alexmercerind/media_kit_video');

  /// Turns the Spatial passes on for the player [handle] with [setup], or changes its setup. The texture of the
  /// player's [VideoController] becomes the view at the viewpoint. Refused, with the reason, on a context without
  /// OpenGL ES 3.0, with software rendering, or when the driver does not compile a pass (the shader's log); the
  /// player is then flat. Every pass is compiled here, so that a later draw never waits for one.
  static Future<ProjectionResult> enable(
          int handle, SpatialSetup setup) async =>
      ProjectionResult.fromMap(await _channel.invokeMethod<Object?>(
        'VideoOutputManager.SetSpatial',
        setup.toArguments(handle),
      ));

  /// Turns the Spatial passes off: the texture shows the video's frame again, as upstream draws it
  static Future<ProjectionResult> disable(int handle) async =>
      ProjectionResult.fromMap(
        await _channel.invokeMethod<Object?>(
          'VideoOutputManager.SetSpatial',
          {'handle': handle, 'enabled': false},
        ),
      );

  /// The viewpoint: 0 the left camera, 0.5 between the two, 1 the right camera. Sent at most once per Flutter frame,
  /// as renderer C's views: the plugin keeps the newest and draws it once, a paused video included. False when the
  /// player has no video output.
  static Future<bool> setViewpoint(int handle, double viewpoint) async =>
      await _channel.invokeMethod<bool>('VideoOutputManager.SetViewpoint', {
        'handle': handle,
        'viewpoint': viewpoint.clamp(0.0, 1.0),
      }) ??
      false;

  /// The disparity map of the left eye instead of the view, for the troubleshooting overlay: near bright, far dark,
  /// unreliable pixels tinted red
  static Future<bool> setDebug(int handle,
          {required bool disparityMap}) async =>
      await _channel.invokeMethod<bool>('VideoOutputManager.SetSpatialDebug', {
        'handle': handle,
        'disparityMap': disparityMap,
      }) ??
      false;

  /// What the passes did since the previous call; [probe] asks for the five pixels and the middle row of the next
  /// draw, given by the next call. Null when the player has no video output.
  static Future<SpatialStats?> stats(int handle, {bool probe = false}) async {
    final value = await _channel
        .invokeMethod<Object?>('VideoOutputManager.SpatialStats', {
      'handle': handle,
      'probe': probe,
    });
    return value is Map ? SpatialStats.fromMap(value) : null;
  }
}
