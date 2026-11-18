import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/creator/conversion_job.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

Map<String, Object?> _fixture(String name) =>
    jsonDecode(File('test/fixtures/video3d/ffprobe_$name.json').readAsStringSync()) as Map<String, Object?>;

/// The phone file with its first stream changed by [change]
Map<String, Object?> _phone(void Function(Map<String, Object?> video) change, {List<Map<String, Object?>>? more}) {
  final json = _fixture('phone_src');
  final streams = (json['streams']! as List).cast<Map<String, Object?>>();
  change(streams.first);
  if (more != null) {
    streams.addAll(more);
  }
  return json;
}

VideoSourceCheck _check(Map<String, Object?> json, {String name = 'IMG_1234.MOV', SphericalProbe? spherical}) =>
    checkVideoSource(VideoSource.fromFfprobe(json), fileName: name, spherical: spherical);

void main() {
  group('a synthetic phone file (portrait, HEVC 10 bit HLG, variable rate, turned by its display matrix)', () {
    final source = VideoSource.fromFfprobe(_fixture('phone_src'))!;

    test('reads its stream, its rotation and its colours', () {
      expect(source.codec, 'hevc');
      expect((source.codedWidth, source.codedHeight), (1920, 1080));
      expect(source.quarterTurn, 90);
      expect((source.displayWidth, source.displayHeight), (1080, 1920));
      // Its sample aspect of 1215:1216 is the rounding of the scale that made it: square
      expect(source.isPortrait, isTrue);
      expect(source.bitDepth, 10);
      expect(source.transfer, VideoTransfer.hlg);
      expect(source.colourTagged, isTrue);
      expect(source.frameCount, 102);
      expect(source.rFrameRate, const VideoRate(30, 1));
      expect(source.formatTags['make'], 'Apple');
      expect(source.formatTags['location'], '+48.8584+002.2945/');
    });

    test('is accepted, with the lines of HDR, 10 bit and variable rate, on a grid of 30', () {
      final check = checkVideoSource(source, fileName: 'IMG_1234.MOV');
      expect(check.skip, isNull);
      expect(check.notes, {VideoPlanNote.hdrToneMapped, VideoPlanNote.deepColour, VideoPlanNote.variableRate});
      expect(check.grid!.rate, const VideoRate(30, 1));
      expect(check.grid!.slowMotion, isFalse);
    });

    test('makes portrait eyes of 1080 x 1920 and a model input of 392 x 700', () {
      final eye = videoEyeSize(source);
      expect((eye.width, eye.height), (1080, 1920));
      final model = videoModelSize(eye.width, eye.height, VideoDepthQuality.standard);
      expect((model.width, model.height), (392, 700));
    });
  });

  group('the CC0 clips of the study', () {
    test('ped (VP8 WebM, avg_frame_rate 1000/1, no frame count but the packets) keeps r_frame_rate 25', () {
      final check = _check(_fixture('pedestrian_area'), name: 'pedestrian_area.webm');
      expect(check.skip, isNull);
      expect(check.grid!.rate, const VideoRate(25, 1));
      expect(check.notes, isEmpty);
      final eye = videoEyeSize(check.source!);
      expect((eye.width, eye.height), (1920, 1080));
      for (final (quality, size) in [
        (VideoDepthQuality.fast, (504, 280)),
        (VideoDepthQuality.standard, (700, 392)),
        (VideoDepthQuality.fine, (924, 518)),
      ]) {
        final model = videoModelSize(eye.width, eye.height, quality);
        expect((model.width, model.height), size, reason: quality.name);
        expect(model.width % 14 + model.height % 14, 0);
      }
    });

    test('ber (Theora in Ogg, avg_frame_rate 0/0) keeps 30000/1001', () {
      final check = _check(_fixture('berbera_morning'), name: 'berbera_morning.ogv');
      expect(check.skip, isNull);
      expect(check.grid!.rate, const VideoRate(30000, 1001));
    });

    test('a 3D video the probe made is refused as already 3D, by its st3d side data and by its name', () {
      expect(_check(_fixture('phone_3D_LRF_Full_SBS'), name: 'phone.mp4').skip, ConversionSkipReason.alreadyStereo);
      expect(_check(_fixture('phone_src'), name: 'phone_3D_LRF_Full_SBS.mp4').skip, ConversionSkipReason.alreadyStereo);
    });
  });

  group('refusals', () {
    test('no video stream, or only an attached picture, is unreadable', () {
      expect(checkVideoSource(null, fileName: 'x.mp4').skip, ConversionSkipReason.unreadableVideo);
      final cover = _phone((video) => video['disposition'] = {'attached_pic': 1});
      expect(_check(cover).skip, ConversionSkipReason.unreadableVideo);
    });

    test('interlaced fields', () {
      for (final order in ['tt', 'bb', 'tb', 'bt']) {
        expect(_check(_phone((video) => video['field_order'] = order)).skip, ConversionSkipReason.interlaced);
      }
      expect(_check(_phone((video) => video['field_order'] = 'progressive')).skip, isNull);
      expect(_check(_phone((video) => video.remove('field_order'))).skip, isNull);
    });

    test('Dolby Vision 5 is refused, 8.1 and 8.4 go through their base layer', () {
      Map<String, Object?> dolby(int profile, int compatibility, String transfer) => _phone((video) {
        video['color_transfer'] = transfer;
        (video['side_data_list']! as List).add({
          'side_data_type': 'DOVI configuration record',
          'dv_version_major': 1,
          'dv_profile': profile,
          'dv_level': 6,
          'rpu_present_flag': 1,
          'el_present_flag': 0,
          'bl_present_flag': 1,
          'dv_bl_signal_compatibility_id': compatibility,
        });
      });
      expect(_check(dolby(5, 0, 'unknown')).skip, ConversionSkipReason.dolbyVisionProfile5);
      final hdr10 = _check(dolby(8, 1, 'smpte2084'));
      expect(hdr10.skip, isNull);
      expect(hdr10.notes, containsAll([VideoPlanNote.hdrToneMapped, VideoPlanNote.dolbyVisionBaseLayer]));
      expect(hdr10.source!.transfer, VideoTransfer.pq);
      final hlg = _check(dolby(8, 4, 'arib-std-b67'));
      expect(hlg.skip, isNull);
      expect(hlg.source!.transfer, VideoTransfer.hlg);
    });

    test('a rotation that is not a quarter turn', () {
      Map<String, Object?> turned(num degrees) =>
          _phone((video) => (video['side_data_list']! as List).first['rotation'] = degrees);
      expect(_check(turned(45)).skip, ConversionSkipReason.oddRotation);
      for (final degrees in [0, 90, -90, 180, -180, 270]) {
        expect(_check(turned(degrees)).skip, isNull, reason: '$degrees');
      }
      expect(VideoSource.fromFfprobe(turned(-90))!.isPortrait, isTrue);
      expect(VideoSource.fromFfprobe(turned(180))!.isPortrait, isFalse);
    });

    test('360° and VR180 videos, by their side data, the app\'s probe or their name', () {
      final sphere = _phone(
        (video) => (video['side_data_list']! as List).add({
          'side_data_type': 'Spherical Mapping',
          'projection': 'equirectangular',
        }),
      );
      expect(_check(sphere).skip, ConversionSkipReason.sphere360);
      final half = _phone(
        (video) => (video['side_data_list']! as List).add({
          'side_data_type': 'Spherical Mapping',
          'projection': 'equirectangular',
          'bound_left': 1073741823,
          'bound_right': 1073741823,
        }),
      );
      expect(_check(half).skip, ConversionSkipReason.vr180);
      expect(
        _check(_fixture('phone_src'), spherical: const SphericalProbe(hasSphericalMetadata: true)).skip,
        ConversionSkipReason.sphere360,
      );
      expect(
        _check(
          _fixture('phone_src'),
          spherical: const SphericalProbe(hasSphericalMetadata: true, halfSphere: true),
        ).skip,
        ConversionSkipReason.vr180,
      );
      expect(_check(_fixture('phone_src'), name: 'GS010012_360.mp4').skip, ConversionSkipReason.sphere360);
      expect(_check(_fixture('phone_src'), name: 'trip_VR180.mp4').skip, ConversionSkipReason.vr180);
    });

    test('already 3D by the app\'s st3d probe or by the frame of two eyes', () {
      expect(
        _check(_fixture('phone_src'), spherical: const SphericalProbe(stereo: StereoLayout.leftRight)).skip,
        ConversionSkipReason.alreadyStereo,
      );
      final wide = _phone((video) {
        video['width'] = 3840;
        video['height'] = 1080;
        video['side_data_list'] = <Object?>[];
        video['sample_aspect_ratio'] = '1:1';
      });
      expect(_check(wide).skip, ConversionSkipReason.alreadyStereo);
    });
  });

  group('plan lines', () {
    test('slow motion at 240 fps is made 30 fps, without the variable rate line', () {
      final slow = _phone((video) {
        video['r_frame_rate'] = '240/1';
        video['avg_frame_rate'] = '240/1';
        video['nb_frames'] = '960';
      });
      final check = _check(slow);
      expect(check.grid, (rate: const VideoRate(30, 1), slowMotion: true));
      expect(check.notes, contains(VideoPlanNote.slowMotion));
      expect(check.notes, isNot(contains(VideoPlanNote.variableRate)));
    });

    test('three audio tracks, subtitles, data tracks and a cover', () {
      final busy = _phone(
        (video) {},
        more: [
          {'index': 1, 'codec_type': 'audio', 'codec_name': 'aac', 'channels': 2},
          {
            'index': 2,
            'codec_type': 'audio',
            'codec_name': 'ac3',
            'channels': 6,
            'tags': {'language': 'fra'},
          },
          {'index': 3, 'codec_type': 'audio', 'codec_name': 'pcm_s16le', 'channels': 2},
          {'index': 4, 'codec_type': 'subtitle', 'codec_name': 'mov_text'},
          {'index': 5, 'codec_type': 'data', 'codec_name': 'bin_data'},
          {
            'index': 6,
            'codec_type': 'video',
            'codec_name': 'mjpeg',
            'width': 320,
            'height': 240,
            'disposition': {'attached_pic': 1},
          },
        ],
      );
      final check = _check(busy);
      expect(
        check.notes,
        containsAll([VideoPlanNote.allAudioKept, VideoPlanNote.subtitlesNotKept, VideoPlanNote.dataNotKept]),
      );
      final audio = check.source!.audio;
      expect(audio.map((track) => (track.codec, track.isCopied)), [('aac', true), ('ac3', true), ('pcm_s16le', false)]);
      expect(audio[1].language, 'fra');
      expect(audio[1].aacBitRate, 384000);
      expect(audio[2].aacBitRate, 192000);
      expect(check.source!.videoOrdinal, 0);
      expect(check.source!.attachedPictureCount, 1);
    });

    test('a video over 20 minutes gets the line of a night or more', () {
      final long = _phone((video) {
        video['duration'] = '1500.0';
        video['nb_frames'] = '45000';
      });
      expect(_check(long).notes, contains(VideoPlanNote.long));
      expect(_check(_fixture('phone_src')).notes, isNot(contains(VideoPlanNote.long)));
    });
  });

  group('the grid of the output', () {
    VideoSource source({String? r, String? avg, String? frames, String? duration}) => VideoSource(
      streamIndex: 0,
      videoOrdinal: 0,
      codec: 'vp8',
      codedWidth: 1920,
      codedHeight: 1080,
      rFrameRate: VideoRate.parse(r),
      avgFrameRate: VideoRate.parse(avg),
      frameCount: frames == null ? null : int.parse(frames),
      duration: duration == null ? null : double.parse(duration),
    );

    test('an r_frame_rate of 1000 that the frame count denies gives way to the measured rate, rounded', () {
      expect(videoGridOf(source(r: '1000/1', frames: '396', duration: '15.84'))!.rate, const VideoRate(25, 1));
      expect(videoGridOf(source(r: '1000/1', frames: '1319', duration: '44.01'))!.rate, const VideoRate(30000, 1001));
      // Nothing standard within 6 %: the measured rate itself
      expect(videoGridOf(source(r: '1000/1', frames: '400', duration: '10'))!.rate, const VideoRate(40000, 1000));
    });

    test('a missing r_frame_rate takes a sane average, else nothing', () {
      expect(videoGridOf(source(avg: '24000/1001'))!.rate, const VideoRate(24000, 1001));
      expect(videoGridOf(source(avg: '1000/1')), isNull);
      expect(videoGridOf(source()), isNull);
    });

    test('variable rate: the average off r_frame_rate by more than 2 %, a bogus average ignored', () {
      expect(isVariableRate(source(r: '30/1', avg: '1530/59')), isTrue);
      expect(isVariableRate(source(r: '30/1', avg: '30/1')), isFalse);
      expect(isVariableRate(source(r: '25/1', avg: '1000/1')), isFalse);
    });
  });

  test('bit depths of the pixel formats', () {
    expect(bitDepthOf('yuv420p'), 8);
    expect(bitDepthOf('yuv420p10le'), 10);
    expect(bitDepthOf('yuv422p12be'), 12);
    expect(bitDepthOf('p010le'), 10);
    expect(bitDepthOf(null, 10), 10);
  });

  test('the output names say Full or Half SBS', () {
    expect(videoOutputName('/a/IMG_1234.MOV', VideoSbsPacking.full), 'IMG_1234_3D_LRF_Full_SBS.mp4');
    expect(videoOutputName('clip.v2.webm', VideoSbsPacking.half), 'clip.v2_3D_LRF_Half_SBS.mp4');
  });

  test('the job memory counts the pass and 0.5 GB', () {
    const gib = 1024 * 1024 * 1024;
    expect(VideoDepthQuality.fast.jobMemoryBytes, closeTo(2.4 * gib, 1));
    expect(VideoDepthQuality.standard.jobMemoryBytes, closeTo(3.9 * gib, 1));
    expect(VideoDepthQuality.fine.jobMemoryBytes, closeTo(7.9 * gib, 1));
  });
}
