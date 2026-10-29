// The focal length and the shift of a MoGe-2 point map (design-final 2026-10-27, sections 2.2 and 2.3, step 3; lot
// S1). MoGe-2 gives its points up to a shift of their depth and without the focal length; its PyTorch code finds both
// with recover_focal_shift, which does not export to ONNX, so the computers do it here. The rule is written once in
// .github/desktop/ai/make_focal_shift_golden.py, whose fixture (focal_shift_golden_v1.json) this file meets within its
// tolerance; the measure M2 checked that an exact solver of the same problem gives what MoGe gives within 1e-4.
//
// As MoGe does: the map is sampled on a grid of 64 x 64 by the nearest point (index floor(i * size / 64), the rule of
// torch.nn.functional.interpolate), each sample with the uv of its pixel on the view plane of MoGe (the half diagonal
// at 1, the centres of the pixels), only the samples whose mask is over 0.5. Then the shift that makes the error of
// the projection the smallest, the focal length following in closed form; with the focal length of the EXIF, only the
// shift. Fewer than two samples give the shift 0 and the focal length 1, as MoGe.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The half diagonal of the 24 x 36 frame, in millimetres: a focal length equivalent to 35 mm over it is the focal
/// length of MoGe (relative to the half diagonal)
const halfDiagonal35mm = 21.635;

final _golden = (math.sqrt(5) - 1) / 2;

/// The view plane of MoGe for a map of [width] x [height]: how far it spans across and down, the half diagonal at 1
({double x, double y}) viewPlaneSpans(int width, int height) {
  final aspect = width / height;
  final diagonal = math.sqrt(1 + aspect * aspect);
  return (x: aspect / diagonal, y: 1 / diagonal);
}

/// The points a fit uses: x, y, z of each (z up to the shift) and the u, v of its pixel on the view plane
class FocalShiftSamples {
  FocalShiftSamples(this.points, this.uv) : assert(points.length * 2 == uv.length * 3, 'Three values, two uv');

  final Float64List points;
  final Float64List uv;

  int get length => points.length ~/ 3;

  /// The samples of a map of [width] x [height] as MoGe takes them: [grid] x [grid] points by the nearest, those whose
  /// [mask] is over SceneV1.validMask. [points] holds x, y, z one pixel after the other.
  factory FocalShiftSamples.ofMap(
    Float32List points,
    Float32List mask,
    int width,
    int height, {
    int grid = SceneV1.focalGrid,
  }) {
    final spans = viewPlaneSpans(width, height);
    final kept = <double>[];
    final uv = <double>[];
    for (var row = 0; row < grid; row++) {
      final y = row * height ~/ grid;
      for (var column = 0; column < grid; column++) {
        final x = column * width ~/ grid;
        final at = y * width + x;
        if (!(mask[at] > SceneV1.validMask)) {
          continue;
        }
        kept
          ..add(points[3 * at])
          ..add(points[3 * at + 1])
          ..add(points[3 * at + 2]);
        uv
          ..add(spans.x * (2 * (x + 0.5) / width - 1))
          ..add(spans.y * (2 * (y + 0.5) / height - 1));
      }
    }
    return FocalShiftSamples(Float64List.fromList(kept), Float64List.fromList(uv));
  }
}

/// What the fit found: the focal length relative to the half diagonal, the shift of the depth, and whether the focal
/// length is the one the EXIF gave
class FocalShift {
  const FocalShift({required this.focal, required this.shift, this.fromExif = false});

  final double focal;
  final double shift;
  final bool fromExif;

  @override
  String toString() => 'FocalShift($focal, $shift${fromExif ? ', EXIF' : ''})';
}

/// The focal length that fits [samples] best once shifted by [shift]: sum(p . uv) / sum(p . p), p the projection
double bestFocal(FocalShiftSamples samples, double shift) {
  final points = samples.points;
  final uv = samples.uv;
  var top = 0.0;
  var bottom = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final px = points[3 * i] / (points[3 * i + 2] + shift);
    final py = points[3 * i + 1] / (points[3 * i + 2] + shift);
    top += px * uv[2 * i] + py * uv[2 * i + 1];
    bottom += px * px + py * py;
  }
  return top / bottom;
}

