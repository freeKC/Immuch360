// The gaussians of a splat scene turned (lot SPF2): an object found lying on its side is set upright on the plane it
// stands on (splat_scale.dart) by turning every gaussian, in the copy for the headset and in the .ply alike. Its
// position turns with the scene, its orientation too (the quaternion of the turn times its own, rot_0 to rot_3, w
// first), its sizes and its opacity stay, and the coefficients of its spherical harmonics past the first turn band by
// band, so that the colour it shows from a direction is the one it showed before from that direction turned back. A
// band is turned by a matrix found once per turn from the harmonics of 3D Gaussian Splatting themselves (the constants
// and the signs of its sh_utils.py, which Brush trains and the headset draws), solved by least squares on
// [splatTurnDirections] directions spread over the sphere: Y(Rᵀ d) = M Y(d) for every direction d, the coefficients c
// of the band becoming Mᵀ c. Pure Dart, run in the isolate of the copy (splat_files.dart); 150 000 gaussians of degree
// 3 in a fraction of a second. Tested by splat_turn_test.dart against eval_sh written again.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';

/// The directions the matrix of each band is solved on (a Fibonacci sphere): more than the 7 coefficients of band 3
const splatTurnDirections = 64;

const _c1 = 0.4886025119029199;
const _c2 = [1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396];
const _c3 = [
  -0.5900435899266435,
  2.890611442640554,
  -0.4570457994644658,
  0.3731763325901154,
  -0.4570457994644658,
  1.445305721320277,
  -0.5900435899266435,
];

/// The harmonics of [band] (1 to 3) of 3D Gaussian Splatting in the unit direction ([x], [y], [z]), in the order of
/// their coefficients (sh_utils.py, eval_sh)
List<double> splatShBand(int band, double x, double y, double z) => switch (band) {
  1 => [-_c1 * y, _c1 * z, -_c1 * x],
  2 => [_c2[0] * x * y, _c2[1] * y * z, _c2[2] * (2 * z * z - x * x - y * y), _c2[3] * x * z, _c2[4] * (x * x - y * y)],
  3 => [
    _c3[0] * y * (3 * x * x - y * y),
    _c3[1] * x * y * z,
    _c3[2] * y * (4 * z * z - x * x - y * y),
    _c3[3] * z * (2 * z * z - 3 * x * x - 3 * y * y),
    _c3[4] * x * (4 * z * z - x * x - y * y),
    _c3[5] * z * (x * x - y * y),
    _c3[6] * x * (x * x - 3 * y * y),
  ],
  _ => throw ArgumentError.value(band, 'band', 'from 1 to 3'),
};

/// The gaussians of [cloud] turned by [r], a rotation given row by row (9 values; see the top of this file); a copy,
/// rounded to float32 as the PLY stores it. Throws an ArgumentError when [r] is not a rotation (a mirror, a scale)
SplatCloud turnedSplatCloud(SplatCloud cloud, Float64List r) {
  if (r.length != 9 || !_isRotation(r)) {
    throw ArgumentError.value(r, 'r', 'a rotation, 9 values row by row');
  }
  final out = Float32List.fromList(cloud.rows);
  if (_isIdentity(r)) {
    return SplatCloud(
      count: cloud.count,
      shDegree: cloud.shDegree,
      rows: out,
      comments: cloud.comments,
      dropped: cloud.dropped,
    );
  }
  final q = _quaternionOf(r);
  final bands = [for (var band = 1; band <= cloud.shDegree; band++) _bandTurn(band, r)];
  final rest = (cloud.shDegree + 1) * (cloud.shDegree + 1) - 1;
  final stride = cloud.stride;
  final restAt = cloud.restAt;
  final rotationAt = cloud.rotationAt;
  final coefficients = Float64List(7);
  for (var at = 0; at < out.length; at += stride) {
    final x = cloud.rows[at];
    final y = cloud.rows[at + 1];
    final z = cloud.rows[at + 2];
    out[at] = r[0] * x + r[1] * y + r[2] * z;
    out[at + 1] = r[3] * x + r[4] * y + r[5] * z;
    out[at + 2] = r[6] * x + r[7] * y + r[8] * z;
    // The quaternion of the turn times that of the gaussian
    final w2 = cloud.rows[at + rotationAt];
    final x2 = cloud.rows[at + rotationAt + 1];
    final y2 = cloud.rows[at + rotationAt + 2];
    final z2 = cloud.rows[at + rotationAt + 3];
    out[at + rotationAt] = q[0] * w2 - q[1] * x2 - q[2] * y2 - q[3] * z2;
    out[at + rotationAt + 1] = q[0] * x2 + q[1] * w2 + q[2] * z2 - q[3] * y2;
    out[at + rotationAt + 2] = q[0] * y2 - q[1] * z2 + q[2] * w2 + q[3] * x2;
    out[at + rotationAt + 3] = q[0] * z2 + q[1] * y2 - q[2] * x2 + q[3] * w2;
    for (var channel = 0; channel < 3; channel++) {
      final base = at + restAt + channel * rest;
      var first = 0;
      for (final (index, turn) in bands.indexed) {
        final size = 2 * index + 3;
        for (var k = 0; k < size; k++) {
          coefficients[k] = cloud.rows[base + first + k];
        }
        for (var j = 0; j < size; j++) {
          var sum = 0.0;
          for (var k = 0; k < size; k++) {
            sum += turn[j * size + k] * coefficients[k];
          }
          out[base + first + j] = sum;
        }
        first += size;
      }
    }
  }
  return SplatCloud(
    count: cloud.count,
    shDegree: cloud.shDegree,
    rows: out,
    comments: cloud.comments,
    dropped: cloud.dropped,
  );
}

