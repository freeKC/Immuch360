import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/core_image_decoder.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';

part 'local_image_request.dart';
part 'remote_image_request.dart';
part 'thumbhash_image_request.dart';
part 'tiff_image_request.dart';

/// An image whose bytes were read and that the engine did not decode ([cause]): reading them again would give the same,
/// so its viewers remember it for the session (see UndecodablePhotos)
class ImageDecodeException implements Exception {
  const ImageDecodeException(this.cause);

  final Object cause;

  @override
  String toString() => 'ImageDecodeException: $cause';
}

/// The code of the error of the platform for a photo its native decoder did not decode, an OutOfMemoryError included
/// (UNDECODABLE_IMAGE of NativeImageDecodeImpl.kt): its bytes came, so it is an [ImageDecodeException]
const undecodableImageCode = 'UndecodableImage';

/// A codec of one frame holding [pixels], a TIFF decoded in Dart (see decodeTiff)
Future<ui.Codec> codecOfTiffPixels(TiffPixels pixels) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels.rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: pixels.width,
    height: pixels.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  buffer.dispose();
  // The codec reads the pixels of the descriptor when its frame is asked for, later: the descriptor goes with it
  return descriptor.instantiateCodec();
}

abstract class ImageRequest {
  static int _nextRequestId = 0;

  /// What makes the engine's descriptor of encoded bytes, ImageDescriptor.encoded; the tests count its calls
  @visibleForTesting
  static Future<ui.ImageDescriptor> Function(ui.ImmutableBuffer buffer) describeEncoded = ui.ImageDescriptor.encoded;

  /// What frees a buffer of the platform, malloc's free; the tests count its calls
  @visibleForTesting
  static void Function(Pointer<Uint8> pointer) freePlatformBuffer = malloc.free;

  final int requestId = _nextRequestId++;
  bool _isCancelled = false;

  /// The decode of the Rust core in progress (JPEG XL on the computers), stopped by [cancel]
  CoreDecodeHandle? _coreDecode;

  // ignore: unused-code
  bool get isCancelled => _isCancelled;

