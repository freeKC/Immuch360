// The drawn poster of a splat photo (plan of 3 November 2026, section 7), for a scene saved without the view on screen
// at hand (a share's file, a selection, the Quest's splat page): pure Dart, no GPU, run in an isolate.
//
// * The gaussians: the strongest 200,000 (splat_poster_cloud.dart).
// * The view: the page's first view (splat_placement.dart, the port of placement.js), turned by the orientation chosen
//   for the scene, else by the floor rule, else Y down; a drawing of 3:2 whose narrower side spans 60 degrees.
// * The drawing: each gaussian projected as Spark 2.4.0 does on the page (its covariance through the Jacobian of the
//   projection, a blur of 0.3 pixel, half axes of 512 pixels at most, a cut at sqrt(8) standard deviations, a centre
//   beyond 1.4 times the frustum left out), degree 0 colours, blended front to back on black, a pixel left alone once
//   nothing shows through it.
// * The mark (decision D1, behind its switch): the "3D" glyph of the viewer's tiles (Material view_in_ar_rounded,
//   Apache 2.0) in a translucent dark rounded square at the bottom right, 7 % of the short side; the page draws the
//   same from the same numbers (splat_viewer/mark.js).
// * JPEG at quality 85 (package:image, MIT).

import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

// The JPEG encoder of package:image (MIT), resolved for the TIFF photos and the 3D conversions, as they import it
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/splat/splat_header.dart';
import 'package:immich_mobile/domain/models/splat/splat_placement.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_poster_cloud.dart';

/// The size of a drawn poster: 3:2, the long side of the page's capture
const splatPosterWidth = 1600;
const splatPosterHeight = 1067;

/// The JPEG quality of a poster
const splatPosterQuality = 85;

// What Spark 2.4.0 does with each gaussian, kept here so the poster looks like the page: the cut in standard
// deviations (the page's on computers), the largest half axis in pixels, the blur, the smallest opacity drawn, and the
// culling of a centre beyond 1.4 times the frustum
const _maxStdDev = 2.8284271247461903;
const _maxPixelRadius = 512.0;
const _blur = 0.3;
const _minAlpha = 0.5 / 255;
const _clipXY = 1.4;

/// Material's view_in_ar_rounded (Apache 2.0) in a box of 24, y down, as Path2D and this file read it
const splatMarkPath =
    'M2.02 6C2.53 6 3 5.53 3 5.02L3 3.98C3 3.47 3.47 3 3.98 3L5.02 3C5.53 3 6 2.53 6 2.02C6 1.45 5.53 0.98 5.02 0.98'
    'L3.98 0.98C2.34 0.98 0.98 2.34 0.98 3.98L0.98 5.02C0.98 5.53 1.45 6 2.02 6ZM5.02 21L3.98 21C3.47 21 3 20.53 3 '
    '20.02L3 18.98C3 18.47 2.53 18 2.02 18C1.45 18 0.98 18.47 0.98 18.98L0.98 20.02C0.98 21.66 2.34 23.02 3.98 23.02'
    'L5.02 23.02C5.53 23.02 6 22.55 6 21.98C6 21.47 5.53 21 5.02 21ZM20.02 0.98L18.98 0.98C18.47 0.98 18 1.45 18 2.02'
    'C18 2.53 18.47 3 18.98 3L20.02 3C20.53 3 21 3.47 21 3.98L21 5.02C21 5.53 21.47 6 21.98 6C22.55 6 23.02 5.53 23.02'
    ' 5.02L23.02 3.98C23.02 2.34 21.66 0.98 20.02 0.98ZM21.98 18C21.47 18 21 18.47 21 18.98L21 20.02C21 20.53 20.53 21'
    ' 20.02 21L18.98 21C18.47 21 18 21.47 18 21.98C18 22.55 18.47 23.02 18.98 23.02L20.02 23.02C21.66 23.02 23.02 21.66'
    ' 23.02 20.02L23.02 18.98C23.02 18.47 22.55 18 21.98 18ZM18.98 14.86L18.98 9.14C18.98 8.39 18.61 7.73 18 7.41'
    'L12.98 4.5C12.7 4.36 12.33 4.27 12 4.27C11.67 4.27 11.3 4.36 11.02 4.5L6 7.41C5.39 7.73 5.02 8.39 5.02 9.14'
    'L5.02 14.86C5.02 15.61 5.39 16.27 6 16.59L11.02 19.5C11.3 19.64 11.67 19.73 12 19.73C12.33 19.73 12.7 19.64 12.98 '
    '19.5L18 16.59C18.61 16.27 18.98 15.61 18.98 14.86ZM11.02 17.16L6.98 14.86L6.98 10.22L11.02 12.56L11.02 17.16Z'
    'M12 10.83L8.06 8.53L12 6.23L15.94 8.53L12 10.83ZM17.02 14.86L12.98 17.16L12.98 12.56L17.02 10.22L17.02 14.86Z';

