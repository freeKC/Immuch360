// Synthetic inputs of raw videos for the tests of the stitch: the texture of one lens of a fisheye pair (Mei with its
// five radial terms, equidistant, Kannala-Brandt), and the EAC tracks of a GoPro .360, each drawn from the pattern of
// dual_fisheye_frames.dart by inverse mapping (each texture pixel back to its direction), so that stitching them back
// must give the pattern again. See docs/18-design-projections-and-parsers.md, section 9.1.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';

import 'dual_fisheye_frames.dart';

/// The unit direction, in the frame of [lens], that the Kannala-Brandt model of [lens] projects to canvas pixel ([u],
/// [v]): theta solved from the distorted radius by Newton's method from theta = radius, 30 iterations. Null where it
/// does not settle within 1e-10, or past [maxTheta] degrees.
Vec3? kannalaBrandtUnproject(DualFisheyeLens lens, double u, double v, {double maxTheta = 94}) {
  final a = (u - lens.cx) / lens.fx!;
  final b = (v - lens.cy) / lens.fy!;
  final rho = math.sqrt(a * a + b * b);
  if (rho < 1e-12) {
    return (x: 0.0, y: 0.0, z: 1.0);
  }
  double thetaD(double theta) {
    final t2 = theta * theta;
    return theta * (1 + t2 * (lens.k1 + t2 * (lens.k2 + t2 * (lens.k3 + t2 * (lens.k4 + t2 * lens.k5)))));
  }

  var theta = rho;
  for (var i = 0; i < 30; i++) {
    final t2 = theta * theta;
    final slope =
        1 + t2 * (3 * lens.k1 + t2 * (5 * lens.k2 + t2 * (7 * lens.k3 + t2 * (9 * lens.k4 + t2 * 11 * lens.k5))));
    theta -= (thetaD(theta) - rho) / slope;
  }
  if (!theta.isFinite || theta < 0 || (thetaD(theta) - rho).abs() > 1e-10 || theta * 180 / math.pi >= maxTheta) {
    return null;
  }
  return (x: math.sin(theta) * a / rho, y: math.sin(theta) * b / rho, z: math.cos(theta));
}

/// The unit direction, in the frame of [lens], that the Mei model of [lens], its five radial terms included, projects
/// to canvas pixel ([u], [v]): the distortion undone by fixed point iteration, then the point lifted onto the unit
/// sphere. Null where no direction lands there.
Vec3? meiUnproject(DualFisheyeLens lens, double u, double v, {double maxTheta = dualFisheyeMaxTheta}) {
  final xi = lens.xi!;
  final distortedX = (u - lens.cx) / lens.fx!;
  final distortedY = (v - lens.cy) / lens.fy!;
  var mx = distortedX;
  var my = distortedY;
  for (var i = 0; i < 80; i++) {
    final r2 = mx * mx + my * my;
    final radial = 1 + r2 * (lens.k1 + r2 * (lens.k2 + r2 * (lens.k3 + r2 * (lens.k4 + r2 * lens.k5))));
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
  final back = meiProject(lens, d, maxTheta: maxTheta);
  if (back == null || (back.x - u).abs() > 0.01 || (back.y - v).abs() > 0.01) {
    return null;
  }
  return d;
}

/// The unit direction, in the frame of [lens], that the equidistant model of [lens] projects to canvas pixel ([u], [v])
Vec3? equidistantUnproject(DualFisheyeLens lens, double u, double v) {
  final dx = u - lens.cx;
  final dy = v - lens.cy;
  final r = math.sqrt(dx * dx + dy * dy);
  if (r < 1e-9) {
    return (x: 0.0, y: 0.0, z: 1.0);
  }
  final theta = r / lens.radius! * equidistantRadiusDegrees * math.pi / 180;
  return (x: math.sin(theta) * dx / r, y: math.sin(theta) * dy / r, z: math.cos(theta));
}

/// The RGBA texture of lens [lensIndex] of [calibration] alone, [side] pixels square: the whole square of the lens on
/// the canvas scaled to [side], each pixel the colour of the pattern in its view direction (viewToLens transposed
/// times its direction in the lens frame); black where the lens sees nothing, or [DualFisheyeCalibration.maxTheta]
/// degrees off its axis and beyond
RgbaTexture patternLensTexture(DualFisheyeCalibration calibration, int lensIndex, int side) {
  final rgba = Uint8List(side * side * 4);
  final square = calibration.canvasSquare;
  final lens = calibration.lenses[lensIndex];
  final lensToView = viewToLens(calibration)[lensIndex].transposed;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final u = lensIndex * square + (x + 0.5) * square / side;
      final v = (y + 0.5) * square / side;
      final d = switch (calibration.model) {
        DualFisheyeModel.mei => meiUnproject(lens, u, v, maxTheta: calibration.maxTheta),
        DualFisheyeModel.equidistant => equidistantUnproject(lens, u, v),
        DualFisheyeModel.kannalaBrandt => kannalaBrandtUnproject(lens, u, v, maxTheta: calibration.maxTheta),
      };
      final at = (y * side + x) * 4;
      rgba[at + 3] = 255;
      if (d == null || offAxisDegrees(d) >= calibration.maxTheta) {
        continue;
      }
      final colour = patternColour(lensToView.apply(d));
      for (var c = 0; c < 3; c++) {
        rgba[at + c] = colour[c].round().clamp(0, 255);
      }
    }
  }
  return (rgba: rgba, width: side, height: side);
}

/// The RGBA track [texture] (0 or 1) of the EAC layout of [geometry], each pixel the colour of the pattern in the view
/// direction of its face column and row (the second half of a split slot mapped back to the face by col = local - half
/// + (F - half)), turned from the camera frame into the view frame by [viewToCamera] transposed (row major)
RgbaTexture patternEacTrack(GoProEacGeometry geometry, int texture, List<double> viewToCamera) {
  final width = geometry.trackWidth;
  final face = geometry.face;
  final f = face.toDouble();
  final half = geometry.half.toDouble();
  final cameraToView = Mat3(viewToCamera).transposed;
  final rgba = Uint8List(width * face * 4);
  for (var py = 0; py < face; py++) {
    for (var px = 0; px < width; px++) {
      final slot = px < geometry.middle ? 0 : (px < geometry.right ? 1 : 2);
      final x = px + 0.5;
      double col;
      if (slot == 1) {
        col = x - geometry.middle;
      } else {
        final local = x - (slot == 0 ? 0 : geometry.right);
        col = local < half ? local : local - half + (f - half);
      }
      final row = py + 0.5;
      final faceAxes = GoProEacGeometry.faces.firstWhere((entry) => entry.texture == texture && entry.slot == slot);
      final u = math.tan((col / f * 2 - 1) * math.pi / 4);
      final v = math.tan((row / f * 2 - 1) * math.pi / 4);
      final c = (
        x: faceAxes.forward.x + u * faceAxes.right.x + v * faceAxes.down.x,
        y: faceAxes.forward.y + u * faceAxes.right.y + v * faceAxes.down.y,
        z: faceAxes.forward.z + u * faceAxes.right.z + v * faceAxes.down.z,
      );
      final length = math.sqrt(c.x * c.x + c.y * c.y + c.z * c.z);
      final colour = patternColour(cameraToView.apply((x: c.x / length, y: c.y / length, z: c.z / length)));
      final at = (py * width + px) * 4;
      for (var channel = 0; channel < 3; channel++) {
        rgba[at + channel] = colour[channel].round().clamp(0, 255);
      }
      rgba[at + 3] = 255;
    }
  }
  return (rgba: rgba, width: width, height: face);
}