  ImageRequest();

  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0});

  Future<ui.Codec?> loadCodec();

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _coreDecode?.stop();
    return _onCancelled();
  }

  void _onCancelled();

  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromEncodedPlatformImage(
    int address,
    int length, {
    ui.Size? decodeSize,
    int? maxLongSide,
  }) async {
    final pointer = Pointer<Uint8>.fromAddress(address);
    if (_isCancelled) {
      freePlatformBuffer(pointer);
      return null;
    }

    // On Android, the engine gets only the formats of its own codecs: it hands any other to Android's decoder at the
    // full size of the image, and aborts the app on an OutOfMemoryError there (see encoded_image_probe.dart). The
    // native decoder had its turn before (RemoteImagesImpl, from Android 9; below it the engine has no Android decoder
    // either), or the bytes were asked encoded for an animation, which only the engine's codecs play
    final kind = sniffEncodedImage(pointer.asTypedList(math.min(length, encodedImageProbeLength)));
    final route = encodedImageRoute(kind);
    if (route == EncodedImageRoute.core) {
      return _codecFromCore(pointer, length, decodeSize: decodeSize, maxLongSide: maxLongSide);
    }
    if (route != EncodedImageRoute.engine) {
      freePlatformBuffer(pointer);
      throw ImageDecodeException(UnsupportedEncodedImage(kind, length));
    }

    final ui.ImmutableBuffer buffer;
    try {
      buffer = await ImmutableBuffer.fromUint8List(pointer.asTypedList(length));
    } finally {
      freePlatformBuffer(pointer);
    }

    if (_isCancelled) {
      buffer.dispose();
      return null;
    }

    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await describeEncoded(buffer);
    } catch (error) {
      // The bytes came, the engine does not read them (a format it has no decoder for, a damaged file)
      throw ImageDecodeException(error);
    } finally {
      buffer.dispose();
    }
    if (_isCancelled) {
      descriptor.dispose();
      return null;
    }

    final target = _boundLongSide(
      descriptor.width,
      descriptor.height,
      _targetSize(descriptor.width, descriptor.height, decodeSize),
      maxLongSide,
    );
    final codec = await descriptor.instantiateCodec(targetWidth: target?.$1, targetHeight: target?.$2);
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    return (codec, descriptor);
  }

  /// Immuch360 Desktop: the JPEG XL of [length] bytes at [pointer] (a buffer of the platform, freed here) decoded by
  /// the Rust core (core_image_decoder.dart) to cover [decodeSize], within [maxLongSide] on the long side: the
  /// thumbnails and previews of a server set to JPEG XL, which the engine of the computers does not decode. Null once
  /// cancelled, an [ImageDecodeException] when the core gave no picture.
  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromCore(
    Pointer<Uint8> pointer,
    int length, {
    ui.Size? decodeSize,
    int? maxLongSide,
  }) async {
    final handle = _coreDecode = CoreDecodeHandle();
    final ui.ImageDescriptor? descriptor;
    try {
      descriptor = await decodeWithCore(
        pointer,
        length,
        targetWidth: decodeSize == null || decodeSize.width <= 0 ? 0 : decodeSize.width.ceil(),
        targetHeight: decodeSize == null || decodeSize.height <= 0 ? 0 : decodeSize.height.ceil(),
        maxPixelSize: maxLongSide ?? coreMaxPixelSize,
        handle: handle,
      );
    } on CoreDecodeException catch (error) {
      throw ImageDecodeException(error);
    } finally {
      _coreDecode = null;
      freePlatformBuffer(pointer);
    }
    if (descriptor == null || _isCancelled) {
      descriptor?.dispose();
      return null;
    }
    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }
    return (codec, descriptor);
  }

  Future<ui.FrameInfo?> _firstFrame((ui.Codec, ui.ImageDescriptor)? result) async {
    if (result == null) {
      return null;
    }

    final (codec, descriptor) = result;
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    final ui.FrameInfo frame;
    try {
      frame = await codec.getNextFrame();
    } catch (error) {
      throw ImageDecodeException(error);
    } finally {
      descriptor.dispose();
      codec.dispose();
    }
    if (_isCancelled) {
      frame.image.dispose();
      return null;
    }

    return frame;
  }

  (int, int)? _targetSize(int width, int height, ui.Size? decodeSize) {
    if (width <= 0 || height <= 0 || decodeSize == null || decodeSize.width <= 0 || decodeSize.height <= 0) {
      return null;
    }

    final scale = math.max(decodeSize.width / width, decodeSize.height / height);
    if (scale >= 1) {
      return null;
    }

    return ((width * scale).ceil(), (height * scale).ceil());
  }

  /// Immuch360 Desktop: [target] (null for the full size) bounded to [maxLongSide] pixels on its long side, the aspect
  /// ratio kept, as the phones bound their decodes (Impeller fits each side to the texture limit on its own, which
  /// squishes long images). Null [maxLongSide]: [target] as it is
  (int, int)? _boundLongSide(int width, int height, (int, int)? target, int? maxLongSide) {
    final (targetWidth, targetHeight) = target ?? (width, height);
    if (maxLongSide == null || width <= 0 || height <= 0 || math.max(targetWidth, targetHeight) <= maxLongSide) {
      return target;
    }

    final bound = maxLongSide / math.max(width, height);
    return (math.max(1, (width * bound).round()), math.max(1, (height * bound).round()));
  }

  Future<(ui.Codec, ui.ImageDescriptor)?> _codecFromDecodedPlatformImage(
    int address,
    int width,
    int height,
    int rowBytes,
  ) async {
    final pointer = Pointer<Uint8>.fromAddress(address);
    if (_isCancelled) {
      malloc.free(pointer);
      return null;
    }

    final size = rowBytes * height;
    final ui.ImmutableBuffer buffer;
    try {
      buffer = await ImmutableBuffer.fromUint8List(pointer.asTypedList(size));
    } finally {
      malloc.free(pointer);
    }

    if (_isCancelled) {
      buffer.dispose();
      return null;
    }

    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      rowBytes: rowBytes,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    buffer.dispose();

    final codec = await descriptor.instantiateCodec();
    if (_isCancelled) {
      descriptor.dispose();
      codec.dispose();
      return null;
    }

    return (codec, descriptor);
  }
}
