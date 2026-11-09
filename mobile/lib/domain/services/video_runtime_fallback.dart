// What a server video plays after the device's decoder refused, while it played, a file its decoder check accepted:
// the server's other file, once, when it may do better (a TV, 8 November 2026: "This device cannot decode this video
// (HEVC 5760 x 2880)" although the check said it decodes). The in-app player asks it through
// VideoSourceService.serverSource, after chooseVideoSource, which stays the shared rule of the players before they
// load. Pure Dart.

import 'package:immich_mobile/domain/services/native_playback_error.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';

/// Whether [error] is a decoder that refused the video or gave no picture for it: what the server's other file may get
/// past. A video the network brings too slowly, one that stopped for another reason, and a text that is not a token of
/// the app (iOS, the computers) are not.
bool isDecoderRefusal(NativePlaybackError? error) => switch (error?.kind) {
  NativePlaybackErrorKind.decoder || NativePlaybackErrorKind.noFrame => true,
  _ => false,
};

/// What [runtimeFallback] decided: the file to play next ([next], null when the refused file stays), what to tell the
/// user about the switch ([notice], null without a switch or when the codec or the size of the refused file is
/// unknown), the server's copy beyond the decoders when that is why nothing switches ([copyBeyondDecoders]), and why,
/// in words for the logs ([reason]).
class RuntimeFallback {
  const RuntimeFallback({this.next, this.notice, this.copyBeyondDecoders, required this.reason});

  final VideoSourceKind? next;
  final VideoSourceNotice? notice;
  final VideoSourceRefusal? copyBeyondDecoders;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is RuntimeFallback &&
      other.next == next &&
      other.notice == notice &&
      other.copyBeyondDecoders == copyBeyondDecoders &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(next, notice, copyBeyondDecoders, reason);

  @override
  String toString() =>
      'RuntimeFallback(${next ?? 'no switch'}, $reason${notice != null ? ', $notice' : ''}'
      '${copyBeyondDecoders != null ? ', copy: $copyBeyondDecoders' : ''})';
}

/// The file of a server video to play after the device's decoder refused the file [refused] while it played ([error],
/// a decoder or noFrame token, see [isDecoderRefusal]). [original] and [copy] are what is known of the two files, each
/// with the verdict of the decoder check; [copy] is null when the server has no copy of its own (its playback stream
/// is the original itself). [forced]: the file was forced in the details, or the policy is "Always the original".
/// [refusedBefore]: the files of this video the decoder refused earlier in the session. [originalStreams]: the server
/// streams the original, rather than a download of it whole before it plays.
///
/// * A forced file never switches: it plays whatever happens, as chooseVideoSource documents.
/// * Nothing switches to a file the server does not have, nor to a file refused already.
/// * After a refused original, the copy plays, unless the decoder check says it is beyond the decoders too (the result
///   then carries its refusal, for the failure panel) or it has the same codec at a frame at least as large (the
///   decoder that just refused that format would refuse it again: a server transcoding HEVC at the original size). An
///   unknown copy is tried: it is the server's playback stream, usually small and streamable.
/// * After a refused copy, the original plays only when its verdict says it decodes, it streams, and it is not the
///   same format at a frame at least as large: an original may weigh several GB.
///
/// The codec and the size of the refused file come from [error] first, which is what the decoder saw, else from its
/// probe; the notice is about that file.
RuntimeFallback runtimeFallback({
  required VideoSourceKind refused,
  required NativePlaybackError error,
  required VideoCandidate original,
  required VideoCandidate? copy,
  bool forced = false,
  Set<VideoSourceKind> refusedBefore = const {},
  bool originalStreams = true,
}) {
  if (forced) {
    return const RuntimeFallback(reason: 'the file was forced: it plays whatever happens');
  }
  if (copy == null) {
    return const RuntimeFallback(reason: 'the server has no copy of its own: its playback stream is the original');
  }
  final other = refused == VideoSourceKind.original ? VideoSourceKind.transcoded : VideoSourceKind.original;
  if (refusedBefore.contains(other)) {
    return const RuntimeFallback(reason: 'the decoder refused the other file too earlier in this session');
  }
  final seen = _seen(error, refused == VideoSourceKind.original ? original : copy);
  if (refused == VideoSourceKind.original) {
    if (copy.undecodable) {
      return RuntimeFallback(
        copyBeyondDecoders: copy.refusal,
        reason: "the server's copy is beyond the decoders of this device too",
      );
    }
    if (_sameFormatAtLeastAsLarge(copy, seen)) {
      return const RuntimeFallback(
        reason: "the server's copy has the same codec at a frame at least as large: the decoder would refuse it too",
      );
    }
    return RuntimeFallback(
      next: VideoSourceKind.transcoded,
      notice: seen.notice(VideoSourceNoticeKind.copyAfterRefusal),
      reason: "the decoder refused the original while it played: the server's copy plays",
    );
  }
  if (original.verdict?.supported != true) {
    return const RuntimeFallback(reason: 'the original is not known to be within the decoders of this device');
  }
  if (!originalStreams) {
    return const RuntimeFallback(reason: 'the server cannot stream the original: it would download whole first');
  }
  if (_sameFormatAtLeastAsLarge(original, seen)) {
    return const RuntimeFallback(
      reason: 'the original has the same codec at a frame at least as large: the decoder would refuse it too',
    );
  }
  return RuntimeFallback(
    next: VideoSourceKind.original,
    notice: seen.notice(VideoSourceNoticeKind.originalAfterRefusal),
    reason: "the decoder refused the server's copy while it played: the original plays",
  );
}

// The refused file as the decoder saw it: the codec and the size of [error] when it tells them, else of [file]
VideoCandidate _seen(NativePlaybackError error, VideoCandidate file) {
  final sized = error.width > 0 && error.height > 0;
  return VideoCandidate(
    codec: error.codec ?? file.codec,
    width: sized ? error.width : file.width,
    height: sized ? error.height : file.height,
  );
}

// Whether [candidate] has the codec of [refused] at a frame at least as large, long side and short side (a copy may
// store a portrait video turned): false when a codec or a size is unknown, the file then being worth a try
bool _sameFormatAtLeastAsLarge(VideoCandidate candidate, VideoCandidate refused) {
  final codec = candidate.codec;
  final width = candidate.width;
  final height = candidate.height;
  final refusedWidth = refused.width;
  final refusedHeight = refused.height;
  if (codec == null || width == null || height == null || refusedWidth == null || refusedHeight == null) {
    return false;
  }
  if (codec != refused.codec) {
    return false;
  }
  final longSide = width > height ? width : height;
  final shortSide = width > height ? height : width;
  final refusedLongSide = refusedWidth > refusedHeight ? refusedWidth : refusedHeight;
  final refusedShortSide = refusedWidth > refusedHeight ? refusedHeight : refusedWidth;
  return longSide >= refusedLongSide && shortSide >= refusedShortSide;
}
