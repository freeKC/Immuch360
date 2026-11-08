// Stand ins for the guarded decode of encoded images on Android (see guarded_image.dart): the native decoder, its
// error for a photo it could not hold, and the first bytes of the formats the engine has no codec of its own for.

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/encoded_image_probe.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/platform/native_image_decode_api.g.dart';

/// What the native decoder was asked
typedef NativeCall = ({EncodedImageKind kind, int length, int maxWidth, int maxHeight});

/// A stand in for the native decoder of Android: it records what it is asked and answers RGBA pixels of [width] x
/// [height] within the bounds asked, or throws [error]
class FakeNativeDecoder extends NativeImageDecodeApi {
  FakeNativeDecoder({this.width = 40, this.height = 30});

  final int width;
  final int height;
  final calls = <NativeCall>[];
  PlatformException? error;

  @override
  Future<Map<String, int>> decodeEncoded(int pointer, int length, int maxWidth, int maxHeight) async {
    // Read before the first await, while the caller holds the bytes
    final head = Uint8List.fromList(Pointer<Uint8>.fromAddress(pointer).asTypedList(math.min(length, 64)));
    calls.add((kind: sniffEncodedImage(head), length: length, maxWidth: maxWidth, maxHeight: maxHeight));
    final error = this.error;
    if (error != null) {
      throw error;
    }
    final w = maxWidth > 0 ? math.min(width, maxWidth) : width;
    final h = maxHeight > 0 ? math.min(height, maxHeight) : height;
    final pixels = malloc<Uint8>(w * h * 4)..asTypedList(w * h * 4).fillRange(0, w * h * 4, 0xFF);
    return {'pointer': pixels.address, 'width': w, 'height': h, 'rowBytes': w * 4};
  }
}

/// The error of the native decoder of Android for a photo it could not hold
PlatformException outOfMemory() => const PlatformException(
  code: undecodableImageCode,
  message: 'java.lang.OutOfMemoryError: OOM allocating Bitmap with dimensions 32768 x 16384',
);

final heic = File('test/fixtures/ai_immersive/codec/display_p3.heic').readAsBytesSync();

/// The head of a DNG, a raw file built like a TIFF, then bytes no decoder of the tests reads
final dng = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, ...List.filled(2048, 0x11)]);

/// The head of an AVIF, then bytes no decoder of the tests reads
final avif = Uint8List.fromList([
  ...[0, 0, 0, 0x1C],
  ...'ftypavif'.codeUnits,
  ...[0, 0, 0, 0],
  ...'mif1miafMA1B'.codeUnits,
  ...List.filled(2048, 0x22),
]);

final svg = Uint8List.fromList('<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>'.codeUnits);