/// The numbers of the mark, shared with the page's mark.js
abstract final class SplatMark {
  /// The side of its square, over the short side of the poster
  static const size = 0.07;

  /// Its distance to the right and bottom edges, over the short side
  static const margin = 0.03;

  /// The radius of the square's corners, over its side
  static const radius = 0.22;

  /// The opacity of the black square
  static const backAlpha = 0.45;

  /// The glyph's box, over the square's side
  static const glyph = 0.72;

  /// The opacity of the white glyph
  static const glyphAlpha = 0.92;
}

/// The contours of an SVG path of M, L, C, Q and Z in absolute numbers (those of [splatMarkPath]), curves flattened
List<List<double>> splatPathContours(String path, {int segments = 12}) {
  final tokens = RegExp(r'[MLCQZ]|-?\d*\.?\d+').allMatches(path).map((m) => m.group(0)!).toList();
  final contours = <List<double>>[];
  var current = <double>[];
  var at = 0;
  var command = 'M';
  var x = 0.0;
  var y = 0.0;
  double next() => double.parse(tokens[at++]);
  while (at < tokens.length) {
    final token = tokens[at];
    if (RegExp(r'^[MLCQZ]$').hasMatch(token)) {
      command = token;
      at++;
      if (command == 'Z') {
        if (current.length >= 6) {
          contours.add(current);
        }
        current = <double>[];
      }
      continue;
    }
    switch (command) {
      case 'M':
        if (current.length >= 6) {
          contours.add(current);
        }
        x = next();
        y = next();
        current = [x, y];
        command = 'L';
      case 'L':
        x = next();
        y = next();
        current.addAll([x, y]);
      case 'C':
        final x1 = next();
        final y1 = next();
        final x2 = next();
        final y2 = next();
        final x3 = next();
        final y3 = next();
        for (var s = 1; s <= segments; s++) {
          final t = s / segments;
          final u = 1 - t;
          current
            ..add(u * u * u * x + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3)
            ..add(u * u * u * y + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3);
        }
        x = x3;
        y = y3;
      case 'Q':
        final x1 = next();
        final y1 = next();
        final x2 = next();
        final y2 = next();
        for (var s = 1; s <= segments; s++) {
          final t = s / segments;
          final u = 1 - t;
          current
            ..add(u * u * x + 2 * u * t * x1 + t * t * x2)
            ..add(u * u * y + 2 * u * t * y1 + t * t * y2);
        }
        x = x2;
        y = y2;
      default:
        at++;
    }
  }
  if (current.length >= 6) {
    contours.add(current);
  }
  return contours;
}

