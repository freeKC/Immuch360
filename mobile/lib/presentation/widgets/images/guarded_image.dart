// The encoded images that do not come through the image loaders of the app (ImageRequest): the files of a share and
// the pictures of its media server, a file opened from another app or shared to the app, the picture of a camera, a
// poster the app draws. Each is decoded where encodedImageRoute says: on Android, the formats of the engine's own
// codecs by the engine, as before; HEIF, AVIF, the raw files and the unknown by the native decoder at a bounded size
// (NativeImageDecodeApi); a TIFF named so by the Dart TIFF decoder; text, videos and empty files refused. So no buffer
// reaches the fallback decoder of the engine, which decodes at the full size and aborts the app on an OutOfMemoryError
// (crash M1 of the Meta Quest store, 8 November 2026). Off Android the engine decodes every buffer, as before. A
// failure is an ImageDecodeException, which the viewers show as a photo that does not decode, and remember for the
// session when they give a key (see UndecodablePhotos).

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('GuardedImage');

/// The long side of the largest texture the phones decode to (MAX_PIXEL_SIZE of the Android side)
const guardedImageMaxSide = 16384;

/// The native decoder of Android (NativeImageDecodeApi); the tests put a fake in its place
NativeImageDecodeApi nativeImageDecodeApi = NativeImageDecodeApi();

/// The size the engine decodes an image at to fit in [maxWidth] x [maxHeight] (0 or less for no bound on that side),
/// never larger than the image, its aspect ratio kept: the rule of ResizeImage with ResizeImagePolicy.fit
ui.TargetImageSizeCallback fitTargetSize(int maxWidth, int maxHeight) => (width, height) {
  if (width <= 0 || height <= 0) {
    return const ui.TargetImageSize();
  }
  final aspectRatio = width / height;
  final boundWidth = maxWidth > 0 ? maxWidth : width;
  final boundHeight = maxHeight > 0 ? maxHeight : height;
  var targetWidth = width;
  var targetHeight = height;
  if (targetWidth > boundWidth) {
    targetWidth = boundWidth;
    targetHeight = targetWidth ~/ aspectRatio;
  }
  if (targetHeight > boundHeight) {
    targetHeight = boundHeight;
    targetWidth = (targetHeight * aspectRatio).floor();
  }
  return ui.TargetImageSize(width: targetWidth, height: targetHeight);
};

/// [bytes], an encoded image, decoded where encodedImageRoute says: by the engine through [decode] (the image
/// decoder of a provider, or the engine's own), at the size [getTargetSize] tells or else within [maxWidth] x
/// [maxHeight] (0 for no bound on a side); by the native decoder of Android within the same bounds; by the Dart TIFF
/// decoder for a TIFF whose [name] or [mimeType] says so. Throws an [ImageDecodeException] for bytes that are no image
/// of this device or that the native decoder did not decode, a TiffDecodeException for a TIFF that did not decode.
/// [source] names the caller in the logs.
Future<ui.Codec> decodeEncodedBytes(
  Uint8List bytes, {
  required int maxWidth,
  required int maxHeight,
  required String source,
  ImageDecoderCallback decode = ui.instantiateImageCodecWithSize,
  ui.TargetImageSizeCallback? getTargetSize,
  String? name,
  String? mimeType,
}) async {
  final kind = sniffEncodedImage(bytes);
  switch (encodedImageRoute(kind, name: name, mimeType: mimeType)) {
    case EncodedImageRoute.engine:
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      return decode(buffer, getTargetSize: getTargetSize ?? fitTargetSize(maxWidth, maxHeight));
    case EncodedImageRoute.native:
      final pointer = malloc<Uint8>(math.max(1, bytes.length));
      try {
        pointer.asTypedList(bytes.length).setAll(0, bytes);
        return await _decodeNatively(pointer, bytes.length, kind, maxWidth, maxHeight, source);
      } finally {
        malloc.free(pointer);
      }
    case EncodedImageRoute.dartTiff:
      final longSide = math.max(maxWidth, maxHeight);
      final maxSide = longSide > 0
          ? math.min(longSide, TiffBudget.current.maxViewerSide)
          : TiffBudget.current.maxViewerSide;
      return codecOfTiffPixels(await inTiffTurn(() => decodeTiffNow(bytes, maxSide: maxSide)));
    case EncodedImageRoute.refuse:
      _log.warning('Not decoded ($source): ${kind.name}, ${bytes.length} bytes, no image of this device');
      throw ImageDecodeException(UnsupportedEncodedImage(kind, bytes.length));
  }
}

