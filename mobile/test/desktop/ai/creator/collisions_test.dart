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
  const salon = OriginalIdentity(name: 'salon.jpg', size: 1234, sha1: 'c2Fsb24uanBn');
  StereoPhotoXmp of({
    String? derivativeId = id,
    String? name = 'salon.jpg',
    int? size = 1234,
    String? sha1 = 'c2Fsb24uanBn',
  }) => StereoPhotoXmp(
    eyes: StereoEyes.full,
    derivativeId: derivativeId,
    sourceName: name,
    sourceSize: size,
    sourceSha1: sha1,
  );
  final ours = withXmp(of());
  final oursWithoutId = withXmp(of(derivativeId: null));
  final oursBlankId = withXmp(of(derivativeId: '  '));
  // salon.heic gives the same name, salon_3D_LRF_Full_SBS.jpg
  final ofTheHeic = withXmp(of(name: 'salon.heic', size: 4321, sha1: 'c2Fsb24uaGVpYw=='));
  // Another original with the same name and size, told by its sum
  final sameNameOtherSum = withXmp(of(sha1: 'b3RoZXI='));
  final withoutSum = withXmp(of(sha1: null));
  final withoutSumOtherSize = withXmp(of(sha1: null, size: 999));
  // An iw3 or SKYBOX file: a side by side JPEG with no XMP of ours
  final another = Uint8List.fromList([0xff, 0xd8, ...utf8.encode('<x:xmpmeta xmlns:x="adobe:ns:meta/"/>'), 0xff, 0xd9]);

  test('the name of a 3D photo, made safe for Windows', () {
    expect(sbsTargetName('salon.jpg'), 'salon_3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('IMG_0001.HEIC'), 'IMG_0001_3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('12:30?.png'), '12_30__3D_LRF_Full_SBS.jpg');
    expect(sbsTargetName('${'x' * 300}.jpg').length, 200);
    expect(sbsTargetName('${'x' * 300}.jpg'), endsWith('.jpg'));
  });

  test('a long name is shortened before the marker, which stays whole', () {
    for (final length in [180, 181, 190, 199, 300]) {
      final name = sbsTargetName('${'x' * length}.jpg');

      expect(name, endsWith('_3D_LRF_Full_SBS.jpg'), reason: '$length characters');
      expect(name.length, lessThanOrEqualTo(200));
    }
    expect(sbsTargetName('${'x' * 179}.jpg'), '${'x' * 179}_3D_LRF_Full_SBS.jpg');
    // Never half of a character outside the basic plane
    final emoji = sbsTargetName('${'x' * 179}\u{1F4F7}\u{1F4F7}.jpg');
    expect(emoji, '${'x' * 179}_3D_LRF_Full_SBS.jpg');
    // A name Windows keeps for a device, made safe, and still whole at the end
    expect(sbsTargetName('con.${'x' * 300}.jpg'), endsWith('_3D_LRF_Full_SBS.jpg'));
    expect(sbsTargetName('con.${'x' * 300}.jpg').length, lessThanOrEqualTo(200));
  });

  test('only our XMP with a DerivativeId, made from the same original, may be replaced', () {
    expect(isReplaceableVersion(ours, original: salon), isTrue);
    expect(isReplaceableVersion(oursWithoutId, original: salon), isFalse);
    expect(isReplaceableVersion(oursBlankId, original: salon), isFalse);
    expect(isReplaceableVersion(another, original: salon), isFalse);
    expect(isReplaceableVersion(Uint8List(0), original: salon), isFalse);
    expect(isReplaceableVersion(ofTheHeic, original: salon), isFalse);
    expect(isReplaceableVersion(sameNameOtherSum, original: salon), isFalse);
  });

  test('without a sum on one side, the same SourceName and SourceSize tell the same original', () {
    expect(isReplaceableVersion(withoutSum, original: salon), isTrue);
    expect(isReplaceableVersion(withoutSumOtherSize, original: salon), isFalse);
    expect(isReplaceableVersion(ours, original: const OriginalIdentity(name: 'salon.jpg', size: 1234)), isTrue);
    expect(isReplaceableVersion(ofTheHeic, original: const OriginalIdentity(name: 'salon.jpg', size: 1234)), isFalse);
  });

  test('a name with a control character still tells the same original, written in the XMP as U+FFFD', () {
    const original = OriginalIdentity(name: 'sa\u0001lon.jpg', size: 1234);

    expect(isReplaceableVersion(withXmp(of(name: 'sa\u0001lon.jpg', sha1: null)), original: original), isTrue);
  });

  test('a free name is always taken as it is', () {
    for (final whenExists in AiWhenExists.values) {
      expect(collisionAction(whenExists: whenExists, taken: false), CollisionAction.newName);
    }
  });

  test('keep both and skip, whatever the file there', () {
    for (final head in [ours, another, null]) {
      expect(
        collisionAction(whenExists: AiWhenExists.keepBoth, taken: true, head: head, original: salon),
        CollisionAction.newName,
      );
      expect(
        collisionAction(whenExists: AiWhenExists.skip, taken: true, head: head, original: salon),
        CollisionAction.skip,
      );
    }
  });

  test('replace takes only one of ours with an id, of the same original, never the original, never unreadable', () {
    CollisionAction replace(Uint8List? head, {bool isOriginal = false, OriginalIdentity? original = salon}) =>
        collisionAction(
          whenExists: AiWhenExists.replace,
          taken: true,
          head: head,
          original: original,
          isOriginal: isOriginal,
        );

    expect(replace(ours), CollisionAction.replace);
    expect(replace(oursWithoutId), CollisionAction.newName);
    expect(replace(another), CollisionAction.newName);
    expect(replace(null), CollisionAction.newName);
    expect(replace(ours, isOriginal: true), CollisionAction.newName);
    expect(replace(ofTheHeic), CollisionAction.newName);
    expect(replace(ours, original: null), CollisionAction.newName);
  });
}
