import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/scene/focal_shift.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

// focal_shift.dart against focal_shift_golden_v1.json, the fixture of .github/desktop/ai/make_focal_shift_golden.py:
// the same shift, focal length, field of view and fovGuessed on every case, within the tolerance of the fixture

Map<String, dynamic> _golden() =>
    jsonDecode(File('test/fixtures/ai_immersive/focal_shift_golden_v1.json').readAsStringSync())
        as Map<String, dynamic>;

Float64List _doubles(Object? list) =>
    Float64List.fromList((list! as List).map((value) => (value as num).toDouble()).toList());

void _close(double actual, double expected, double tolerance, {String? reason}) =>
    expect(actual, closeTo(expected, tolerance * math.max(1, expected.abs())), reason: reason);

/// The samples of a case: its points and uv as the fixture gives them, those whose mask is over 0.5
FocalShiftSamples _samplesOf(Map<String, dynamic> entry) {
  final points = _doubles(entry['points']);
  final uv = _doubles(entry['uv']);
  final mask = _doubles(entry['mask']);
  final keptPoints = <double>[];
  final keptUv = <double>[];
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] > SceneV1.validMask) {
      keptPoints.addAll(points.sublist(3 * i, 3 * i + 3));
      keptUv.addAll(uv.sublist(2 * i, 2 * i + 2));
    }
  }
  return FocalShiftSamples(Float64List.fromList(keptPoints), Float64List.fromList(keptUv));
}