/// The encoded image in the file at [path], decoded as [decodeEncodedBytes] does: the formats of the engine straight
/// from the file, as FileImage reads it; the others read whole first, unless refused by their first bytes
Future<ui.Codec> decodeEncodedFile(
  String path, {
  required int maxWidth,
  required int maxHeight,
  required String source,
  ImageDecoderCallback decode = ui.instantiateImageCodecWithSize,
  ui.TargetImageSizeCallback? getTargetSize,
}) async {
  final file = File(path);
  final Uint8List head;
  final handle = await file.open();
  try {
    head = await handle.read(encodedImageProbeLength);
  } finally {
    await handle.close();
  }
  final name = p.basename(path);
  final kind = sniffEncodedImage(head);
  final route = encodedImageRoute(kind, name: name);
  if (route == EncodedImageRoute.engine) {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    return decode(buffer, getTargetSize: getTargetSize ?? fitTargetSize(maxWidth, maxHeight));
  }
  if (route == EncodedImageRoute.refuse) {
    _log.warning('Not decoded ($source): ${kind.name}, $name, no image of this device');
    throw ImageDecodeException(UnsupportedEncodedImage(kind, head.length));
  }
  return decodeEncodedBytes(
    await file.readAsBytes(),
    maxWidth: maxWidth,
    maxHeight: maxHeight,
    source: source,
    decode: decode,
    getTargetSize: getTargetSize,
    name: name,
  );
}

// The encoded image of [length] bytes at [pointer] (the caller's) decoded by the native decoder: a codec of a frame
Future<ui.Codec> _decodeNatively(
  Pointer<Uint8> pointer,
  int length,
  EncodedImageKind kind,
  int maxWidth,
  int maxHeight,
  String source,
) async {
  final Map<String, int> info;
  try {
    info = await nativeImageDecodeApi.decodeEncoded(
      pointer.address,
      length,
      math.max(0, maxWidth),
      math.max(0, maxHeight),
    );
  } on PlatformException catch (error) {
    // An OutOfMemoryError of the native decoder included: the bytes came, the same next time
    _log.warning('Not decoded ($source): ${kind.name}, $length bytes, ${error.code}: ${error.message}');
    throw ImageDecodeException(error);
  }
  final pixels = Pointer<Uint8>.fromAddress(info['pointer']!);
  final width = info['width']!;
  final height = info['height']!;
  final rowBytes = info['rowBytes']!;
  final ui.ImmutableBuffer buffer;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(pixels.asTypedList(rowBytes * height));
  } finally {
    malloc.free(pixels);
  }
  _log.info('Decoded natively ($source): ${kind.name}, $length bytes, ${width}x$height');
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    rowBytes: rowBytes,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  buffer.dispose();
  // The codec reads the pixels of the descriptor when its frame is asked for, later: the descriptor goes with it
  return descriptor.instantiateCodec();
}

/// Remembers for the session that the photo [key] did not decode, when [error] says its bytes are the reason
void _rememberUndecodable(String? key, Object error) {
  if (key != null && error is Exception && (error is ImageDecodeException || error is TiffDecodeException)) {
    UndecodablePhotos.instance.remember(key, error);
  }
}

/// An encoded image in memory, as MemoryImage, decoded as [decodeEncodedBytes] does within [maxWidth] x [maxHeight].
/// Known to the image cache by the identity of its [bytes], as MemoryImage is.
@immutable
class GuardedMemoryImage extends ImageProvider<GuardedMemoryImage> {
  const GuardedMemoryImage(
    this.bytes, {
    required this.source,
    this.maxWidth = guardedImageMaxSide,
    this.maxHeight = guardedImageMaxSide,
  });

  final Uint8List bytes;
  final String source;
  final int maxWidth;
  final int maxHeight;

  @override
  Future<GuardedMemoryImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GuardedMemoryImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: decodeEncodedBytes(
          key.bytes,
          maxWidth: key.maxWidth,
          maxHeight: key.maxHeight,
          source: key.source,
          decode: decode,
        ),
        scale: 1,
        debugLabel: 'GuardedMemoryImage(${describeIdentity(key.bytes)})',
      );

  @override
  bool operator ==(Object other) =>
      other is GuardedMemoryImage &&
      identical(other.bytes, bytes) &&
      other.maxWidth == maxWidth &&
      other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(identityHashCode(bytes), maxWidth, maxHeight);

  @override
  String toString() => 'GuardedMemoryImage(${describeIdentity(bytes)}, $source, ${maxWidth}x$maxHeight)';
}

