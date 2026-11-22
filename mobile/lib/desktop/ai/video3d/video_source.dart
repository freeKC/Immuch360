// A flat video about to be made 3D on a computer (store/m2/release-49/lots/video3d-plan.md, sections 2.1, 2.4 and 4.2):
// what ffprobe of the FFmpeg program says of it (-show_format -show_streams -count_packets -of json), read into
// [VideoSource], then checked by [checkVideoSource]: the refusals before the job (a 360° or VR180 video, one already in
// 3D, interlaced, Dolby Vision without a base layer, a rotation that is not a quarter turn, no video at all) and the
// lines the dialog shows for what the job changes (HDR tone mapped, 10 or 12 bit made 8 bit, variable rate kept on the
// grid, slow motion made 30 fps, every audio track kept, subtitles and data tracks not kept, a long video). The sizes
// the job works at come from here too: the eye (up to 1920 wide in landscape, 1920 high in portrait), the model's input
// (a short side of 280, 392 or 518, both sides multiples of 14), and the grid of the output (r_frame_rate, checked
// against the frame count and the duration: the WebM of Wikimedia Commons say avg_frame_rate=1000/1).
//
// A 360° video (lot ai-360-3d-51) is one whose spherical side data, sv3d or Spherical Video V1 box, name words, or the
// mark of the app (the server's projection, a 360° file found on this computer, "view as 360°") say so: a whole
// equirectangular sphere in one 2:1 eye is made a 360° 3D video (VideoSourceCheck.sphere); two eyes already (st3d, a
// square or 4:1 frame, the words of a stereo name) are refused as already 3D, a half sphere (VR180) and the raw files
// of the 360° cameras (two fisheye lenses, not stitched yet) are refused with their own words. A 2:1 frame with no mark
// at all may be a 360° video or a 2.00:1 film: the dialog asks (VideoSourceCheck.looksLike360), never guesses.
//
// Pure Dart, no I/O and no Flutter (the command line tool of the lot runs it too): the tests feed it the JSON of real
// files (test/fixtures/video3d) and of made up ones.

import 'dart:math' as math;

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart' show nameSays360;
import 'package:immich_mobile/domain/models/flat_stereo.dart';
import 'package:immich_mobile/domain/models/stereo_layout.dart';
import 'package:immich_mobile/domain/services/raw/raw_360_detection.dart' show isRawVideoName;
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:path/path.dart' as p;

/// The quality of the depth: the short side of the model's input
enum VideoDepthQuality {
  fast(280),
  standard(392),
  fine(518);

  const VideoDepthQuality(this.shortSide);

  final int shortSide;

  /// The peak memory of one pass of Video Depth Anything Small at this size on the processor, measured on ai1 (study
  /// section 2), plus the 0.5 GB the job holds besides (32 prepared inputs, the eye frames held back)
  int get jobMemoryBytes => switch (this) {
    fast => _gib(1.9 + 0.5),
    standard => _gib(3.4 + 0.5),
    fine => _gib(7.4 + 0.5),
  };

  static int _gib(double gib) => (gib * 1024 * 1024 * 1024).round();
}

/// How the two eyes are stored side by side: each at its full width (3840 x 1080 for a 1080p video), or each squeezed
/// to half its width (1920 x 1080)
enum VideoSbsPacking { full, half }

/// What a frame's colours are, as the job has to read them
enum VideoTransfer {
  /// SDR, BT.709 or untagged: read as it is
  sdr,

  /// HLG (arib-std-b67): tone mapped to SDR
  hlg,

  /// PQ (smpte2084): tone mapped to SDR
  pq,
}

/// A frame rate as a fraction
class VideoRate {
  const VideoRate(this.numerator, this.denominator);

  final int numerator;
  final int denominator;

  double get value => denominator == 0 ? 0 : numerator / denominator;

  bool get isValid => numerator > 0 && denominator > 0;

  /// "30000/1001", as FFmpeg reads it
  String get ffmpeg => '$numerator/$denominator';

