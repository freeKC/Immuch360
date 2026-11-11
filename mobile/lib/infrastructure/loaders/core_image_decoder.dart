// JPEG XL on the computers (Immuch360 Desktop) through the Rust core of upstream, called with dart:ffi. The core
// (native/crates/native_core_ffi, its decoder in native/crates/codecs) is compiled into every build and test of the
// app by the build hook of native/native_core, the computers included; the phones reach the same core through their
// platform code (RemoteImagesImpl and JpegXlDecode on Android, NativeCore.swift on iOS). The engine of the computers
// has no JPEG XL codec: without this, the photos of an Immich 3.4.0 server whose admin picked JPEG XL thumbnails and
// previews would stay blank there. The two functions are bound by hand, as the AI codec does
// (packages/immuch_sbs_codec): the asset is the library the hook of native_core builds under the id below.
@DefaultAsset('package:native_core/src/bindings.g.dart')
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';

/// The long side of the largest picture the core decodes to (MAX_PIXEL_SIZE of the phones)
const coreMaxPixelSize = 16384;

/// The core gave no picture: the bytes are no JPEG XL it reads, or it had no memory for them
class CoreDecodeException implements Exception {
  const CoreDecodeException(this.length, this.reason);

  final int length;
  final String reason;

  @override
  String toString() => 'CoreDecodeException: JPEG XL not decoded by the core, $length bytes, $reason';
}

/// NativeCoreImageInfo of native_core.h
final class _CoreImageInfo extends Struct {
  @Int32()
  external int width;

  @Int32()
  external int height;

  @Uint8()
  external int bitDepth;

  @Uint8()
  external int primaries;

  @Uint8()
  external int transfer;
}

@Native<
  Pointer<Uint8> Function(Pointer<Uint8>, Size, Bool, Uint32, Uint32, Uint32, Pointer<Bool>, Pointer<_CoreImageInfo>)
>(symbol: 'native_core_decode_image')
external Pointer<Uint8> _decodeImage(
  Pointer<Uint8> data,
  int length,
  bool keepSpace,
  int targetWidth,
  int targetHeight,
  int maxPixelSize,
  Pointer<Bool> cancelled,
  Pointer<_CoreImageInfo> info,
);

@Native<Void Function(Pointer<Bool>)>(symbol: 'native_core_cancel')
external void _cancelDecode(Pointer<Bool> flag);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);

/// The free() of the C runtime the core takes its pixels from (calloc): the C library on Linux and macOS, the
/// universal CRT on Windows, where package:ffi's malloc is CoTaskMemAlloc, another heap. Uses dart:io's Platform on
/// purpose: the system the app runs on, never the platform a test pretends to be.
final _Free _freeCorePixels = (Platform.isWindows ? DynamicLibrary.open('ucrtbase.dll') : DynamicLibrary.process())
    .lookupFunction<_FreeNative, _Free>('free');

/// How many decodes of the core run at once, each on a helper isolate (a large one also on the core's own threads)
final int _concurrentDecodes = math.max(1, math.min(4, Platform.numberOfProcessors ~/ 2));
int _running = 0;
final Queue<Completer<void>> _waiting = Queue();

Future<void> _turn() async {
  if (_running < _concurrentDecodes) {
    _running++;
    return;
  }
  final turn = Completer<void>();
  _waiting.add(turn);
  await turn.future;
}

void _endTurn() {
  if (_waiting.isNotEmpty) {
    _waiting.removeFirst().complete();
  } else {
    _running--;
  }
}

/// A decode of the core in progress, which [stop] asks to end early
class CoreDecodeHandle {
  Pointer<Bool>? _flag;
  bool _stopped = false;

  /// Whether [stop] was called
  bool get stopped => _stopped;

  /// Asks the decode to stop: it then gives no picture
  void stop() {
    _stopped = true;
    final flag = _flag;
    if (flag != null) {
      _cancelDecode(flag);
    }
  }
}