/// The coverage, from 0 to 1, of the pixels of a box of [width] by [height] by [contours] scaled by [scale] and moved
/// by ([left], [top]) into the box: the non-zero rule, 4 rows of samples a pixel, exact across each row
Float32List splatFillCoverage(
  List<List<double>> contours,
  int width,
  int height, {
  double scale = 1,
  double left = 0,
  double top = 0,
}) {
  const rows = 4;
  final coverage = Float32List(width * height);
  final edges = <List<double>>[];
  for (final contour in contours) {
    final n = contour.length ~/ 2;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      final x0 = left + contour[2 * i] * scale;
      final y0 = top + contour[2 * i + 1] * scale;
      final x1 = left + contour[2 * j] * scale;
      final y1 = top + contour[2 * j + 1] * scale;
      if (y0 != y1) {
        edges.add([x0, y0, x1, y1]);
      }
    }
  }
  final crossings = <(double, int)>[];
  for (var py = 0; py < height; py++) {
    for (var r = 0; r < rows; r++) {
      final sy = py + (r + 0.5) / rows;
      crossings.clear();
      for (final e in edges) {
        final (y0, y1) = (e[1], e[3]);
        if ((sy >= y0 && sy < y1) || (sy >= y1 && sy < y0)) {
          final t = (sy - y0) / (y1 - y0);
          crossings.add((e[0] + t * (e[2] - e[0]), y1 > y0 ? 1 : -1));
        }
      }
      crossings.sort((a, b) => a.$1.compareTo(b.$1));
      var winding = 0;
      for (var k = 0; k + 1 < crossings.length; k++) {
        winding += crossings[k].$2;
        if (winding == 0) {
          continue;
        }
        final from = math.max(0.0, crossings[k].$1);
        final to = math.min(width.toDouble(), crossings[k + 1].$1);
        for (var px = from.floor(); px < to; px++) {
          final overlap = math.min(to, px + 1.0) - math.max(from, px.toDouble());
          if (overlap > 0) {
            coverage[py * width + px] += overlap / rows;
          }
        }
      }
    }
  }
  for (var i = 0; i < coverage.length; i++) {
    coverage[i] = math.min(1.0, coverage[i]);
  }
  return coverage;
}

/// [rgb] (3 bytes a pixel, [width] wide) with [r], [g], [b] laid over the box at ([left], [top]) by [coverage] times
/// [alpha]
void _blend(
  Uint8List rgb,
  int width,
  int height,
  int left,
  int top,
  int boxWidth,
  int boxHeight,
  Float32List coverage,
  int r,
  int g,
  int b,
  double alpha,
) {
  for (var y = 0; y < boxHeight; y++) {
    final py = top + y;
    if (py < 0 || py >= height) {
      continue;
    }
    for (var x = 0; x < boxWidth; x++) {
      final px = left + x;
      final a = coverage[y * boxWidth + x] * alpha;
      if (px < 0 || px >= width || a <= 0) {
        continue;
      }
      final at = 3 * (py * width + px);
      rgb[at] = (rgb[at] * (1 - a) + r * a).round();
      rgb[at + 1] = (rgb[at + 1] * (1 - a) + g * a).round();
      rgb[at + 2] = (rgb[at + 2] * (1 - a) + b * a).round();
    }
  }
}

/// The glyph of [splatMarkPath] in white at [alpha], its box of 24 drawn [side] pixels wide at ([left], [top])
void drawSplatGlyph(
  Uint8List rgb,
  int width,
  int height, {
  required double left,
  required double top,
  required double side,
  double alpha = 1,
  int r = 255,
  int g = 255,
  int b = 255,
}) {
  final x0 = left.floor();
  final y0 = top.floor();
  final box = side.ceil() + 2;
  final coverage = splatFillCoverage(
    splatPathContours(splatMarkPath),
    box,
    box,
    scale: side / 24,
    left: left - x0,
    top: top - y0,
  );
  _blend(rgb, width, height, x0, y0, box, box, coverage, r, g, b, alpha);
}

