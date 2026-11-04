// The gaussians of a splat scene turned (lot SPF2): an object found lying on its side is set upright on the plane it
// stands on, every gaussian turned with it. Its position and its orientation turn with the scene, its size does not,
// and its spherical harmonics turn band by band: the colour it shows from a direction is the one it showed before from
// that direction turned back, checked against the formula of 3D Gaussian Splatting (sh_utils.py), written again here.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/splat/splat_turn.dart';
import 'package:immich_mobile/domain/models/splat/splat_cloud.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// The colour of one channel of a gaussian seen from the unit direction ([x], [y], [z]), its coefficients [c] (the
/// first one, then those of the bands 1 to 3 as far as there are), as eval_sh of 3D Gaussian Splatting adds them up
double _shade(List<double> c, double x, double y, double z) {
  const c0 = 0.28209479177387814;
  const c1 = 0.4886025119029199;
  const c2 = [1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396];
  const c3 = [
    -0.5900435899266435,
    2.890611442640554,
    -0.4570457994644658,
    0.3731763325901154,
    -0.4570457994644658,
    1.445305721320277,
    -0.5900435899266435,
  ];
  var result = c0 * c[0];
  if (c.length > 1) {
    result += -c1 * y * c[1] + c1 * z * c[2] - c1 * x * c[3];
  }
  if (c.length > 4) {
    final (xx, yy, zz, xy, yz, xz) = (x * x, y * y, z * z, x * y, y * z, x * z);
    result +=
        c2[0] * xy * c[4] +
        c2[1] * yz * c[5] +
        c2[2] * (2 * zz - xx - yy) * c[6] +
        c2[3] * xz * c[7] +
        c2[4] * (xx - yy) * c[8];
    if (c.length > 9) {
      result +=
          c3[0] * y * (3 * xx - yy) * c[9] +
          c3[1] * xy * z * c[10] +
          c3[2] * y * (4 * zz - xx - yy) * c[11] +
          c3[3] * z * (2 * zz - 3 * xx - 3 * yy) * c[12] +
          c3[4] * x * (4 * zz - xx - yy) * c[13] +
          c3[5] * z * (xx - yy) * c[14] +
          c3[6] * x * (xx - 3 * yy) * c[15];
    }
  }
  return result;
}

/// The rotation of [angle] radians about the axis ([ax], [ay], [az]), row by row
Float64List _rotation(double ax, double ay, double az, double angle) {
  final length = math.sqrt(ax * ax + ay * ay + az * az);
  final (x, y, z) = (ax / length, ay / length, az / length);
  final c = math.cos(angle);
  final s = math.sin(angle);
  final t = 1 - c;
  return Float64List.fromList([
    t * x * x + c,
    t * x * y - s * z,
    t * x * z + s * y,
    t * x * y + s * z,
    t * y * y + c,
    t * y * z - s * x,
    t * x * z - s * y,
    t * y * z + s * x,
    t * z * z + c,
  ]);
}

List<double> _times(Float64List r, List<double> v) => [
  for (var i = 0; i < 3; i++) r[3 * i] * v[0] + r[3 * i + 1] * v[1] + r[3 * i + 2] * v[2],
];

/// A unit direction drawn by [random]
List<double> _direction(math.Random random) {
  while (true) {
    final v = [for (var k = 0; k < 3; k++) random.nextDouble() * 2 - 1];
    final length = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (length > 0.1 && length <= 1) {
      return [for (final value in v) value / length];
    }
  }
}

/// [count] gaussians of [degree] with values drawn by [random], their quaternions of any length
SplatCloud _cloud(int count, int degree, math.Random random) {
  final stride = splatRowValues(degree);
  final rows = Float32List(count * stride);
  for (var k = 0; k < rows.length; k++) {
    rows[k] = random.nextDouble() * 2 - 1;
  }
  return SplatCloud(count: count, shDegree: degree, rows: rows);
}

/// The coefficients of channel [channel] of gaussian [i] of [cloud]: its first one, then those of its bands, the PLY
/// keeping them colour by colour
List<double> _coefficients(SplatCloud cloud, int i, int channel) {
  final rest = splatShCoefficients(cloud.shDegree);
  final at = i * cloud.stride;
  return [
    cloud.rows[at + 3 + channel],
    for (var k = 0; k < rest; k++) cloud.rows[at + cloud.restAt + channel * rest + k],
  ];
}

