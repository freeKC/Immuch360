import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/splat_photo/jpeg_walk.dart';

import 'splat_photo_fixtures.dart';

/// What release 40 makes of a splat photo, through the readers it ships and this build keeps (plan of 3 November
/// 2026, section 2.3): a plain photo. Its 3D scene probe, its flat 3D probe and its name rules see nothing.
void main() {
  const carriers = ['ok_v2.jpg', 'ok_v4.jpg', 'ok_exiftool.jpg'];

  for (final file in carriers) {
    final name = 'salon_${file.replaceAll('.jpg', '')}_splat.jpg';
    test('$file, named $name, is a plain photo for release 40', () {
      final bytes = splatPhotoFixture(file);
      final layout = walkJpeg(bytes);
      expect(isScenePhotoCandidate(name), isFalse);
      expect(sceneXmpOfHead(bytes), isNull);
      expect(holdsImmuch360Xmp(bytes), isTrue);
      // Our packet of a kind release 40 does not know, FormatVersion 1: not a 3D photo of a newer version
      final stereo = StereoPhotoXmp.findIn(bytes);
      expect(stereo, isNotNull);
      expect(stereo!.kind, isNull);
      expect(stereo.isNewerFormat, isFalse);
      expect(decideStereoPhoto(name: name, width: layout.width, height: layout.height, xmp: stereo), isNull);
      expect(ImmersiveXmp.findIn(bytes), isA<StereoPhotoXmp>());
      // A 3:2 frame and no word of theirs: the flat 3D rules do not read it
      expect(isStereoPhotoCandidate(name: name, width: layout.width, height: layout.height), isFalse);
      expect(guessFlatStereoFormat(fileName: name, width: layout.width, height: layout.height), isNull);
    });
  }

  test('why FormatVersion stays 1: release 40 takes a FormatVersion 2 of an unknown kind for a 3D photo', () {
    final bytes = splatPhotoFixture('newer_format.jpg');
    final layout = walkJpeg(bytes);
    final stereo = StereoPhotoXmp.findIn(bytes)!;
    expect(stereo.isNewerFormat, isTrue);
    expect(
      decideStereoPhoto(name: 'salon_splat.jpg', width: layout.width, height: layout.height, xmp: stereo),
      isNotNull,
    );
  });
}
