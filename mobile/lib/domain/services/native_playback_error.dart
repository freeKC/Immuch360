// The error of a native player in the words of the app: the flat player of Android sends a token for the errors it
// knows (PlaybackErrors.kt and FlatPlayerErrors.kt: "immuch360-playback-error:noFrame:video/avc:5760:2880"), which the
// failure panel puts in a sentence of ours with the codec and the size, never the text of Media3 ("Player stuck playing
// with no progress for 10000 ms", its stuck checks of 1.10). Pure Dart.

import 'package:immich_mobile/domain/services/video_source_policy.dart';

/// What the native player found: a decoder that refused or failed, a decoder full of data that gives no picture, a
/// video the network or the server sends too slowly, or a video that stopped for another reason
enum NativePlaybackErrorKind { decoder, noFrame, stalled, stopped }

/// An error of a native player of [kind], on a video of the MIME type [mime] (null when unknown) and [width] x
/// [height] pixels (0 when unknown)
class NativePlaybackError {
  const NativePlaybackError(this.kind, {this.mime, this.width = 0, this.height = 0});

  /// The start of the token, as PlaybackErrors.TOKEN_PREFIX writes it
  static const prefix = 'immuch360-playback-error:';

  final NativePlaybackErrorKind kind;
  final String? mime;
  final int width;
  final int height;

  /// The name of the codec ("H.264"), null when unknown
  String? get codec {
    final mime = this.mime;
    return mime == null ? null : videoCodecName(mime);
  }

  /// The error [message] tells, null for any other text and for a kind this version does not know
  static NativePlaybackError? parse(String? message) {
    if (message == null || !message.startsWith(prefix)) {
      return null;
    }
    final parts = message.substring(prefix.length).split(':');
    if (parts.length != 4) {
      return null;
    }
    final kind = switch (parts[0]) {
      'decoder' => NativePlaybackErrorKind.decoder,
      'noFrame' => NativePlaybackErrorKind.noFrame,
      'stalled' => NativePlaybackErrorKind.stalled,
      'stopped' => NativePlaybackErrorKind.stopped,
      _ => null,
    };
    if (kind == null) {
      return null;
    }
    return NativePlaybackError(
      kind,
      mime: parts[1].isEmpty ? null : parts[1],
      width: int.tryParse(parts[2]) ?? 0,
      height: int.tryParse(parts[3]) ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NativePlaybackError &&
      other.kind == kind &&
      other.mime == mime &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(kind, mime, width, height);

  @override
  String toString() => 'NativePlaybackError($kind, $mime $width x $height)';
}

/// Whether [message] is the text of a stuck check of Media3 ("Player stuck playing with no progress for 10000 ms"),
/// which never shows: a player that sends it without the token of the app
bool isMedia3StuckText(String message) => message.trimLeft().startsWith('Player stuck ');