  /// The rate ffprobe wrote as "30000/1001" or "25/1", null for "0/0" or anything else
  static VideoRate? parse(Object? text) {
    if (text is! String) {
      return null;
    }
    final parts = text.split('/');
    final numerator = int.tryParse(parts.first);
    final denominator = parts.length == 2 ? int.tryParse(parts[1]) : 1;
    if (numerator == null || denominator == null || numerator <= 0 || denominator <= 0) {
      return null;
    }
    return VideoRate(numerator, denominator);
  }

  @override
  bool operator ==(Object other) =>
      other is VideoRate && other.numerator * denominator == numerator * other.denominator;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => ffmpeg;
}

/// An audio track of the source: copied into the MP4 when it takes it as it is, else made AAC by FFmpeg's own encoder
class VideoAudioTrack {
  const VideoAudioTrack({
    required this.index,
    required this.codec,
    this.channels,
    this.language,
    this.ambisonic = false,
  });

  /// The index of the stream in the file
  final int index;
  final String codec;
  final int? channels;
  final String? language;

  /// Spatial sound of a 360° video: first order (or higher) ambisonics, as ffprobe reads the SA3D box ("ambisonic 1")
  final bool ambisonic;

  /// The codecs an MP4 takes as they are (plan 2.5)
  static const copied = {'aac', 'mp3', 'opus', 'alac', 'ac3', 'eac3', 'flac'};

  /// The audio codecs the FFmpeg program can decode, so make AAC: the audio decoders of its sources.lock
  /// (immuch360/libmpv-builds, ffmpeg-lgpl-*), by the codec names ffprobe gives (its dca decoder reads "dts"). No WMA,
  /// AMR or ADPCM decoder is built in
  static const decodable = {
    'aac',
    'aac_latm',
    'ac3',
    'eac3',
    'mp2',
    'mp3',
    'opus',
    'vorbis',
    'flac',
    'alac',
    'truehd',
    'mlp',
    'dts',
    'pcm_alaw',
    'pcm_bluray',
    'pcm_dvd',
    'pcm_f16le',
    'pcm_f24le',
    'pcm_f32be',
    'pcm_f32le',
    'pcm_f64be',
    'pcm_f64le',
    'pcm_lxf',
    'pcm_mulaw',
    'pcm_s8',
    'pcm_s8_planar',
    'pcm_s16be',
    'pcm_s16be_planar',
    'pcm_s16le',
    'pcm_s16le_planar',
    'pcm_s24be',
    'pcm_s24daud',
    'pcm_s24le',
    'pcm_s24le_planar',
    'pcm_s32be',
    'pcm_s32le',
    'pcm_s32le_planar',
    'pcm_s64be',
    'pcm_s64le',
    'pcm_sga',
    'pcm_u8',
    'pcm_u16be',
    'pcm_u16le',
    'pcm_u24be',
    'pcm_u24le',
    'pcm_u32be',
    'pcm_u32le',
    'pcm_vidc',
  };

  bool get isCopied => copied.contains(codec);

  /// Whether the final mux can keep it: copied as it is, or decoded and made AAC. Any other track would only fail at
  /// the very end of the job ("decoder not found"), so it is left out from the start
  bool get isKept => isCopied || decodable.contains(codec);

  /// The bit rate of the AAC it becomes when it cannot be copied: 192 kbit/s for stereo, 384 for 5.1 and more
  int get aacBitRate => (channels ?? 2) > 2 ? 384000 : 192000;
}

/// The Dolby Vision configuration of a stream (ffprobe's "DOVI configuration record")
class DolbyVisionConfig {
  const DolbyVisionConfig({required this.profile, required this.compatibility});

  final int profile;

  /// dv_bl_signal_compatibility_id: 0 none (profile 5), 1 HDR10, 2 SDR, 4 HLG, 6 Blu-ray HDR10
  final int compatibility;

  /// Whether a decoder that knows nothing of Dolby Vision reads a picture of its base layer: profile 5 (and any
  /// profile with no compatible base layer) gives IPT colours only Dolby Vision turns right
  bool get hasBaseLayer => profile != 5 && compatibility != 0;
}

