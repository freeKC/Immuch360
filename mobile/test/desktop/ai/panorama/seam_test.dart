// The seam of a generated 360° panorama (lot P3, design-final 2026-10-27, section 4.3, point 6; measure M3, section 9,
// point 8): the panorama rolled by half a turn, the band at its centre filled in region after region by the filling of
// the panorama (MI-GAN, a fake here), rolled back; nothing but the band changes, the seam is measured before and after
// as M3 measured it, and the flag seam is raised when it stays above twice the jump between neighbouring columns.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/engine/backends.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_engine.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/desktop/ai/panorama/seam.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

import '../fakes/fake_backends.dart';

/// A panorama of [width] x [height] that changes slowly across, whose last column does not meet its first: a ramp of
/// red from 0 to 250 and a constant blue
Uint8List _ramp(int width, int height) {
  final rgba = Uint8List(4 * width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final at = 4 * (y * width + x);
      rgba[at] = 250 * x ~/ (width - 1);
      rgba[at + 1] = 60 + y % 7;
      rgba[at + 2] = 140;
      rgba[at + 3] = 255;
    }
  }
  return rgba;
}

/// A filling that writes the mean of the known pixels of each row of the region into its holes
class _RowMean implements InpaintBackend {
  _RowMean({this.regionMax = 512});

  @override
  final int regionMax;

  @override
  String get modelSha256 => '4' * 64;
  final regions = <InpaintRegion>[];

  @override
  Uint8List fill(InpaintRegion region) {
    regions.add(region);
    final out = Uint8List.fromList(region.rgb);
    for (var y = 0; y < region.height; y++) {
      final sums = [0, 0, 0];
      var known = 0;
      for (var x = 0; x < region.width; x++) {
        if (region.mask[y * region.width + x] == 255) {
          known++;
          for (var c = 0; c < 3; c++) {
            sums[c] += region.rgb[3 * (y * region.width + x) + c];
          }
        }
      }
      for (var x = 0; x < region.width; x++) {
        if (region.mask[y * region.width + x] != 255) {
          for (var c = 0; c < 3; c++) {
            out[3 * (y * region.width + x) + c] = known == 0 ? 0 : sums[c] ~/ known;
          }
        }
      }
    }
    return out;
  }

  @override
  void close() {}
}

/// A filling that writes one grey into the holes of each region, a different one for each: [greyOf] the index of the
/// region
class _GreyPerRegion implements InpaintBackend {
  _GreyPerRegion(this.regionMax);

  @override
  final int regionMax;

  @override
  String get modelSha256 => '4' * 64;
  var _regions = 0;

  static int greyOf(int region) => 30 + 60 * region;

  @override
  Uint8List fill(InpaintRegion region) {
    final grey = greyOf(_regions++);
    final out = Uint8List.fromList(region.rgb);
    for (var i = 0; i < region.width * region.height; i++) {
      if (region.mask[i] == 0) {
        out.fillRange(3 * i, 3 * i + 3, grey);
      }
    }
    return out;
  }

  @override
  void close() {}
}

