import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/collisions.dart';
import 'package:immich_mobile/desktop/ai/settings/desktop_ai_settings.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

import '../fakes/fake_immersive_engine.dart';

Uint8List withXmp(StereoPhotoXmp xmp) => fakeSbsJpeg(xmp: xmp);

void main() {
  const id = 'urn:uuid:6f1c2e0a-0000-4000-8000-000000000000';
  final ours = withXmp(const StereoPhotoXmp(eyes: StereoEyes.full, derivativeId: id));
  final oursWithoutId = withXmp(const StereoPhotoXmp(eyes: StereoEyes.full));
  final oursBlankId = withXmp(const StereoPhotoXmp(eyes: StereoEyes.full, derivativeId: '  '));
  // An iw3 or SKYBOX file: a side by side JPEG with no XMP of ours
  final another = Uint8List.fromList([0xff, 0xd8, ...utf8.encode('<x:xmpmeta xmlns:x="adobe:ns:meta/"/>'), 0xff, 0xd9]);

  test('the name of a 3D photo, made safe for Windows', () {
    expect(sbsTargetName('salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('IMG_0001.HEIC'), 'IMG_0001_3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('12:30?.png'), '12_30__3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('${'x' * 300}.jpg').length, 200);
    expect(sbsTargetName('${'x' * 300}.jpg'), endsWith('.jpg'));
  });

  test('only our XMP with a DerivativeId may be replaced', () {
    expect(isReplaceableVersion(ours), isTrue);
    expect(isReplaceableVersion(oursWithoutId), isFalse);
    expect(isReplaceableVersion(oursBlankId), isFalse);
    expect(isReplaceableVersion(another), isFalse);
    expect(isReplaceableVersion(Uint8List(0)), isFalse);
  });

  test('a free name is always taken as it is', () {
    for (final whenExists in AiWhenExists.values) {
      expect(collisionAction(whenExists: whenExists, taken: false), CollisionAction.newName);
    }
  });

  test('keep both and skip, whatever the file there', () {
    for (final head in [ours, another, null]) {
      expect(collisionAction(whenExists: AiWhenExists.keepBoth, taken: true, head: head), CollisionAction.newName);
      expect(collisionAction(whenExists: AiWhenExists.skip, taken: true, head: head), CollisionAction.skip);
    }
  });

  test('replace takes only one of ours with an id, never the original, never an unreadable file', () {
    CollisionAction replace(Uint8List? head, {bool isOriginal = false}) =>
        collisionAction(whenExists: AiWhenExists.replace, taken: true, head: head, isOriginal: isOriginal);

    expect(replace(ours), CollisionAction.replace);
    expect(replace(oursWithoutId), CollisionAction.newName);
    expect(replace(another), CollisionAction.newName);
    expect(replace(null), CollisionAction.newName);
    expect(replace(ours, isOriginal: true), CollisionAction.newName);
  });
}