/// What ffprobe says of a video file, the parts the job reads
class VideoSource {
  const VideoSource({
    required this.streamIndex,
    required this.videoOrdinal,
    required this.codec,
    required this.codedWidth,
    required this.codedHeight,
    this.sampleAspect = 1.0,
    this.rotation = 0,
    this.pixelFormat,
    this.bitDepth = 8,
    this.transfer = VideoTransfer.sdr,
    this.colourTagged = false,
    this.interlaced = false,
    this.dolbyVision,
    this.rFrameRate,
    this.avgFrameRate,
    this.frameCount,
    this.duration,
    this.startTime = 0,
    this.timeBase,
    this.audio = const [],
    this.subtitleCount = 0,
    this.dataCount = 0,
    this.attachedPictureCount = 0,
    this.declaredStereo = false,
    this.declaredSpherical = false,
    this.declaredHalfSphere = false,
    this.formatTags = const {},
  });

  /// The index of the video stream in the file, and its rank among the video streams (-map 0:v:N)
  final int streamIndex;
  final int videoOrdinal;
  final String codec;

  /// The size of the decoded frames, before rotation and before the sample aspect
  final int codedWidth;
  final int codedHeight;

  /// The width of a sample over its height (1 for square pixels)
  final double sampleAspect;

  /// The rotation the display matrix asks for, in degrees as ffprobe gives it
  final double rotation;
  final String? pixelFormat;
  final int bitDepth;
  final VideoTransfer transfer;

  /// Whether the stream tells its colours (transfer, primaries or matrix): zscale needs them for a tone map
  final bool colourTagged;
  final bool interlaced;
  final DolbyVisionConfig? dolbyVision;
  final VideoRate? rFrameRate;
  final VideoRate? avgFrameRate;

  /// nb_frames, else the packets ffprobe counted (-count_packets)
  final int? frameCount;

  /// In seconds, the stream's or else the file's
  final double? duration;

  /// The start of the video stream, in seconds (kept by -itsoffset at the final mux)
  final double startTime;
  final VideoRate? timeBase;
  final List<VideoAudioTrack> audio;
  final int subtitleCount;
  final int dataCount;
  final int attachedPictureCount;

  /// The stream's side data says its eyes (Stereo 3D) or a sphere (Spherical Mapping)
  final bool declaredStereo;
  final bool declaredSpherical;
  final bool declaredHalfSphere;
  final Map<String, String> formatTags;

  /// The rotation as a quarter turn (0, 90, 180, 270), null when it is not one
  int? get quarterTurn {
    final turned = rotation % 360;
    final normal = turned < 0 ? turned + 360 : turned;
    for (final quarter in const [0, 90, 180, 270, 360]) {
      if ((normal - quarter).abs() < 0.01) {
        return quarter % 360;
      }
    }
    return null;
  }

  bool get isTurned => quarterTurn == 90 || quarterTurn == 270;

  /// The size as shown: the sample aspect applied, then the rotation
  int get displayWidth => isTurned ? codedHeight : _shownWidth;
  int get displayHeight => isTurned ? _shownWidth : codedHeight;
  int get _shownWidth => math.max(1, (codedWidth * sampleAspect).round());

  bool get isPortrait => displayHeight > displayWidth;

  bool get isHdr => transfer != VideoTransfer.sdr;

