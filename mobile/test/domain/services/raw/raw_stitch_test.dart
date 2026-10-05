// The CPU reference stitch of the raw videos (docs/18-design-projections-and-parsers.md, section 6.4): inputs drawn from
// the pattern by inverse mapping, then stitched back by the samplers, must give the pattern again. Two textures of a
// fisheye pair (Insta360 two tracks or split pair, DJI Kannala-Brandt), the five radial terms of a V6 string, and the
// two EAC tracks of a GoPro.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/raw/dual_fisheye_calibration.dart';
import 'package:immich_mobile/domain/services/raw/dji_osv.dart';
import 'package:immich_mobile/domain/services/raw/dual_fisheye_math.dart';
import 'package:immich_mobile/domain/services/raw/gopro_eac.dart';
import 'package:immich_mobile/domain/services/raw/insta360_trailer.dart';
import 'package:immich_mobile/domain/services/raw/raw_sampler.dart';

import '../../../fixtures/raw/dji_osv.stub.dart';
import '../../../fixtures/raw/dual_fisheye_frames.dart';
import '../../../fixtures/raw/insta360.stub.dart';
import '../../../fixtures/raw/raw_frames.dart';

// The accelerometer of the MakerNote of the real X3 photo whose calibration the fixtures hold
const _x3Accelerometer = [-1.003906, -0.124023, 0.082031];

DualFisheyeCalibration _x3() =>
    parseInsta360OffsetV3(x3OffsetV3)!.copyWith(downBody: downBodyFromAccelerometer(_x3Accelerometer));

const _side = 256;
const _sizes = [(width: _side, height: _side), (width: _side, height: _side)];

/// The textures of the two lenses of [calibration], lens i in texture [textureOfLens][i]
List<RgbaTexture> _lensTextures(DualFisheyeCalibration calibration, List<int> textureOfLens) {
  final lenses = [for (var i = 0; i < 2; i++) patternLensTexture(calibration, i, _side)];
  return [for (var texture = 0; texture < 2; texture++) lenses[textureOfLens.indexOf(texture)]];
}

double _error(List<RgbaTexture> textures, RawSampler sampler, {int width = 512, int height = 256}) =>
    meanPatternError(stitchRawRgba(textures, sampler, width: width, height: height), width, height);

