part of 'image_request.dart';

/// A TIFF of the device on a device without TIFF decoder (Android, see photoDecodePath): its file comes whole from the
/// platform, encoded, when the turn of the decoder comes ([work], see inTiffTurn), and is decoded in Dart at most
/// [maxSide] pixels on its long side (see decodeTiffNow). Cancelled while it waits, it never reads the file. One that
/// does not decode, or whose file is larger than the device reads, fails at once the next times in the session, its
/// file not read again.
class LocalTiffImageRequest extends ImageRequest {
  LocalTiffImageRequest({required this.localId, required this.maxSide, this.work = TiffWork.viewer});

  final String localId;
  final int maxSide;
  final TiffWork work;
  final _cancel = TiffCancel();

  /// The key of the TIFF [localId] among the photos that did not decode in the session (see UndecodablePhotos)
  static String undecodableKey(String localId) => 'local:$localId';

  /// The errors of the platform that tell the file itself is the reason, as a decoder failure would: it is larger than
  /// the device reads at once, or it did not fit in memory (see LocalImagesImpl.getEncodedImageInternal)
  static const _fileErrors = {'EncodedImageTooLargeException', 'OutOfMemoryError'};

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

    final TiffPixels? pixels;
    try {
      pixels = await inTiffTurn(_readAndDecode, work: work, cancel: _cancel);
    } on TiffDecodeCancelled {
      return null;
    } on TiffDecodeException catch (error) {
      UndecodablePhotos.instance.remember(key, error);
      rethrow;
    }
    if (pixels == null || _isCancelled) {
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

  // In the turn of the decoder: the file, then its decode; null when cancelled meanwhile
  Future<TiffPixels?> _readAndDecode() async {
    final Map<String, int>? info;
    try {
      info = await localImageApi.requestImage(
        localId,
        requestId: requestId,
        width: 0,
        height: 0,
        isVideo: false,
        preferEncoded: true,
      );
    } on PlatformException catch (error) {
      if (_fileErrors.contains(error.code)) {
        throw TiffDecodeException('${error.code}: ${error.message}');
      }
      rethrow;
    }
    if (info == null) {
      return null;
    }
    final pointer = Pointer<Uint8>.fromAddress(info['pointer']!);
    final Future<TiffPixels> decoding;
    try {
      if (_isCancelled) {
        return null;
      }
      // decodeTiffNow copies the file for its isolate before it returns: the platform's buffer goes at once
      decoding = decodeTiffNow(pointer.asTypedList(info['length']!), maxSide: maxSide);
    } finally {
      malloc.free(pointer);
    }
    return decoding;
  }

  @override
  Future<ui.Codec?> loadCodec() async => throw UnsupportedError('A TIFF of the device is no animation');

  @override
  Future<void> _onCancelled() {
    // Out of the queue of the decoder at once when it waits there
    _cancel.cancel();
    return localImageApi.cancelRequest(requestId);
  }
}
