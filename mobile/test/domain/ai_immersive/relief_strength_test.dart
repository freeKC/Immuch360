// The relief strength of release 46: three parallaxes within the comfort limits of the research, Normal the value of
// every earlier version, read back from the XMP of a 3D photo of ours only.

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/relief_strength.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

void main() {
  test('Subtle, Normal and Strong are 1.5 %, 2 % and 3 %, Normal the parallax of relief-v1 until now', () {
    expect(ReliefStrength.values, [ReliefStrength.subtle, ReliefStrength.normal, ReliefStrength.strong]);
    expect(ReliefStrength.subtle.parallax, 0.015);
    expect(ReliefStrength.normal.parallax, ReliefV1.parallax);
    expect(ReliefStrength.normal.parallax, 0.02);
    expect(ReliefStrength.strong.parallax, 0.03);
    // 3 % at most in total (Sky), 2 to 3 % for a still photo (Shibata)
    for (final strength in ReliefStrength.values) {
      expect(strength.parallax, inInclusiveRange(0.01, 0.03), reason: strength.name);
    }
  });

  test('a parallax tells its strength, any other none', () {
    for (final strength in ReliefStrength.values) {
      expect(ReliefStrength.ofParallax(strength.parallax), strength);
    }
    expect(ReliefStrength.ofParallax(double.parse('0.015')), ReliefStrength.subtle);
    expect(ReliefStrength.ofParallax(0.25), isNull);
    expect(ReliefStrength.ofParallax(0.025), isNull);
    expect(ReliefStrength.ofParallax(null), isNull);
  });

  test('a name kept in the settings tells its strength, a missing or unknown one Normal', () {
    expect(ReliefStrength.named('subtle'), ReliefStrength.subtle);
    expect(ReliefStrength.named('strong'), ReliefStrength.strong);
    expect(ReliefStrength.named('extreme'), ReliefStrength.normal);
    expect(ReliefStrength.named(null), ReliefStrength.normal);
    expect(ReliefStrength.named(3), ReliefStrength.normal);
  });

  group('the strength of a file', () {
    StereoPhotoXmp ours({double parallax = 0.02}) => StereoPhotoXmp.estimated(
      eyeWidth: 4032,
      eyeHeight: 3024,
      depthModelSha256: depthModelOnnxSha256,
      sourceName: 'salon.jpg',
      sourceSize: 1000,
      sourceSha1: 'sum',
      sourceQuarterTurns: 0,
      created: '2026-11-11T23:30:00Z',
      creatorTool: 'Immuch360 3.4.1',
      derivativeId: 'urn:uuid:1',
      parallax: parallax,
    );

    test('is read back from the XMP our 3D photos carry', () {
      for (final strength in ReliefStrength.values) {
        final read = StereoPhotoXmp.parse(ours(parallax: strength.parallax).toXml())!;

        expect(read.parallax, strength.parallax);
        expect(reliefStrengthOfXmp(read), strength);
      }
    });

    test('is none for a parallax of no strength, another pipeline, or a file of another tool', () {
      expect(reliefStrengthOfXmp(ours(parallax: 0.025)), isNull);
      expect(
        reliefStrengthOfXmp(
          const StereoPhotoXmp(origin: ImmersiveOrigin.estimatedDepth, pipeline: 'relief-v2', parallax: 0.03),
        ),
        isNull,
      );
      expect(reliefStrengthOfXmp(const StereoPhotoXmp(origin: ImmersiveOrigin.unknown, parallax: 0.02)), isNull);
      expect(reliefStrengthOfXmp(const StereoPhotoXmp()), isNull);
    });
  });
}