/// Whether [r] is a rotation: its rows of length 1 and square to each other, its determinant 1
bool _isRotation(Float64List r) {
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      final dot = r[3 * i] * r[3 * j] + r[3 * i + 1] * r[3 * j + 1] + r[3 * i + 2] * r[3 * j + 2];
      if ((dot - (i == j ? 1 : 0)).abs() > 1e-6) {
        return false;
      }
    }
  }
  final det =
      r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) + r[2] * (r[3] * r[7] - r[4] * r[6]);
  return (det - 1).abs() < 1e-6;
}

bool _isIdentity(Float64List r) {
  for (var k = 0; k < 9; k++) {
    if (r[k] != (k % 4 == 0 ? 1 : 0)) {
      return false;
    }
  }
  return true;
}

/// The unit quaternion of the rotation [r], w x y z
List<double> _quaternionOf(Float64List r) {
  final trace = r[0] + r[4] + r[8];
  final double w;
  final double x;
  final double y;
  final double z;
  if (trace > 0) {
    final s = 2 * math.sqrt(trace + 1);
    w = s / 4;
    x = (r[7] - r[5]) / s;
    y = (r[2] - r[6]) / s;
    z = (r[3] - r[1]) / s;
  } else if (r[0] > r[4] && r[0] > r[8]) {
    final s = 2 * math.sqrt(1 + r[0] - r[4] - r[8]);
    w = (r[7] - r[5]) / s;
    x = s / 4;
    y = (r[1] + r[3]) / s;
    z = (r[2] + r[6]) / s;
  } else if (r[4] > r[8]) {
    final s = 2 * math.sqrt(1 + r[4] - r[0] - r[8]);
    w = (r[2] - r[6]) / s;
    x = (r[1] + r[3]) / s;
    y = s / 4;
    z = (r[5] + r[7]) / s;
  } else {
    final s = 2 * math.sqrt(1 + r[8] - r[0] - r[4]);
    w = (r[3] - r[1]) / s;
    x = (r[2] + r[6]) / s;
    y = (r[5] + r[7]) / s;
    z = s / 4;
  }
  return [w, x, y, z];
}

/// The matrix that turns the coefficients of [band] for the rotation [r] (Mᵀ of the top of this file), row by row
Float64List _bandTurn(int band, Float64List r) {
  final size = 2 * band + 1;
  // AᵀA and AᵀB over the directions, A the harmonics of each direction, B those of each direction turned back
  final ata = Float64List(size * size);
  final atb = Float64List(size * size);
  const golden = 2.399963229728653;
  for (var i = 0; i < splatTurnDirections; i++) {
    final y = 1 - 2 * (i + 0.5) / splatTurnDirections;
    final radius = math.sqrt(1 - y * y);
    final x = radius * math.cos(golden * i);
    final z = radius * math.sin(golden * i);
    final a = splatShBand(band, x, y, z);
    // Rᵀ d
    final b = splatShBand(
      band,
      r[0] * x + r[3] * y + r[6] * z,
      r[1] * x + r[4] * y + r[7] * z,
      r[2] * x + r[5] * y + r[8] * z,
    );
    for (var j = 0; j < size; j++) {
      for (var k = 0; k < size; k++) {
        ata[j * size + k] += a[j] * a[k];
        atb[j * size + k] += a[j] * b[k];
      }
    }
  }
  // X = (AᵀA)⁻¹ AᵀB = Mᵀ, by Gauss-Jordan with partial pivoting
  for (var col = 0; col < size; col++) {
    var pivot = col;
    for (var row = col + 1; row < size; row++) {
      if (ata[row * size + col].abs() > ata[pivot * size + col].abs()) {
        pivot = row;
      }
    }
    if (pivot != col) {
      for (var k = 0; k < size; k++) {
        final a = ata[col * size + k];
        ata[col * size + k] = ata[pivot * size + k];
        ata[pivot * size + k] = a;
        final b = atb[col * size + k];
        atb[col * size + k] = atb[pivot * size + k];
        atb[pivot * size + k] = b;
      }
    }
    final head = ata[col * size + col];
    for (var k = 0; k < size; k++) {
      ata[col * size + k] /= head;
      atb[col * size + k] /= head;
    }
    for (var row = 0; row < size; row++) {
      if (row == col) {
        continue;
      }
      final factor = ata[row * size + col];
      if (factor == 0) {
        continue;
      }
      for (var k = 0; k < size; k++) {
        ata[row * size + k] -= factor * ata[col * size + k];
        atb[row * size + k] -= factor * atb[col * size + k];
      }
    }
  }
  return atb;
}
