import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';
import 'package:immich_mobile/domain/services/local_panorama.service.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart';

import '../../desktop/ai/fakes/fake_immersive_engine.dart';
import '../../test_utils/heif_builder.dart';
import 'stereo_photo_fixtures.dart';

/// What [probeStereoPhoto] says of [file] named [name], and the reads it made
Future<(FlatStereoPhoto?, List<(int, int)>)> probe(Uint8List file, String name, {int? width, int? height}) async {
  final reader = RecordingReader(file);
  final found = await probeStereoPhoto(reader.call, name: name, width: width, height: height);
  return (found, reader.reads);
}

void main() {
  final contract =
      jsonDecode(File('test/fixtures/ai_immersive/stereo_pair_contract_v1.json').readAsStringSync()) as Map;

  group('candidates', () {
    test('a name that marks two eyes side by side: ours, those of iw3, the words of the Spatial 2.5D player', () {
      for (final name in [
        'salon_3D_LRF_Full_SBS.jpg',
        'photo_LRF_Full_SBS.png',
        'photo_LR.png',
        'photo_RLF_cross.png',
        'scene_rl.jpg',
        'Trip 3D-SBS.jpg',
        'holiday.hsbs.webp',
      ]) {
        expect(isStereoPhotoCandidate(name: name), isTrue, reason: name);
      }
    });

    test('a frame of two landscape or square eyes side by side', () {
      expect(isStereoPhotoCandidate(name: 'holiday.jpg', width: 8000, height: 3000), isTrue);
      expect(isStereoPhotoCandidate(name: 'holiday.jpg', width: 4400, height: 2000), isTrue);
      expect(isStereoPhotoCandidate(name: 'holiday.jpg', width: 8000, height: 2000), isTrue);
      expect(isStereoPhotoCandidate(name: 'holiday.jpg', width: 8000, height: 4000), isTrue);
      expect(isStereoPhotoCandidate(name: 'holiday.jpg', width: 4060, height: 2000), isTrue, reason: '2:1 within 2 %');
    });

    test('an ordinary photo is no candidate', () {
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg', width: 4000, height: 3000), isFalse);
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg', width: 3000, height: 4000), isFalse);
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg', width: 3000, height: 3000), isFalse);
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg', width: 4100, height: 2000), isFalse, reason: '2.05:1');
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg', width: 9000, height: 2000), isFalse, reason: '4.5:1');
      expect(isStereoPhotoCandidate(name: 'IMG_0001.jpg'), isFalse, reason: 'frame unknown');
      expect(isStereoPhotoCandidate(name: 'DSLR_0001.jpg', width: 6000, height: 4000), isFalse);
      expect(isStereoPhotoCandidate(name: 'clip_tb.jpg', width: 1920, height: 2160), isFalse, reason: 'top and bottom');
    });
  });

  group('our XMP decides', () {
    test('full width eyes, left eye first: the request of the contract', () async {
      final file = jpegFile(width: 8000, height: 3000, xmp: ourXmp());
      final (found, _) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found?.eyes, StereoEyes.full);
      expect(found?.eyeOrder, EyeOrder.leftRight);
      expect(found?.isOurs, isTrue);
      expect(found?.isEstimatedRelief, isTrue);
      expect(found?.canShowIn3d, isTrue);
      expect(found?.xmp, ourXmp());
      final ours = (contract['sbsPhoto'] as List).firstWhere((entry) => entry['name'] == 'ours');
      expect(found?.request?.toJson(), ours['request']);
    });

    test('half width eyes, as the XMP says, whatever the frame', () async {
      final file = jpegFile(width: 4000, height: 3000, xmp: ourXmp(eyes: StereoEyes.half));
      final (found, _) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found?.eyes, StereoEyes.half);
      expect(found?.request?.eyes, StereoEyes.half);
    });

    test('the right eye first, as the XMP says', () async {
      final file = jpegFile(width: 8000, height: 3000, xmp: ourXmp(eyeOrder: EyeOrder.rightLeft));
      final (found, _) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found?.eyeOrder, EyeOrder.rightLeft);
    });

    test('a file of ours renamed without the words is still ours', () async {
      final (found, _) = await probe(
        jpegFile(width: 8000, height: 3000, xmp: ourXmp()),
        'holiday.jpg',
        width: 8000,
        height: 3000,
      );

      expect(found?.isOurs, isTrue);
      expect(found?.eyes, StereoEyes.full);
    });

    test('trip_180_3D_LRF_Full_SBS.jpg of two square eyes is read side by side, not as VR180', () async {
      final file = jpegFile(width: 6000, height: 3000, xmp: ourXmp(eyeWidth: 3000, sourceName: 'trip_180.jpg'));
      final (found, _) = await probe(file, 'trip_180_3D_LRF_Full_SBS.jpg', width: 6000, height: 3000);

      expect(found?.isOurs, isTrue);
      expect(found?.eyes, StereoEyes.full);
      expect(found?.eyeOrder, EyeOrder.leftRight);
    });

    test('the side by side photo of a square drone photo (2:1) is two eyes', () async {
      final file = jpegFile(
        width: 8000,
        height: 4000,
        xmp: ourXmp(eyeWidth: 4000, eyeHeight: 4000, sourceName: 'DJI_0001.JPG'),
      );
      final (found, _) = await probe(file, 'DJI_0001_3D_LRF_Full_SBS.jpg', width: 8000, height: 4000);

      expect(found?.isOurs, isTrue);
      expect(found?.eyes, StereoEyes.full);
    });

    test('nor does the 360° scan of the device make it a sphere: no GPano, no camera in its EXIF', () async {
      final file = jpegFile(
        width: 8000,
        height: 4000,
        xmp: ourXmp(eyeWidth: 4000, eyeHeight: 4000, sourceName: 'DJI_0001.JPG'),
      );
      const name = 'DJI_0001_3D_LRF_Full_SBS.jpg';
      expect(isEquirectCameraPhoto(name: name, width: 8000, height: 4000), isFalse);

      final scanned = await probeLocalPanoramaPhoto(
        RecordingReader(file).call,
        file.length,
        name: name,
        width: 8000,
        height: 4000,
      );
      expect(scanned.isPanorama, isFalse);
    });

    test('a FormatVersion 2 file is shown flat, made by a newer version', () async {
      final file = jpegFile(width: 8000, height: 3000, xmp: ourXmp(formatVersion: 2));
      final (found, _) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found, isNotNull);
      expect(found!.isOurs, isTrue);
      expect(found.isNewerFormat, isTrue);
      expect(found.canShowIn3d, isFalse);
      expect(found.request, isNull);
    });

    test('a kind this build does not know: flat, made by a newer version when the format is newer', () async {
      final unknown = ourXmp(formatVersion: 2).toXml().replaceFirst('Kind="StereoPhoto"', 'Kind="StereoVideo"');
      final (newer, _) = await probe(
        jpegFile(width: 8000, height: 3000, xmpText: unknown),
        'salon_3D_LRF_Full_SBS.jpg',
      );
      expect(newer?.isNewerFormat, isTrue);
      expect(newer?.request, isNull);

      final reserved = ourXmp().toXml().replaceFirst('Kind="StereoPhoto"', 'Kind="Panorama360"');
      final (panorama, _) = await probe(
        jpegFile(width: 8000, height: 3000, xmpText: reserved),
        'salon_3D_LRF_Full_SBS.jpg',
      );
      expect(panorama, isNull, reason: 'another kind of ours, whatever the name');
    });

    test('our XMP comes before the GPano tags', () async {
      final file = jpegFile(width: 8000, height: 4000, xmp: ourXmp(), segments: [gpanoSegment()]);
      final (found, _) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found?.isOurs, isTrue);
    });

    test('the file the fake engine of the computers writes', () async {
      final xmp = StereoPhotoXmp.estimated(
        eyeWidth: 8,
        eyeHeight: 6,
        depthModelSha256: depthModelOnnxSha256,
        sourceName: 'salon.jpg',
        sourceSize: 4182311,
        sourceSha1: 'X8tYgvibyzHDDN2yXGU/ft1XxeM=',
        sourceQuarterTurns: 0,
        created: '2026-10-27T10:12:00+01:00',
        creatorTool: 'Immuch360 Desktop 3.3.0 (linux)',
      );
      final file = fakeSbsJpeg(xmp: xmp);
      expect(frameOfHead(file), (width: 16, height: 6));

      final (found, reads) = await probe(file, sbsFileNameFor('salon.jpg'), width: 16, height: 6);
      expect(found?.xmp, xmp);
      expect(found?.request?.toJson(), {
        'kind': 'sbsPhoto',
        'version': 1,
        'layout': 'leftRight',
        'eyes': 'full',
        'origin': 'estimatedDepth',
        'leftEye': 'original',
      });
      expect(reads, hasLength(1));
    });
  });

  group('another tool, by its name and its frame', () {
    test('iw3, full width (_LRF_Full_SBS)', () async {
      final (found, _) = await probe(pngFile(width: 8064, height: 3024), 'photo_LRF_Full_SBS.png');

      expect(found, const FlatStereoPhoto(eyes: StereoEyes.full));
      expect(found?.isOurs, isFalse);
      expect(found?.isEstimatedRelief, isFalse);
      expect(found?.request?.toJson(), {
        'kind': 'sbsPhoto',
        'version': 1,
        'layout': 'leftRight',
        'eyes': 'full',
        'origin': 'unknown',
        'leftEye': 'unknown',
      });
    });

    test('iw3, full width eyes of a portrait or a square photo: the name tells the width', () async {
      final (portrait, _) = await probe(pngFile(width: 6048, height: 4032), 'portrait_LRF_Full_SBS.png');
      expect(portrait?.eyes, StereoEyes.full);

      final (square, _) = await probe(pngFile(width: 8000, height: 4000), 'DJI_0001_LRF_Full_SBS.png');
      expect(square?.eyes, StereoEyes.full);
    });

    test('full and half tell the width next to sbs only, not as words of a title', () async {
      // "Full HD": the frame of a video still, two half width eyes
      final (fullHd, _) = await probe(jpegFile(width: 1920, height: 1080), 'Avatar Full HD SBS.jpg');
      expect(fullHd, const FlatStereoPhoto(eyes: StereoEyes.half));
      // "Half Dome": a Full SBS of 3.56:1, which a half width reading would refuse as too wide
      final (halfDome, _) = await probe(jpegFile(width: 7120, height: 2000), 'Half Dome_sbs.jpg');
      expect(halfDome, const FlatStereoPhoto(eyes: StereoEyes.full));
      // Next to sbs, before or after it, they do
      final (fullSbs, _) = await probe(jpegFile(width: 3000, height: 2000), 'clip_Full-SBS.jpg');
      expect(fullSbs, const FlatStereoPhoto(eyes: StereoEyes.full));
      final (sbsHalf, _) = await probe(jpegFile(width: 3000, height: 2000), 'clip_SBS_Half.jpg');
      expect(sbsHalf, const FlatStereoPhoto(eyes: StereoEyes.half));
    });

    test('iw3, half width (_LR)', () async {
      final (found, _) = await probe(pngFile(width: 4032, height: 3024), 'photo_LR.png');

      expect(found, const FlatStereoPhoto(eyes: StereoEyes.half));
    });

    test('iw3, crossed eyes (_RLF_cross): the right eye first', () async {
      final (found, _) = await probe(pngFile(width: 8064, height: 3024), 'photo_RLF_cross.png');

      expect(found, const FlatStereoPhoto(eyes: StereoEyes.full, eyeOrder: EyeOrder.rightLeft));
    });

    test('iw3, VR180 (_180x180_LR): two halves of a sphere, left to the 360° viewers', () async {
      final (found, reads) = await probe(pngFile(width: 8000, height: 4000), 'trip_180x180_LR.png');

      expect(found, isNull);
      expect(reads, hasLength(1), reason: 'a candidate by its name');
    });

    test('rl: the right eye first, the width from the frame', () async {
      final (full, _) = await probe(jpegFile(width: 7680, height: 2160), 'scene_rl.jpg');
      expect(full, const FlatStereoPhoto(eyes: StereoEyes.full, eyeOrder: EyeOrder.rightLeft));

      final (half, _) = await probe(jpegFile(width: 1920, height: 1080), 'scene_rl.jpg');
      expect(half, const FlatStereoPhoto(eyes: StereoEyes.half, eyeOrder: EyeOrder.rightLeft));
    });

    test('a name that says full width is trusted for wide eyes too: a 21:9 photo, a 3:1 panorama', () async {
      final (wide, _) = await probe(pngFile(width: 8000, height: 1714), 'photo_LRF_Full_SBS.png');
      expect(wide, const FlatStereoPhoto(eyes: StereoEyes.full));

      final (panorama, _) = await probe(pngFile(width: 12000, height: 2000), 'pano_LRF_Full_SBS.png');
      expect(panorama, const FlatStereoPhoto(eyes: StereoEyes.full));

      // Not when the width comes from the frame: 5:1 makes two half width eyes, too wide
      final (guessed, _) = await probe(jpegFile(width: 10000, height: 2000), 'view_sbs.jpg');
      expect(guessed, isNull);
    });

    test('a frame that holds no two photos is flat, whatever the name', () async {
      final (tooWide, _) = await probe(jpegFile(width: 6000, height: 1000), 'view_hsbs.jpg');
      expect(tooWide, isNull);

      final (tooTall, _) = await probe(jpegFile(width: 1000, height: 3000), 'view_sbs.jpg');
      expect(tooTall, isNull);
    });

    test('a flat 3:1 panorama stays flat: the frame alone never decides', () async {
      final (found, reads) = await probe(
        jpegFile(width: 6000, height: 2000),
        'PANO_0001.jpg',
        width: 6000,
        height: 2000,
      );

      expect(found, isNull);
      expect(reads, hasLength(1), reason: 'a candidate by its frame, read for our XMP');
    });

    test('a 360° photo stays a 360° photo, whatever its name', () async {
      final file = jpegFile(width: 8000, height: 4000, segments: [gpanoSegment()]);
      final (found, _) = await probe(file, 'street_sbs.jpg');

      expect(found, isNull);
    });

    test('top and bottom names are no side by side photo', () async {
      expect(decideStereoPhoto(name: 'clip_tb.jpg', width: 1920, height: 2160), isNull);
      expect(decideStereoPhoto(name: 'clip_ou.jpg', width: 3840, height: 2160), isNull);
    });

    test('a frame that cannot be read leaves the photo flat', () async {
      final (found, _) = await probe(Uint8List.fromList(List.filled(2048, 0)), 'photo_LRF_Full_SBS.heic');

      expect(found, isNull);
    });
  });

  group('reads', () {
    test('an ordinary photo is not read at all', () async {
      final (found, reads) = await probe(
        jpegFile(width: 4000, height: 3000),
        'IMG_0001.jpg',
        width: 4000,
        height: 3000,
      );

      expect(found, isNull);
      expect(reads, isEmpty);
    });

    test('a candidate is read once, in the window of the GPano tags', () async {
      final file = Uint8List.fromList([
        ...jpegFile(width: 8000, height: 3000, xmp: ourXmp()),
        ...List.filled(300 * 1024, 0),
      ]);
      final (found, reads) = await probe(file, 'salon_3D_LRF_Full_SBS.jpg');

      expect(found?.isOurs, isTrue);
      expect(reads, [(0, 131072)]);
    });

    test('the frame of the head beats the size given', () async {
      final (found, _) = await probe(jpegFile(width: 8000, height: 3000), 'photo_sbs.jpg', width: 3000, height: 8000);

      expect(found?.eyes, StereoEyes.full);
    });
  });

  group('frameOfHead', () {
    test('JPEG, baseline and progressive, after other segments', () {
      expect(frameOfHead(jpegFile(width: 8064, height: 3024, xmp: ourXmp())), (width: 8064, height: 3024));
      final progressive = jpegFile(width: 640, height: 480);
      progressive[3] = 0xc2;
      expect(frameOfHead(progressive), (width: 640, height: 480));
    });

    test('JPEG whose Huffman tables come before the frame, as some encoders write it', () {
      // A DHT segment (FF C4) is no frame, though its marker sits among those of the frames
      final dht = Uint8List.fromList([0xff, 0xc4, 0x00, 0x0b, 0x10, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]);
      expect(frameOfHead(jpegFile(width: 640, height: 480, segments: [dht])), (width: 640, height: 480));
    });

    test('PNG', () {
      expect(frameOfHead(pngFile(width: 100000, height: 3)), (width: 100000, height: 3));
    });

    test('WebP, extended, lossy and lossless', () {
      Uint8List webp(String chunk, List<int> payload) => Uint8List.fromList([
        ...ascii.encode('RIFF'),
        0,
        0,
        0,
        0,
        ...ascii.encode('WEBP'),
        ...ascii.encode(chunk),
        0,
        0,
        0,
        0,
        ...payload,
      ]);
      // Canvas 8064 x 3024, less one, on 24 bits each, after 4 bytes of flags
      final extended = webp('VP8X', [0, 0, 0, 0, 0x7f, 0x1f, 0x00, 0xcf, 0x0b, 0x00]);
      expect(frameOfHead(extended), (width: 8064, height: 3024));
      // Frame tag, start code, then 8064 and 3024 on 14 bits
      final lossy = webp('VP8 ', [0, 0, 0, 0x9d, 0x01, 0x2a, 0x80, 0x1f, 0xd0, 0x0b]);
      expect(frameOfHead(lossy), (width: 8064, height: 3024));
      // Signature, then 8063 and 3023 packed on 14 bits each
      const bits = 8063 | 3023 << 14;
      final lossless = webp('VP8L', [0x2f, bits & 0xff, bits >> 8 & 0xff, bits >> 16 & 0xff, bits >> 24 & 0xff]);
      expect(frameOfHead(lossless), (width: 8064, height: 3024));
    });

    test('anything else', () {
      expect(frameOfHead(Uint8List(0)), isNull);
      expect(frameOfHead(Uint8List.fromList([0xff, 0xd8, 0xff, 0xda, 0, 0])), isNull);
      expect(frameOfHead(Uint8List.fromList(List.filled(64, 7))), isNull);
    });
  });

  test('holdsImmuch360Xmp', () {
    expect(holdsImmuch360Xmp(jpegFile(width: 8, height: 6, xmp: ourXmp())), isTrue);
    expect(holdsImmuch360Xmp(jpegFile(width: 8, height: 6)), isFalse);
    expect(holdsImmuch360Xmp(Uint8List.fromList(utf8.encode('http://ns.aprogsys.com/immuch360/1.'))), isFalse);
  });
}
