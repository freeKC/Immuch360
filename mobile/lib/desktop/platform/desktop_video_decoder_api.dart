import 'package:flutter/services.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';

/// VideoDecoderApi on the computers, the static answer until the desktop player can probe the machine: the player
/// of the computers decodes through FFmpeg, in hardware when the GPU can and in software otherwise, so every codec is
/// taken as supported up to 8K, and the decoders page lists nothing rather than guessing.
class DesktopVideoDecoderApi implements VideoDecoderApi {
  @override
  // ignore: non_constant_identifier_names
  final BinaryMessenger? pigeonVar_binaryMessenger = null;

  @override
  // ignore: non_constant_identifier_names
  final String pigeonVar_messageChannelSuffix = '';

  static const maxWidth = 8192;
  static const maxHeight = 8192;

  @override
  Future<DecodeVerdict> canDecode(
    String codec,
    String? codecs,
    int width,
    int height,
    double frameRate,
    int bitDepth,
    int transferCharacteristics, {
    int instances = 1,
  }) async {
    final fits = width <= maxWidth && height <= maxHeight;
    return DecodeVerdict(
      supported: fits,
      hardware: false,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      reason: fits ? null : 'Larger than ${maxWidth}x$maxHeight',
    );
  }

  @override
  Future<List<DecoderInfo>> listDecoders() async => const [];
}
