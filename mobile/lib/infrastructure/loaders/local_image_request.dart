part of 'image_request.dart';

/// The long side of a decode on the computers, the texture limit the phones bound their decodes to
const _desktopMaxPixelSize = 16384;

class LocalImageRequest extends ImageRequest {
  final String localId;
  final int width;
  final int height;
  final AssetType assetType;

  LocalImageRequest({required this.localId, required ui.Size size, required this.assetType})
    : width = size.width.toInt(),
      height = size.height.toInt();

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final info = await localImageApi.requestImage(
      localId,
      requestId: requestId,
      width: width,
      height: height,
      isVideo: assetType == AssetType.video,
      preferEncoded: false,
    );
    if (info == null) {
      return null;
    }

    // The computers answer with the encoded file, decoded here at the requested size; the phones decode natively. At
    // most 16384 pixels on the long side, the original too, as Android and iOS decode
    if (info case {'pointer': final int pointer, 'length': final int length}) {
      final encoded = await _fromEncodedPlatformImage(
        pointer,
        length,
        decodeSize: ui.Size(width.toDouble(), height.toDouble()),
        maxLongSide: _desktopMaxPixelSize,
      );
      return encoded == null ? null : ImageInfo(image: encoded.image, scale: scale);
    }

    final frame = await _fromDecodedPlatformImage(info["pointer"]!, info["width"]!, info["height"]!, info["rowBytes"]!);
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final info = await localImageApi.requestImage(
      localId,
      requestId: requestId,
      width: width,
      height: height,
      isVideo: assetType == AssetType.video,
      preferEncoded: true,
    );
    if (info == null) {
      return null;
    }

    final (codec, _) = await _codecFromEncodedPlatformImage(info['pointer']!, info['length']!) ?? (null, null);
    return codec;
  }

  @override
  Future<void> _onCancelled() {
    return localImageApi.cancelRequest(requestId);
  }
}