  /// The video stream of [json], the output of ffprobe; null when the file has none (attached pictures are not one)
  static VideoSource? fromFfprobe(Map<String, Object?> json) {
    final streams = (json['streams'] as List?)?.whereType<Map>().map((s) => s.cast<String, Object?>()).toList() ?? [];
    final format = (json['format'] as Map?)?.cast<String, Object?>() ?? const {};
    Map<String, Object?>? video;
    var ordinal = -1;
    var videoOrdinal = -1;
    var attached = 0;
    final audio = <VideoAudioTrack>[];
    var subtitles = 0;
    var data = 0;
    for (final stream in streams) {
      final type = stream['codec_type'];
      final disposition = (stream['disposition'] as Map?)?.cast<String, Object?>() ?? const {};
      switch (type) {
        case 'video':
          ordinal++;
          if (disposition['attached_pic'] == 1) {
            attached++;
          } else if (video == null) {
            video = stream;
            videoOrdinal = ordinal;
          }
        case 'audio':
          audio.add(
            VideoAudioTrack(
              index: _int(stream['index']) ?? audio.length,
              codec: '${stream['codec_name'] ?? 'unknown'}',
              channels: _int(stream['channels']),
              language: (stream['tags'] as Map?)?['language'] as String?,
              ambisonic: '${stream['channel_layout'] ?? ''}'.contains('ambisonic'),
            ),
          );
        case 'subtitle':
          subtitles++;
        case 'data' || 'attachment':
          data++;
      }
    }
    if (video == null) {
      return null;
    }
    final width = _int(video['width']) ?? 0;
    final height = _int(video['height']) ?? 0;
    if (width <= 0 || height <= 0) {
      return null;
    }
    final sideData = (video['side_data_list'] as List?)?.whereType<Map>().toList() ?? const [];
    double rotation = 0;
    DolbyVisionConfig? dolby;
    var stereo = false;
    var spherical = false;
    var halfSphere = false;
    for (final side in sideData) {
      switch (side['side_data_type']) {
        case 'Display Matrix':
          rotation = _double(side['rotation']) ?? 0;
        case 'DOVI configuration record':
          dolby = DolbyVisionConfig(
            profile: _int(side['dv_profile']) ?? 0,
            compatibility: _int(side['dv_bl_signal_compatibility_id']) ?? 0,
          );
        case 'Stereo 3D':
          stereo = '${side['type'] ?? ''}' != '2D';
        case 'Spherical Mapping':
          spherical = true;
          final projection = '${side['projection'] ?? ''}';
          final bounds = [
            'bound_left',
            'bound_right',
            'bound_top',
            'bound_bottom',
          ].any((k) => (_int(side[k]) ?? 0) != 0);
          halfSphere = projection.contains('half') || projection.contains('fisheye') || bounds;
      }
    }
    // An older ffprobe gives the rotation as a tag
    if (rotation == 0) {
      rotation = _double((video['tags'] as Map?)?['rotate']) ?? 0;
    }
    final pixelFormat = video['pix_fmt'] as String?;
    final transfer = switch (video['color_transfer']) {
      'arib-std-b67' => VideoTransfer.hlg,
      'smpte2084' => VideoTransfer.pq,
      _ => VideoTransfer.sdr,
    };
    final tagged = [
      video['color_transfer'],
      video['color_primaries'],
      video['color_space'],
    ].any((value) => value is String && value.isNotEmpty && value != 'unknown');
    final fieldOrder = video['field_order'];
    final tags = <String, String>{
      for (final MapEntry(:key, :value) in ((format['tags'] as Map?) ?? const {}).entries) '$key': '$value',
    };
    return VideoSource(
      streamIndex: _int(video['index']) ?? 0,
      videoOrdinal: videoOrdinal,
      codec: '${video['codec_name'] ?? 'unknown'}',
      codedWidth: width,
      codedHeight: height,
      sampleAspect: _sampleAspect(video['sample_aspect_ratio']),
      rotation: rotation,
      pixelFormat: pixelFormat,
      bitDepth: bitDepthOf(pixelFormat, _int(video['bits_per_raw_sample'])),
      transfer: transfer,
      colourTagged: tagged,
      interlaced: fieldOrder is String && const {'tt', 'bb', 'tb', 'bt'}.contains(fieldOrder),
      dolbyVision: dolby,
      rFrameRate: VideoRate.parse(video['r_frame_rate']),
      avgFrameRate: VideoRate.parse(video['avg_frame_rate']),
      frameCount: _int(video['nb_frames']) ?? _int(video['nb_read_frames']) ?? _int(video['nb_read_packets']),
      duration: _double(video['duration']) ?? _double(format['duration']),
      startTime: _double(video['start_time']) ?? 0,
      timeBase: VideoRate.parse(video['time_base']),
      audio: audio,
      subtitleCount: subtitles,
      dataCount: data,
      attachedPictureCount: attached,
      declaredStereo: stereo,
      declaredSpherical: spherical,
      declaredHalfSphere: halfSphere,
      formatTags: tags,
    );
  }
}

/// The bits of a sample of [pixelFormat] (yuv420p10le gives 10), or [rawBits] when the name says nothing; 8 by default
int bitDepthOf(String? pixelFormat, [int? rawBits]) {
  final match = RegExp(r'p(9|10|12|14|16)(le|be)?$').firstMatch(pixelFormat ?? '');
  if (match != null) {
    return int.parse(match.group(1)!);
  }
  if (pixelFormat != null && pixelFormat.startsWith('p010')) {
    return 10;
  }
  return rawBits != null && rawBits > 8 ? rawBits : 8;
}

