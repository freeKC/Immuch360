import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

// The golden fixtures of phases 2 and 3, written once in Python (.github/desktop/ai/make_scene_golden.py,
// make_focal_shift_golden.py, make_pano_golden.py): their constants are those of SceneV1, PanoV1 and Relief360V1, and a
// few of their numbers are checked here by small ports, so that the engines of S1, P1 and P3 start from a fixture
// whose rules this side reads the same way.

Map<String, dynamic> _golden(String name) =>
    jsonDecode(File('test/fixtures/ai_immersive/$name').readAsStringSync()) as Map<String, dynamic>;

List<double> _doubles(Object? list) => (list! as List).map((value) => (value as num).toDouble()).toList();

void _close(double actual, double expected, double tolerance, {String? reason}) =>
    expect(actual, closeTo(expected, tolerance * math.max(1, expected.abs())), reason: reason);

double _smooth(double t) {
  final clamped = t.clamp(0.0, 1.0);
  return clamped * clamped * (3 - 2 * clamped);
}

void main() {
  group('scene_golden_v1.json', () {
    final golden = _golden('scene_golden_v1.json');
    final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
    final tolerance = (golden['tolerance'] as num).toDouble();

    test('holds the constants of SceneV1', () {
      expect(golden['pipeline'], SceneV1.pipeline);
      expect(golden['gridStep'], SceneV1.gridStep);
      expect(golden['maxGridVertices'], SceneV1.maxGridVertices);
      expect(golden['breakThreshold'], SceneV1.breakThreshold);
      expect(golden['percentiles'], [SceneV1.lowPercentile, SceneV1.highPercentile]);
      expect(golden['comfortDistance'], SceneV1.comfortDistance);
      expect(_doubles(golden['band']), [SceneV1.bandFactor, SceneV1.bandMin, SceneV1.bandMax, SceneV1.bandSmoothing]);
      expect(golden['inpaintFactor'], SceneV1.inpaintMaskFactor);
      expect(golden['hiddenAreasRatio'], SceneV1.hiddenAreasRatio);
      expect(_doubles(golden['sky']), [
        SceneV1.validMask,
        SceneV1.skyPercentile,
        SceneV1.skyNearest,
        SceneV1.skyFarthest,
        SceneV1.skyRatio,
      ]);
      final zone = golden['zone'] as Map<String, dynamic>;
      expect(zone['percentile'], SceneV1.zonePercentile);
      expect(_doubles(zone['lateral']), [SceneV1.lateralMin, SceneV1.lateralMax]);
      expect(zone['verticalShare'], SceneV1.verticalShare);
      expect(zone['forwardPercentile'], SceneV1.forwardPercentile);
      expect(zone['forwardShare'], SceneV1.forwardShare);
      expect(_doubles(zone['forward']), [SceneV1.forwardMin, SceneV1.forwardMax]);
      expect(zone['backwardShare'], SceneV1.backwardShare);
      expect(_doubles(zone['backward']), [SceneV1.backwardMin, SceneV1.backwardMax]);
      expect(zone['smallZone'], SceneV1.smallZone);
      expect(_doubles(golden['flatten']), [
        SceneV1.flattenFrom,
        SceneV1.flattenTo,
        SceneV1.darkenFrom,
        SceneV1.darkenMax,
        SceneV1.flatBackground,
        SceneV1.flattenStep,
      ]);
    });

    test('the edge of the zone flattens then darkens on the smooth curve of ReliefMesh', () {
      for (final row in (golden['edgeCurve'] as List).cast<List<dynamic>>()) {
        final rho = (row[0] as num).toDouble();
        final flatten = _smooth((rho - SceneV1.flattenFrom) / (SceneV1.flattenTo - SceneV1.flattenFrom));
        final darken =
            SceneV1.darkenMax * _smooth((rho - SceneV1.darkenFrom) / (SceneV1.flattenTo - SceneV1.darkenFrom));

        _close(flatten, (row[1] as num).toDouble(), tolerance, reason: 'flatten at $rho');
        _close(darken, (row[2] as num).toDouble(), tolerance, reason: 'darken at $rho');
      }
    });

    test('the grid steps from 4 to keep the main grid under 50 000 vertices: 5 for a square photo', () {
      for (final row in (golden['gridSteps'] as List).cast<List<dynamic>>()) {
        final width = row[0] as int;
        final height = row[1] as int;
        final step = row[2] as int;
        final reason = '$width x $height';

        expect(SceneV1.gridStepFor(width, height), step, reason: reason);
        expect(SceneV1.gridStepFor(height, width), step, reason: reason);
        expect(SceneV1.gridLineCount(width, step), row[3], reason: reason);
        expect(SceneV1.gridLineCount(height, step), row[4], reason: reason);
      }
      final square = cases.firstWhere((entry) => entry['name'] == 'square');
      expect(square['gridStep'], SceneV1.gridStepFor(1024, 1024));
      expect(square['gridStep'], 5);
    });

    test('every case: a grid of ReliefMesh, masks of the map, flags of a scene, a zone within its bounds', () {
      expect(cases.map((entry) => entry['name']), [
        'step',
        'person',
        'close',
        'ledge',
        'flat',
        'sky',
        'near',
        'nearest',
        'square',
      ]);
      for (final entry in cases) {
        final reason = entry['name'] as String;
        final width = entry['width'] as int;
        final height = entry['height'] as int;
        final step = entry['gridStep'] as int;
        final columns = entry['columns'] as int;
        final rows = entry['rows'] as int;

        expect(columns, SceneV1.gridLineCount(width, step), reason: reason);
        expect(rows, SceneV1.gridLineCount(height, step), reason: reason);
        expect(entry['vertices'] as List, hasLength(3 * columns * rows), reason: reason);
        for (final key in ['band', 'inpaintMask']) {
          final mask = (entry[key] as List).cast<String>();
          expect(mask, hasLength(height), reason: reason);
          expect(mask.every((row) => RegExp('^[01]{$width}\$').hasMatch(row)), isTrue, reason: reason);
        }
        // The filling reaches at least the band
        final band = (entry['band'] as List).cast<String>().join();
        final inpaint = (entry['inpaintMask'] as List).cast<String>().join();
        for (var i = 0; i < band.length; i++) {
          if (band[i] == '1') {
            expect(inpaint[i], '1', reason: reason);
          }
        }
        final flags = (entry['flags'] as List).cast<String>();
        expect(
          flags.every(
            (flag) => qualityFlagsOf(ImmersiveKind.volumetricScene).contains(ReliefQualityFlag.fromXmp(flag)),
          ),
          isTrue,
          reason: reason,
        );
        final safe = (entry['safe'] as Map).cast<String, num>();
        expect(safe['lateral'], inInclusiveRange(SceneV1.lateralMin, SceneV1.lateralMax), reason: reason);
        // The flags by their rules: smallZone under 12 cm of lateral zone, hiddenAreas over 8 % of the map in bands
        expect(flags.contains('smallZone'), safe['lateral']! < SceneV1.smallZone, reason: reason);
        expect(
          flags.contains('hiddenAreas'),
          '1'.allMatches(band).length > SceneV1.hiddenAreasRatio * width * height,
          reason: reason,
        );
        _close(safe['vertical']!.toDouble(), SceneV1.verticalShare * safe['lateral']!, tolerance, reason: reason);
        expect(safe['forward'], inInclusiveRange(SceneV1.forwardMin, SceneV1.forwardMax), reason: reason);
        expect(safe['backward'], inInclusiveRange(SceneV1.backwardMin, SceneV1.backwardMax), reason: reason);
        // The bands of the breaks, by their rule
        final breaks = (entry['breaks'] as List).cast<List<dynamic>>();
        final widths = (entry['bandWidths'] as List).cast<int>();
        for (var i = 0; i < breaks.length; i++) {
          final jump = (breaks[i][4] as num).toDouble();
          expect(jump, greaterThan(SceneV1.breakThreshold), reason: reason);
          expect(
            widths[i],
            (SceneV1.bandFactor * jump + 0.5).floor().clamp(SceneV1.bandMin, SceneV1.bandMax),
            reason: reason,
          );
        }
        // The lateral zone: the percentile 10, by nearest rank, of the step aside each break allows, clamped
        final depth = (entry['depth'] as List).map(_doubles).toList();
        final focal = (entry['focal'] as num).toDouble();
        final steps = [
          for (var i = 0; i < breaks.length; i++)
            widths[i] /
                (focal *
                    (1 / depth[breaks[i][1] as int][breaks[i][0] as int] -
                        1 / depth[breaks[i][3] as int][breaks[i][2] as int])),
        ]..sort();
        final lateral = steps.isEmpty
            ? SceneV1.lateralMax
            : steps[math.max(1, (SceneV1.zonePercentile * steps.length + 99) ~/ 100) - 1].clamp(
                SceneV1.lateralMin,
                SceneV1.lateralMax,
              );
        _close(safe['lateral']!.toDouble(), lateral, tolerance, reason: reason);
      }
    });

    test('the cases cover the comfort scale, the sky, a flat wall, a narrow band and a small zone', () {
      Map<String, dynamic> named(String name) => cases.firstWhere((entry) => entry['name'] == name);

      _close((named('close')['scale'] as num).toDouble(), SceneV1.comfortDistance / 0.30, tolerance);
      expect(named('step')['scale'], 1.0);
      expect(named('sky')['flags'], contains('sky'));
      expect(named('flat')['flags'], ['lowRelief']);
      expect(named('flat')['breaks'], isEmpty);
      expect((named('flat')['safe'] as Map)['lateral'], SceneV1.lateralMax);
      expect(named('ledge')['bandWidths'], contains(10));
      // A small zone: between the floor and 12 cm, then held at the floor
      final near = (named('near')['safe'] as Map)['lateral'] as num;
      expect(near, allOf(greaterThan(SceneV1.lateralMin), lessThan(SceneV1.smallZone)));
      expect(named('near')['flags'], ['hiddenAreas', 'smallZone']);
      expect((named('nearest')['safe'] as Map)['lateral'], SceneV1.lateralMin);
      expect(named('nearest')['flags'], contains('smallZone'));
      expect(named('close')['flags'], isNot(contains('smallZone')), reason: 'just over 12 cm');
    });
  });

  group('focal_shift_golden_v1.json', () {
    final golden = _golden('focal_shift_golden_v1.json');
    final cases = (golden['cases'] as List).cast<Map<String, dynamic>>();
    final tolerance = (golden['tolerance'] as num).toDouble();

    double error(Map<String, dynamic> entry, double shift, double? focal) {
      final points = _doubles(entry['points']);
      final uv = _doubles(entry['uv']);
      final mask = _doubles(entry['mask']);
      var top = 0.0;
      var bottom = 0.0;
      for (var i = 0; i < mask.length; i++) {
        if (mask[i] > SceneV1.validMask) {
          final px = points[3 * i] / (points[3 * i + 2] + shift);
          final py = points[3 * i + 1] / (points[3 * i + 2] + shift);
          top += px * uv[2 * i] + py * uv[2 * i + 1];
          bottom += px * px + py * py;
        }
      }
      final f = focal ?? top / bottom;
      var total = 0.0;
      for (var i = 0; i < mask.length; i++) {
        if (mask[i] > SceneV1.validMask) {
          final ex = f * points[3 * i] / (points[3 * i + 2] + shift) - uv[2 * i];
          final ey = f * points[3 * i + 1] / (points[3 * i + 2] + shift) - uv[2 * i + 1];
          total += ex * ex + ey * ey;
        }
      }
      return total;
    }

    test('holds the constants of the fit', () {
      expect(golden['validMask'], SceneV1.validMask);
      expect(golden['fovMismatch'], SceneV1.fovMismatch);
      expect(golden['halfDiagonal35mm'], 21.635);
    });

    test('the view plane of MoGe: the half diagonal is 1, the centres of the points', () {
      for (final entry in cases) {
        final width = entry['width'] as int;
        final height = entry['height'] as int;
        final aspect = width / height;
        final spanX = aspect / math.sqrt(1 + aspect * aspect);
        final spanY = 1 / math.sqrt(1 + aspect * aspect);
        final uv = _doubles(entry['uv']);

        _close(spanX, (entry['spanX'] as num).toDouble(), tolerance);
        for (var j = 0; j < height; j++) {
          for (var i = 0; i < width; i++) {
            _close(uv[2 * (j * width + i)], spanX * (2 * (i + 0.5) / width - 1), tolerance);
            _close(uv[2 * (j * width + i) + 1], spanY * (2 * (j + 0.5) / height - 1), tolerance);
          }
        }
      }
    });

    test('the shift found is the least error, and the focal comes back on exact points', () {
      for (final entry in cases) {
        final shift = (entry['shift'] as num).toDouble();
        final reason = entry['name'] as String;
        final best = error(entry, shift, null);

        _close(best, (entry['error'] as num).toDouble(), tolerance, reason: reason);
        expect(error(entry, shift - 1e-3, null), greaterThanOrEqualTo(best), reason: reason);
        expect(error(entry, shift + 1e-3, null), greaterThanOrEqualTo(best), reason: reason);
        _close(
          (entry['fovDegrees'] as num).toDouble(),
          2 * math.atan((entry['spanX'] as num) / (entry['focal'] as num)) * 180 / math.pi,
          tolerance,
          reason: reason,
        );
      }
      final exact = cases.firstWhere((entry) => entry['name'] == 'exact');
      _close((exact['focal'] as num).toDouble(), (exact['trueFocal'] as num).toDouble(), 1e-9);
      _close((exact['shift'] as num).toDouble(), (exact['trueShift'] as num).toDouble(), 1e-9);
    });

    test('the EXIF fixes the focal length, and a mismatch over 25 % says fovGuessed', () {
      Map<String, dynamic> named(String name) => cases.firstWhere((entry) => entry['name'] == name);
      double fov(Map<String, dynamic> entry, double focal) => 2 * math.atan((entry['spanX'] as num) / focal);

      _close((named('exif')['exifFocal'] as num).toDouble(), 28 / 21.635, tolerance);
      expect(named('exif')['fovGuessed'], isFalse);
      expect(named('exifMismatch')['fovGuessed'], isTrue);
      expect(named('exact')['fovGuessed'], isTrue, reason: 'no EXIF');
      // The rule compares focal lengths, against that of the EXIF
      for (final entry in cases) {
        final exifFocal = (entry['exifFocal'] as num?)?.toDouble();
        final focal = (entry['focal'] as num).toDouble();

        expect(
          entry['fovGuessed'],
          exifFocal == null || (focal - exifFocal).abs() > SceneV1.fovMismatch * exifFocal,
          reason: entry['name'] as String,
        );
      }
      // On each side of the threshold, where the wrong rules give the other answer
      final near = named('exifNear');
      final far = named('exifFar');
      final nearFocal = (near['focal'] as num).toDouble();
      final farFocal = (far['focal'] as num).toDouble();
      final nearExif = (near['exifFocal'] as num).toDouble();
      final farExif = (far['exifFocal'] as num).toDouble();
      expect(near['fovGuessed'], isFalse);
      expect(far['fovGuessed'], isTrue);
      expect((nearFocal - nearExif).abs() / nearFocal, greaterThan(SceneV1.fovMismatch), reason: 'over the model');
      expect(
        (fov(far, farFocal) - fov(far, farExif)).abs() / fov(far, farExif),
        lessThan(SceneV1.fovMismatch),
        reason: 'fields of view',
      );
      final exif = named('exif');
      final shift = (exif['shiftForExif'] as num).toDouble();
      final focal = (exif['exifFocal'] as num).toDouble();
      expect(error(exif, shift + 1e-3, focal), greaterThanOrEqualTo(error(exif, shift, focal)));
    });
  });

  group('pano_golden_v1.json', () {
    final golden = _golden('pano_golden_v1.json');
    final tolerance = (golden['tolerance'] as num).toDouble();

    test('holds the constants of PanoV1 and Relief360V1', () {
      expect(golden['green'], [0, 255, 0]);
      expect(golden['pasteFeather'], PanoV1.pasteFeather);
      expect(golden['maxShiftDegrees'], Relief360V1.maxShiftDegrees);
      expect(golden['linkThreshold'], Relief360V1.linkThreshold);
      expect(golden['maxFilled'], Relief360V1.maxFilled);
      expect(golden['hiddenAreasRatio'], ReliefV1.hiddenAreasRatio);
    });

    test('a photo projected on the control frame: green around it, its coverage, the roll of half a turn', () {
      final width = golden['frameWidth'] as int;
      final height = golden['frameHeight'] as int;
      for (final entry in (golden['projections'] as List).cast<Map<String, dynamic>>()) {
        final control = (entry['control'] as List).map((row) => (row as List).cast<int>()).toList();
        final rolled = (entry['rolled'] as List).map((row) => (row as List).cast<int>()).toList();
        final inside = (entry['inside'] as List).cast<String>();
        var covered = 0.0;
        var total = 0.0;
        for (var y = 0; y < height; y++) {
          final weight = math.cos(math.pi * (0.5 - (y + 0.5) / height));
          for (var x = 0; x < width; x++) {
            total += weight;
            final pixel = control[y].sublist(3 * x, 3 * x + 3);
            if (inside[y][x] == '1') {
              covered += weight;
            } else {
              expect(pixel, [0, 255, 0]);
            }
            final source = (x + width ~/ 2) % width;
            expect(rolled[y].sublist(3 * x, 3 * x + 3), control[y].sublist(3 * source, 3 * source + 3));
          }
        }
        _close(covered / total, (entry['coverage'] as num).toDouble(), tolerance);
        final t = math.tan((entry['hfov'] as num) * math.pi / 360);
        _close(
          (entry['vfov'] as num).toDouble(),
          2 * math.atan(t * (entry['photoHeight'] as int) / (entry['photoWidth'] as int)) * 180 / math.pi,
          tolerance,
        );
        // The photo stays at the centre column: the panorama opens on it
        expect(inside[height ~/ 2][width ~/ 2], '1');
      }
    });

    test('relief-360-v1: the far stays, a flat map is refused, a strong shift opens holes across the seam', () {
      final reliefs = {
        for (final entry in (golden['reliefs'] as List).cast<Map<String, dynamic>>()) entry['name'] as String: entry,
      };

      expect(reliefs['production']!['filledPixels'], 0);
      expect(reliefs['production']!['refused'], isFalse);
      expect(reliefs['flat']!['refused'], isTrue);
      expect(reliefs['flat']!['flags'], ['lowRelief']);
      final holes = (reliefs['strong']!['holes'] as List).cast<String>();
      expect(holes.any((row) => row.startsWith('1')), isTrue, reason: 'beside the object, past the seam');
      // The rows away from the object open nothing
      expect(holes.first, isNot(contains('1')));
      expect(holes.last, isNot(contains('1')));
      final strong = reliefs['strong']!;
      expect(
        (strong['filledFraction'] as num).toDouble(),
        closeTo(
          (strong['filledPixels'] as int) / ((golden['frameWidth'] as int) * (golden['frameHeight'] as int)),
          1e-12,
        ),
      );
    });

    test('relief-360-v1: hiddenAreas over 5 % filled, refused over 8 % or without relief', () {
      final reliefs = {
        for (final entry in (golden['reliefs'] as List).cast<Map<String, dynamic>>()) entry['name'] as String: entry,
      };
      final frame = (golden['frameWidth'] as int) * (golden['frameHeight'] as int);

      for (final entry in reliefs.values) {
        final reason = entry['name'] as String;
        final fraction = (entry['filledFraction'] as num).toDouble();
        final flags = (entry['flags'] as List).cast<String>();

        expect(fraction, closeTo((entry['filledPixels'] as int) / frame, 1e-12), reason: reason);
        expect(flags.contains('hiddenAreas'), fraction > ReliefV1.hiddenAreasRatio, reason: reason);
        expect(entry['refused'], flags.contains('lowRelief') || fraction > Relief360V1.maxFilled, reason: reason);
      }
      final hidden = (reliefs['hidden']!['filledFraction'] as num).toDouble();
      expect(hidden, allOf(greaterThan(ReliefV1.hiddenAreasRatio), lessThanOrEqualTo(Relief360V1.maxFilled)));
      expect(reliefs['hidden']!['flags'], ['hiddenAreas']);
      expect(reliefs['hidden']!['refused'], isFalse);
      expect((reliefs['tooMuch']!['filledFraction'] as num).toDouble(), greaterThan(Relief360V1.maxFilled));
      expect(reliefs['tooMuch']!['flags'], ['hiddenAreas']);
      expect(reliefs['tooMuch']!['refused'], isTrue);
    });
  });
}
