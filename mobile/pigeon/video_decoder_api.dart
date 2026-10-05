import 'package:pigeon/pigeon.dart';

// What the device decodes: used before playing a video original to choose between the original and the
// server's transcoded stream, and for the decoders page of the troubleshooting settings.
@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/video_decoder_api.g.dart',
    swiftOut: 'ios/Runner/Core/VideoDecoder.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/videodecoder/VideoDecoder.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.videodecoder'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
/// The answer to "can this device decode that video": [supported] is the verdict, [hardware] says whether a
/// hardware decoder does it, [maxWidth] and [maxHeight] the largest frame the best decoder of that codec takes,
/// [reason] a short technical note for the logs (not translated).
class DecodeVerdict {
  const DecodeVerdict({
    required this.supported,
    required this.hardware,
    required this.maxWidth,
    required this.maxHeight,
    this.reason,
    this.profile,
    this.missingProfile,
  });

  final bool supported;
  final bool hardware;
  final int maxWidth;
  final int maxHeight;
  final String? reason;

  /// The profile the decoders were checked for, as the decoders page names it ("Main 10", "Main 10 HDR10",
  /// "High 10"); null when no profile was checked
  final String? profile;

  /// [profile] again when no decoder of the device lists it (nor Main 10 for an HDR10 one): the refusal comes from it
  final String? missingProfile;
}

/// One video decoder of the device, for the decoders page: [name] as the system calls it, [codec] the MIME type
/// it decodes, [hardware] whether it is a hardware decoder, [maxWidth] and [maxHeight] its largest frame,
/// [maxFrameRate] the frame rate it reaches at that size when the system tells (0 when unknown).
class DecoderInfo {
  const DecoderInfo({
    required this.name,
    required this.codec,
    required this.hardware,
    required this.maxWidth,
    required this.maxHeight,
    required this.maxFrameRate,
    this.profiles,
  });

  final String name;
  final String codec;
  final bool hardware;
  final int maxWidth;
  final int maxHeight;
  final double maxFrameRate;

  /// The profiles the decoder lists, each with its highest level ("Main 10 L6.1", "Main 10 HDR10 H6.1"), in the order
  /// of the profile constants; null or empty when the system does not tell
  final List<String>? profiles;
}

@HostApi()
abstract class VideoDecoderApi {
  /// Whether the device decodes a video of [codec] (a MIME type such as "video/avc", "video/hevc", "video/av01",
  /// or a sample entry four character code such as "avc1", "hvc1", "hev1", "av01"), [codecs] the RFC 6381 string
  /// when known (profile and level, such as "hvc1.2.4.L153.B0"), of [width] x [height] at [frameRate] frames per
  /// second (0 when unknown), [bitDepth] the bits per luma sample (0 when unknown) and [transferCharacteristics] the
  /// ITU-T H.273 transfer (1 BT.709, 16 PQ, 18 HLG; 0 when unknown), which tell the 10 bit and HDR profiles a decoder
  /// must list when the codecs string is missing, and [instances] the streams of that size to decode at once (2 for
  /// the two lenses of a raw 360° video). Answers from the system's decoder list, corrected by what was measured on
  /// the Meta Quest 3 (H.264 above 4096x2304 drops frames there whatever the list says). Cached per question.
  @async
  DecodeVerdict canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  });

  /// Every video decoder of the device with its limits, for the troubleshooting page.
  @async
  List<DecoderInfo> listDecoders();
}