/// The covariance of gaussian [i] of [cloud]: R S S Rᵀ, R its quaternion made unit, S its scales (logarithms)
List<double> _covariance(SplatCloud cloud, int i) {
  final at = i * cloud.stride;
  final q = [for (var k = 0; k < 4; k++) cloud.rows[at + cloud.rotationAt + k]];
  final n = math.sqrt(q.fold(0.0, (sum, v) => sum + v * v));
  final (w, x, y, z) = (q[0] / n, q[1] / n, q[2] / n, q[3] / n);
  final r = [
    1 - 2 * (y * y + z * z),
    2 * (x * y - w * z),
    2 * (x * z + w * y),
    2 * (x * y + w * z),
    1 - 2 * (x * x + z * z),
    2 * (y * z - w * x),
    2 * (x * z - w * y),
    2 * (y * z + w * x),
    1 - 2 * (x * x + y * y),
  ];
  final s = [for (var k = 0; k < 3; k++) math.exp(2 * cloud.rows[at + cloud.scaleAt + k])];
  return [
    for (var i = 0; i < 3; i++)
      for (var j = 0; j < 3; j++)
        r[3 * i] * r[3 * j] * s[0] + r[3 * i + 1] * r[3 * j + 1] * s[1] + r[3 * i + 2] * r[3 * j + 2] * s[2],
  ];
}

void main() {
  test('the colours of every band seen from any direction: those seen before from the direction turned back', () {
    final random = math.Random(7);
    for (final degree in [1, 2, 3]) {
      final cloud = _cloud(40, degree, random);
      for (var t = 0; t < 6; t++) {
        final axis = _direction(random);
        final r = _rotation(axis[0], axis[1], axis[2], random.nextDouble() * 2 * math.pi);
        final turned = turnedSplatCloud(cloud, r);
        expect(turned.shDegree, degree);
        for (var i = 0; i < cloud.count; i++) {
          for (var channel = 0; channel < 3; channel++) {
            final before = _coefficients(cloud, i, channel);
            final after = _coefficients(turned, i, channel);
            expect(after[0], before[0], reason: 'the first coefficient has no direction');
            for (var d = 0; d < 4; d++) {
              final v = _direction(random);
              final w = _times(r, v);
              expect(
                _shade(after, w[0], w[1], w[2]),
                closeTo(_shade(before, v[0], v[1], v[2]), 2e-5),
                reason: 'degree $degree, gaussian $i, channel $channel',
              );
            }
          }
        }
      }
    }
  });

  test('the positions and the shapes turn with the scene, the sizes, the opacities and the counts stay', () {
    final random = math.Random(11);
    final cloud = _cloud(200, 3, random);
    // A quarter turn about an axis near z, about what FreeKC's object of 3 November needed (its desk along x)
    final r = _rotation(0.0531, 0, 0.9986, -math.pi / 2 + 0.0753);
    final turned = turnedSplatCloud(cloud, r);
    expect((turned.count, turned.dropped, turned.comments), (cloud.count, cloud.dropped, cloud.comments));
    for (var i = 0; i < cloud.count; i++) {
      final at = i * cloud.stride;
      final position = _times(r, [for (var k = 0; k < 3; k++) cloud.rows[at + k]]);
      for (var k = 0; k < 3; k++) {
        expect(turned.rows[at + k], closeTo(position[k], 1e-6));
        expect(turned.rows[at + cloud.scaleAt + k], cloud.rows[at + cloud.scaleAt + k]);
      }
      expect(turned.rows[at + cloud.opacityAt], cloud.rows[at + cloud.opacityAt]);
      // R Σ Rᵀ
      final sigma = _covariance(cloud, i);
      final expected = [
        for (var a = 0; a < 3; a++)
          for (var b = 0; b < 3; b++)
            [
              for (var m = 0; m < 3; m++)
                for (var n = 0; n < 3; n++) r[3 * a + m] * sigma[3 * m + n] * r[3 * b + n],
            ].fold(0.0, (sum, v) => sum + v),
      ];
      final got = _covariance(turned, i);
      for (var k = 0; k < 9; k++) {
        expect(got[k], closeTo(expected[k], 1e-4 * (1 + expected[k].abs())), reason: 'gaussian $i');
      }
    }
  });

  test('no turn, and a cloud of degree 0, are written as they were', () {
    final random = math.Random(3);
    final cloud = _cloud(30, 3, random);
    final same = turnedSplatCloud(cloud, Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]));
    expect(same.rows, cloud.rows);
    final flat = _cloud(30, 0, random);
    final r = _rotation(0, 0, 1, math.pi / 2);
    final turned = turnedSplatCloud(flat, r);
    for (var i = 0; i < flat.count; i++) {
      final at = i * flat.stride;
      expect(turned.rows.sublist(at + 3, at + 6), flat.rows.sublist(at + 3, at + 6));
      expect(turned.rows[at], closeTo(-flat.rows[at + 1], 1e-6));
      expect(turned.rows[at + 1], closeTo(flat.rows[at], 1e-6));
    }
  });

  test('a turn that is not a rotation is refused', () {
    final cloud = _cloud(3, 1, math.Random(1));
    expect(() => turnedSplatCloud(cloud, Float64List.fromList([1, 0, 0, 0, 1, 0, 0, 0, -1])), throwsArgumentError);
    expect(() => turnedSplatCloud(cloud, Float64List.fromList([2, 0, 0, 0, 1, 0, 0, 0, 1])), throwsArgumentError);
    expect(() => turnedSplatCloud(cloud, Float64List(8)), throwsArgumentError);
  });
}
