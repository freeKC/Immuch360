import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/flat_stereo.dart';

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
}
