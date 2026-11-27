// Spatial 2.5D photos on the computers (release 53, lots P1 and P2): where the eyes of a 3D photo are, its depth made
// once (both eyes drawn at the size of the map by the GPU, read back, matched in a background isolate, see
// stereo_disparity.dart), and the painter that draws the view at the viewpoint of the moment with one fragment shader
// (shaders/spatial_photo.frag), the same on Windows, Linux and macOS. Only the uniform p changes from one frame to the
// next: one pass, one read per eye and a few of the map per pixel.

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:immich_mobile/desktop/spatial/stereo_disparity.dart';

/// Asset key of the fragment shader, as pubspec.yaml lists it
const spatialPhotoShaderAsset = 'shaders/spatial_photo.frag';

/// How the two eyes share the frame of a 3D photo
enum SpatialPhotoPacking { sideBySide, topBottom }

/// Where the eyes of a 3D photo are, and how they are meant to be seen
@immutable
class SpatialPhotoLayout {
  const SpatialPhotoLayout({required this.packing, this.swapped = false, this.squeezed = false, this.sphere});

  final SpatialPhotoPacking packing;

  /// The right eye comes first (on the left half, or on top)
  final bool swapped;

  /// Each eye squeezed into half the width (side by side) or half the height (top bottom) of the frame
  final bool squeezed;

  /// For a 360° or VR180 3D photo, the part of the sphere each eye covers, as fractions of the whole sphere (longitude
  /// left to right, latitude top to bottom, as a GPano crop: the whole sphere or its front half); null for a flat 3D
  /// photo. Each eye is then an equirectangular picture, shown by spatial_sphere_render.dart.
  final Rect? sphere;

  /// The part of the frame that holds the left eye, or the right one when [left] is false, as fractions of the frame
  Rect eyeRect({required bool left}) {
    final first = left != swapped;
    return switch (packing) {
      SpatialPhotoPacking.sideBySide => Rect.fromLTWH(first ? 0 : 0.5, 0, 0.5, 1),
      SpatialPhotoPacking.topBottom => Rect.fromLTWH(0, first ? 0 : 0.5, 1, 0.5),
    };
  }

