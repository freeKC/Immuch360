// What the 3D videos ask of the FFmpeg program (store/m2/release-49/lots/video3d-plan.md, sections 2.1, 2.4 and 2.5),
// the arguments only, so that the tests read them: the probe, the decoder that gives the eye frames as RGB on its
// standard output with each frame's time, the test of an encoder (the command of a segment), the encoder of a
// segment (Matroska marked left right), and the final mux (the segments joined, the source's audio, tags and chapters,
// our keys, st3d written by FFmpeg). Also the grid of the output: how many slots of the constant rate each decoded
// frame takes, so that a variable rate phone clip keeps its timing with no extra depth work.
//
// Pure Dart, no Flutter, no I/O.

import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:immich_mobile/desktop/ai/video3d/video_source.dart';

/// The tone map of the study (section 4.3), for HLG and PQ sources: linear light, BT.709 primaries, Hable, BT.709
const videoToneMap =
    'zscale=t=linear:npl=203,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv';

/// Bits per pixel and frame an encoder with a bitrate target is given: 18.7 Mbit/s for 3840 x 1080 at 30 fps
const videoBitsPerPixel = 0.15;

/// The encoders, in the order a computer tries them (the first whose test passes)
enum VideoEncoder {
  /// Media Foundation on Windows, the hardware MFT
  h264MfHardware('h264_mf', 'H.264'),

  /// Media Foundation, the software MFT (Windows Server, a computer without a hardware encoder)
  h264Mf('h264_mf', 'H.264'),

  /// VideoToolbox on macOS
  h264VideoToolbox('h264_videotoolbox', 'H.264'),

  /// VA-API on Linux at constant QP, the entry point that works on ai1's Intel driver
  h264VaapiFull('h264_vaapi', 'H.264'),

  /// VA-API, the low power entry point
  h264VaapiLowPower('h264_vaapi', 'H.264'),

  /// SVT-AV1 everywhere: plays on computers and the Quest 3, not on a Quest 2
  svtAv1('libsvtav1', 'AV1');

  const VideoEncoder(this.codec, this.format);

  /// The FFmpeg encoder
  final String codec;

  /// The format of the video it writes
  final String format;

  bool get isAv1 => this == svtAv1;

  bool get isVaapi => this == h264VaapiFull || this == h264VaapiLowPower;

  /// The encoders tried on [os] ('windows', 'macos', 'linux'), in order
  static List<VideoEncoder> orderFor(String os) => switch (os) {
    'windows' => const [h264MfHardware, h264Mf, svtAv1],
    'macos' => const [h264VideoToolbox, svtAv1],
    'linux' => const [h264VaapiFull, h264VaapiLowPower, svtAv1],
    _ => const [svtAv1],
  };

  /// [orderFor] this computer
  static List<VideoEncoder> get forThisComputer =>
      orderFor(Platform.isWindows ? 'windows' : (Platform.isMacOS ? 'macos' : 'linux'));
}

/// The name of [encoder] as the panel and the dialog say it (not translated: the names of the programs)
String videoEncoderName(VideoEncoder encoder) => switch (encoder) {
  VideoEncoder.h264MfHardware => 'H.264 hardware (Media Foundation)',
  VideoEncoder.h264Mf => 'H.264 software (Media Foundation)',
  VideoEncoder.h264VideoToolbox => 'H.264 (VideoToolbox)',
  VideoEncoder.h264VaapiFull || VideoEncoder.h264VaapiLowPower => 'H.264 hardware (VA-API)',
  VideoEncoder.svtAv1 => 'AV1 (SVT-AV1)',
};

/// The error of a job that no encoder of this computer finishes at its frame: the encoder that stopped last, the frame,
/// the eye width of a smaller 360° frame to choose, and the end of what FFmpeg said ([videoEncoderDeadEndOf] reads it)
String videoEncoderDeadEndMessage({
  required VideoEncoder encoder,
  required int width,
  required int height,
  int? smaller,
  required String said,
}) =>
    'The encoder ${encoder.name} stopped at ${width}x$height'
    '${smaller == null ? '' : ' (smaller: ${smaller}x$smaller)'}: ${said.isEmpty ? 'no word from FFmpeg' : said}';

