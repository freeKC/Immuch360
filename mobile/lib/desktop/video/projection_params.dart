// What the 360° player of the computers draws (design 2.3 and 2.4): the parameters SphericalVideoApi.open carries for
// the phones' native players (the stereo layout, the eye, the coverage, the rawProjection JSON of a raw camera file),
// and the view the user turns (yaw, pitch, field of view). Renderer C takes them as uniforms of its pass
// (render/plugin_renderer.dart): nothing of mpv changes while the view moves (DP1, 2026-10-09).
//
// Raw files of 360 cameras: a file whose two lenses are side by side in one track plays stitched. A file of two
// tracks (an X4, a GoPro .360) or a pair of files (an X3 pair) has its two streams stacked side by side in one frame,
// or one of them alone, as raw_two_streams.dart decides: the projection follows what mpv's frame holds.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:immich_mobile/desktop/video/raw_two_streams.dart';
import 'package:immich_mobile/desktop/video/render/plugin_renderer.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';

/// The view of the sphere, in degrees: [yaw] positive to the right of the frame's centre, [pitch] positive up (the
/// longitude and latitude of the photo sphere), [fov] the vertical field of view
@immutable
class ViewAngles {
  const ViewAngles({this.yaw = 0, this.pitch = 0, this.fov = defaultFov});

  /// The field of view a player opens with, and its limits (those of the 360° photo viewer)
  static const defaultFov = 90.0;
  static const minFov = 15.0;
  static const maxFov = 115.0;

  final double yaw;
  final double pitch;
  final double fov;

  /// [yaw] kept within -180 and 180, [pitch] within -90 and 90, [fov] within its limits
  ViewAngles normalized() {
    var y = (yaw + 180) % 360;
    if (y < 0) {
      y += 360;
    }
    return ViewAngles(yaw: y - 180, pitch: pitch.clamp(-90.0, 90.0), fov: fov.clamp(minFov, maxFov));
  }

  /// The view after a drag of [delta] logical pixels on a view [viewHeight] pixels high: the picture follows the
  /// pointer, as on the 360° photo viewer (dragging to the right turns the view to the left)
  ViewAngles dragged(Offset delta, double viewHeight) {
    if (viewHeight <= 0) {
      return this;
    }
    final degreesPerPixel = fov / viewHeight;
    return ViewAngles(
      yaw: yaw - delta.dx * degreesPerPixel,
      pitch: pitch + delta.dy * degreesPerPixel,
      fov: fov,
    ).normalized();
  }

  /// The view zoomed by [factor]: below 1 zooms in
  ViewAngles zoomed(double factor) => ViewAngles(yaw: yaw, pitch: pitch, fov: fov * factor).normalized();

  /// The view turned by [degrees] of yaw (x) and pitch (y)
  ViewAngles turned(Offset degrees) =>
      ViewAngles(yaw: yaw + degrees.dx, pitch: pitch + degrees.dy, fov: fov).normalized();

  PluginView toPlugin() => PluginView(yaw: yaw, pitch: pitch, fov: fov);

  @override
  bool operator ==(Object other) => other is ViewAngles && other.yaw == yaw && other.pitch == pitch && other.fov == fov;

  @override
  int get hashCode => Object.hash(yaw, pitch, fov);

  @override
  String toString() => 'ViewAngles($yaw, $pitch, $fov)';
}

/// After a drag, the view keeps turning and slows down with this time constant, in seconds, as on the 360° photo
/// viewer
const sphereInertiaTimeConstant = 0.3;

/// Slower than this, in degrees per second, the rotation after a drag stops
const sphereInertiaStopSpeed = 3.0;

/// One step of the rotation that goes on after a drag, over [dt] seconds, from [velocity] in degrees per second of
/// yaw (x) and pitch (y): the view and the velocity after it, null once the rotation is too slow to go on. The decay
/// is integrated over the step, so the view travels the same way whatever the frame rate.
({ViewAngles view, Offset velocity})? sphereInertiaStep(ViewAngles view, Offset velocity, double dt) {
  if (velocity.distance < sphereInertiaStopSpeed || dt <= 0) {
    return null;
  }
  final decay = math.exp(-dt / sphereInertiaTimeConstant);
  final travel = velocity * (sphereInertiaTimeConstant * (1 - decay));
  final next = view.turned(travel);
  final atPole = next.pitch.abs() >= 90 && (view.pitch + travel.dy).abs() > 90;
  return (view: next, velocity: Offset(velocity.dx * decay, atPole ? 0 : velocity.dy * decay));
}

/// The parameters of the projection, see the top of this file
@immutable
class ProjectionParams {
  /// An equirectangular video
  const ProjectionParams({
    this.layout = StereoLayout.mono,
    this.eye = PluginEye.left,
    this.coverage = SphereCoverage.full,
  }) : rawProjection = null,
       _raw = null;

  const ProjectionParams._(this.layout, this.eye, this.coverage, this.rawProjection, this._raw);

  /// The parameters SphericalVideoApi.open carries: [rawProjection] is null for an equirectangular video, or the JSON
  /// of RawVideoPlan.toNativeJson (version 2). Throws a [FormatException] for a JSON that is not an object.
  factory ProjectionParams.fromOpen({
    required StereoLayout layout,
    required SphereCoverage coverage,
    String? rawProjection,
  }) {
    if (rawProjection == null) {
      return ProjectionParams(layout: layout, coverage: coverage);
    }
    final decoded = jsonDecode(rawProjection);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('rawProjection: not an object');
    }
    // A raw file is one picture over the whole sphere, as the phones show it (raw360SphereView)
    return ProjectionParams._(StereoLayout.mono, PluginEye.left, SphereCoverage.full, rawProjection, decoded);
  }

  final StereoLayout layout;
  final PluginEye eye;
  final SphereCoverage coverage;

  /// The rawProjection JSON as received, null for an equirectangular video
  final String? rawProjection;
  final Map<String, Object?>? _raw;

  bool get isRaw => rawProjection != null;

  /// The same parameters with another layout, eye or coverage (the 3D cycle, the 180 and 360 switch); a raw file
  /// keeps its own
  ProjectionParams copyWith({StereoLayout? layout, PluginEye? eye, SphereCoverage? coverage}) => isRaw
      ? this
      : ProjectionParams(layout: layout ?? this.layout, eye: eye ?? this.eye, coverage: coverage ?? this.coverage);

  /// The streams of a raw file, null for an equirectangular video. Throws a [FormatException] for tracks it cannot
  /// read.
  RawStreams? get rawStreams {
    final raw = _raw;
    return raw == null ? null : RawStreams.fromJson(raw);
  }

  /// What renderer C draws for these parameters; for a raw file, with mpv's frame holding [frame] (by default every
  /// stream of the file, side by side). Throws a [FormatException] for a rawProjection it cannot draw.
  PluginProjection toPlugin({RawFrame? frame}) {
    final streams = rawStreams;
    if (streams == null) {
      return PluginProjection.equirect(layout: layout, coverage: coverage, eye: eye);
    }
    return rawProjectionFor(streams, frame ?? RawFrame.streams([for (var i = 0; i < streams.tracks.length; i++) i]));
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectionParams &&
      other.layout == layout &&
      other.eye == eye &&
      other.coverage == coverage &&
      other.rawProjection == rawProjection;

  @override
  int get hashCode => Object.hash(layout, eye, coverage, rawProjection);

  @override
  String toString() => 'ProjectionParams(${layout.name}, ${eye.name}, ${coverage.name}${isRaw ? ', raw' : ''})';
}
