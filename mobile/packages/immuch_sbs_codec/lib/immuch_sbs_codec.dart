// The Dart side of the Rust JPEG codec of Immuch360 Desktop (rust/src/lib.rs): decode an original, encode a side by
// side pair, read the licence texts. Each call copies its input into native memory, and copies what Rust returns into
// Dart lists before freeing it, so that nothing native outlives a call and the memory of a job never waits for the
// garbage collector. Synchronous: the AI job calls it from its own isolate, as the rest of its body.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:immuch_sbs_codec/src/bindings.dart';

/// The version of the C interface this file was written for, ABI_VERSION of rust/src/lib.rs
const nativeCodecAbiVersion = 1;

/// The chroma subsampling written, in the order of the C interface
enum NativeSubsampling { s444, s422, s420, s440, s411 }

/// What a call of the codec returned, Status of rust/src/codec.rs in its order
enum NativeCodecStatus {
  ok,
  invalidArgument,
  decodeFailed,
  tooLarge,
  outOfMemory,
  encodeFailed,
  segmentTooLarge,
  panic,

  /// Not available in this build, or a status this file does not know
  unavailable,
}

/// A failed call: its status and the reason the codec gave
class NativeCodecException implements Exception {
  const NativeCodecException(this.status, this.message);

  final NativeCodecStatus status;
  final String message;

  @override
  String toString() => 'NativeCodecException(${status.name}): $message';
}

/// A decoded JPEG: opaque RGBA rows as the file stores them, no orientation applied, no colour management (a grey,
/// CMYK or YCCK file comes out as RGB the way libjpeg-turbo turns it), and the ICC profile those pixels are in (null
/// when the file has none, or one for another colour space)
class NativeJpeg {
  const NativeJpeg({required this.width, required this.height, required this.rgba, this.iccProfile});

  final int width;
  final int height;
  final Uint8List rgba;
  final Uint8List? iccProfile;
}

const _errorCapacity = 512;

bool _probed = false;
String? _unavailableReason;

/// Why the codec cannot be used in this process, or null when it can. The library is looked for once.
String? get nativeCodecUnavailableReason {
  if (!_probed) {
    _unavailableReason = _probe();
    _probed = true;
  }
  return _unavailableReason;
}

/// Whether the library of the codec is in this build and speaks the interface of this file
bool get nativeCodecAvailable => nativeCodecUnavailableReason == null;

String? _probe() {
  try {
    final version = iscAbiVersion();
    return version == nativeCodecAbiVersion
        ? null
        : 'the codec library speaks version $version of its interface, $nativeCodecAbiVersion expected';
  } catch (error) {
    // An ArgumentError when the build has no such library (a target hook/build.dart builds nothing for), or the
    // error of the loader
    return 'the codec library is not in this build: $error';
  }
}

void _ensureAvailable() {
  final reason = nativeCodecUnavailableReason;
  if (reason != null) {
    throw NativeCodecException(NativeCodecStatus.unavailable, reason);
  }
}

/// The pixels of the JPEG [jpeg]. Throws [NativeCodecException].
NativeJpeg decodeJpeg(Uint8List jpeg) {
  _ensureAvailable();
  if (jpeg.isEmpty) {
    throw const NativeCodecException(NativeCodecStatus.decodeFailed, 'no bytes');
  }
  return using((arena) {
    final input = _copyIn(arena, jpeg);
    final width = arena<Uint32>();
    final height = arena<Uint32>();
    final rgba = arena<Pointer<Uint8>>();
    final rgbaLength = arena<Size>();
    final icc = arena<Pointer<Uint8>>();
    final iccLength = arena<Size>();
    final error = arena<Uint8>(_errorCapacity);
    final status = iscDecode(
      input,
      jpeg.length,
      width,
      height,
      rgba,
      rgbaLength,
      icc,
      iccLength,
      error,
      _errorCapacity,
    );
    _check(status, error);
    try {
      return NativeJpeg(
        width: width.value,
        height: height.value,
        rgba: _copyOut(rgba.value, rgbaLength.value),
        iccProfile: icc.value == nullptr ? null : _copyOut(icc.value, iccLength.value),
      );
    } finally {
      iscFree(rgba.value, rgbaLength.value);
      iscFree(icc.value, iccLength.value);
    }
  }, malloc);
}

/// The JPEG of [width] x [height] RGBA pixels: SOI, the EXIF APP1 payload [exif] ("Exif\0\0" and its TIFF
/// structure), the XMP packet [xmp] (UTF-8) in its APP1, the ICC profile [icc] in APP2 chunks, then the image. A pixel
/// that is not opaque is laid on black. Throws [NativeCodecException].
Uint8List encodeJpeg(
  Uint8List rgba, {
  required int width,
  required int height,
  required int quality,
  NativeSubsampling subsampling = NativeSubsampling.s444,
  Uint8List? exif,
  Uint8List? xmp,
  Uint8List? icc,
}) {
  _ensureAvailable();
  if (rgba.isEmpty || width <= 0 || height <= 0) {
    throw NativeCodecException(NativeCodecStatus.invalidArgument, 'no pixels for $width x $height');
  }
  return using((arena) {
    final pixels = _copyIn(arena, rgba);
    final exifIn = _copyIn(arena, exif);
    final xmpIn = _copyIn(arena, xmp);
    final iccIn = _copyIn(arena, icc);
    final jpeg = arena<Pointer<Uint8>>();
    final jpegLength = arena<Size>();
    final error = arena<Uint8>(_errorCapacity);
    final status = iscEncode(
      pixels,
      rgba.length,
      width,
      height,
      quality,
      subsampling.index,
      exifIn,
      exif?.length ?? 0,
      xmpIn,
      xmp?.length ?? 0,
      iccIn,
      icc?.length ?? 0,
      jpeg,
      jpegLength,
      error,
      _errorCapacity,
    );
    _check(status, error);
    try {
      return _copyOut(jpeg.value, jpegLength.value);
    } finally {
      iscFree(jpeg.value, jpegLength.value);
    }
  }, malloc);
}

/// The licence texts of the crates built into the library (with the sentence the IJG terms ask for), or null when
/// the library is not available
String? nativeCodecLicenses() {
  if (!nativeCodecAvailable) {
    return null;
  }
  return using((arena) {
    final length = arena<Size>();
    final text = iscLicenses(length);
    return utf8.decode(text.asTypedList(length.value));
  }, malloc);
}

Pointer<Uint8> _copyIn(Arena arena, Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) {
    return nullptr;
  }
  final native = arena<Uint8>(bytes.length);
  native.asTypedList(bytes.length).setAll(0, bytes);
  return native;
}

Uint8List _copyOut(Pointer<Uint8> data, int length) =>
    data == nullptr || length == 0 ? Uint8List(0) : Uint8List.fromList(data.asTypedList(length));

void _check(int status, Pointer<Uint8> error) {
  if (status == 0) {
    return;
  }
  final bytes = error.asTypedList(_errorCapacity);
  final end = bytes.indexOf(0);
  final message = utf8.decode(bytes.sublist(0, end < 0 ? _errorCapacity : end), allowMalformed: true);
  final known = status > 0 && status < NativeCodecStatus.unavailable.index;
  throw NativeCodecException(
    known ? NativeCodecStatus.values[status] : NativeCodecStatus.unavailable,
    known ? message : 'status $status: $message',
  );
}