int? _int(Object? value) => switch (value) {
  final int number => number,
  final double number => number.round(),
  final String text => int.tryParse(text) ?? double.tryParse(text)?.round(),
  _ => null,
};

double? _double(Object? value) => switch (value) {
  final num number => number.toDouble(),
  final String text => double.tryParse(text),
  _ => null,
};

double _sampleAspect(Object? text) {
  if (text is! String) {
    return 1;
  }
  final parts = text.split(':');
  final numerator = parts.length == 2 ? int.tryParse(parts[0]) : null;
  final denominator = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (numerator == null || denominator == null || numerator <= 0 || denominator <= 0) {
    return 1;
  }
  // A sample aspect within 1 % of square is a rounding of the encoder that made the file (1215:1216 after a scale):
  // square, so that a 1080 x 1920 phone clip keeps eyes of 1080 x 1920
  final aspect = numerator / denominator;
  return (aspect - 1).abs() < 0.01 ? 1 : aspect;
}

/// What the dialog says the job does to a video, besides making it 3D (plan 4.2)
enum VideoPlanNote {
  /// HLG or PQ made SDR by a tone map
  hdrToneMapped,

  /// Dolby Vision 8.x read through its base layer
  dolbyVisionBaseLayer,

  /// 10 or 12 bit made 8 bit
  deepColour,

  /// The source's frames kept at their times on the output's grid, a gap showing the frame before it
  variableRate,

  /// Above 60 frames a second: made 30 fps
  slowMotion,

  /// Several audio tracks: all kept
  allAudioKept,

  /// Audio tracks the FFmpeg program cannot read (WMA, AMR, ADPCM...): left out, the video silent when none is left
  audioNotKept,

  /// Subtitles not kept
  subtitlesNotKept,

  /// Data tracks and attached pictures not kept
  dataNotKept,

  /// Over 20 minutes: a night or more, the computer kept awake, the job resumes where it stopped
  long,

  /// A 360° video: spatial sound (ambisonics) kept as it is, the head turning in the sound as in the picture
  spatialAudioKept,

  /// A 360° video: spatial sound the MP4 cannot take as it is, made plain AAC (the sound no longer turns with the head)
  spatialAudioPlain,
}

/// The output's frame grid and whether frames above 60 fps were made 30 fps
typedef VideoGrid = ({VideoRate rate, bool slowMotion});

/// The standard frame rates the median interval of a file whose r_frame_rate cannot be trusted is rounded to
const _standardRates = [
  VideoRate(24000, 1001),
  VideoRate(24, 1),
  VideoRate(25, 1),
  VideoRate(30000, 1001),
  VideoRate(30, 1),
  VideoRate(48, 1),
  VideoRate(50, 1),
  VideoRate(60000, 1001),
  VideoRate(60, 1),
  VideoRate(100, 1),
  VideoRate(120, 1),
  VideoRate(240, 1),
];

/// The grid of the output of [source]: its r_frame_rate when the frame count and the duration agree with it (a
/// variable rate phone clip says 30 for 25.9 frames a second on average: kept, its gaps repeat a frame), else the
/// measured rate rounded to the nearest standard one within 6 % (the WebM trap, 1000/1), else the measured rate itself; 30 fps for
/// a rate above 60 (slow motion). Null when nothing tells a rate.
VideoGrid? videoGridOf(VideoSource source) {
  final count = source.frameCount;
  final duration = source.duration;
  final measured = count != null && duration != null && count > 1 && duration > 0 ? count / duration : null;
  final r = source.rFrameRate;
  VideoRate? rate;
  if (r != null &&
      r.value <= 1000 &&
      (measured == null || (r.value <= measured * 1.6 + 0.5 && r.value >= measured * 0.6))) {
    rate = r;
  } else if (measured != null) {
    var nearest = double.infinity;
    for (final standard in _standardRates) {
      final off = (standard.value - measured).abs() / standard.value;
      if (off <= 0.06 && off < nearest) {
        nearest = off;
        rate = standard;
      }
    }
    rate ??= VideoRate((measured * 1000).round(), 1000);
  } else {
    final average = source.avgFrameRate;
    rate = average != null && average.value <= 240 ? average : null;
  }
  if (rate == null) {
    return null;
  }
  if (rate.value > 60.5) {
    return (rate: const VideoRate(30, 1), slowMotion: true);
  }
  return (rate: rate, slowMotion: false);
}