/// What [videoEncoderDeadEndMessage] wrote into [message], null for another message
({VideoEncoder encoder, String frame, String? smaller, String said})? videoEncoderDeadEndOf(String? message) {
  final match = RegExp(
    r'^The encoder (\w+) stopped at (\d+)x(\d+)(?: \(smaller: (\d+)x(\d+)\))?: (.*)$',
    dotAll: true,
  ).firstMatch(message ?? '');
  final encoder = match == null ? null : VideoEncoder.values.asNameMap()[match.group(1)];
  if (match == null || encoder == null) {
    return null;
  }
  return (
    encoder: encoder,
    frame: '${match.group(2)} x ${match.group(3)}',
    smaller: match.group(4) == null ? null : '${match.group(4)} x ${match.group(5)}',
    said: match.group(6)!,
  );
}

/// The render node the VA-API encoders open
const vaapiDevice = '/dev/dri/renderD128';

/// The options of [encoder] for a frame of [width] x [height] at [rate]: the device before the input for VA-API, then
/// the filter and the codec's settings
({List<String> device, String filter, List<String> codec}) videoEncoderOptions(
  VideoEncoder encoder,
  int width,
  int height,
  VideoRate rate,
) {
  final bitrate = (videoBitsPerPixel * width * height * rate.value).round();
  const colour = 'scale=out_color_matrix=bt709:out_range=tv';
  return switch (encoder) {
    VideoEncoder.h264MfHardware => (
      device: const [],
      filter: '$colour,format=nv12',
      codec: ['-c:v', 'h264_mf', '-hw_encoding', '1', '-b:v', '$bitrate'],
    ),
    VideoEncoder.h264Mf => (
      device: const [],
      filter: '$colour,format=nv12',
      codec: ['-c:v', 'h264_mf', '-b:v', '$bitrate'],
    ),
    VideoEncoder.h264VideoToolbox => (
      device: const [],
      filter: '$colour,format=nv12',
      codec: ['-c:v', 'h264_videotoolbox', '-allow_sw', '1', '-b:v', '$bitrate'],
    ),
    VideoEncoder.h264VaapiFull || VideoEncoder.h264VaapiLowPower => (
      device: const ['-vaapi_device', vaapiDevice],
      filter: '$colour,format=nv12,hwupload',
      codec: [
        '-c:v',
        'h264_vaapi',
        '-low_power',
        encoder == VideoEncoder.h264VaapiLowPower ? '1' : '0',
        '-rc_mode',
        'CQP',
        '-qp',
        '22',
      ],
    ),
    VideoEncoder.svtAv1 => (
      device: const [],
      filter: '$colour,format=yuv420p',
      codec: ['-c:v', 'libsvtav1', '-preset', '10', '-crf', '30', '-svtav1-params', 'lp=2'],
    ),
  };
}

/// The colour tags of every output, BT.709 in TV range
const _colourTags = ['-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-color_range', 'tv'];

/// ffprobe of [path], as VideoSource.fromFfprobe reads it
List<String> videoProbeArguments(String path) => [
  '-v',
  'error',
  '-show_format',
  '-show_streams',
  '-count_packets',
  '-of',
  'json',
  path,
];

/// The filter of the decoder for [source] at an eye of [eyeWidth] x [eyeHeight]: 30 fps for slow motion, the tone map
/// of HDR, the eye size by area (its sample aspect already counted in it; the program has no setsar), RGB
String videoDecoderFilter(VideoSource source, int eyeWidth, int eyeHeight, {required bool slowMotion}) {
  // An untagged HD stream is BT.709 (swscale would take it for BT.601 and shift its colours)
  final matrix = !source.colourTagged && math.max(source.codedWidth, source.codedHeight) >= 1280
      ? ':in_color_matrix=bt709'
      : '';
  return [
    if (slowMotion) 'fps=30',
    if (source.isHdr && source.colourTagged) videoToneMap,
    'scale=$eyeWidth:$eyeHeight:flags=area$matrix',
    'format=rgb24',
  ].join(',');
}

/// The decoder: the frames of [source] (the file [path]) at the eye size, RGB on its standard output, each frame's
/// time written to [statsPath] as "{n} {pts} {tb}" (-stats_enc_pre); from [seekSeconds] on for a resumed job (an
/// accurate seek, the source's own times kept by -copyts)
List<String> videoDecoderArguments({
  required String path,
  required VideoSource source,
  required int eyeWidth,
  required int eyeHeight,
  required bool slowMotion,
  required String statsPath,
  double? seekSeconds,
  int threads = 2,
}) => [
  '-nostdin',
  '-hide_banner',
  '-v',
  'error',
  '-threads',
  '$threads',
  '-copyts',
  if (seekSeconds != null) ...['-ss', seekSeconds.toStringAsFixed(6)],
  '-i',
  path,
  '-map',
  '0:v:${source.videoOrdinal}',
  '-an',
  '-sn',
  '-dn',
  '-fps_mode',
  'passthrough',
  '-vf',
  videoDecoderFilter(source, eyeWidth, eyeHeight, slowMotion: slowMotion),
  '-stats_enc_pre',
  statsPath,
  '-stats_enc_pre_fmt',
  '{n} {pts} {tb}',
  '-f',
  'rawvideo',
  '-pix_fmt',
  'rgb24',
  'pipe:1',
];