/// The mark at the bottom right of the poster [rgb] of [width] by [height] (see the top of this file)
void drawSplatMark(Uint8List rgb, int width, int height) {
  final short = math.min(width, height);
  final side = (short * SplatMark.size).roundToDouble();
  final margin = (short * SplatMark.margin).roundToDouble();
  final left = width - margin - side;
  final top = height - margin - side;
  final radius = side * SplatMark.radius;
  // The square: the distance to a rounded rectangle, a pixel of soft edge
  final box = side.ceil();
  final square = Float32List(box * box);
  final half = side / 2;
  for (var y = 0; y < box; y++) {
    for (var x = 0; x < box; x++) {
      final dx = math.max(0.0, (x + 0.5 - half).abs() - (half - radius));
      final dy = math.max(0.0, (y + 0.5 - half).abs() - (half - radius));
      final distance = math.sqrt(dx * dx + dy * dy) - radius;
      square[y * box + x] = (0.5 - distance).clamp(0.0, 1.0);
    }
  }
  _blend(rgb, width, height, left.round(), top.round(), box, box, square, 0, 0, 0, SplatMark.backAlpha);
  final glyph = side * SplatMark.glyph;
  drawSplatGlyph(
    rgb,
    width,
    height,
    left: left + (side - glyph) / 2,
    top: top + (side - glyph) / 2,
    side: glyph,
    alpha: SplatMark.glyphAlpha,
  );
}

/// What drawing a poster gave
final class SplatPosterDrawing {
  const SplatPosterDrawing({
    required this.jpeg,
    required this.width,
    required this.height,
    required this.kept,
    required this.drawn,
    required this.upright,
    required this.readMs,
    required this.drawMs,
    required this.encodeMs,
  });

  final Uint8List jpeg;
  final int width;
  final int height;

  /// The gaussians read, and those that showed
  final int kept;
  final int drawn;

  /// The orientation the scene was drawn in
  final String upright;

  final int readMs;
  final int drawMs;
  final int encodeMs;
}