/// The frames of the source come at irregular times: its average rate is off its r_frame_rate by more than 2 %
bool isVariableRate(VideoSource source) {
  final r = source.rFrameRate;
  final average = source.avgFrameRate;
  if (r == null || average == null || average.value > r.value * 4 || average.value < r.value / 4) {
    return false;
  }
  return (average.value - r.value).abs() > 0.02 * r.value;
}

/// The size of one eye of the output for [source]: its width up to 1920 for a landscape video, its height up to 1920
/// for a portrait one, the other side by the shown aspect, both even
({int width, int height}) videoEyeSize(VideoSource source) {
  final width = source.displayWidth;
  final height = source.displayHeight;
  if (height > width) {
    final eyeHeight = _even(math.min(height, 1920));
    return (width: _even(eyeHeight * width / height), height: eyeHeight);
  }
  final eyeWidth = _even(math.min(width, 1920));
  return (width: eyeWidth, height: _even(eyeWidth * height / width));
}

/// The input of Video Depth Anything Small for an eye of [eyeWidth] x [eyeHeight] at [quality]: the short side at the
/// quality's size, the long one by the eye's aspect, both multiples of 14 (700 x 392 for 16:9 at Standard, 392 x 700
/// for a portrait 9:16)
({int width, int height}) videoModelSize(int eyeWidth, int eyeHeight, VideoDepthQuality quality) {
  final short = quality.shortSide;
  int long(int a, int b) => math.max(14, (short * a / b / 14).round() * 14);
  return eyeHeight > eyeWidth
      ? (width: short, height: long(eyeHeight, eyeWidth))
      : (width: long(eyeWidth, eyeHeight), height: short);
}

int _even(num value) => math.max(2, (value / 2).round() * 2);

/// The name of the 3D video of [sourceName]: `<name>_3D_LRF_Full_SBS.mp4` or `<name>_3D_LRF_Half_SBS.mp4`, the words every
/// reader of the app and the players of the headsets know
String videoOutputName(String sourceName, VideoSbsPacking packing) {
  final stem = p.basenameWithoutExtension(sourceName);
  return '${stem}_3D_LRF_${packing == VideoSbsPacking.full ? 'Full' : 'Half'}_SBS.mp4';
}

/// Why a video is not made 3D (each a ConversionSkipReason of the queue, see videoSkipReason)
enum VideoRefusal {
  sphere360,
  vr180,
  alreadyStereo,
  interlaced,
  dolbyVisionProfile5,
  oddRotation,
  unreadable,

  /// The raw file of a 360° camera (two fisheye lenses, .insv, .360, .osv): to be stitched by the camera's app first
  raw360,

  /// A 360° video that is not one 2:1 equirectangular frame (a cube map, a cropped sphere)
  sphereLayout,
}

/// How a video is to be made 3D, as the caller asks it
enum VideoProjectionAsk {
  /// A flat video only: a 360° video is refused (the jobs of flat 3D videos)
  flat,

  /// As the video says: a marked 360° video is made 360° 3D, a 2:1 one with no mark is flat and looksLike360 (the
  /// dialog, which then asks)
  auto,

  /// A 360° video, marked or not (the jobs of 360° 3D videos, a 2:1 video the user said is 360°)
  sphere,
}

/// The sizes of the eyes of a 360° 3D video, by their width (each eye 2:1, the frame top and bottom, so square)
const sphereEyeWidths = [2048, 3072, 4096];

/// The eye of the 360° 3D videos by default: 3072 x 1536, a frame of 3072 x 3072, within the 36 864 macroblocks of
/// H.264 level 5.1 that most hardware decoders take, phones and headsets included
const sphereDefaultEyeWidth = 3072;

