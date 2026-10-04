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
  });

  final bool supported;
  final bool hardware;
  final int maxWidth;
  final int maxHeight;
  final String? reason;
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
  });

  final String name;
  final String codec;
  final bool hardware;
  final int maxWidth;
  final int maxHeight;
  final double maxFrameRate;
}

@HostApi()
abstract class VideoDecoderApi {
  /// Whether the device decodes a video of [codec] (a MIME type such as "video/avc", "video/hevc", "video/av01",
  /// or a sample entry four character code such as "avc1", "hvc1", "hev1", "av01"), [codecs] the RFC 6381 string
  /// when known (profile and level, such as "hvc1.2.4.L153.B0"), of [width] x [height] at [frameRate] frames per
  /// second (0 when unknown). Answers from the system's decoder list, corrected by what was measured on the
  /// Meta Quest 3 (H.264 above 4096x2304 drops frames there whatever the list says). Cached per question.
  @async
  DecodeVerdict canDecode(String codec, String? codecs, int width, int height, double frameRate);

  /// Every video decoder of the device with its limits, for the troubleshooting page.
  @async
  List<DecoderInfo> listDecoders();
}