/// The frames of the test of an encoder: one second at 30 fps, enough for the encoders that hold frames back (the
/// asynchronous Media Foundation ones) to give their packets and finish
const videoEncoderTestFrames = 30;

/// The test of [encoder] at [width] x [height] and [rate]: exactly the command of a segment ([videoSegmentArguments]),
/// RGB frames on its standard input into the Matroska file [outputPath]. A test that wrote to nothing (the null muxer)
/// passed on FreeKC's PC (23 Nov 2026) while the job failed at once: the Intel Quick Sync H.264 MFT gives no
/// sequence header when it opens ("Didn't get extradata in 70 ms"), which the null muxer takes and Matroska refuses
/// ("Could not write header (incorrect codec parameters ?)").
List<String> videoEncoderTestArguments(
  VideoEncoder encoder,
  int width,
  int height,
  VideoRate rate, {
  required String outputPath,
  bool markLeftRight = true,
}) => videoSegmentArguments(
  encoder: encoder,
  width: width,
  height: height,
  rate: rate,
  segmentPath: outputPath,
  markLeftRight: markLeftRight,
);

/// ffprobe of the file of an encoder test: its first video stream decoded and its frames counted
List<String> videoTestCheckArguments(String path) => [
  '-v',
  'error',
  '-count_frames',
  '-select_streams',
  'v:0',
  '-show_entries',
  'stream=codec_name,width,height,nb_read_frames',
  '-of',
  'json',
  path,
];

/// The frames [videoTestCheckArguments] counted in [json] (ffprobe's answer), null when it found no video stream
int? videoTestFrameCount(Object? json) {
  if (json is! Map || json['streams'] is! List) {
    return null;
  }
  for (final stream in json['streams'] as List) {
    if (stream is Map) {
      final frames = stream['nb_read_frames'];
      return frames is int ? frames : int.tryParse('$frames');
    }
  }
  return null;
}

/// The segment [inputPath] (made by another encoder) made again by [encoder] into [segmentPath], frame for frame and
/// with the marks of a segment: after the encoder of a job stopped, the segments written before it are made by the
/// next encoder too, so that the final mux joins one stream of one codec
List<String> videoSegmentTranscodeArguments({
  required VideoEncoder encoder,
  required int width,
  required int height,
  required VideoRate rate,
  required String inputPath,
  required String segmentPath,
  bool markLeftRight = true,
}) {
  final options = videoEncoderOptions(encoder, width, height, rate);
  return [
    '-nostdin',
    '-hide_banner',
    '-v',
    'error',
    '-y',
    ...options.device,
    '-i',
    inputPath,
    '-map',
    '0:v:0',
    '-fps_mode',
    'passthrough',
    '-vf',
    options.filter,
    ...options.codec,
    '-g',
    '${math.max(1, (2 * rate.value).round())}',
    ..._colourTags,
    if (markLeftRight) ...['-metadata:s:v:0', 'stereo_mode=left_right'],
    '-f',
    'matroska',
    segmentPath,
  ];
}

/// The last [lines] lines of what an FFmpeg program wrote on its error output, the addresses of its contexts left out
/// ("[out#0/matroska @ 000001c1cb674b40]" becomes "[out#0/matroska]"): what the log and the error of a job quote
String videoProgramTail(String errors, {int lines = 6}) {
  final kept = [
    for (final line in errors.split(RegExp(r'[\r\n]+')))
      if (line.trim().isNotEmpty) line.trim().replaceAll(RegExp(r' @ (0x)?[0-9a-fA-F]{6,}\]'), ']'),
  ];
  return kept.sublist(math.max(0, kept.length - lines)).join('\n');
}