void main() {
  group('FisheyePairSampler', () {
    test('stitches two textures of an X3, lens 1 in texture 0, back into the pattern', () {
      final calibration = _x3();
      const textureOfLens = [1, 0];
      final textures = _lensTextures(calibration, textureOfLens);

      final right = _error(
        textures,
        FisheyePairSampler(
          calibration,
          regions: FisheyePairSampler.wholeTextureRegions(textureOfLens),
          textureSizes: _sizes,
        ),
      );
      final swapped = _error(
        textures,
        FisheyePairSampler(
          calibration,
          regions: FisheyePairSampler.wholeTextureRegions(const [0, 1]),
          textureSizes: _sizes,
        ),
      );

      expect(right, lessThan(1));
      expect(swapped, greaterThan(10 * right), reason: 'the lenses swapped');
    });

    test('stitches the Kannala-Brandt lenses of an Osmo 360, placed by their quaternions', () {
      final quaternions = parseDjiCamdRecords(Uint8List.fromList(djiCamdRecords()))!.calibration;
      final angles = parseDjiCamdRecords(
        Uint8List.fromList(djiCamdRecords(config: djiConfig(calibration: djiSampleCalibration(withQuaternion: false)))),
      )!.calibration;
      const textureOfLens = [0, 1];
      final textures = _lensTextures(quaternions, textureOfLens);
      FisheyePairSampler sampler(DualFisheyeCalibration calibration) => FisheyePairSampler(
        calibration,
        regions: FisheyePairSampler.wholeTextureRegions(textureOfLens),
        textureSizes: _sizes,
      );

      final right = _error(textures, sampler(quaternions));
      final byAngles = _error(textures, sampler(angles));

      expect(quaternions.model, DualFisheyeModel.kannalaBrandt);
      expect(right, lessThan(1));
      expect(byAngles, greaterThan(1.5 * right), reason: 'lens 1 placed by its yaw, pitch and roll');
    });

    test('reads the five radial terms of a V6 string', () {
      final v6 = parseInsta360OffsetV6(x5OffsetV6)!;
      expect((v6.lenses.first.k4, v6.lenses.first.k5), (x5K4, x5K5));
      // The synthetic terms of the fixture move the rim by a thousandth of a pixel at this size: terms a thousand times
      // larger move it by a few pixels, which the pattern shows
      DualFisheyeCalibration withTerms(double k4, double k5) => v6.copyWith(
        lenses: [
          for (final lens in v6.lenses)
            DualFisheyeLens(
              cx: lens.cx,
              cy: lens.cy,
              yaw: lens.yaw,
              pitch: lens.pitch,
              roll: lens.roll,
              xi: lens.xi,
              fx: lens.fx,
              fy: lens.fy,
              k1: lens.k1,
              k2: lens.k2,
              k3: lens.k3,
              k4: k4,
              k5: k5,
              p1: lens.p1,
              p2: lens.p2,
            ),
        ],
      );
      final drawn = withTerms(1000 * x5K4, 1000 * x5K5);
      const textureOfLens = [0, 1];
      final textures = _lensTextures(drawn, textureOfLens);
      FisheyePairSampler sampler(DualFisheyeCalibration calibration) => FisheyePairSampler(
        calibration,
        regions: FisheyePairSampler.wholeTextureRegions(textureOfLens),
        textureSizes: _sizes,
      );

      final right = _error(textures, sampler(drawn));
      final wrong = _error(textures, sampler(withTerms(0, 0)));

      expect(right, lessThan(1));
      expect(wrong, greaterThan(3 * right));
    });

    test('scales a texture decoded at another size than declared, on each axis', () {
      final calibration = _x3();
      const textureOfLens = [1, 0];
      final textures = _lensTextures(calibration, textureOfLens);
      // Declared twice as large: the samples land on the same texture pixels once scaled back
      final sampler = FisheyePairSampler(
        calibration,
        regions: FisheyePairSampler.wholeTextureRegions(textureOfLens),
        textureSizes: const [(width: 2 * _side, height: 2 * _side), (width: 2 * _side, height: 2 * _side)],
      );

      expect(_error(textures, sampler), lessThan(1));
    });

    test('keeps the samples of a side by side frame half a pixel inside the half of their lens', () {
      final calibration = nominalX3(64);
      final sampler = FisheyePairSampler(
        calibration,
        regions: FisheyePairSampler.sideBySideRegions(),
        textureSizes: const [(width: 128, height: 64)],
      );

      for (var j = 0; j < 32; j++) {
        for (var i = 0; i < 64; i++) {
          final (:lon, :lat) = equirectAngles(i, j, 64, 32);
          for (final (:lens, :sample) in sampler.sampleLenses(lon, lat)) {
            expect(sample.texture, 0);
            expect(sample.x, inInclusiveRange(64 * lens + 0.5, 64 * lens + 63.5));
            expect(sample.y, inInclusiveRange(0.5, 63.5));
          }
        }
      }
    });
  });

  group('GoProEacSampler', () {
    test('reads the directions of the faces where the face table puts them', () {
      const geometry = GoProEacGeometry(trackWidth: 5888, trackHeight: 1920);
      final sampler = GoProEacSampler(geometry, viewToCamera: const [1, 0, 0, 0, -1, 0, 0, 0, 1]);

      expect(sampler.textureSizes, [(width: 5888, height: 1920), (width: 5888, height: 1920)]);
      final [forward] = sampler.sample(0, 0);
      expect((forward.texture, forward.x, forward.y, forward.weight), (0, 2944.0, 960.0, 1.0));
      final [backward] = sampler.sample(math.pi, 0);
      expect(backward.texture, 1);
      expect(backward.x, closeTo(2944, 1e-3));
      expect(backward.y, closeTo(960, 1e-3));
      // 20 degrees above forward
      final [up] = sampler.sample(0, 20 * math.pi / 180);
      expect(up.y, closeTo(533.333, 1e-3));
    });

    test('stitches the two tracks of a small EAC layout back into the pattern, opaque everywhere', () {
      const geometry = GoProEacGeometry(trackWidth: 208, trackHeight: 64);
      expect((geometry.overlap, geometry.half, geometry.middle, geometry.right), (8, 36, 72, 136));
      final viewToCamera = goProViewToCamera(geometry);
      final textures = [for (var texture = 0; texture < 2; texture++) patternEacTrack(geometry, texture, viewToCamera)];
      final sampler = GoProEacSampler(geometry);

      final stitched = stitchRawRgba(textures, sampler, width: 256, height: 128);

      expect(meanPatternError(stitched, 256, 128), lessThan(1.5));
      for (var at = 3; at < stitched.length; at += 4) {
        expect(stitched[at], 255);
      }
      // The camera turned a quarter, as the MAX table turns it: the error shows
      final turned = GoProEacSampler(geometry, viewToCamera: const [0, 1, 0, 1, 0, 0, 0, 0, 1]);
      expect(meanPatternError(stitchRawRgba(textures, turned, width: 256, height: 128), 256, 128), greaterThan(10));
    });
  });

  test('the side by side stitch of the photos is the fisheye pair sampler on one texture', () {
    final calibration = _x3();
    final frame = patternDualFisheye(calibration, 128);
    final sampler = FisheyePairSampler(
      calibration,
      regions: FisheyePairSampler.sideBySideRegions(),
      textureSizes: const [(width: 256, height: 128)],
    );

    expect(_error([(rgba: frame, width: 256, height: 128)], sampler, width: 256, height: 128), lessThan(1.5));
    expect(
      [for (final (:lens, :sample) in sampler.sampleLenses(0, 0)) (lens, sample.x.round(), sample.y.round())],
      [
        for (final sample in DualFisheyeSampler(calibration, frameWidth: 256, frameHeight: 128).sample(0, 0))
          (sample.lens, sample.x.round(), sample.y.round()),
      ],
    );
    expect(djiMaxTheta, 94);
  });
}
