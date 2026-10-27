import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/derived_file_rule.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

const _sum = 'X8tYgvibyzHDDN2yXGU/ft1XxeM=';
const _otherSum = 'AAAAAAAAAAAAAAAAAAAAAAAAAAA=';

StereoPhotoXmp _xmp({String? sha1 = _sum, String sourceName = 'salon.jpg', int sourceSize = 4182311}) => StereoPhotoXmp(
  eyes: StereoEyes.full,
  eyeOrder: EyeOrder.leftRight,
  origin: ImmersiveOrigin.estimatedDepth,
  sourceName: sourceName,
  sourceSize: sourceSize,
  sourceSha1: sha1,
);

void main() {
  group('the name of a 3D photo', () {
    test('is the name of the original without its extension, then _3D_LRF_Full_SBS.jpg', () {
      expect(sbsFileNameFor('salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
      expect(sbsFileNameFor('IMG_0042.HEIC'), 'IMG_0042_3D_LRF_Full_SBS.jpg');
      expect(sbsFileNameFor('photo.final.png'), 'photo.final_3D_LRF_Full_SBS.jpg');
      expect(sbsFileNameFor('noextension'), 'noextension_3D_LRF_Full_SBS.jpg');
    });

    test('adds nothing the 360°, VR180 or panorama rules read', () {
      final name = sbsFileNameFor('trip.jpg').toLowerCase();

      expect(name, isNot(contains('_180')));
      expect(name, isNot(contains('360')));
      expect(name, isNot(contains('pano')));
    });
  });

  group('isDerivedFrom', () {
    const original = DerivedRuleOriginal(name: 'salon.jpg', size: 4182311, folder: '/photos', sha1: _sum);

    test('the SHA-1 decides when both sides know it, wherever the version is and whatever its name', () {
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'anything.jpg', folder: '/elsewhere', xmp: _xmp()), original),
        isTrue,
      );
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(
            name: 'salon_3D_LRF_Full_SBS.jpg',
            folder: '/photos',
            xmp: _xmp(sha1: _otherSum),
          ),
          original,
        ),
        isFalse,
      );
    });

    test('without the sum of the original: same folder, name, SourceName and SourceSize', () {
      const unhashed = DerivedRuleOriginal(name: 'salon.jpg', size: 4182311, folder: '/photos');

      expect(
        isDerivedFrom(
          DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: _xmp()),
          unhashed,
        ),
        isTrue,
      );
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS (1).jpg', folder: '/photos', xmp: _xmp()),
          unhashed,
        ),
        isTrue,
      );
      // Another folder
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/other', xmp: _xmp()), unhashed),
        isFalse,
      );
      // A different size: the original was replaced by another photo of the same name
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: _xmp(sourceSize: 99)),
          unhashed,
        ),
        isFalse,
      );
      // An unknown folder never matches by name
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', xmp: _xmp()),
          const DerivedRuleOriginal(name: 'salon.jpg', size: 4182311),
        ),
        isFalse,
      );
    });

    test('without the sum in the version, the name rule applies', () {
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: _xmp(sha1: null)),
          original,
        ),
        isTrue,
      );
    });

    test('a name with a control character, which an XMP holds as U+FFFD, still names its original', () {
      const unhashed = DerivedRuleOriginal(name: 'sa\u0001lon.jpg', size: 4182311, folder: '/photos');

      expect(
        isDerivedFrom(
          DerivedRuleCandidate(
            name: 'sa\u0001lon_3D_LRF_Full_SBS.jpg',
            folder: '/photos',
            xmp: _xmp(sourceName: 'sa\uFFFDlon.jpg'),
          ),
          unhashed,
        ),
        isTrue,
      );
    });

    test('close names do not mislead it', () {
      const salon2 = DerivedRuleOriginal(name: 'salon2.jpg', size: 4182311, folder: '/photos');

      // The version of salon.jpg is not one of salon2.jpg
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: _xmp()), salon2),
        isFalse,
      );
      // A version named after salon2 but made from salon.jpg
      expect(
        isDerivedFrom(DerivedRuleCandidate(name: 'salon2_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: _xmp()), salon2),
        isFalse,
      );
      // A version of a version
      expect(
        isDerivedFrom(
          DerivedRuleCandidate(
            name: 'salon_3D_LRF_Full_SBS_3D_LRF_Full_SBS.jpg',
            folder: '/photos',
            xmp: _xmp(sourceName: 'salon_3D_LRF_Full_SBS.jpg'),
          ),
          const DerivedRuleOriginal(name: 'salon.jpg', size: 4182311, folder: '/photos'),
        ),
        isFalse,
      );
    });

    test('a file without our XMP is never a version, even under the right name', () {
      expect(
        isDerivedFrom(
          const DerivedRuleCandidate(name: 'salon_3D_LRF_Full_SBS.jpg', folder: '/photos', xmp: null),
          original,
        ),
        isFalse,
      );
    });
  });

  group('derivedNameCandidates', () {
    test('keeps the names that start like a version, at most eight, never the original', () {
      final names = [
        'salon.jpg',
        'salon2.jpg',
        'salon_3D_LRF_Full_SBS.jpg',
        'salon2_3D_LRF_Full_SBS.jpg',
        for (var i = 1; i <= 9; i++) 'salon_3D_LRF_Full_SBS ($i).jpg',
      ];

      expect(derivedNameCandidates('salon.jpg', names), [
        'salon_3D_LRF_Full_SBS.jpg',
        for (var i = 1; i <= 7; i++) 'salon_3D_LRF_Full_SBS ($i).jpg',
      ]);
      expect(maxDerivedCandidates, 8);
    });

    test('knows the four kinds of versions, and the 3D version of a photo whose name says 360', () {
      final names = [
        'salon_scene3D.jpg',
        'salon_360.jpg',
        'salon_360_3D.jpg',
        'salon_360 (2).jpg',
        'salon_scene3D (1).jpg',
        'PANO_0001_3D.jpg',
        // Close names: no read
        'salon_3Dmax.jpg',
        'salon_3600.jpg',
        'salon_360x.jpg',
        'salon_scene3Dx.jpg',
        'salon2_360.jpg',
        'salon_360.jpg.txt',
      ];

      expect(derivedNameCandidates('salon.jpg', names), [
        'salon_scene3D.jpg',
        'salon_360.jpg',
        'salon_360_3D.jpg',
        'salon_360 (2).jpg',
        'salon_scene3D (1).jpg',
      ]);
      expect(derivedNameCandidates('PANO_0001.jpg', names), ['PANO_0001_3D.jpg']);
      // The names the app writes are candidates of their original
      for (final kind in ImmersiveKind.values) {
        expect(isDerivedNameCandidate('salon.jpg', derivedFileNameFor(kind, 'salon.jpg')), isTrue, reason: '$kind');
        expect(
          isDerivedNameCandidate('PANO_0001.jpg', derivedFileNameFor(kind, 'PANO_0001.jpg')),
          isTrue,
          reason: '$kind',
        );
      }
    });

    test('a scene or a panorama is a version by its sum, whatever its kind, as a 3D photo', () {
      const original = DerivedRuleOriginal(name: 'salon.jpg', size: 4182311, folder: '/photos', sha1: _sum);
      for (final kind in [ImmersiveKind.volumetricScene, ImmersiveKind.panorama360, ImmersiveKind.stereoPanorama360]) {
        final xmp = StereoPhotoXmp(kind: kind, sourceSha1: _sum, sourceName: 'salon.jpg');

        expect(
          isDerivedFrom(DerivedRuleCandidate(name: 'renamed.jpg', folder: '/elsewhere', xmp: xmp), original),
          isTrue,
          reason: '$kind',
        );
      }
    });

    test('accepts the name the computers write for a name Windows refuses', () {
      expect(isDerivedNameCandidate('12:30.jpg', '12_30_3D_LRF_Full_SBS.jpg'), isTrue);
      expect(isDerivedNameCandidate('12:30.jpg', '12:30_3D_LRF_Full_SBS.jpg'), isTrue);
      expect(isDerivedNameCandidate('12:30.jpg', '12_31_3D_LRF_Full_SBS.jpg'), isFalse);
    });
  });
}
