import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/ai/video3d/ffmpeg_commands.dart';
import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';

VideoSource _source(String name) => VideoSource.fromFfprobe(
  jsonDecode(File('test/fixtures/video3d/ffprobe_$name.json').readAsStringSync()) as Map<String, Object?>,
)!;

void main() {
  test('the encoders each computer tries, in order', () {
    expect(VideoEncoder.orderFor('windows'), [VideoEncoder.h264MfHardware, VideoEncoder.h264Mf, VideoEncoder.svtAv1]);
    expect(VideoEncoder.orderFor('macos'), [VideoEncoder.h264VideoToolbox, VideoEncoder.svtAv1]);
    expect(VideoEncoder.orderFor('linux'), [
      VideoEncoder.h264VaapiFull,
      VideoEncoder.h264VaapiLowPower,
      VideoEncoder.svtAv1,
    ]);
    expect(VideoEncoder.svtAv1.isAv1, isTrue);
  });

  test('the decoder of the phone file: tone map, portrait eye, passthrough, times, RGB on its output', () {
    final source = _source('phone_src');
    final arguments = videoDecoderArguments(
      path: '/v/IMG.MOV',
      source: source,
      eyeWidth: 1080,
      eyeHeight: 1920,
      slowMotion: false,
      statsPath: '/w/stats-1.txt',
    );
    expect(arguments, containsAllInOrder(['-copyts', '-i', '/v/IMG.MOV', '-map', '0:v:0', '-an', '-sn', '-dn']));
    expect(arguments, containsAllInOrder(['-fps_mode', 'passthrough']));
    expect(arguments, containsAllInOrder(['-stats_enc_pre', '/w/stats-1.txt', '-stats_enc_pre_fmt', '{n} {pts} {tb}']));
    expect(arguments.sublist(arguments.length - 5), ['-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1']);
    expect(arguments, isNot(contains('-ss')));
    expect(arguments[arguments.indexOf('-vf') + 1], '$videoToneMap,scale=1080:1920:flags=area,setsar=1,format=rgb24');
  });

  test('a resumed decoder seeks accurately; slow motion and untagged HD get their filters', () {
    final ped = _source('pedestrian_area');
    final arguments = videoDecoderArguments(
      path: 'ped.webm',
      source: ped,
      eyeWidth: 1920,
      eyeHeight: 1080,
      slowMotion: true,
      statsPath: 's.txt',
      seekSeconds: 1.82,
    );
    expect(arguments, containsAllInOrder(['-copyts', '-ss', '1.820000', '-i', 'ped.webm']));
    expect(
      arguments[arguments.indexOf('-vf') + 1],
      'fps=30,scale=1920:1080:flags=area:in_color_matrix=bt709,setsar=1,format=rgb24',
    );
  });

  test('the options of each encoder, with about 0.15 bit per pixel and frame where a bitrate works', () {
    const rate = VideoRate(30, 1);
    final mf = videoEncoderOptions(VideoEncoder.h264MfHardware, 3840, 1080, rate);
    expect(mf.codec, ['-c:v', 'h264_mf', '-hw_encoding', '1', '-b:v', '18662400']);
    expect(mf.filter, 'scale=out_color_matrix=bt709:out_range=tv,format=nv12');
    final vaapi = videoEncoderOptions(VideoEncoder.h264VaapiFull, 3840, 1080, rate);
    expect(vaapi.device, ['-vaapi_device', '/dev/dri/renderD128']);
    expect(vaapi.filter, endsWith('format=nv12,hwupload'));
    expect(vaapi.codec, ['-c:v', 'h264_vaapi', '-low_power', '0', '-rc_mode', 'CQP', '-qp', '22']);
    expect(videoEncoderOptions(VideoEncoder.h264VaapiLowPower, 64, 64, rate).codec, contains('1'));
    expect(videoEncoderOptions(VideoEncoder.svtAv1, 64, 64, rate).codec, [
      '-c:v',
      'libsvtav1',
      '-preset',
      '10',
      '-crf',
      '30',
      '-svtav1-params',
      'lp=2',
    ]);
    expect(videoEncoderOptions(VideoEncoder.h264VideoToolbox, 64, 64, rate).codec, contains('h264_videotoolbox'));
  });

  test('the one second test and the encoder of a segment', () {
    final probe = videoEncoderTestArguments(VideoEncoder.svtAv1, 3840, 1080, const VideoRate(30000, 1001));
    expect(
      probe,
      containsAllInOrder(['-f', 'lavfi', '-i', 'color=c=gray:s=3840x1080:r=30000/1001', '-frames:v', '30']),
    );
    expect(probe.sublist(probe.length - 3), ['-f', 'null', '-']);
    final segment = videoSegmentArguments(
      encoder: VideoEncoder.h264VaapiFull,
      width: 2160,
      height: 1920,
      rate: const VideoRate(30, 1),
      segmentPath: '/w/seg-0001.seg',
    );
    expect(
      segment,
      containsAllInOrder(['-vaapi_device', '/dev/dri/renderD128', '-f', 'rawvideo', '-pix_fmt', 'rgb24']),
    );
    expect(segment, containsAllInOrder(['-s', '2160x1920', '-framerate', '30/1', '-i', 'pipe:0']));
    expect(segment, containsAllInOrder(['-g', '60', '-colorspace', 'bt709']));
    expect(segment.sublist(segment.length - 5), [
      '-metadata:s:v:0',
      'stereo_mode=left_right',
      '-f',
      'matroska',
      '/w/seg-0001.seg',
    ]);
  });

  test('the final mux: segments, every audio track copied or made AAC, the source\'s tags, our keys', () {
    const audio = [
      VideoAudioTrack(index: 1, codec: 'aac', channels: 2),
      VideoAudioTrack(index: 2, codec: 'vorbis', channels: 2),
      VideoAudioTrack(index: 4, codec: 'pcm_s16le', channels: 6),
    ];
    final arguments = videoMuxArguments(
      concatPath: '/w/segments.txt',
      sourcePath: '/v/clip.webm',
      audio: audio,
      keys: const {'com.immuch360.kind': 'StereoVideo'},
      outputPath: '/v/clip_3D_LRF_Full_SBS.mp4.part',
      videoOffset: 0.5,
    );
    expect(
      arguments,
      containsAllInOrder(['-itsoffset', '0.500000', '-f', 'concat', '-safe', '0', '-i', '/w/segments.txt']),
    );
    expect(arguments, containsAllInOrder(['-map', '0:v', '-map', '1:1', '-map', '1:2', '-map', '1:4']));
    expect(arguments, containsAllInOrder(['-map_metadata', '1', '-map_chapters', '1', '-c:v', 'copy']));
    expect(arguments, containsAllInOrder(['-c:a:0', 'copy', '-c:a:1', 'aac', '-b:a:1', '192000']));
    expect(arguments, containsAllInOrder(['-c:a:2', 'aac', '-b:a:2', '384000']));
    expect(arguments, containsAllInOrder(['-metadata', 'com.immuch360.kind=StereoVideo']));
    expect(arguments, containsAllInOrder(['-strict', 'unofficial', '-movflags', '+faststart+use_metadata_tags']));
    expect(arguments, isNot(contains('-shortest')));
    expect(arguments.last, '/v/clip_3D_LRF_Full_SBS.mp4.part');
    expect(
      videoMuxArguments(concatPath: 'c', sourcePath: 's', audio: const [], keys: const {}, outputPath: 'o'),
      isNot(contains('-itsoffset')),
    );
  });

  test('the concat list quotes each name', () {
    expect(
      videoConcatList(['seg-0001.seg', "it's.seg"]),
      "ffconcat version 1.0\nfile 'seg-0001.seg'\nfile 'it'\\''s.seg'",
    );
  });

  test('the lines of -stats_enc_pre', () {
    expect(parseStatsLine('12 6144 1/15360'), (frame: 12, seconds: 0.4));
    expect(parseStatsLine('0 0 1/25'), (frame: 0, seconds: 0.0));
    expect(parseStatsLine('frame=12'), isNull);
    expect(parseStatsLine(''), isNull);
  });

  test('the grid: a constant rate gives one slot a frame, a gap repeats the frame before it', () {
    const rate = VideoRate(30, 1);
    expect(videoGridRepeats([0, 1 / 30, 2 / 30], rate), [1, 1, 1]);
    // The study's phone clip: one frame in 7 dropped
    final times = [
      for (var i = 0; i < 14; i++)
        if (i % 7 != 6) i / 30,
    ];
    expect(videoGridRepeats(times, rate), [1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1]);
    // Two frames on one slot: the later one shows
    expect(videoGridRepeats([0, 0.01, 1 / 30], rate), [0, 1, 1]);
    expect(videoGridRepeats(const [], rate), isEmpty);
    expect(videoGridSlot(0.5 + 1 / 60, 0.5, rate), 1);
  });
}
