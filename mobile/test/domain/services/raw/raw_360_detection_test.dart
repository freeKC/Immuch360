import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/sphere_coverage.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../fixtures/raw/insta360.stub.dart';

ByteRangeReader _reader(Uint8List file, [List<(int, int)>? reads]) => (offset, length) async {
  reads?.add((offset, length));
  final start = math.min(offset, file.length);
  return Uint8List.sublistView(file, start, math.min(file.length, start + length));
};

void main() {
  group('names', () {
    test('an Insta360 photo is .insp, a raw video .insv, .360 or .osv, whatever the case', () {
      expect(isRawPhotoName('IMG_20240908_133036_00_001.insp'), isTrue);
      expect(isRawPhotoName('IMG_001.INSP'), isTrue);
      expect(isRawPhotoName('IMG_001.insp.jpg'), isFalse);
      expect(isRawVideoName('VID_20240908_133036_00_002.insv'), isTrue);
      expect(isRawVideoName('VID_002.INSV'), isTrue);
      expect(isRawVideoName('GS010013.360'), isTrue);
      expect(isRawVideoName('CAM_20250715191201_0003_D.OSV'), isTrue);
      expect(isRawVideoName('LRV_20240908_133036_01_004.lrv'), isFalse);
      expect(isRawVideoName('VID_002.mp4'), isFalse);
      expect(isRawVideoName('GS010013.36P'), isFalse);
    });

    test('rawMediaKindOfName tells the camera by the last extension, and the media must match it', () {
      for (final (name, isVideo, expected) in [
        ('IMG_20240908_133036_00_001.insp', false, RawMediaKind.insta360Photo),
        ('VID_20240908_133036_00_002.INSV', true, RawMediaKind.insta360Video),
        ('GS010013.360', true, RawMediaKind.goProVideo),
        ('CAM_20250715191201_0003_D.OSV', true, RawMediaKind.djiVideo),
        ('LRV_20240908_133036_01_004.lrv', true, null),
        ('GL010013.LRF', true, null),
        ('GS010013.36P', false, null),
        ('VID_002.mp4', true, null),
        ('VID_20240908_133036_00_002.insv.mp4', true, null),
        // A photo named as a video, a video named as a photo
        ('VID_002.insv', false, null),
        ('IMG_001.insp', true, null),
        ('GS010013.360', false, null),
      ]) {
        expect(rawMediaKindOfName(name, isVideo: isVideo), expected, reason: '$name, video $isVideo');
      }
    });

    test('isRaw360FileName takes the four raw extensions', () {
      for (final name in ['IMG_001.insp', 'VID_002.INSV', 'GS010013.360', 'CAM_0003_D.osv']) {
        expect(isRaw360FileName(name), isTrue, reason: name);
      }
      for (final name in ['GS010013.36P', 'LRV_01_004.lrv', 'VID_002.mp4', 'IMG_001.jpg', '360']) {
        expect(isRaw360FileName(name), isFalse, reason: name);
      }
    });
  });

  group('split pairs', () {
    test('splitPairOf gives the lens of a file of a split recording and the name of the other one', () {
      expect(splitPairOf('VID_20240908_193126_00_004.insv'), (lens: 0, siblingName: 'VID_20240908_193126_10_004.insv'));
      expect(splitPairOf('VID_20240908_193126_10_004.insv'), (lens: 1, siblingName: 'VID_20240908_193126_00_004.insv'));
      // The case and a suffix of the copy are kept
      expect(splitPairOf('vid_20240908_193126_10_004(1).INSV'), (
        lens: 1,
        siblingName: 'vid_20240908_193126_00_004(1).INSV',
      ));
    });

    test('splitPairOf gives nothing for the proxies, another extension, or a name without the pattern', () {
      for (final name in [
        'LRV_20240908_193126_01_004.lrv',
        'LRV_20240908_193126_11_004.insv',
        'VID_20240908_193126_00_004.mp4',
        'VID_20240908_193126_004.insv',
        'VID_20240908_193126_20_004.insv',
        'GS010013.360',
        'IMG_20240908_133036_00_001.insp',
      ]) {
        expect(splitPairOf(name), isNull, reason: name);
      }
    });

    test('splitSiblingMismatch accepts the other lens of the same recording, and tells why another file is not', () {
      ProbedTrack video({int width = 2880, String codec = 'hvc1', int? durationMs = 60000}) => ProbedTrack(
        index: 0,
        trackId: 1,
        handlerType: 'vide',
        codec: codec,
        codedWidth: width,
        codedHeight: width,
        durationMs: durationMs,
      );
      SphericalProbe probe(ProbedTrack? track) => SphericalProbe(tracks: [?track]);

      final opened = probe(video());
      expect(splitSiblingMismatch(probe: opened, siblingProbe: probe(video())), isNull);
      // Within 1 second, or 1 percent of a long recording; durations unknown
      expect(splitSiblingMismatch(probe: opened, siblingProbe: probe(video(durationMs: 60900))), isNull);
      expect(
        splitSiblingMismatch(probe: probe(video(durationMs: 600000)), siblingProbe: probe(video(durationMs: 605500))),
        isNull,
      );
      expect(splitSiblingMismatch(probe: opened, siblingProbe: probe(video(durationMs: null))), isNull);
      // The probe of the opened file unknown: the sibling must still be a video
      expect(splitSiblingMismatch(probe: null, siblingProbe: probe(video())), isNull);
      expect(
        splitSiblingMismatch(
          probe: opened,
          siblingProbe: probe(video()),
          groupIdentity: 'A',
          siblingGroupIdentity: 'A',
        ),
        isNull,
      );
      expect(splitSiblingMismatch(probe: opened, siblingProbe: probe(video()), groupIdentity: 'A'), isNull);

      for (final (sibling, groupIdentity, reason) in [
        (null, null, 'no video track'),
        (probe(null), null, 'no video track'),
        (probe(video(width: 1920)), null, '2880 x 2880 and 1920 x 1920'),
        (probe(video(codec: 'avc1')), null, 'hvc1 and avc1'),
        (probe(video(durationMs: 62000)), null, '60000 and 62000'),
        (probe(video()), 'B', 'A and B'),
      ]) {
        expect(
          splitSiblingMismatch(
            probe: opened,
            siblingProbe: sibling,
            groupIdentity: 'A',
            siblingGroupIdentity: groupIdentity,
          ),
          contains(reason),
        );
      }
    });

    test('splitFirstLensName names the _00_ file of a _10_ file only', () {
      expect(splitFirstLensName('VID_20240914_175112_10_027.insv'), 'VID_20240914_175112_00_027.insv');
      expect(splitFirstLensName('VID_20240914_175112_00_027.insv'), isNull);
      expect(splitFirstLensName('VID_20240914_175112_10_027.mp4'), isNull);
    });
  });

  group('isEquirectCameraPhoto', () {
    test('takes a .36p at any size, and a 2:1 JPEG of a known 360 camera', () {
      for (final (name, make, model, width, height, expected) in [
        ('GS010013.36P', null, null, null, null, true),
        ('GS010013.36p', 'GoPro', 'GoPro Max', 4000, 3000, true),
        ('GS010013.JPG', 'GoPro', 'GoPro Max', 5760, 2880, true),
        ('GS010013.JPG', 'GoPro', 'GoPro Max', 4000, 3000, false),
        ('GS010013.JPG', 'GoPro', 'HERO12 Black', 5760, 2880, false),
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', 15520, 7760, true),
        ('DJI_0001.JPG', 'DJI', 'OQ101', 7680, 3840, true),
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', 6400, 4800, false),
        ('DJI_0001.JPG', 'DJI', 'Mavic 3', 8000, 4000, false),
        ('IMG_001.jpg', 'Arashi Vision', 'Insta360 X3', 11968, 5984, true),
        ('IMG_001.jpg', ' arashi vision ', null, 6080, 3040, true),
        ('IMG_001.jpg', 'Canon', 'EOS R5', 8192, 4096, false),
        ('IMG_001.jpg', null, null, 8192, 4096, false),
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', null, 7760, false),
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', null, null, false),
        // Within 1 percent of 2:1
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', 15600, 7760, true),
        ('DJI_0001.JPG', 'DJI', 'Osmo 360', 15800, 7760, false),
        // A raw photo is never one
        ('IMG_001.insp', 'Arashi Vision', 'Insta360 X3', 11968, 5984, false),
      ]) {
        expect(
          isEquirectCameraPhoto(name: name, make: make, model: model, width: width, height: height),
          expected,
          reason: '$name $make $model $width x $height',
        );
      }
    });
  });

  test('isSideBySideFrame tells two squares side by side, null while the frame is unknown', () {
    expect(isSideBySideFrame(5760, 2880), isTrue);
    expect(isSideBySideFrame(1024, 512), isTrue);
    expect(isSideBySideFrame(2880, 2880), isFalse);
    expect(isSideBySideFrame(null, 2880), isNull);
  });

  test('a stitched raw media is one picture over the whole sphere', () {
    expect(raw360SphereView.layout, StereoLayout.mono);
    expect(raw360SphereView.coverage, SphereCoverage.full);
    expect(raw360SphereView.coverageGuess, SphereCoverage.full);
  });

  group('hasInsta360Trailer', () {
    test('finds the trailer of a version 3 file in its last 72 bytes', () async {
      final file = insta360File([insta360Record(1, x3Metadata(), format: 1)], body: List.filled(5000, 0));
      final reads = <(int, int)>[];

      expect(await hasInsta360Trailer(_reader(file, reads), file.length), isTrue);
      expect(reads, [(file.length - 72, 72)]);
    });

    test('refuses another magic, another version, and a file too short', () async {
      final otherMagic = insta360File([], magic: '9c792b1ac55c40418d36ffb0d1d16b58');
      final version2 = insta360File([], version: 2);
      final jpeg = Uint8List.fromList(List.filled(1000, 0));

      expect(await hasInsta360Trailer(_reader(otherMagic), otherMagic.length), isFalse);
      expect(await hasInsta360Trailer(_reader(version2), version2.length), isFalse);
      expect(await hasInsta360Trailer(_reader(jpeg), jpeg.length), isFalse);
      expect(await hasInsta360Trailer(_reader(jpeg), 10), isFalse);
    });
  });
}