/// The encoder of one segment: RGB frames of [width] x [height] on its standard input at [rate], written by [encoder]
/// into the Matroska file [segmentPath] marked left right; with [markLeftRight] false (a 360° video, top and bottom)
/// not marked at all: the marks of a sphere go into the MP4 after the mux (spherical_mp4_writer.dart)
List<String> videoSegmentArguments({
  required VideoEncoder encoder,
  required int width,
  required int height,
  required VideoRate rate,
  required String segmentPath,
  bool markLeftRight = true,
}) {
  final options = videoEncoderOptions(encoder, width, height, rate);
  return [
    '-nostdin',
    '-hide_banner',
    '-v',
    'error',
    '-y',
    ...options.device,
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgb24',
    '-s',
    '${width}x$height',
    '-framerate',
    rate.ffmpeg,
    '-i',
    'pipe:0',
    '-vf',
    options.filter,
    ...options.codec,
    '-g',
    '${math.max(1, (2 * rate.value).round())}',
    ..._colourTags,
    if (markLeftRight) ...['-metadata:s:v:0', 'stereo_mode=left_right'],
    '-f',
    'matroska',
    segmentPath,
  ];
}

/// The list of segments of the concat demuxer, each path quoted and followed by its exact length: its [slots] at
/// [rate]. Without it the demuxer places each segment after the duration of the one before as Matroska keeps it, in
/// whole milliseconds, and the picture drifts from the source's sound by about 0.6 ms a segment (150 ms over a two
/// hour film at 29.97 fps, measured with the program on ai1)
String videoConcatList(List<({String name, int slots})> segments, VideoRate rate) => [
  'ffconcat version 1.0',
  for (final segment in segments) ...[
    "file '${segment.name.replaceAll("'", r"'\''")}'",
    'duration ${(segment.slots * rate.denominator / rate.numerator).toStringAsFixed(9)}',
  ],
].join('\n');

/// The final mux: the segments of [concatPath] joined, the audio tracks of the source [sourcePath] each copied or made
/// AAC, the source's tags (date, place, make, model) and chapters, our [keys], [videoOffset] seconds of the video's
/// start kept, written to [outputPath] (a .part file, renamed when complete)
List<String> videoMuxArguments({
  required String concatPath,
  required String sourcePath,
  required List<VideoAudioTrack> audio,
  required Map<String, String> keys,
  required String outputPath,
  double videoOffset = 0,
}) => [
  '-nostdin',
  '-hide_banner',
  '-v',
  'error',
  '-y',
  if (videoOffset > 0) ...['-itsoffset', videoOffset.toStringAsFixed(6)],
  '-f',
  'concat',
  '-safe',
  '0',
  '-i',
  concatPath,
  '-i',
  sourcePath,
  '-map',
  '0:v',
  for (final track in audio) ...['-map', '1:${track.index}'],
  '-map_metadata',
  '1',
  '-map_chapters',
  '1',
  '-c:v',
  'copy',
  for (final (i, track) in audio.indexed)
    if (track.isCopied) ...['-c:a:$i', 'copy'] else ...['-c:a:$i', 'aac', '-b:a:$i', '${track.aacBitRate}'],
  for (final MapEntry(:key, :value) in keys.entries) ...['-metadata', '$key=$value'],
  '-strict',
  'unofficial',
  '-movflags',
  '+faststart+use_metadata_tags',
  '-f',
  'mp4',
  outputPath,
];

/// A line of -stats_enc_pre ("{n} {pts} {tb}"): the frame's number and its time in seconds; null for another line
({int frame, double seconds})? parseStatsLine(String line) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length != 3) {
    return null;
  }
  final frame = int.tryParse(parts[0]);
  final pts = int.tryParse(parts[1]);
  final timeBase = VideoRate.parse(parts[2]);
  if (frame == null || pts == null || timeBase == null) {
    return null;
  }
  return (frame: frame, seconds: pts * timeBase.value);
}

/// The slot of the grid of [rate] a frame at [seconds] takes, the first frame at [start] taking slot 0: rounded half up
int videoGridSlot(double seconds, double start, VideoRate rate) => ((seconds - start) * rate.value + 0.5).floor();

/// How many slots of the grid each frame takes: from its slot to the next frame's (0 when two frames fall on one slot:
/// the later one shows), the last frame one; the frames at [times] seconds
List<int> videoGridRepeats(List<double> times, VideoRate rate) {
  if (times.isEmpty) {
    return const [];
  }
  final start = times.first;
  return [
    for (var i = 0; i < times.length; i++)
      i + 1 < times.length
          ? math.max(0, videoGridSlot(times[i + 1], start, rate) - videoGridSlot(times[i], start, rate))
          : 1,
  ];
}