/// The eye widths a 360° video of [source] is offered: those of [sphereEyeWidths] not wider than its frame, else its
/// own width (a multiple of 4, so that both sides of each eye are even)
List<int> sphereEyeWidthsFor(VideoSource source) {
  final width = source.displayWidth;
  final offered = [
    for (final eye in sphereEyeWidths)
      if (eye <= width) eye,
  ];
  return offered.isNotEmpty ? offered : [math.max(4, width ~/ 4 * 4)];
}

/// The eye width a dialog starts with among [offered]: [kept] (the last chosen) when offered, else the default, else
/// the largest
int sphereDefaultEyeWidthOf(List<int> offered, int? kept) {
  if (kept != null && offered.contains(kept)) {
    return kept;
  }
  return offered.contains(sphereDefaultEyeWidth) ? sphereDefaultEyeWidth : offered.last;
}

/// The name of the 360° 3D video of [sourceName]: `<name>_360_3D.mp4`, or `<name>_3D.mp4` when the name already says
/// 360 or pano, the rule of the 3D versions of the 360° photos (derivedNameEnd)
String sphereOutputName(String sourceName) {
  final stem = p.basenameWithoutExtension(sourceName);
  return nameSays360(sourceName) ? '${stem}_3D.mp4' : '${stem}_360_3D.mp4';
}

/// Whether a frame of [width] x [height] is 2:1 within [tolerance]
bool isTwoToOne(int width, int height, {double tolerance = 0.01}) =>
    width > 0 && height > 0 && (width / height - 2).abs() <= 2 * tolerance;

/// The words of the name of a 360° video in two eyes, as cameras, players and the app write them (our own
/// `<name>_360_3D.mp4` among them)
const _stereoSphereWords = {'tb', 'ou', 'tab', 'overunder', 'topbottom', 'sbs', 'lr', '3d', 'stereo'};

/// Whether a 360° frame of [width] x [height] holds two eyes by its shape: about square (top and bottom) or 4:1 (side
/// by side), as the 360° viewers read it (guessStereoLayout)
bool isStereoSphereShape(int width, int height) => guessStereoLayout(width: width, height: height) != StereoLayout.mono;

/// Whether a flat frame of [width] x [height] holds two eyes by its shape alone, as the players read it
/// (guessSpatialLayout of spatial_media.dart): about twice as wide as a regular one (3.2 to 3.9) side by side, a little
/// taller than wide (above 0.8, up to 0.95) stacked
bool isStereoFrameShape(int width, int height) {
  if (width <= 0 || height <= 0) {
    return false;
  }
  final ratio = width / height;
  return (ratio >= 3.2 && ratio <= 3.9) || (ratio > 0.8 && ratio <= 0.95);
}

/// The verdict on a video before its job
class VideoSourceCheck {
  const VideoSourceCheck._({
    this.source,
    this.skip,
    this.notes = const {},
    this.grid,
    this.audio = const [],
    this.sphere = false,
    this.looksLike360 = false,
  });

  final VideoSource? source;

  /// The audio tracks the output keeps (VideoAudioTrack.isKept), in the order of the source
  final List<VideoAudioTrack> audio;

  /// Why it is refused, null when it can be made 3D
  final VideoRefusal? skip;
  final Set<VideoPlanNote> notes;
  final VideoGrid? grid;

  /// Made a 360° 3D video: a whole sphere, one 2:1 equirectangular eye
  final bool sphere;

  /// A flat video whose 2:1 frame with no mark may be a 360° one: the dialog asks before Convert
  final bool looksLike360;

  bool get accepted => skip == null;
}

/// Videos longer than this get the line of a night or more
const videoLongJob = Duration(minutes: 20);