  /// The size one eye is shown at, for a frame of [frame] pixels: as stored, or stretched back when squeezed. An eye of
  /// a sphere takes the shape of the part of the sphere it covers (2:1 for the whole sphere, square for VR180) at the
  /// width it is stored at, whatever the packing squeezed.
  Size eyeShownSize(Size frame) {
    final sphere = this.sphere;
    if (sphere != null) {
      final width = frame.width * eyeRect(left: true).width;
      return Size(width, width * sphere.height / (2 * sphere.width));
    }
    return switch (packing) {
      SpatialPhotoPacking.sideBySide => Size(squeezed ? frame.width : frame.width / 2, frame.height),
      SpatialPhotoPacking.topBottom => Size(frame.width, squeezed ? frame.height : frame.height / 2),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is SpatialPhotoLayout &&
      other.packing == packing &&
      other.swapped == swapped &&
      other.squeezed == squeezed &&
      other.sphere == sphere;

  @override
  int get hashCode => Object.hash(packing, swapped, squeezed, sphere);

  @override
  String toString() =>
      'SpatialPhotoLayout(${packing.name}${swapped ? ', swapped' : ''}${squeezed ? ', half' : ''}'
      '${sphere != null ? ', sphere $sphere' : ''})';
}

/// The depth of a photo as the shader reads it: the map picture and how its values decode
class SpatialPhotoDepth {
  SpatialPhotoDepth({required this.map, required this.minimum, required this.range});

  /// Opaque RGBA: the left disparity in red, the right one in green, the reliability of the left one in blue
  final ui.Image map;

  /// The disparity of the channel value v (0 to 1) is [minimum] + v [range], in pixels of the map
  final double minimum;
  final double range;

  int get width => map.width;

  void dispose() => map.dispose();
}

/// What the shader is given for a frame of [frame] pixels laid out as [layout], its depth of [mapWidth] pixels wide
/// decoded from [minimum] over [range], drawn into [size] logical pixels at [viewpoint], the scene or (in [showDepth])
/// the map. The floats in the order shaders/spatial_photo.frag declares them.
List<double> spatialPhotoUniforms({
  required Size size,
  required Size frame,
  required SpatialPhotoLayout layout,
  required int mapWidth,
  required double minimum,
  required double range,
  required double viewpoint,
  bool showDepth = false,
}) {
  final left = layout.eyeRect(left: true);
  final right = layout.eyeRect(left: false);
  final eyeWidth = left.width * frame.width;
  final eyeHeight = left.height * frame.height;
  return [
    size.width,
    size.height,
    left.left,
    left.top,
    left.width,
    left.height,
    right.left,
    right.top,
    right.width,
    right.height,
    // Half a texel of the frame, in eye coordinates
    0.5 / eyeWidth,
    0.5 / eyeHeight,
    // Disparities in eye widths
    minimum / mapWidth,
    range / mapWidth,
    // The settled threshold (one pixel of the map), the search step (two), the margin (half a texel of the eye), p
    1 / mapWidth,
    2 / mapWidth,
    0.5 / eyeWidth,
    viewpoint.clamp(0.0, 1.0),
    if (showDepth) 1 else 0,
  ];
}

/// Both eyes of [frame], laid out as [layout], side by side at the size of the map (each [mapSize]), drawn by the GPU
/// with a smooth downscale
Future<ui.Image> eyesAtMapSize(ui.Image frame, SpatialPhotoLayout layout, ({int width, int height}) mapSize) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final frameSize = Size(frame.width.toDouble(), frame.height.toDouble());
  final paint = ui.Paint()..filterQuality = ui.FilterQuality.medium;
  for (final (index, left) in [(0, true), (1, false)]) {
    final rect = layout.eyeRect(left: left);
    final source = Rect.fromLTWH(
      rect.left * frameSize.width,
      rect.top * frameSize.height,
      rect.width * frameSize.width,
      rect.height * frameSize.height,
    );
    final target = Rect.fromLTWH(
      index * mapSize.width.toDouble(),
      0,
      mapSize.width.toDouble(),
      mapSize.height.toDouble(),
    );
    canvas.drawImageRect(frame, source, target, paint);
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(mapSize.width * 2, mapSize.height);
  } finally {
    picture.dispose();
  }
}

/// The depth of [frame] laid out as [layout]: computed once, the matching in a background isolate. Throws when the
/// picture cannot be read back.
Future<SpatialPhotoDepth> computeSpatialPhotoDepth(ui.Image frame, SpatialPhotoLayout layout) async {
  final shown = layout.eyeShownSize(Size(frame.width.toDouble(), frame.height.toDouble()));
  final mapSize = disparityMapSize(shown.width.round(), shown.height.round());
  final eyes = await eyesAtMapSize(frame, layout, mapSize);
  final ByteData? bytes;
  try {
    bytes = await eyes.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    eyes.dispose();
  }
  if (bytes == null) {
    throw StateError('The eyes of the photo could not be read back');
  }
  final encoded = await _disparityInBackground(TransferableTypedData.fromList([bytes]), mapSize.width, mapSize.height);
  final map = await _imageOfRgba(encoded.rgba, encoded.width, encoded.height);
  return SpatialPhotoDepth(map: map, minimum: encoded.minimum, range: encoded.range);
}

// In a function of its own, so that the closure sent to the isolate holds nothing but what it needs
Future<EncodedDisparity> _disparityInBackground(TransferableTypedData pixels, int width, int height) =>
    Isolate.run(() => disparityOfSideBySide(pixels.materialize().asUint8List(), width, height));

Future<ui.Image> _imageOfRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// Draws one eye of [frame] as it is meant to be seen, contained and centred in [size]: the area the views fill
Rect spatialPhotoArea(Size frame, SpatialPhotoLayout layout, Size size) {
  final shown = layout.eyeShownSize(frame);
  final fitted = applyBoxFit(BoxFit.contain, shown, size).destination;
  return Alignment.center.inscribe(fitted, Offset.zero & size);
}

/// Draws the view of [frame] at the viewpoint [viewpoint] holds, with [program] and [depth]; repaints when it moves.
/// Without a depth yet, the left eye alone.
class SpatialPhotoPainter extends CustomPainter {
  SpatialPhotoPainter({
    required this.program,
    required this.frame,
    required this.layout,
    required this.depth,
    required this.viewpoint,
    this.showDepth = false,
  }) : super(repaint: viewpoint);

  final ui.FragmentProgram? program;
  final ui.Image frame;
  final SpatialPhotoLayout layout;
  final SpatialPhotoDepth? depth;
  final ValueListenable<double> viewpoint;
  final bool showDepth;

  @override
  void paint(Canvas canvas, Size size) {
    final frameSize = Size(frame.width.toDouble(), frame.height.toDouble());
    final area = spatialPhotoArea(frameSize, layout, size);
    final program = this.program;
    final depth = this.depth;
    if (program == null || depth == null) {
      final eye = layout.eyeRect(left: true);
      final source = Rect.fromLTWH(
        eye.left * frameSize.width,
        eye.top * frameSize.height,
        eye.width * frameSize.width,
        eye.height * frameSize.height,
      );
      canvas.drawImageRect(frame, source, area, Paint()..filterQuality = FilterQuality.medium);
      return;
    }
    final uniforms = spatialPhotoUniforms(
      size: area.size,
      frame: frameSize,
      layout: layout,
      mapWidth: depth.width,
      minimum: depth.minimum,
      range: depth.range,
      viewpoint: viewpoint.value,
      showDepth: showDepth,
    );
    final shader = program.fragmentShader();
    for (var i = 0; i < uniforms.length; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    shader
      ..setImageSampler(0, frame, filterQuality: FilterQuality.low)
      ..setImageSampler(1, depth.map, filterQuality: FilterQuality.low);
    // The shader works in the coordinates of the area: 0 at its top left corner on every backend
    canvas
      ..save()
      ..translate(area.left, area.top)
      ..drawRect(Offset.zero & area.size, Paint()..shader = shader)
      ..restore();
    shader.dispose();
  }

  @override
  bool shouldRepaint(SpatialPhotoPainter oldDelegate) =>
      !identical(oldDelegate.frame, frame) ||
      !identical(oldDelegate.depth, depth) ||
      !identical(oldDelegate.program, program) ||
      oldDelegate.layout != layout ||
      oldDelegate.viewpoint != viewpoint ||
      oldDelegate.showDepth != showDepth;
}
