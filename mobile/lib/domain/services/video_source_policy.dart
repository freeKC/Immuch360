// Which file of a server video plays: the original, as the camera recorded it, or the stream the server transcoded
// (H.264 at 720p by default, but at whatever codec and size its settings say: H.264 at the original 5760 x 2880 is
// beyond the decoder of a Meta Quest 3). The server's transcoded stream is the original itself when nothing was
// transcoded.
//
// The choice is decodability first (chooseVideoSource), then the setting (VideoSourcePolicy): the probe of each file
// (see probeSphericalMetadata) gives the codec, the frame size and the frame rate, which the native decoder check
// (VideoDecoderApi.canDecode) answers for. Pure Dart: the players read the probes and the verdicts, then call
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
  /// The server's copy plays, the original being beyond what the device decodes
  switched,

  /// The original plays although it is beyond what the device decodes, as the user asked
  originalForced,

  /// The original plays rather than the server's copy the settings ask for, the copy being beyond what the device
  /// decodes: the notice tells of the copy
  originalOverCopy,

  /// The server's copy plays although it is beyond what the device decodes, as the user asked: the notice tells of the
  /// copy
  copyForced,

  /// A file of the device or of a network share is beyond what the device decodes: it plays, and may not
  beyondDecoders,
}

/// A message about the file chosen: its [kind], and the file it is about (the one beyond what the device decodes), of
/// [codec] (a name such as "HEVC", see [videoCodecName]) and [width] x [height] pixels
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

/// Why a server video does not play at all: the file a player would load, of [codec] (a name, see [videoCodecName])
/// and [width] x [height] pixels, is beyond what the device decodes, at most [maxWidth] x [maxHeight] for that codec
/// (0 x 0 when the device has no decoder for it), and the server has nothing the device decodes better. Said at once,
/// rather than a player that tries and stalls.
class VideoSourceRefusal {
  const VideoSourceRefusal({
    required this.codec,
    required this.width,
    required this.height,
    required this.maxWidth,
    required this.maxHeight,
  });

  final String codec;
  final int width;
  final int height;
  final int maxWidth;
  final int maxHeight;

  /// Whether the device has a decoder for the codec, only too small for the frame
  bool get hasDecoder => maxWidth > 0 && maxHeight > 0;

  @override
  bool operator ==(Object other) =>
      other is VideoSourceRefusal &&
      other.codec == codec &&
      other.width == width &&
      other.height == height &&
      other.maxWidth == maxWidth &&
      other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(codec, width, height, maxWidth, maxHeight);

  @override
  String toString() => 'VideoSourceRefusal($codec $width x $height, at most $maxWidth x $maxHeight)';
}

/// The file a player loads ([kind]), whether a native player may switch to the transcoded stream by itself when it
/// cannot play the original ([allowFallback]: its own decoder check at the first frames, or a failure of the
/// original), and what to tell the user, null for nothing. With a [refusal], nothing the server has plays on the
/// device: the player says so at once instead of loading, and [kind] is the file it tries when the user asks to play
/// anyway.
class VideoSourceChoice {
  const VideoSourceChoice(this.kind, {this.allowFallback = false, this.notice, this.refusal});

  final VideoSourceKind kind;
  final bool allowFallback;
  final VideoSourceNotice? notice;
  final VideoSourceRefusal? refusal;

  @override
  bool operator ==(Object other) =>
      other is VideoSourceChoice &&
      other.kind == kind &&
      other.allowFallback == allowFallback &&
      other.notice == notice &&
      other.refusal == refusal;

  @override
  int get hashCode => Object.hash(kind, allowFallback, notice, refusal);

  @override
  String toString() => 'VideoSourceChoice($kind, allowFallback: $allowFallback, notice: $notice, refusal: $refusal)';
}

/// What a player knows of one file it may load, before it plays: the [codec] name of its video track (see
/// [videoCodecName]), its frame size, and whether the device decodes it ([verdict], from VideoDecoderApi.canDecode;
/// null when the probe or the check gave nothing, the file then counting as one that may play).
class VideoCandidate {
  const VideoCandidate({this.codec, this.width, this.height, this.verdict});

  /// The file [probe] describes (null when the probe found nothing), with the [verdict] of the decoder check on it
  factory VideoCandidate.of(SphericalProbe? probe, DecodeVerdict? verdict) {
    final codec = probe?.codec;
    return VideoCandidate(
      codec: codec == null ? null : videoCodecName(codec),
      width: probe?.codedWidth,
      height: probe?.codedHeight,
      verdict: verdict,
    );
  }

  /// A file nothing is known of
  static const unknown = VideoCandidate();

  final String? codec;
  final int? width;
  final int? height;
  final DecodeVerdict? verdict;

  /// The decoder check says the device cannot decode it: a file it did not answer for may play
  bool get undecodable => verdict?.supported == false;