/// Whether the video named [fileName], that ffprobe described as [source] (null when it found no video stream or could
/// not open the file), can be made 3D, and what the job changes. [spherical] is what the app's own probe of the MP4
/// boxes found (sv3d, st3d), when it ran; [marked360] says that the app takes it for a 360° video (the server's
/// projection, a 360° file found on this computer, the user's "view as 360°"). [ask] says what the caller makes of a
/// 360° video (VideoProjectionAsk).
VideoSourceCheck checkVideoSource(
  VideoSource? source, {
  required String fileName,
  SphericalProbe? spherical,
  bool marked360 = false,
  VideoProjectionAsk ask = VideoProjectionAsk.flat,
}) {
  if (source == null) {
    return const VideoSourceCheck._(skip: VideoRefusal.unreadable);
  }
  final nameStem = p.basenameWithoutExtension(fileName).toLowerCase();
  final words = nameStem.split(RegExp(r'[._\- ]+')).toSet();
  if (isRawVideoName(fileName)) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.raw360);
  }
  final halfSphere = source.declaredHalfSphere || (spherical?.halfSphere ?? false) || words.contains('vr180');
  final sphere =
      source.declaredSpherical ||
      (spherical?.hasSphericalMetadata ?? false) ||
      marked360 ||
      ask == VideoProjectionAsk.sphere ||
      words.any(const {'360', '180', 'vr', 'vr180', 'vr360', 'equirect', 'equirectangular', '360x180'}.contains);
  final declaredStereo = source.declaredStereo || (spherical?.stereo != null && spherical!.stereo != StereoLayout.mono);
  final byName = guessFlatStereoFormat(fileName: fileName, isVideo: true) != null;
  if (sphere) {
    if (halfSphere || words.contains('180')) {
      return VideoSourceCheck._(source: source, skip: VideoRefusal.vr180);
    }
    if (ask == VideoProjectionAsk.flat) {
      return VideoSourceCheck._(source: source, skip: VideoRefusal.sphere360);
    }
    if (declaredStereo ||
        byName ||
        words.any(_stereoSphereWords.contains) ||
        isStereoSphereShape(source.displayWidth, source.displayHeight)) {
      return VideoSourceCheck._(source: source, skip: VideoRefusal.alreadyStereo);
    }
    if (!isTwoToOne(source.displayWidth, source.displayHeight, tolerance: 0.02)) {
      return VideoSourceCheck._(source: source, skip: VideoRefusal.sphereLayout);
    }
    return _checkStream(source, sphere: true);
  }
  final byShape = isStereoFrameShape(source.displayWidth, source.displayHeight);
  if (declaredStereo || byName || byShape) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.alreadyStereo);
  }
  return _checkStream(
    source,
    looksLike360: ask == VideoProjectionAsk.auto && isTwoToOne(source.displayWidth, source.displayHeight),
  );
}

/// The checks of a video's stream once its shape is known
VideoSourceCheck _checkStream(VideoSource source, {bool sphere = false, bool looksLike360 = false}) {
  if (source.interlaced) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.interlaced);
  }
  final dolby = source.dolbyVision;
  if (dolby != null && !dolby.hasBaseLayer) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.dolbyVisionProfile5);
  }
  // A sphere turns in the headset, never in its frame
  if (source.quarterTurn == null || (sphere && source.quarterTurn != 0)) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.oddRotation);
  }
  final grid = videoGridOf(source);
  if (grid == null) {
    return VideoSourceCheck._(source: source, skip: VideoRefusal.unreadable);
  }
  final duration = source.duration;
  final audio = [
    for (final track in source.audio)
      if (track.isKept) track,
  ];
  final notes = {
    if (source.isHdr) VideoPlanNote.hdrToneMapped,
    if (dolby != null) VideoPlanNote.dolbyVisionBaseLayer,
    if (source.bitDepth > 8) VideoPlanNote.deepColour,
    if (isVariableRate(source) && !grid.slowMotion) VideoPlanNote.variableRate,
    if (grid.slowMotion) VideoPlanNote.slowMotion,
    if (audio.length > 1 && audio.length == source.audio.length) VideoPlanNote.allAudioKept,
    if (audio.length < source.audio.length) VideoPlanNote.audioNotKept,
    if (source.subtitleCount > 0) VideoPlanNote.subtitlesNotKept,
    if (source.dataCount > 0 || source.attachedPictureCount > 0) VideoPlanNote.dataNotKept,
    if (duration != null && duration * 1000 > videoLongJob.inMilliseconds) VideoPlanNote.long,
    if (sphere && audio.any((track) => track.ambisonic && track.isCopied)) VideoPlanNote.spatialAudioKept,
    if (sphere && audio.any((track) => track.ambisonic && !track.isCopied)) VideoPlanNote.spatialAudioPlain,
  };
  return VideoSourceCheck._(
    source: source,
    notes: notes,
    grid: grid,
    audio: audio,
    sphere: sphere,
    looksLike360: looksLike360,
  );
}
