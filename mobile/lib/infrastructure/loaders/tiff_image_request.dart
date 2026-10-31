part of 'image_request.dart';

/// A TIFF of the device on a device without TIFF decoder (Android, see photoDecodePath): its file comes whole from the
/// platform, encoded, and is decoded in Dart at most [maxSide] pixels on its long side (see decodeTiff). One that does
/// not decode fails at once the next times in the session, its file not read again.
class LocalTiffImageRequest extends ImageRequest {
  LocalTiffImageRequest({required this.localId, required this.maxSide});

  final String localId;
  final int maxSide;

  /// The key of the TIFF [localId] among the photos that did not decode in the session (see UndecodablePhotos)
  static String undecodableKey(String localId) => 'local:$localId';

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }
    final key = undecodableKey(localId);
    final failure = UndecodablePhotos.instance.failureOf(key);
    if (failure != null) {
      throw failure;
    }

    final info = await localImageApi.requestImage(
      localId,
      requestId: requestId,
      width: 0,
      height: 0,
      isVideo: false,
      preferEncoded: true,
    );
    if (info == null) {
      return null;
    }
    final pointer = Pointer<Uint8>.fromAddress(info['pointer']!);
    if (_isCancelled) {
      malloc.free(pointer);
      return null;
    }
    final Future<TiffPixels> decoding;
    try {
      // decodeTiff copies the file for its isolate before it returns: the platform's buffer goes at once
      decoding = decodeTiff(pointer.asTypedList(info['length']!), maxSide: maxSide);
    } finally {
      malloc.free(pointer);
    }

    final TiffPixels pixels;
    try {
      pixels = await decoding;
    } on TiffDecodeException catch (error) {
      UndecodablePhotos.instance.remember(key, error);
      rethrow;
    }
    if (_isCancelled) {
      return null;
    }
    final codec = await codecOfTiffPixels(pixels);
    try {
      final frame = await codec.getNextFrame();
      if (_isCancelled) {
        frame.image.dispose();
        return null;
      }
      return ImageInfo(image: frame.image, scale: scale);
    } finally {
      codec.dispose();
    }
  }

  @override
  Future<ui.Codec?> loadCodec() async => throw UnsupportedError('A TIFF of the device is no animation');

  @override
  Future<void> _onCancelled() {
    return localImageApi.cancelRequest(requestId);
  }
}
