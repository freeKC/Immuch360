// Spatial 2.5D of a 360° or VR180 3D photo on the computers (release 53, lot P3): the look around view of the sphere
// drawn with one fragment shader (shaders/spatial_sphere.frag), the same on Windows, Linux and macOS. The depth is that
// of the flat 3D photos (spatial_photo_render.dart, computeSpatialPhotoDepth), measured once on the whole eyes: the
// two eyes of a stereo sphere differ along their rows only, so one map holds for every direction of the view. Each
// frame only the viewpoint p and the view (yaw, pitch, field of view) change.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:immich_mobile/desktop/spatial/spatial_photo_render.dart';
import 'package:immich_mobile/desktop/video/projection_params.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';

/// Asset key of the fragment shader, as pubspec.yaml lists it
const spatialSphereShaderAsset = 'shaders/spatial_sphere.frag';

/// The layout of a 3D sphere whose eyes are laid out as [layout] (the 360° viewers' guess or the user's choice) over
/// the part [crop] of the sphere (the whole sphere, or the front half of a VR180 photo); null for a sphere of one eye
SpatialPhotoLayout? spatialSphereLayout(StereoLayout layout, {Rect crop = fullSphereCrop}) => switch (layout) {
  StereoLayout.mono => null,
  StereoLayout.topBottom => SpatialPhotoLayout(packing: SpatialPhotoPacking.topBottom, sphere: crop),
  StereoLayout.leftRight => SpatialPhotoLayout(packing: SpatialPhotoPacking.sideBySide, sphere: crop),
};

/// Whether the eyes of [sphere] cover the whole sphere: their rows go round
bool sphereWraps(Rect sphere) => sphere.width >= 0.999;

/// The focal length of [view] on an output [height] pixels high, in pixels: the field of view is vertical, as on the
/// 360° photo viewer
double sphereFocalLength(ViewAngles view, double height) => height / 2 / math.tan(view.fov * math.pi / 360);

/// The point of an eye (0 to 1 over the eye, x right, y down) the output pixel at [pixel] of an output of [size] looks
/// at in [view], for eyes covering [sphere]; null where the eyes do not cover. The maths of shaders/spatial_sphere.frag.
Offset? sphereEyePoint(Offset pixel, Size size, ViewAngles view, Rect sphere) {
  final cx = pixel.dx - size.width / 2;
  final cy = pixel.dy - size.height / 2;
  final f = sphereFocalLength(view, size.height);
  final length = math.sqrt(cx * cx + cy * cy + f * f);
  final rx = cx / length;
  final ry = -cy / length;
  final rz = f / length;
  final pitch = view.pitch * math.pi / 180;
  final cp = math.cos(pitch);
  final sp = math.sin(pitch);
  final wx = rx;
  final wy = ry * cp + rz * sp;
  final wz = rz * cp - ry * sp;
  final raw = math.atan2(wx, wz) + view.yaw * math.pi / 180 + math.pi;
  final longitude = raw - 2 * math.pi * (raw / (2 * math.pi)).floorToDouble() - math.pi;
  final latitude = math.asin(wy.clamp(-1.0, 1.0));
  final u = 0.5 + longitude / (2 * math.pi);
  final v = 0.5 - latitude / math.pi;
  var x = (u - sphere.left) / sphere.width;
  final y = (v - sphere.top) / sphere.height;
  if (sphereWraps(sphere)) {
    x -= x.floorToDouble();
  }
  return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? Offset(x, y) : null;
}

/// What the shader is given, in the order shaders/spatial_sphere.frag declares the floats: those of the flat photos
/// (spatialPhotoUniforms, without its mode), then the view and the part of the sphere, then the mode: 0 the scene, 1
/// the depth map ([showDepth]), 2 the left eye alone (no [depth] yet)
List<double> spatialSphereUniforms({
  required Size size,
  required Size frame,
  required SpatialPhotoLayout layout,
  required SpatialPhotoDepth? depth,
  required double viewpoint,
  required ViewAngles view,
  bool showDepth = false,
}) {
  final sphere = layout.sphere ?? fullSphereCrop;
  final flat = spatialPhotoUniforms(
    size: size,
    frame: frame,
    layout: layout,
    mapWidth: depth?.width ?? 1,
    minimum: depth?.minimum ?? 0,
    range: depth?.range ?? 0,
    viewpoint: viewpoint,
  );
  return [
    ...flat.sublist(0, flat.length - 1),
    view.yaw * math.pi / 180,
    view.pitch * math.pi / 180,
    sphereFocalLength(view, size.height),
    if (sphereWraps(sphere)) 1 else 0,
    sphere.left,
    sphere.top,
    sphere.width,
    sphere.height,
    if (depth == null) 2 else if (showDepth) 1 else 0,
  ];
}

/// Draws the view of the 3D sphere [frame] at the viewpoint [viewpoint] holds, in the view [view] holds, with
/// [program] and [depth]; repaints when either moves. Without a depth yet, the left eye alone; without the shader,
/// the left eye flat, as it is stored.
class SpatialSpherePainter extends CustomPainter {
  SpatialSpherePainter({
    required this.program,
    required this.frame,
    required this.layout,
    required this.depth,
    required this.viewpoint,
    required this.view,
    this.showDepth = false,
  }) : super(repaint: Listenable.merge([viewpoint, view]));

  final ui.FragmentProgram? program;
  final ui.Image frame;
  final SpatialPhotoLayout layout;
  final SpatialPhotoDepth? depth;
  final ValueListenable<double> viewpoint;
  final ValueListenable<ViewAngles> view;
  final bool showDepth;

  @override
  void paint(Canvas canvas, Size size) {
    final frameSize = Size(frame.width.toDouble(), frame.height.toDouble());
    final program = this.program;
    final eye = layout.eyeRect(left: true);
    if (program == null) {
      final source = Rect.fromLTWH(
        eye.left * frameSize.width,
        eye.top * frameSize.height,
        eye.width * frameSize.width,
        eye.height * frameSize.height,
      );
      canvas.drawImageRect(
        frame,
        source,
        spatialPhotoArea(frameSize, layout, size),
        Paint()..filterQuality = FilterQuality.medium,
      );
      return;
    }
    final depth = this.depth;
    final uniforms = spatialSphereUniforms(
      size: size,
      frame: frameSize,
      layout: layout,
      depth: depth,
      viewpoint: viewpoint.value,
      view: view.value,
      showDepth: showDepth,
    );
    final shader = program.fragmentShader();
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    shader
      ..setImageSampler(0, frame, filterQuality: FilterQuality.low)
      // Not read in mode 2, but every sampler must be set
      ..setImageSampler(1, depth?.map ?? frame, filterQuality: FilterQuality.low);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    shader.dispose();
  }

  @override
  bool shouldRepaint(SpatialSpherePainter oldDelegate) =>
      !identical(oldDelegate.frame, frame) ||
      !identical(oldDelegate.depth, depth) ||
      !identical(oldDelegate.program, program) ||
      oldDelegate.layout != layout ||
      oldDelegate.viewpoint != viewpoint ||
      oldDelegate.view != view ||
      oldDelegate.showDepth != showDepth;
}
