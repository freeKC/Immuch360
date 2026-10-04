// Synthetic dual fisheye frames for the tests of the stitcher: a pattern known in every direction of the sphere, drawn
// into the two lenses of a calibration by inverse mapping (each frame pixel back to its direction), so that stitching
// the frame back must give the pattern again.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';

/// The colour of the test pattern in the view direction [v]: smooth, without seam anywhere on the sphere, yet with a
/// few cycles per radian, so that a pixel off shows
List<double> patternColour(Vec3 v) => [
  128 + 100 * math.sin(3 * v.x + 2 * v.y),
  128 + 100 * math.sin(2 * v.y - 3 * v.z),
  128 + 100 * math.sin(4 * v.z + v.x),
];

/// The RGBA pixels of the pattern as an equirect picture of [width] x [height]
Uint8List patternEquirect(int width, int height) {
  final rgba = Uint8List(width * height * 4);
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final colour = patternColour(directionForEquirect(i, j, width, height));
      final at = (j * width + i) * 4;
      for (var c = 0; c < 3; c++) {
        rgba[at + c] = colour[c].round().clamp(0, 255);
      }
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

// The unit direction, in the frame of [lens], that the Mei model of [lens] projects to canvas pixel ([u], [v]): the
// distortion undone by fixed point iteration, then the normalised point lifted back onto the unit sphere. Null where no
// direction lands there.
Vec3? _meiUnproject(DualFisheyeLens lens, double u, double v) {
  final xi = lens.xi!;
  final distortedX = (u - lens.cx) / lens.fx!;
  final distortedY = (v - lens.cy) / lens.fy!;
  var mx = distortedX;
  var my = distortedY;
  for (var i = 0; i < 50; i++) {
    final r2 = mx * mx + my * my;
    final radial = 1 + r2 * (lens.k1 + r2 * (lens.k2 + r2 * lens.k3));
    final dx = 2 * lens.p1 * mx * my + lens.p2 * (r2 + 2 * mx * mx);
    final dy = lens.p1 * (r2 + 2 * my * my) + 2 * lens.p2 * mx * my;
    mx = (distortedX - dx) / radial;
    my = (distortedY - dy) / radial;
  }
  final r2 = mx * mx + my * my;
  final root = 1 + (1 - xi * xi) * r2;
  if (root < 0) {
    return null;
  }
  final factor = (xi + math.sqrt(root)) / (1 + r2);
  final d = (x: factor * mx, y: factor * my, z: factor - xi);
  // Where the iteration did not settle, the direction does not project back there
  final back = meiProject(lens, d);
  if (back == null || (back.x - u).abs() > 0.01 || (back.y - v).abs() > 0.01) {
    return null;
  }
  return d;
}

// The unit direction, in the frame of [lens], that the equidistant model of [lens] projects to canvas pixel ([u], [v])
Vec3? _equidistantUnproject(DualFisheyeLens lens, double u, double v) {
  final dx = u - lens.cx;
  final dy = v - lens.cy;
  final r = math.sqrt(dx * dx + dy * dy);
  final theta = r / lens.radius! * dualFisheyeMaxTheta * math.pi / 180;
  if (r < 1e-9) {
    return (x: 0.0, y: 0.0, z: 1.0);
  }
  return (x: math.sin(theta) * dx / r, y: math.sin(theta) * dy / r, z: math.cos(theta));
}

/// The RGBA pixels of a dual fisheye frame of 2 [square] x [square] drawn with [calibration] (lens 0 in the left
/// square) from the pattern: black where the lens sees nothing, or further than [dualFisheyeMaxTheta] off its axis
Uint8List patternDualFisheye(DualFisheyeCalibration calibration, int square) {
  final width = 2 * square;
  final rgba = Uint8List(width * square * 4);
  final scale = square / calibration.canvasSquare;
  final viewToBody = bodyFrame(calibration.downBody).transposed;
  final bodyToLens = [for (var i = 0; i < 2; i++) lensPose(calibration.lenses[i], i).transposed];
  for (var y = 0; y < square; y++) {
    for (var x = 0; x < width; x++) {
      final index = x < square ? 0 : 1;
      final lens = calibration.lenses[index];
      final u = (x + 0.5) / scale;
      final v = (y + 0.5) / scale;
      final d = switch (calibration.model) {
        DualFisheyeModel.mei => _meiUnproject(lens, u, v),
        DualFisheyeModel.equidistant => _equidistantUnproject(lens, u, v),
      };
      final at = (y * width + x) * 4;
      rgba[at + 3] = 255;
      if (d == null || offAxisDegrees(d) >= dualFisheyeMaxTheta) {
        continue;
      }
      final colour = patternColour(viewToBody.apply(bodyToLens[index].apply(d)));
      for (var c = 0; c < 3; c++) {
        rgba[at + c] = colour[c].round().clamp(0, 255);
      }
    }
  }
  return rgba;
}

/// Mean absolute difference per channel between the RGBA pixels [rgba] of an equirect picture of [width] x [height]
/// and the pattern, in levels of 255
double meanPatternError(Uint8List rgba, int width, int height) {
  var sum = 0.0;
  for (var j = 0; j < height; j++) {
    for (var i = 0; i < width; i++) {
      final colour = patternColour(directionForEquirect(i, j, width, height));
      final at = (j * width + i) * 4;
      for (var c = 0; c < 3; c++) {
        sum += (rgba[at + c] - colour[c]).abs();
      }
    }
  }
  return sum / (width * height * 3);
}

/// Mean absolute difference per channel between two RGBA pictures of the same size, in levels of 255
double meanDifference(Uint8List a, Uint8List b) {
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i < a.length; i++) {
    if (i % 4 == 3) {
      continue;
    }
    sum += (a[i] - b[i]).abs();
    count++;
  }
  return sum / count;
}
