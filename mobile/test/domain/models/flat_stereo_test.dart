import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';

import '../../fixtures/asset.stub.dart';

void main() {
  group('guessFlatStereoFormat', () {
    test('reads the words GAV Stereo Studio writes', () {
      expect(guessFlatStereoFormat(fileName: 'beach-da2-SBS.png'), FlatStereoFormat.sbs);
      expect(guessFlatStereoFormat(fileName: 'beach-da2-HSBS.png'), FlatStereoFormat.halfSbs);
      expect(guessFlatStereoFormat(fileName: 'beach-da2-TB.png'), FlatStereoFormat.tb);
      expect(guessFlatStereoFormat(fileName: 'beach-da2-HTB.png'), FlatStereoFormat.halfTb);
      expect(guessFlatStereoFormat(fileName: 'beach-da2-SBS-2.png'), FlatStereoFormat.sbs);
      expect(guessFlatStereoFormat(fileName: 'clip-vdaSmall-SBS.mp4', isVideo: true), FlatStereoFormat.sbs);
    });

    test('reads the words of other players and rippers, in any case', () {
      expect(guessFlatStereoFormat(fileName: 'Movie.3D.Half-SBS.mkv', isVideo: true), FlatStereoFormat.halfSbs);
      expect(guessFlatStereoFormat(fileName: 'movie_LR.mp4', isVideo: true), FlatStereoFormat.sbs);
      expect(guessFlatStereoFormat(fileName: 'movie_3dh.mp4', isVideo: true), FlatStereoFormat.sbs);
      expect(guessFlatStereoFormat(fileName: 'Movie.Half-OU.mkv', isVideo: true), FlatStereoFormat.halfTb);
      expect(guessFlatStereoFormat(fileName: 'movie_hou.mp4', isVideo: true), FlatStereoFormat.halfTb);
      expect(guessFlatStereoFormat(fileName: 'movie OU.mp4', isVideo: true), FlatStereoFormat.tb);
    });

    test('takes the squeezed eyes of a video from its frame', () {
      expect(
        guessFlatStereoFormat(fileName: 'movie_SBS.mp4', width: 1920, height: 1080, isVideo: true),
        FlatStereoFormat.halfSbs,
      );
      expect(
        guessFlatStereoFormat(fileName: 'movie_SBS.mp4', width: 3840, height: 1080, isVideo: true),
        FlatStereoFormat.sbs,
      );
      expect(
        guessFlatStereoFormat(fileName: 'movie_OU.mp4', width: 1920, height: 1080, isVideo: true),
        FlatStereoFormat.halfTb,
      );
      expect(
        guessFlatStereoFormat(fileName: 'movie_OU.mp4', width: 1920, height: 2160, isVideo: true),
        FlatStereoFormat.tb,
      );
    });

    test('keeps the eyes of a photo as they are: two portrait photos side by side are common', () {
      expect(guessFlatStereoFormat(fileName: 'portrait-SBS.png', width: 2160, height: 1920), FlatStereoFormat.sbs);
    });

    test('leaves out regular media, 360° and VR180 media', () {
      for (final name in ['IMG_1234.JPG', 'tablet.jpg', 'lrb.png', 'sbsx.mp4', 'PXL_20240101.mp4', '']) {
        expect(guessFlatStereoFormat(fileName: name), isNull, reason: name);
      }
      for (final name in ['trip_360_SBS.mp4', 'trip-180-sbs.mp4', 'trip_VR180_LR.mp4', 'pano_TB_360.jpg']) {
        expect(guessFlatStereoFormat(fileName: name, isVideo: true), isNull, reason: name);
      }
      expect(guessFlatStereoFormat(fileName: null), isNull);
    });
  });

  group('stackedPhotoFormatOf', () {
    test('puts the photos of two eyes one above the other on the stereo quad, by their name', () {
      expect(stackedPhotoFormatOf('beach-da2-TB.png'), FlatStereoFormat.tb);
      expect(stackedPhotoFormatOf('beach-da2-HTB.png'), FlatStereoFormat.halfTb);
      expect(stackedPhotoFormatOf('street_OU.jpg'), FlatStereoFormat.tb);
      expect(stackedPhotoFormatOf('Street.Half-OU.jpg'), FlatStereoFormat.halfTb);
      expect(stackedPhotoFormatOf('street 3dv.jpg'), FlatStereoFormat.tb);
      expect(stackedPhotoFormatOf('STREET_HOU.JPG'), FlatStereoFormat.halfTb);
    });

    test('leaves the side by side photos to the stereo photo probe, which keeps reading them as before', () {
      // The 3D photo a computer makes keeps its path: our XMP first, then its name, never the flat 3D rule
      const ours = 'salon_3D_LRF_Full_SBS.jpg';
      expect(stackedPhotoFormatOf(ours), isNull);
      expect(
        decideStereoPhoto(name: ours, width: 8000, height: 3000),
        const FlatStereoPhoto(eyes: StereoEyes.full, eyeOrder: EyeOrder.leftRight),
      );
      // The side by side names of the list of the flat 3D rule, through the probe
      for (final (name, width, height, eyes) in [
        ('beach-da2-SBS.png', 3840, 1080, StereoEyes.full),
        ('beach-da2-HSBS.png', 1920, 1080, StereoEyes.half),
        ('trip_LR.jpg', 4000, 1500, StereoEyes.full),
        ('Trip.Half-SBS.jpg', 1920, 1080, StereoEyes.half),
      ]) {
        expect(stackedPhotoFormatOf(name), isNull, reason: name);
        expect(decideStereoPhoto(name: name, width: width, height: height)?.eyes, eyes, reason: name);
      }
    });

    test('leaves out the ordinary photos and the 360° and VR180 names', () {
      for (final name in ['IMG_1234.JPG', 'tablet.jpg', 'pano_TB_360.jpg', 'trip_vr180_ou.jpg', 'Street_SBS_TB.jpg']) {
        expect(stackedPhotoFormatOf(name), isNull, reason: name);
      }
    });
  });

  group('flatStereoVideoFormatOf', () {
    test('reads the name and the frame of a video, never of a photo', () {
      final video = LocalAssetStub.image1.copyWith(
        name: 'movie_SBS.mp4',
        type: AssetType.video,
        width: 1920,
        height: 1080,
      );
      expect(flatStereoVideoFormatOf(video), FlatStereoFormat.halfSbs);
      expect(flatStereoVideoFormatOf(video.copyWith(width: 3840)), FlatStereoFormat.sbs);
      expect(flatStereoVideoFormatOf(video.copyWith(name: 'movie_OU.mp4', height: 2160)), FlatStereoFormat.tb);
      expect(flatStereoVideoFormatOf(video.copyWith(name: 'movie.mp4')), isNull);
      expect(flatStereoVideoFormatOf(video.copyWith(type: AssetType.image, name: 'photo_SBS.jpg')), isNull);
    });
  });

  group('Flat3dRequest', () {
    final contract =
        jsonDecode(File('test/fixtures/ai_immersive/flat3d_contract_v1.json').readAsStringSync())
            as Map<String, dynamic>;
    final cases = (contract['flat3d'] as List).cast<Map<String, dynamic>>();

    test('writes the JSON of the contract for every format', () {
      expect(cases.map((c) => c['format']).toSet(), FlatStereoFormat.values.map((f) => f.wire).toSet());
      for (final c in cases) {
        final format = FlatStereoFormat.fromWire(c['format'])!;

        expect(jsonDecode(Flat3dRequest(format).toJsonString()), c['request'], reason: c['name'] as String);
      }
    });

    test('reads back what it writes', () {
      for (final c in cases) {
        expect(Flat3dRequest.fromJson(c['request']), Flat3dRequest(FlatStereoFormat.fromWire(c['format'])!));
      }
    });

    test('reads nothing of what a reader of version 1 refuses', () {
      for (final request in contract['unknown'] as List) {
        expect(Flat3dRequest.fromJson(request), isNull, reason: jsonEncode(request));
      }
      expect(Flat3dRequest.fromJson(null), isNull);
      expect(Flat3dRequest.fromJson('flat3d'), isNull);
    });

    test('says which formats stack the eyes', () {
      expect(FlatStereoFormat.values.where((f) => f.isStacked), [FlatStereoFormat.tb, FlatStereoFormat.halfTb]);
    });
  });
}
