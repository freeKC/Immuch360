// A TIFF of a network share on a device without TIFF decoder (Android, see photoDecodePath): the engine's own
// decoder refuses it ("Invalid image data", and "Failed to create image decoder with message 'invalid input'" in the
// logcat), so the file is read whole through the media bridge and decoded in Dart, in a background isolate.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';

/// Whether the file of the media bridge at [url] is a TIFF this device decodes in Dart: the bridge puts the path of the
/// file in its URL, its name last
bool isDartTiffUrl(Uri url) =>
    photoDecodePath(url.pathSegments.lastOrNull ?? '', fromServer: false) == PhotoDecodePath.dartTiff;

/// The key of the photo of a share at [url] among the photos that did not decode in the session (see
/// UndecodablePhotos): the same for the tile and the page, so that neither reads a file the other could not decode
String undecodableShareKey(Uri url) => 'share:${url.path}';

/// The TIFF of a share at [url] on the media bridge, decoded in Dart at most [maxSide] pixels on its long side, with
/// the progress of its download as chunk events (see TiffDecodingView). One that does not decode fails at once the
/// next times in the session, without reading its file again; a network error is tried again the next time it shows.
class NetworkTiffImage extends ImageProvider<NetworkTiffImage> {
  const NetworkTiffImage(this.url, {required this.maxSide});

  final Uri url;
  final int maxSide;

  static HttpClient? _client;

  @override
  Future<NetworkTiffImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkTiffImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, chunks),
      chunkEvents: chunks.stream,
      scale: 1,
      debugLabel: url.path,
    );
  }

  Future<ui.Codec> _load(NetworkTiffImage key, StreamController<ImageChunkEvent> chunks) async {
    // At once, so that the viewer tells what it does before the first bytes come
    chunks.add(const ImageChunkEvent(cumulativeBytesLoaded: 0, expectedTotalBytes: null));
    try {
      return await loadDartTiff(
        url,
        maxSide: maxSide,
        client: _client ??= HttpClient()..autoUncompress = false,
        onProgress: (loaded, total) {
          if (!chunks.isClosed) {
            chunks.add(ImageChunkEvent(cumulativeBytesLoaded: loaded, expectedTotalBytes: total));
          }
        },
      );
    } catch (_) {
      // The image cache lets the failure go; the session keeps a failure of the decoder (see loadDartTiff)
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      await chunks.close();
    }
  }

  @override
  bool operator ==(Object other) => other is NetworkTiffImage && other.url == url && other.maxSide == maxSide;

  @override
  int get hashCode => Object.hash(url, maxSide);

  @override
  String toString() => 'NetworkTiffImage(${url.path}, maxSide: $maxSide)';
}

/// The TIFF of the media bridge at [url] read whole with [client] ([onProgress] told as its bytes come, then once
/// without a total while it decodes) and decoded in Dart at most [maxSide] pixels on its long side. A TIFF that did not
/// decode in this session fails at once with the same error, its file not read again; one that does not decode now is
/// remembered. A network error is not.
Future<ui.Codec> loadDartTiff(
  Uri url, {
  required int maxSide,
  required HttpClient client,
  void Function(int loaded, int? total)? onProgress,
}) async {
  final key = undecodableShareKey(url);
  final failure = UndecodablePhotos.instance.failureOf(key);
  if (failure != null) {
    throw failure;
  }
  final response = await (await client.getUrl(url)).close();
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw NetworkImageLoadException(statusCode: response.statusCode, uri: url);
  }
  if (response.contentLength > tiffMaxFileBytes) {
    await response.drain<void>();
    const error = TiffDecodeException('the file is larger than this device reads for a TIFF');
    UndecodablePhotos.instance.remember(key, error);
    throw error;
  }
  final bytes = await consolidateHttpClientResponseBytes(
    response,
    onBytesReceived: (loaded, total) => onProgress?.call(loaded, total),
  );
  // Read: the decoder takes the time it takes, no total to show
  onProgress?.call(bytes.length, null);
  try {
    return await codecOfTiffPixels(await decodeTiff(bytes, maxSide: maxSide));
  } on TiffDecodeException catch (error) {
    UndecodablePhotos.instance.remember(key, error);
    rethrow;
  }
}