/// The encoded image in the file at [path], as FileImage, decoded as [decodeEncodedFile] does within [maxWidth] x
/// [maxHeight]. One that does not decode is remembered for the session under [undecodableKey], when given.
@immutable
class GuardedFileImage extends ImageProvider<GuardedFileImage> {
  const GuardedFileImage(
    this.path, {
    required this.source,
    this.maxWidth = guardedImageMaxSide,
    this.maxHeight = guardedImageMaxSide,
    this.undecodableKey,
  });

  final String path;
  final String source;
  final int maxWidth;
  final int maxHeight;
  final String? undecodableKey;

  @override
  Future<GuardedFileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GuardedFileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(key, decode), scale: 1, debugLabel: path);

  Future<ui.Codec> _load(GuardedFileImage key, ImageDecoderCallback decode) async {
    final undecodable = undecodableKey;
    final failure = undecodable == null ? null : UndecodablePhotos.instance.failureOf(undecodable);
    if (failure != null) {
      throw failure;
    }
    try {
      return await decodeEncodedFile(path, maxWidth: maxWidth, maxHeight: maxHeight, source: source, decode: decode);
    } catch (error) {
      _rememberUndecodable(undecodable, error);
      // Loaded again the next time it is shown, unless it did not decode (see above)
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GuardedFileImage && other.path == path && other.maxWidth == maxWidth && other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(path, maxWidth, maxHeight);

  @override
  String toString() => 'GuardedFileImage($path, $source, ${maxWidth}x$maxHeight)';
}

/// The encoded image at [url], as NetworkImage (its download told as chunk events), decoded as [decodeEncodedBytes]
/// does within [maxWidth] x [maxHeight]: the name of the file, last in the URL, tells a TIFF. One that does not decode
/// is remembered for the session under [undecodableKey], when given, and fails at once the next times, without a
/// download; a network error is not.
@immutable
class GuardedNetworkImage extends ImageProvider<GuardedNetworkImage> {
  const GuardedNetworkImage(
    this.url, {
    required this.source,
    required this.maxWidth,
    required this.maxHeight,
    this.undecodableKey,
  });

  final String url;
  final String source;
  final int maxWidth;
  final int maxHeight;
  final String? undecodableKey;

  // Without automatic decompression, so that Content-Length can be trusted, as NetworkImage does
  static HttpClient? _client;

  @override
  Future<GuardedNetworkImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(GuardedNetworkImage key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode, chunkEvents),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(
    GuardedNetworkImage key,
    ImageDecoderCallback decode,
    StreamController<ImageChunkEvent> chunkEvents,
  ) async {
    final undecodable = undecodableKey;
    try {
      final failure = undecodable == null ? null : UndecodablePhotos.instance.failureOf(undecodable);
      if (failure != null) {
        throw failure;
      }
      final uri = Uri.base.resolve(url);
      final request = await (_client ??= HttpClient()..autoUncompress = false).getUrl(uri);
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
      }
      final bytes = await consolidateHttpClientResponseBytes(
        response,
        onBytesReceived: (cumulative, total) {
          if (!chunkEvents.isClosed) {
            chunkEvents.add(ImageChunkEvent(cumulativeBytesLoaded: cumulative, expectedTotalBytes: total));
          }
        },
      );
      if (bytes.isEmpty) {
        throw NetworkImageLoadException(statusCode: response.statusCode, uri: uri);
      }
      try {
        return await decodeEncodedBytes(
          bytes,
          maxWidth: maxWidth,
          maxHeight: maxHeight,
          source: source,
          decode: decode,
          name: uri.pathSegments.lastOrNull,
        );
      } catch (error) {
        _rememberUndecodable(undecodable, error);
        rethrow;
      }
    } catch (_) {
      // Loaded again the next time it is shown, unless it did not decode (see above)
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      rethrow;
    } finally {
      unawaited(chunkEvents.close());
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GuardedNetworkImage && other.url == url && other.maxWidth == maxWidth && other.maxHeight == maxHeight;

  @override
  int get hashCode => Object.hash(url, maxWidth, maxHeight);

  @override
  String toString() => 'GuardedNetworkImage($url, $source, ${maxWidth}x$maxHeight)';
}