/// The JPEG XL of [length] bytes at [data] (the caller's, kept until this ends) decoded by the core on a helper
/// isolate, in sRGB, premultiplied: to cover [targetWidth] x [targetHeight] (0 for the full size), never more than
/// [maxPixelSize] on the long side (at most [coreMaxPixelSize]); once more at half the size when the core gives
/// nothing, as on the phones. Null once [handle] was stopped; a [CoreDecodeException] when the core gave nothing.
Future<ui.ImageDescriptor?> decodeWithCore(
  Pointer<Uint8> data,
  int length, {
  int targetWidth = 0,
  int targetHeight = 0,
  int maxPixelSize = coreMaxPixelSize,
  CoreDecodeHandle? handle,
}) async {
  final decode = handle ?? CoreDecodeHandle();
  final maxSide = math.max(1, math.min(maxPixelSize, coreMaxPixelSize));
  await _turn();
  final flag = calloc<Bool>();
  decode._flag = flag;
  try {
    if (decode.stopped) {
      return null;
    }
    var pixels = await _decodeOnHelper(data, length, targetWidth, targetHeight, maxSide, flag);
    if (pixels == null && !decode.stopped) {
      pixels = await _decodeOnHelper(
        data,
        length,
        targetWidth ~/ 2,
        targetHeight ~/ 2,
        math.max(1, maxSide ~/ 2),
        flag,
      );
    }
    if (decode.stopped) {
      if (pixels != null) {
        _freeCorePixels(Pointer<Void>.fromAddress(pixels.$1));
      }
      return null;
    }
    if (pixels == null) {
      throw CoreDecodeException(length, 'no picture at ${targetWidth}x$targetHeight within $maxSide, nor at half');
    }
    return await _descriptorOf(pixels, length);
  } finally {
    decode._flag = null;
    calloc.free(flag);
    _endTurn();
  }
}

// The pixels of the core (its address, the width, the height) in an image descriptor; the core's buffer freed
Future<ui.ImageDescriptor> _descriptorOf((int, int, int, int) pixels, int length) async {
  final (address, width, height, bitDepth) = pixels;
  final pointer = Pointer<Uint8>.fromAddress(address);
  final ui.ImmutableBuffer buffer;
  try {
    // Pixels in sRGB are 8 bits: the core gives 16 only in the space of an HDR image, which is never asked here
    if (bitDepth != 8 || width <= 0 || height <= 0) {
      throw CoreDecodeException(length, 'a picture of ${width}x$height in $bitDepth bits');
    }
    buffer = await ui.ImmutableBuffer.fromUint8List(pointer.asTypedList(width * height * 4));
  } finally {
    _freeCorePixels(pointer.cast());
  }
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    rowBytes: width * 4,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  buffer.dispose();
  return descriptor;
}

// One call of the core on a helper isolate: the address of its pixels, their width, height and bits per sample, or
// null when it gave none
Future<(int, int, int, int)?> _decodeOnHelper(
  Pointer<Uint8> data,
  int length,
  int targetWidth,
  int targetHeight,
  int maxPixelSize,
  Pointer<Bool> flag,
) {
  final dataAddress = data.address;
  final flagAddress = flag.address;
  return Isolate.run(() {
    final info = calloc<_CoreImageInfo>();
    try {
      final pixels = _decodeImage(
        Pointer<Uint8>.fromAddress(dataAddress),
        length,
        false,
        math.max(0, targetWidth),
        math.max(0, targetHeight),
        maxPixelSize,
        Pointer<Bool>.fromAddress(flagAddress),
        info,
      );
      if (pixels == nullptr) {
        return null;
      }
      return (pixels.address, info.ref.width, info.ref.height, info.ref.bitDepth);
    } finally {
      calloc.free(info);
    }
  });
}

/// The JPEG XL [bytes] decoded by the core, as [decodeWithCore] does: a copy in native memory for the call
Future<ui.ImageDescriptor?> decodeBytesWithCore(
  List<int> bytes, {
  int targetWidth = 0,
  int targetHeight = 0,
  int maxPixelSize = coreMaxPixelSize,
  CoreDecodeHandle? handle,
}) async {
  final data = malloc<Uint8>(math.max(1, bytes.length));
  try {
    data.asTypedList(bytes.length).setAll(0, bytes);
    return await decodeWithCore(
      data,
      bytes.length,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
      maxPixelSize: maxPixelSize,
      handle: handle,
    );
  } finally {
    malloc.free(data);
  }
}
