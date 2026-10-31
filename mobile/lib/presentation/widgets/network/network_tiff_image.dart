// A TIFF of a network share on a device without TIFF decoder (Android, see photoDecodePath): the engine's own
// decoder refuses it ("Invalid image data", and "Failed to create image decoder with message 'invalid input'" in the
// logcat), so the file is read whole through the media bridge and decoded in Dart, in a background isolate.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/presentation/widgets/images/tiff_image_completer.dart';

/// Whether the file of the media bridge at [url] is a TIFF this device decodes in Dart: the bridge puts the path of the
/// file in its URL, its name last; [mimeType] is the type its share gives it, when it gives one
bool isDartTiffUrl(Uri url, {String? mimeType}) =>
    photoDecodePath(url.pathSegments.lastOrNull ?? '', mimeType: mimeType, fromServer: false) ==
    PhotoDecodePath.dartTiff;

/// The key of the photo of a share at [url] among the photos that did not decode in the session (see
/// UndecodablePhotos): the same for the tile and the page, so that neither reads a file the other could not decode
String undecodableShareKey(Uri url) => 'share:${url.path}';

/// The TIFF of a share at [url] on the media bridge, decoded in Dart at most [maxSide] pixels on its long side, with
/// the progress of its download as chunk events (see TiffDecodingView). [size] is the size its share gives, when known:
/// a file larger than the device reads is refused before it is read. Its download stops and its decode is skipped once
/// no widget wants it (see TiffImageStreamCompleter). One that does not decode fails at once the next times in the
/// session, without reading its file again; a network error is tried again the next time it shows.
class NetworkTiffImage extends ImageProvider<NetworkTiffImage> {
  const NetworkTiffImage(this.url, {required this.maxSide, this.size, this.work = TiffWork.viewer});

  final Uri url;
  final int maxSide;
  final int? size;

  /// The page of a photo, or a tile: the page goes first (see inTiffTurn)
  final TiffWork work;

  static HttpClient? _client;

  @override
  Future<NetworkTiffImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(NetworkTiffImage key, ImageDecoderCallback decode) {
    final chunks = StreamController<ImageChunkEvent>();
    return TiffImageStreamCompleter.load(
      key,
      (cancel) => _load(key, chunks, cancel),
      chunkEvents: chunks.stream,
      debugLabel: url.path,
    );
  }

  Future<ui.Codec> _load(NetworkTiffImage key, StreamController<ImageChunkEvent> chunks, TiffCancel cancel) async {
    // At once, so that the viewer tells what it does before the first bytes come
    chunks.add(const ImageChunkEvent(cumulativeBytesLoaded: 0, expectedTotalBytes: null));
    try {
      return await loadDartTiff(
        url,
        maxSide: maxSide,
        client: _client ??= HttpClient()..autoUncompress = false,
        size: size,
        work: work,
        cancel: cancel,
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
  bool operator ==(Object other) =>
      other is NetworkTiffImage && other.url == url && other.maxSide == maxSide && other.work == work;

  @override
  int get hashCode => Object.hash(url, maxSide, work);

  @override
  String toString() => 'NetworkTiffImage(${url.path}, maxSide: $maxSide)';
}

/// The TIFF of the media bridge at [url] read whole with [client] when the turn of the decoder comes ([work], see
/// inTiffTurn; [onProgress] told as its bytes come, then once without a total while it decodes) and decoded in Dart at
/// most [maxSide] pixels on its long side. A TIFF that did not decode in this session fails at once with the same
/// error, its file not read again; one that does not decode now, or that is larger than the device reads ([size], the
/// one its share gives, its Content-Length, or the bytes that come), is remembered. A network error is not. [cancel]
/// stops the download and skips the decode.
Future<ui.Codec> loadDartTiff(
  Uri url, {
  required int maxSide,
  required HttpClient client,
  int? size,
  TiffWork work = TiffWork.viewer,
  TiffCancel? cancel,
  void Function(int loaded, int? total)? onProgress,
}) async {
  final key = undecodableShareKey(url);
  final failure = UndecodablePhotos.instance.failureOf(key);
  if (failure != null) {
    throw failure;
  }
  try {
    if (size != null) {
      checkTiffFileLength(size);
    }
    final pixels = await decodeTiff(
      () => readShareTiff(url, client: client, cancel: cancel, onProgress: onProgress),
      maxSide: maxSide,
      work: work,
      cancel: cancel,
    );
    return await codecOfTiffPixels(pixels);
  } on TiffDecodeException catch (error) {
    UndecodablePhotos.instance.remember(key, error);
    rethrow;
  }
}

/// The whole TIFF of the media bridge at [url], read with [client], at most as many bytes as the device reads for a
/// TIFF: a [TiffDecodeException] once more come, or when its Content-Length says so. [cancel] stops the download.
Future<Uint8List> readShareTiff(
  Uri url, {
  required HttpClient client,
  TiffCancel? cancel,
  void Function(int loaded, int? total)? onProgress,
}) async {
  final request = await client.getUrl(url);
  cancel?.onCancel(() => request.abort(const TiffDecodeCancelled()));
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    request.abort();
    throw NetworkImageLoadException(statusCode: response.statusCode, uri: url);
  }
  final total = response.contentLength >= 0 ? response.contentLength : null;
  if (total != null && total > TiffBudget.current.maxFileBytes) {
    request.abort();
    checkTiffFileLength(total);
  }
  final bytes = BytesBuilder(copy: false);
  try {
    await for (final chunk in response) {
      bytes.add(chunk);
      if (bytes.length > TiffBudget.current.maxFileBytes) {
        request.abort();
        checkTiffFileLength(bytes.length);
      }
      onProgress?.call(bytes.length, total);
    }
  } catch (_) {
    if (cancel?.isCancelled ?? false) {
      throw const TiffDecodeCancelled();
    }
    rethrow;
  }
  // Read: the decoder takes the time it takes, no total to show
  onProgress?.call(bytes.length, null);
  return bytes.takeBytes();
}