/// [cloud] drawn from [view] on black: 3 bytes a pixel, [width] by [height]; the number of gaussians that showed
(Uint8List, int) renderSplatCloud(
  SplatPosterCloud cloud,
  SplatFirstView view,
  int width,
  int height, {
  bool Function()? cancelled,
}) {
  final stop = cancelled ?? () => false;
  final aspect = width / height;
  final fovY = splatVerticalFov(aspect) * math.pi / 180;
  final fy = height / 2 / math.tan(fovY / 2);
  final fx = fy;
  final cx = width / 2;
  final cy = height / 2;
  // The camera: three.js's lookAt with y up
  final eye = view.eye;
  final look = view.look;
  var f = [look[0] - eye[0], look[1] - eye[1], look[2] - eye[2]];
  f = _normalized(f);
  var r = _cross(f, const [0.0, 1.0, 0.0]);
  if (_length(r) < 1e-9) {
    r = const [1.0, 0.0, 0.0];
  }
  r = _normalized(r);
  final u = _cross(r, f);
  // The rows of the view times the turn of the scene about x
  final c = math.cos(view.pitch);
  final s = math.sin(view.pitch);
  List<double> turned(List<double> row) => [row[0], row[1] * c + row[2] * s, -row[1] * s + row[2] * c];
  final w0 = turned(r);
  final w1 = turned(u);
  final w2 = turned(f);
  // The eye in the file's frame, as seen from the scene's origin
  final ex = eye[0] - view.position[0];
  final ey = eye[1] - view.position[1];
  final ez = eye[2] - view.position[2];
  final ox = -(r[0] * ex + r[1] * ey + r[2] * ez);
  final oy = -(u[0] * ex + u[1] * ey + u[2] * ez);
  final oz = -(f[0] * ex + f[1] * ey + f[2] * ez);

  final n = cloud.count;
  final depth = Float32List(n);
  final px = Float32List(n);
  final py = Float32List(n);
  final alphas = Float32List(n);
  final conicA = Float32List(n);
  final conicB = Float32List(n);
  final conicC = Float32List(n);
  final extentX = Float32List(n);
  final extentY = Float32List(n);
  final visible = Uint8List(n);
  var shown = 0;
  const near = 0.01;
  const far = 2000.0;
  final p = cloud.positions;
  final q = cloud.rotations;
  final sc = cloud.scales;
  for (var i = 0; i < n; i++) {
    final x = p[3 * i];
    final y = p[3 * i + 1];
    final z = p[3 * i + 2];
    final vx = w0[0] * x + w0[1] * y + w0[2] * z + ox;
    final vy = w1[0] * x + w1[1] * y + w1[2] * z + oy;
    final vz = w2[0] * x + w2[1] * y + w2[2] * z + oz;
    if (!(vz > near && vz < far) || cloud.opacities[i] < _minAlpha) {
      continue;
    }
    // The rotation of the gaussian times its scales: the columns of M
    final qw = q[4 * i];
    final qx = q[4 * i + 1];
    final qy = q[4 * i + 2];
    final qz = q[4 * i + 3];
    final m00 = 1 - 2 * (qy * qy + qz * qz);
    final m01 = 2 * (qx * qy - qw * qz);
    final m02 = 2 * (qx * qz + qw * qy);
    final m10 = 2 * (qx * qy + qw * qz);
    final m11 = 1 - 2 * (qx * qx + qz * qz);
    final m12 = 2 * (qy * qz - qw * qx);
    final m20 = 2 * (qx * qz - qw * qy);
    final m21 = 2 * (qy * qz + qw * qx);
    final m22 = 1 - 2 * (qx * qx + qy * qy);
    final s0 = sc[3 * i];
    final s1 = sc[3 * i + 1];
    final s2 = sc[3 * i + 2];
    // B = W M S, in the frame of the view
    final b00 = (w0[0] * m00 + w0[1] * m10 + w0[2] * m20) * s0;
    final b01 = (w0[0] * m01 + w0[1] * m11 + w0[2] * m21) * s1;
    final b02 = (w0[0] * m02 + w0[1] * m12 + w0[2] * m22) * s2;
    final b10 = (w1[0] * m00 + w1[1] * m10 + w1[2] * m20) * s0;
    final b11 = (w1[0] * m01 + w1[1] * m11 + w1[2] * m21) * s1;
    final b12 = (w1[0] * m02 + w1[1] * m12 + w1[2] * m22) * s2;
    final b20 = (w2[0] * m00 + w2[1] * m10 + w2[2] * m20) * s0;
    final b21 = (w2[0] * m01 + w2[1] * m11 + w2[2] * m21) * s1;
    final b22 = (w2[0] * m02 + w2[1] * m12 + w2[2] * m22) * s2;
    // G = J B, J the Jacobian of the projection at the centre (pixels, y down)
    final iz = 1 / vz;
    final sx = cx + fx * vx * iz;
    final sy = cy - fy * vy * iz;
    // Spark culls a centre beyond 1.4 times the frustum
    if ((sx - cx).abs() > _clipXY * cx || (sy - cy).abs() > _clipXY * cy) {
      continue;
    }
    final j00 = fx * iz;
    final j02 = -fx * vx * iz * iz;
    final j11 = -fy * iz;
    final j12 = fy * vy * iz * iz;
    final g00 = j00 * b00 + j02 * b20;
    final g01 = j00 * b01 + j02 * b21;
    final g02 = j00 * b02 + j02 * b22;
    final g10 = j11 * b10 + j12 * b20;
    final g11 = j11 * b11 + j12 * b21;
    final g12 = j11 * b12 + j12 * b22;
    final a0 = g00 * g00 + g01 * g01 + g02 * g02;
    final b = g00 * g10 + g01 * g11 + g02 * g12;
    final d0 = g10 * g10 + g11 * g11 + g12 * g12;
    // The blur of 0.3 pixel, its opacity lowered to keep the gaussian's weight, as Spark does
    final a = a0 + _blur;
    final d = d0 + _blur;
    final det = a * d - b * b;
    if (!(det > 0) || !det.isFinite) {
      continue;
    }
    final opacity = cloud.opacities[i] * math.sqrt(math.max(0.0, (a0 * d0 - b * b) / det));
    if (opacity < _minAlpha) {
      continue;
    }
    // The axes of the ellipse, each at most 512 pixels long: a larger gaussian is squeezed into that, not cut
    final average = 0.5 * (a + d);
    final halfDifference = 0.5 * (a - d);
    final delta = math.sqrt(halfDifference * halfDifference + b * b);
    final eigen1 = average + delta;
    final eigen2 = math.max(0.0, det / eigen1);
    var e1x = halfDifference >= 0 ? delta + halfDifference : b;
    var e1y = halfDifference >= 0 ? b : delta - halfDifference;
    final e1Length = math.sqrt(e1x * e1x + e1y * e1y);
    if (e1Length > 0) {
      e1x /= e1Length;
      e1y /= e1Length;
    } else {
      e1x = 1;
      e1y = 0;
    }
    final e2x = e1y;
    final e2y = -e1x;
    final scale1 = math.min(_maxPixelRadius, _maxStdDev * math.sqrt(eigen1));
    final scale2 = math.min(_maxPixelRadius, _maxStdDev * math.sqrt(eigen2));
    if (!(scale2 > 0)) {
      continue;
    }
    // z2 = (s (d.e1) / scale1)^2 + (s (d.e2) / scale2)^2, s the cut in standard deviations
    const cutSquared = _maxStdDev * _maxStdDev;
    final i1 = cutSquared / (scale1 * scale1);
    final i2 = cutSquared / (scale2 * scale2);
    final rx = math.sqrt(e1x * e1x * scale1 * scale1 + e2x * e2x * scale2 * scale2);
    final ry = math.sqrt(e1y * e1y * scale1 * scale1 + e2y * e2y * scale2 * scale2);
    if (sx + rx < 0 || sx - rx > width || sy + ry < 0 || sy - ry > height) {
      continue;
    }
    depth[i] = vz;
    px[i] = sx;
    py[i] = sy;
    alphas[i] = opacity;
    conicA[i] = i1 * e1x * e1x + i2 * e2x * e2x;
    conicB[i] = i1 * e1x * e1y + i2 * e2x * e2y;
    conicC[i] = i1 * e1y * e1y + i2 * e2y * e2y;
    extentX[i] = rx;
    extentY[i] = ry;
    visible[i] = 1;
    shown++;
  }
  // Front to back: a counting sort on the logarithm of the depth, 65,536 steps from the near plane to the far one
  const buckets = 65536;
  final logNear = math.log(near);
  final span = math.log(far) - logNear;
  final keys = Uint16List(n);
  final counts = Int32List(buckets + 1);
  for (var i = 0; i < n; i++) {
    if (visible[i] == 0) {
      continue;
    }
    final key = ((math.log(depth[i]) - logNear) / span * (buckets - 1)).clamp(0, buckets - 1).toInt();
    keys[i] = key;
    counts[key + 1]++;
  }
  for (var k = 0; k < buckets; k++) {
    counts[k + 1] += counts[k];
  }
  final order = Int32List(shown);
  for (var i = 0; i < n; i++) {
    if (visible[i] == 1) {
      order[counts[keys[i]]++] = i;
    }
  }
  // exp(-x) for x from 0 to 4 (the cut of sqrt(8) standard deviations), in 4,096 steps
  const steps = 4096;
  const cut = 0.5 * _maxStdDev * _maxStdDev;
  final falloff = Float32List(steps + 1);
  for (var k = 0; k <= steps; k++) {
    falloff[k] = math.exp(-cut * k / steps);
  }
  const perUnit = steps / cut;
  final accR = Float32List(width * height);
  final accG = Float32List(width * height);
  final accB = Float32List(width * height);
  final trans = Float32List(width * height)..fillRange(0, width * height, 1);
  const opaque = 1 / 255;
  var drawn = 0;
  final colors = cloud.colors;
  for (var o = 0; o < shown; o++) {
    if (o % 8192 == 0 && stop()) {
      throw const SplatPosterCancelled();
    }
    final i = order[o];
    final opacity = alphas[i];
    final ca = conicA[i];
    final cb = conicB[i];
    final ccn = conicC[i];
    final sx = px[i];
    final sy = py[i];
    final left = math.max(0, (sx - extentX[i]).floor());
    final right = math.min(width - 1, (sx + extentX[i]).ceil());
    final top = math.max(0, (sy - extentY[i]).floor());
    final bottom = math.min(height - 1, (sy + extentY[i]).ceil());
    final red = colors[3 * i].clamp(0.0, 1.0);
    final green = colors[3 * i + 1].clamp(0.0, 1.0);
    final blue = colors[3 * i + 2].clamp(0.0, 1.0);
    var touched = false;
    for (var y = top; y <= bottom; y++) {
      final dy = y + 0.5 - sy;
      final row = y * width;
      final ay = ccn * dy * dy;
      final by = 2 * cb * dy;
      for (var x = left; x <= right; x++) {
        final at = row + x;
        final t = trans[at];
        if (t < opaque) {
          continue;
        }
        final dx = x + 0.5 - sx;
        final power = 0.5 * (ca * dx * dx + by * dx + ay);
        if (power > cut || power < 0) {
          continue;
        }
        var alpha = opacity * falloff[(power * perUnit).toInt()];
        if (alpha < _minAlpha) {
          continue;
        }
        if (alpha > 1) {
          alpha = 1;
        }
        final weight = t * alpha;
        accR[at] += weight * red;
        accG[at] += weight * green;
        accB[at] += weight * blue;
        trans[at] = t - weight;
        touched = true;
      }
    }
    if (touched) {
      drawn++;
    }
  }
  final rgb = Uint8List(3 * width * height);
  for (var k = 0; k < width * height; k++) {
    rgb[3 * k] = (accR[k] * 255 + 0.5).clamp(0, 255).toInt();
    rgb[3 * k + 1] = (accG[k] * 255 + 0.5).clamp(0, 255).toInt();
    rgb[3 * k + 2] = (accB[k] * 255 + 0.5).clamp(0, 255).toInt();
  }
  return (rgb, drawn);
}