void main() {
  test('the band of the seam is that of the control frame in proportion: 96 columns of a generation of 1536', () {
    expect(seamBandFor(PanoV1.generationWidth), 96);
    expect(seamBandFor(PanoV1.controlWidth), PanoV1.seamBand);
    expect(seamBandFor(48), 4);
  });

  test('the seam measured as M3 did: the jump from the last column to the first over the usual jump', () {
    final rgba = _ramp(64, 8);
    // Red goes up by about 4 a column and falls by 250 at the seam, over three channels
    expect(seamRatioOf(rgba, 64, 8), closeTo(250 / 3.968, 0.5));
    final turned = rollColumns(rgba, 64, 8, 32);
    expect(seamRatioOf(turned, 64, 8), lessThan(2));
  });

  test('filled in at the centre of the panorama rolled by half a turn, then rolled back: only the band changes', () {
    const width = 128;
    const height = 40;
    final rgba = _ramp(width, height);
    final inpaint = _RowMean();
    final joined = joinSeam(rgba, width, height, inpaint, band: 16);
    expect(joined.before, greaterThan(PanoV1.seamRatio));
    expect(joined.after, lessThan(joined.before));
    expect(joined.visible, joined.after > PanoV1.seamRatio);
    expect(joined.regions, 1);
    final region = inpaint.regions.single;
    expect(region.width, width);
    expect(region.height, height);
    // The holes: 16 columns at the centre of the rolled panorama, every row
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        expect(region.mask[y * width + x], x >= 56 && x < 72 ? 0 : 255, reason: '($x, $y)');
      }
    }
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final inBand = x < 8 || x >= width - 8;
        final at = 4 * (y * width + x);
        if (!inBand) {
          expect(joined.rgba.sublist(at, at + 4), rgba.sublist(at, at + 4), reason: '($x, $y) is not in the band');
        }
        expect(joined.rgba[at + 3], 255);
      }
    }
    expect(joined.rgba, isNot(equals(rgba)));
  });

  test('a panorama taller than a region: regions down the band, each after the one above it, blended into it', () {
    const width = 64;
    const height = 50;
    final inpaint = _RowMean(regionMax: 20);
    final tops = joinSeamRegionTops(height, 20);
    expect(tops, [0, 10, 20, 30]);
    final done = <(int, int)>[];
    final rgba = _ramp(width, height);
    final joined = joinSeam(
      rgba,
      width,
      height,
      inpaint,
      band: 8,
      onRegion: (index, total) => done.add((index, total)),
    );
    expect(joined.regions, 4);
    expect(done, [(1, 4), (2, 4), (3, 4), (4, 4)]);
    // Every row of the band is a hole; the last rows a region filled are filled again by the next, then blended
    final holes = List.filled(height, 0);
    for (final (index, region) in inpaint.regions.indexed) {
      expect(region.width, lessThanOrEqualTo(20));
      expect(region.height, 20);
      for (var y = 0; y < region.height; y++) {
        if (region.mask[y * region.width + region.width ~/ 2] == 0) {
          holes[tops[index] + y]++;
        }
      }
    }
    final blend = seamRegionBlend(20);
    expect(blend, greaterThan(0));
    for (var y = 0; y < height; y++) {
      final again = [20, 30, 40].any((end) => y >= end - blend && y < end);
      expect(holes[y], again ? 2 : 1, reason: 'row $y');
    }
  });

  test('where two regions meet, the rows filled again go from the fill above to the one below in even steps', () {
    // The bright lines of the first run on the RTX 4060 came back with a hard edge at the first row filled again (no
    // blend) or at the end of the region above (the blend the other way round): each region writes its own grey here,
    // and down a column of the band no row may jump by more than one step of the blend
    const width = 64;
    const height = 160;
    const regionMax = 64;
    expect(joinSeamRegionTops(height, regionMax), [0, 32, 64, 96]);
    final blend = seamRegionBlend(regionMax);
    expect(blend, 4);
    final joined = joinSeam(_ramp(width, height), width, height, _GreyPerRegion(regionMax), band: 8);
    // Column 0 is in the band, which straddles the seam (columns 60 to 63 and 0 to 3)
    final column = [for (var y = 0; y < height; y++) joined.rgba[4 * y * width]];
    // 60 between two greys over the 4 rows filled again and the first row below them: 12 a row
    final step = (_GreyPerRegion.greyOf(1) - _GreyPerRegion.greyOf(0)) ~/ (blend + 1);
    for (final (index, end) in [64, 96, 128].indexed) {
      final above = _GreyPerRegion.greyOf(index);
      final below = _GreyPerRegion.greyOf(index + 1);
      expect(column[end - blend - 1], above, reason: 'the last row the region above keeps as it filled it');
      for (var k = 0; k < blend; k++) {
        expect(column[end - blend + k], above + (k + 1) * step, reason: 'row ${end - blend + k}, filled again');
      }
      expect(column[end], below, reason: 'row $end, the first row only the region below filled');
    }
    for (var y = 1; y < height; y++) {
      expect((column[y] - column[y - 1]).abs(), lessThanOrEqualTo(step), reason: 'row $y');
    }
  });

  test('cancelled between two regions, and the failure of the filling, are told', () {
    final inpaint = _RowMean(regionMax: 20);
    var asked = 0;
    expect(
      () => joinSeam(_ramp(64, 50), 64, 50, inpaint, band: 8, isCancelled: () => ++asked > 1),
      throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.cancelled)),
    );
    expect(inpaint.regions, hasLength(1));
    final failing = FakeInpaintBackend(failure: const BackendException(ImmersiveErrorCode.modelFailed, 'MI-GAN'));
    expect(
      () => joinSeam(_ramp(64, 8), 64, 8, failing, band: 8),
      throwsA(isA<BackendException>().having((error) => error.code, 'code', ImmersiveErrorCode.modelFailed)),
    );
  });
}