void main() {
  final golden = _golden();
  final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
  final tolerance = (golden['tolerance'] as num).toDouble();

  test('the constants of the fit are those of the fixture', () {
    expect(golden['halfDiagonal35mm'], halfDiagonal35mm);
    expect(golden['validMask'], SceneV1.validMask);
    expect(golden['fovMismatch'], SceneV1.fovMismatch);
  });

  test('every case: the shift, the focal length, the error and the field of view of the fixture', () {
    for (final entry in cases) {
      final reason = entry['name'] as String;
      final samples = _samplesOf(entry);
      final found = recoverFocalShift(samples);
      final spans = viewPlaneSpans(entry['width'] as int, entry['height'] as int);

      _close(spans.x, (entry['spanX'] as num).toDouble(), tolerance, reason: reason);
      _close(found.shift, (entry['shift'] as num).toDouble(), tolerance, reason: '$reason: shift');
      _close(found.focal, (entry['focal'] as num).toDouble(), tolerance, reason: '$reason: focal');
      expect(found.fromExif, isFalse, reason: reason);
      _close(fitError(samples, found.shift), (entry['error'] as num).toDouble(), tolerance, reason: '$reason: error');
      _close(
        horizontalFovDegrees(spans.x, found.focal),
        (entry['fovDegrees'] as num).toDouble(),
        tolerance,
        reason: '$reason: field of view',
      );
      _close(
        focalPixels(found.focal, entry['width'] as int, spans.x),
        (entry['focalPixels'] as num).toDouble(),
        tolerance,
        reason: '$reason: focal in pixels',
      );
    }
  });

  test('with the EXIF: its focal length, the shift for it, and fovGuessed by the rule of the fixture', () {
    for (final entry in cases) {
      final reason = entry['name'] as String;
      final samples = _samplesOf(entry);
      final focal35 = (entry['exifFocal35'] as num?)?.toDouble();
      final exifFocal = focalOfExif35(focal35);
      final model = recoverFocalShift(samples);

      expect(exifFocal == null, entry['exifFocal'] == null, reason: reason);
      if (exifFocal != null) {
        _close(exifFocal, (entry['exifFocal'] as num).toDouble(), tolerance, reason: reason);
        final fixed = recoverFocalShift(samples, exifFocal: exifFocal);
        expect(fixed.fromExif, isTrue);
        expect(fixed.focal, exifFocal);
        _close(
          fixed.shift,
          (entry['shiftForExif'] as num).toDouble(),
          tolerance,
          reason: '$reason: shift for the EXIF',
        );
      }
      expect(fovGuessedOf(model.focal, exifFocal), entry['fovGuessed'], reason: reason);
    }
  });

  test('the samples of a map: 64 x 64 by the nearest point, the uv of their pixels, the mask over 0.5', () {
    const width = 100;
    const height = 70;
    final points = Float32List(3 * width * height);
    final mask = Float32List(width * height);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final at = y * width + x;
        points[3 * at] = x.toDouble();
        points[3 * at + 1] = y.toDouble();
        points[3 * at + 2] = 1;
        // The left tenth has no depth; exactly 0.5 is not over it
        mask[at] = x < 10 ? 0.5 : 0.9;
      }
    }
    final samples = FocalShiftSamples.ofMap(points, mask, width, height);
    final spans = viewPlaneSpans(width, height);
    final columns = [
      for (var column = 0; column < 64; column++)
        if (column * width ~/ 64 >= 10) column * width ~/ 64,
    ];

    expect(samples.length, 64 * columns.length);
    for (var row = 0; row < 64; row++) {
      for (final (k, x) in columns.indexed) {
        final i = row * columns.length + k;
        final y = row * height ~/ 64;
        expect(samples.points[3 * i], x);
        expect(samples.points[3 * i + 1], y);
        expect(samples.uv[2 * i], closeTo(spans.x * (2 * (x + 0.5) / width - 1), 1e-15));
        expect(samples.uv[2 * i + 1], closeTo(spans.y * (2 * (y + 0.5) / height - 1), 1e-15));
      }
    }
  });

  // The real cases of the measure M2 (p2/results/ai1/focal_shift_reference_m2.json, four photos at 2 500 tokens):
  // the samples of MoGe at 64 x 64 and what recover_focal_shift of MoGe found, free and with a focal length fixed, and
  // the exact minimum. By hand only, the file staying out of the repository (1 MB): IMMUCH360_AI_FOCAL_REFERENCE.
  final reference = Platform.environment['IMMUCH360_AI_FOCAL_REFERENCE'];
  test('the real cases of M2: the samples of MoGe, its focal length and shift within 1e-4', () {
    final cases = ((jsonDecode(File(reference!).readAsStringSync()) as Map)['cases'] as List).cast<Map>();
    expect(cases, isNotEmpty);
    for (final entry in cases) {
      final width = entry['width'] as int;
      final height = entry['height'] as int;
      final reason = entry['photo'] as String;
      expect(entry['sample_rows'], [for (var row = 0; row < 64; row++) row * height ~/ 64], reason: reason);
      expect(entry['sample_cols'], [for (var column = 0; column < 64; column++) column * width ~/ 64], reason: reason);
      final spans = viewPlaneSpans(width, height);
      final points = <double>[];
      final uv = <double>[];
      for (var row = 0; row < 64; row++) {
        for (var column = 0; column < 64; column++) {
          final pixelUv = ((entry['uv_64'] as List)[row] as List)[column] as List;
          final x = (entry['sample_cols'] as List)[column] as int;
          final y = (entry['sample_rows'] as List)[row] as int;
          expect(pixelUv[0], closeTo(spans.x * (2 * (x + 0.5) / width - 1), 1e-6), reason: reason);
          expect(pixelUv[1], closeTo(spans.y * (2 * (y + 0.5) / height - 1), 1e-6), reason: reason);
          if (((entry['mask_64'] as List)[row] as List)[column] == 1) {
            points.addAll(
              (((entry['points_64'] as List)[row] as List)[column] as List).map((value) => (value as num).toDouble()),
            );
            uv.addAll(pixelUv.map((value) => (value as num).toDouble()));
          }
        }
      }
      final samples = FocalShiftSamples(Float64List.fromList(points), Float64List.fromList(uv));
      final free = recoverFocalShift(samples);
      final fixedFocal = (entry['fixed_focal'] as num).toDouble();
      final fixed = recoverFocalShift(samples, exifFocal: fixedFocal);

      expect(free.focal, closeTo((entry['moge_focal'] as num).toDouble(), 1e-4 * free.focal), reason: reason);
      expect(free.shift, closeTo((entry['moge_shift'] as num).toDouble(), 1e-4), reason: reason);
      expect(free.focal, closeTo((entry['exact_focal'] as num).toDouble(), 1e-6 * free.focal), reason: reason);
      expect(free.shift, closeTo((entry['exact_shift'] as num).toDouble(), 1e-6), reason: reason);
      expect(fixed.shift, closeTo((entry['moge_shift_with_fixed_focal'] as num).toDouble(), 1e-4), reason: reason);
      expect(fixed.shift, closeTo((entry['exact_shift_with_fixed_focal'] as num).toDouble(), 1e-6), reason: reason);
    }
  }, skip: reference == null ? 'by hand: set IMMUCH360_AI_FOCAL_REFERENCE to focal_shift_reference_m2.json' : null);

  test('a map of fewer than two valid points: the shift 0 and the focal length 1, as MoGe', () {
    final none = FocalShiftSamples(Float64List(0), Float64List(0));
    final one = FocalShiftSamples(Float64List.fromList([0.1, 0.2, 2]), Float64List.fromList([0.1, 0.2]));

    for (final samples in [none, one]) {
      final found = recoverFocalShift(samples);
      expect(found.shift, 0);
      expect(found.focal, 1);
      expect(found.fromExif, isFalse);
    }
    expect(recoverFocalShift(none, exifFocal: 1.2).focal, 1.2);
    expect(recoverFocalShift(none, exifFocal: 1.2).fromExif, isTrue);
    expect(focalOfExif35(0), isNull);
    expect(focalOfExif35(null), isNull);
  });
}