List<double> _cross(List<double> a, List<double> b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

double _length(List<double> v) => math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

List<double> _normalized(List<double> v) {
  final length = _length(v);
  return length > 0 ? [v[0] / length, v[1] / length, v[2] / length] : v;
}

/// The drawing was cancelled
class SplatPosterCancelled implements Exception {
  const SplatPosterCancelled();
}

/// [rgb] ([width] by [height], 3 bytes a pixel) with the mark when [mark], as a JPEG of quality 85
Uint8List encodeSplatPoster(Uint8List rgb, int width, int height, {bool mark = true}) {
  if (mark) {
    drawSplatMark(rgb, width, height);
  }
  final image = img.Image.fromBytes(width: width, height: height, bytes: rgb.buffer, numChannels: 3);
  return img.encodeJpg(image, quality: splatPosterQuality);
}

/// The poster of the scene [file] (an SPZ of versions 1 to 3 or a PLY, whose head is [head]): its first view turned
/// [up] when the user chose one, its strongest [keep] gaussians, the mark when [mark]. Throws for a version 4.
Future<SplatPosterDrawing> drawSplatPoster({
  required File file,
  required SplatHead head,
  String? up,
  bool mark = true,
  int width = splatPosterWidth,
  int height = splatPosterHeight,
  int keep = splatPosterKeep,
  bool Function()? cancelled,
}) async {
  final clock = Stopwatch()..start();
  final cloud = await readSplatPosterCloud(file, head, keep: keep, cancelled: cancelled);
  final readMs = clock.elapsedMilliseconds;
  final bounds = splatBoundsOf(cloud.samples);
  final upright = splatOpeningUpright(up, cloud.samples, bounds);
  final view = splatFirstView(bounds, upright);
  final (rgb, drawn) = renderSplatCloud(cloud, view, width, height, cancelled: cancelled);
  final drawMs = clock.elapsedMilliseconds - readMs;
  final jpeg = encodeSplatPoster(rgb, width, height, mark: mark);
  return SplatPosterDrawing(
    jpeg: jpeg,
    width: width,
    height: height,
    kept: cloud.count,
    drawn: drawn,
    upright: upright,
    readMs: readMs,
    drawMs: drawMs,
    encodeMs: clock.elapsedMilliseconds - readMs - drawMs,
  );
}

/// [drawSplatPoster] in an isolate of its own
Future<SplatPosterDrawing> drawSplatPosterInIsolate({
  required String path,
  required SplatHead head,
  String? up,
  bool mark = true,
  int keep = splatPosterKeep,
}) => Isolate.run(() => drawSplatPoster(file: File(path), head: head, up: up, mark: mark, keep: keep));