  /// The notice of [kind] about this file, null when its codec or its size is unknown
  VideoSourceNotice? notice(VideoSourceNoticeKind kind) {
    final codec = this.codec;
    final width = this.width;
    final height = this.height;
    if (codec == null || width == null || height == null) {
      return null;
    }
    return VideoSourceNotice(kind, codec: codec, width: width, height: height);
  }

  /// Why this file does not play, null when it may (see [undecodable]) or its codec or size is unknown
  VideoSourceRefusal? get refusal {
    final codec = this.codec;
    final width = this.width;
    final height = this.height;
    final verdict = this.verdict;
    if (!undecodable || codec == null || width == null || height == null || verdict == null) {
      return null;
    }
    return VideoSourceRefusal(
      codec: codec,
      width: width,
      height: height,
      maxWidth: verdict.maxWidth,
      maxHeight: verdict.maxHeight,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoCandidate &&
      other.codec == codec &&
      other.width == width &&
      other.height == height &&
      other.verdict?.supported == verdict?.supported &&
      other.verdict?.maxWidth == verdict?.maxWidth &&
      other.verdict?.maxHeight == verdict?.maxHeight;

  @override
  int get hashCode => Object.hash(codec, width, height, verdict?.supported, verdict?.maxWidth, verdict?.maxHeight);

  @override
  String toString() => 'VideoCandidate($codec $width x $height, decodes: ${verdict?.supported})';
}

/// Which file of a video plays, decodability first: the shared rule of the in-app player and of the immersive viewer
/// of the Meta Quest (see VideoSourceService.serverSource; the viewer's start choice in Kotlin, VideoStartRule, only
/// decides how the file chosen here reaches the decoder).
///
/// [original] is what is known of the original and [copy] of the server's transcoded stream; [copy] is null when the
/// server has none (it transcoded nothing: its playback stream is the original itself) and for a file of the device or
/// of a network share ([fromServer] false), which plays as it is. Each comes with the verdict of the device's own
/// decoder check (its decoder list, and on a Meta Quest what was measured there): a phone, a TV and a headset each
/// keep their limits, and a file without a verdict counts as one that may play, as before the check existed.
///
/// * A file the device decodes beats one it cannot, whatever [policy] prefers: the server's copy when the original is
///   beyond the decoders, the original when the copy is (a server transcoding at the original size in H.264, which a
///   Quest 3 cannot decode above 4096 x 2304, while it decodes the HEVC original). The notice says so.
/// * When nothing the server has is decodable, the choice carries a [VideoSourceChoice.refusal]: the player says at
///   once which file it is and what to change in Immich, rather than trying for seconds.
/// * Between files that may both play, [policy] decides: the original (preferOriginalWithinDecoder, alwaysOriginal) or
///   the copy (alwaysTranscoded).
/// * The user may still force a file: [forced], from the details of the video, and [VideoSourcePolicy.alwaysOriginal],
///   which plays the original whatever happens. A forced file plays with a word when it is beyond the decoders.
/// * A native player may switch from the original to the copy by itself ([VideoSourceChoice.allowFallback]) only
///   under preferOriginalWithinDecoder, and never to a copy beyond the decoders.
VideoSourceChoice chooseVideoSource({
  required VideoSourcePolicy policy,
  VideoCandidate original = VideoCandidate.unknown,
  VideoCandidate? copy,
  bool fromServer = true,
  VideoSourceKind? forced,
}) {
  if (!fromServer) {
    return VideoSourceChoice(.original, notice: original.undecodable ? original.notice(.beyondDecoders) : null);
  }
  final forcedKind = forced ?? (policy == VideoSourcePolicy.alwaysOriginal ? VideoSourceKind.original : null);
  if (forcedKind == VideoSourceKind.transcoded && copy != null) {
    return VideoSourceChoice(.transcoded, notice: copy.undecodable ? copy.notice(.copyForced) : null);
  }
  if (forcedKind != null) {
    // The original, or the copy of a server that has none, which is the original again
    return VideoSourceChoice(.original, notice: original.undecodable ? original.notice(.originalForced) : null);
  }
  if (copy == null) {
    final refusal = original.refusal;
    return refusal != null ? VideoSourceChoice(.original, refusal: refusal) : const VideoSourceChoice(.original);
  }
  final prefersCopy = policy == VideoSourcePolicy.alwaysTranscoded;
  final preferred = prefersCopy ? copy : original;
  final other = prefersCopy ? original : copy;
  if (!preferred.undecodable) {
    return prefersCopy
        ? const VideoSourceChoice(.transcoded)
        : VideoSourceChoice(.original, allowFallback: !copy.undecodable);
  }
  if (!other.undecodable) {
    return prefersCopy
        ? VideoSourceChoice(.original, notice: copy.notice(.originalOverCopy))
        : VideoSourceChoice(.transcoded, notice: original.notice(.switched));
  }
  // Nothing plays: the copy is what the server's settings change
  final refusal = copy.refusal ?? original.refusal;
  return VideoSourceChoice(.transcoded, refusal: refusal);
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
