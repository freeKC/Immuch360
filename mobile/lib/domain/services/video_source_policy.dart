// Which file of a server video plays: the original, as the camera recorded it, or the stream the server transcoded
// (H.264 at 720p by default), which every device decodes but which is too blurry for a 360° video. The server's
// transcoded stream is the original itself when nothing was transcoded.
//
// The choice follows the setting (VideoSourcePolicy) and, by default, what the device decodes: the probe of the file
// (see probeSphericalMetadata) gives the codec, the frame size and the frame rate, which the native decoder check
// (VideoDecoderApi.canDecode) answers for. Pure Dart: the players read the probe and the verdict, then call
// chooseVideoSource.

import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/viewer_config.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';

extension ViewerConfigVideoSource on ViewerConfig {
  /// Which file the in-app player, the 360° player of phones and the Spatial 2.5D player load: the source the user
  /// picked, else what the former "load the original video" switch said (the original within the device's decoders
  /// when on, the transcoded stream when off). Read here rather than migrated, so that the switch keeps its meaning
  /// until the user picks a source.
  VideoSourcePolicy get videoSourcePolicy =>
      videoSource ??
      (loadOriginalVideo ? VideoSourcePolicy.preferOriginalWithinDecoder : VideoSourcePolicy.alwaysTranscoded);

  /// Which file the immersive viewer of the Meta Quest loads: the source the user picked, else the original within
  /// the decoders of the headset. The immersive viewer always played the original whatever the former switch said, the
  /// transcoded stream being too blurry for 360°, and keeps doing so until the user picks a source.
  VideoSourcePolicy get immersiveVideoSourcePolicy => videoSource ?? VideoSourcePolicy.preferOriginalWithinDecoder;
}

extension VideoSourcePolicyProbe on VideoSourcePolicy {
  /// Whether the choice depends on the file: always the transcoded stream needs no probe, nor any decoder check
  bool get readsTheFile => this != VideoSourcePolicy.alwaysTranscoded;
}

/// The file a player loads
enum VideoSourceKind { original, transcoded }

/// What the user is told about the file chosen
enum VideoSourceNoticeKind {
  /// The transcoded stream plays, the original being beyond what the device decodes
  switched,

  /// The original plays although it is beyond what the device decodes, as the user asked, or as the server has no
  /// transcoded stream of it
  originalForced,
}

/// A message about the file chosen: its [kind], and the original it is about, of [codec] (a name such as "HEVC", see
/// [videoCodecName]) and [width] x [height] pixels
class VideoSourceNotice {
  const VideoSourceNotice(this.kind, {required this.codec, required this.width, required this.height});

  final VideoSourceNoticeKind kind;
  final String codec;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is VideoSourceNotice &&
      other.kind == kind &&
      other.codec == codec &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(kind, codec, width, height);

  @override
  String toString() => 'VideoSourceNotice($kind, $codec $width x $height)';
}

/// The file a player loads ([kind]), whether a native player may switch to the transcoded stream by itself when it
/// cannot play the original ([allowFallback]: its own decoder check at the first frames, or a failure of the
/// original), and what to tell the user, null for nothing.
class VideoSourceChoice {
  const VideoSourceChoice(this.kind, {this.allowFallback = false, this.notice});

  final VideoSourceKind kind;
  final bool allowFallback;
  final VideoSourceNotice? notice;

  @override
  bool operator ==(Object other) =>
      other is VideoSourceChoice &&
      other.kind == kind &&
      other.allowFallback == allowFallback &&
      other.notice == notice;

  @override
  int get hashCode => Object.hash(kind, allowFallback, notice);

  @override
  String toString() => 'VideoSourceChoice($kind, allowFallback: $allowFallback, notice: $notice)';
}

/// Which file of a video plays under [policy], given what its file declares ([probe]) and whether the device decodes
/// it ([verdict], from VideoDecoderApi.canDecode with the probe's codec, size and frame rate; null when the probe or
/// the check gave nothing). [hasTranscode] tells that the server has a transcoded stream to choose: false for a file
/// on the device or on a network share, and for a server video the server did not transcode, whose stream is the
/// original itself. Such a file plays as it is, with a word when the device cannot decode it.
///
/// Without a verdict the original plays, as before the decoder check existed, and the native players keep the
/// transcoded stream at hand: their own check at the first frames can still switch to it.
VideoSourceChoice chooseVideoSource({
  required VideoSourcePolicy policy,
  SphericalProbe? probe,
  DecodeVerdict? verdict,
  required bool hasTranscode,
}) {
  final undecodable = verdict != null && !verdict.supported;
  VideoSourceNotice? notice(VideoSourceNoticeKind kind) {
    final codec = probe?.codec;
    final width = probe?.codedWidth;
    final height = probe?.codedHeight;
    if (codec == null || width == null || height == null) {
      return null;
    }
    return VideoSourceNotice(kind, codec: videoCodecName(codec), width: width, height: height);
  }

  if (!hasTranscode) {
    // Nothing to switch to: telling of a switch would be wrong, telling that it may not play is not
    return VideoSourceChoice(
      VideoSourceKind.original,
      notice: undecodable ? notice(VideoSourceNoticeKind.originalForced) : null,
    );
  }
  return switch (policy) {
    VideoSourcePolicy.alwaysTranscoded => const VideoSourceChoice(VideoSourceKind.transcoded),
    // The user asked for the original whatever happens: no switch behind their back, but a word when it will not play
    VideoSourcePolicy.alwaysOriginal => VideoSourceChoice(
      VideoSourceKind.original,
      notice: undecodable ? notice(VideoSourceNoticeKind.originalForced) : null,
    ),
    VideoSourcePolicy.preferOriginalWithinDecoder when undecodable => VideoSourceChoice(
      VideoSourceKind.transcoded,
      notice: notice(VideoSourceNoticeKind.switched),
    ),
    VideoSourcePolicy.preferOriginalWithinDecoder => const VideoSourceChoice(
      VideoSourceKind.original,
      allowFallback: true,
    ),
  };
}

/// A name for the codec of a video: [codec] is the four character code of its sample entry ("hvc1") or the MIME type
/// of a decoder ("video/hevc"). An unknown codec keeps its code.
String videoCodecName(String codec) => switch (codec.toLowerCase()) {
  'avc1' || 'avc3' || 'video/avc' => 'H.264',
  'hvc1' || 'hev1' || 'video/hevc' => 'HEVC',
  'dvh1' || 'dvhe' || 'video/dolby-vision' => 'Dolby Vision',
  'av01' || 'video/av01' => 'AV1',
  'vp09' || 'video/x-vnd.on2.vp9' => 'VP9',
  'vp08' || 'video/x-vnd.on2.vp8' => 'VP8',
  'mp4v' || 'video/mp4v-es' => 'MPEG-4',
  'video/mpeg2' => 'MPEG-2',
  'video/3gpp' => 'H.263',
  _ => codec,
};

/// A frame rate with two decimals at most, without the trailing zeros: 30, 29.97, 59.94
String formatFrameRate(double frameRate) {
  final rounded = (frameRate * 100).round() / 100;
  return rounded == rounded.roundToDouble() ? rounded.round().toString() : rounded.toString();
}