/// The error of the projection of [samples] shifted by [shift] with [focal], the best one when null
double fitError(FocalShiftSamples samples, double shift, [double? focal]) {
  final points = samples.points;
  final uv = samples.uv;
  final f = focal ?? bestFocal(samples, shift);
  var total = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final ex = f * points[3 * i] / (points[3 * i + 2] + shift) - uv[2 * i];
    final ey = f * points[3 * i + 1] / (points[3 * i + 2] + shift) - uv[2 * i + 1];
    total += ex * ex + ey * ey;
  }
  return total;
}

/// The shift that makes [fitError] the smallest over shifts that keep every depth positive: golden section, as the
/// header of make_focal_shift_golden.py writes it
double searchShift(FocalShiftSamples samples, [double? focal]) {
  final points = samples.points;
  var lowest = double.infinity;
  var highest = double.negativeInfinity;
  for (var i = 0; i < samples.length; i++) {
    lowest = math.min(lowest, points[3 * i + 2]);
    highest = math.max(highest, points[3 * i + 2]);
  }
  var lo = -lowest + 1e-6 * math.max(1.0, lowest.abs());
  var hi = lo + 100 * (highest - lowest + 1);
  var a = hi - _golden * (hi - lo);
  var b = lo + _golden * (hi - lo);
  var ea = fitError(samples, a, focal);
  var eb = fitError(samples, b, focal);
  while (hi - lo >= 1e-12 * math.max(1.0, lo.abs())) {
    if (ea < eb) {
      hi = b;
      b = a;
      eb = ea;
      a = hi - _golden * (hi - lo);
      ea = fitError(samples, a, focal);
    } else {
      lo = a;
      a = b;
      ea = eb;
      b = lo + _golden * (hi - lo);
      eb = fitError(samples, b, focal);
    }
  }
  return (lo + hi) / 2;
}

/// The focal length and the shift of [samples]; with [exifFocal] (relative to the half diagonal), that focal length
/// and the shift for it. Fewer than two samples give the shift 0 and the focal length 1 (or the EXIF's), as MoGe.
FocalShift recoverFocalShift(FocalShiftSamples samples, {double? exifFocal}) {
  if (samples.length < 2) {
    return FocalShift(focal: exifFocal ?? 1.0, shift: 0, fromExif: exifFocal != null);
  }
  if (exifFocal != null) {
    return FocalShift(focal: exifFocal, shift: searchShift(samples, exifFocal), fromExif: true);
  }
  final shift = searchShift(samples);
  return FocalShift(focal: bestFocal(samples, shift), shift: shift);
}

/// The focal length of MoGe for a focal length [focal35] equivalent to 35 mm (the EXIF FocalLengthIn35mmFilm); null
/// when there is none
double? focalOfExif35(double? focal35) => focal35 == null || !(focal35 > 0) ? null : focal35 / halfDiagonal35mm;

/// fovGuessed: no EXIF, or the focal length of the model [modelFocal] differs from that of the EXIF by more than
/// SceneV1.fovMismatch of the latter (focal lengths, not fields of view)
bool fovGuessedOf(double modelFocal, double? exifFocal) =>
    exifFocal == null || (modelFocal - exifFocal).abs() > SceneV1.fovMismatch * exifFocal;

/// The horizontal field of view in degrees of a map whose view plane spans [spanX] across, for [focal]
double horizontalFovDegrees(double spanX, double focal) => 2 * math.atan(spanX / focal) * (180 / math.pi);

/// The focal length in pixels of a map [width] wide whose view plane spans [spanX], for [focal]
double focalPixels(double focal, int width, double spanX) => focal * width / (2 * spanX);
