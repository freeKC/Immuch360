// TIFF photos where the device has no TIFF decoder. Android has none: BitmapFactory and ImageDecoder refuse TIFF, and
// the engine's fallback decoder is ImageDecoder itself ("Failed to create image decoder with message 'invalid input'"
// in the logcat of a Meta Quest 3, 31 October 2026). So, on Android (phones, TVs, the Quest):
//
// - a TIFF of the server shows as the largest JPEG the server makes of it, as a browser shows a HEIF or a raw file
//   (AssetMediaSize.fullsize: the server's full size conversion, or its preview while that conversion is off, see
//   sharpPanoramaUrl), with a notice in the details; the original stays what downloads and exports send;
// - a TIFF of the device or of a network share, of which no server made a JPEG, is decoded in Dart with the image
//   package (MIT, in the lock already through maplibre_gl), in a background isolate, at most [tiffMaxDecodedBytes]
//   of samples, shown at most a given number of pixels on its long side;
// - a TIFF that does not decode says so ("This device cannot decode this TIFF") instead of the engine's "Invalid image
//   data", once: the failure is remembered for the session ([UndecodablePhotos]), so that no widget that resolves the
//   photo again (a new density, the page shown again, the tiles of a folder opened again) reads and decodes it again.
//
// iOS, macOS and Windows keep their decoders, which read TIFF: Core Graphics (ImageIO) and WIC, through the engine and
// the native image pipelines alike. Linux keeps its folder library tile for the formats its engine does not read.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
// The TIFF decoder: pure Dart, already in the lock through maplibre_gl, so no plugin list changes (as in
// lib/desktop/library/local_image_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/extensions/platform_extensions.dart';

final _tiffName = RegExp(r'\.tiff?$', caseSensitive: false);

// The camera raw files built on TIFF: never shown as a TIFF, whatever type a share gives them
final _rawName = RegExp(
  r'\.(dng|cr2|cr3|crw|nef|nrw|arw|srf|sr2|orf|rw2|raf|pef|srw|3fr|erf|kdc|dcr|mos|mrw|x3f|iiq|rwl)$',
  caseSensitive: false,
);

const _tiffMimeTypes = {'image/tiff', 'image/tif', 'image/x-tiff'};

/// Whether [name] is the name of a TIFF file (.tif, .tiff)
bool isTiffName(String name) => _tiffName.hasMatch(name);

/// Whether [mimeType] is the type of a TIFF file (image/tiff and its older spellings), its parameters left out
bool isTiffMimeType(String? mimeType) =>
    mimeType != null && _tiffMimeTypes.contains(mimeType.split(';').first.trim().toLowerCase());

/// Whether [head], the first bytes of a file, starts as a TIFF does ("II*\0" or "MM\0*"). The camera raw files built
/// on TIFF (DNG, CR2, NEF, ARW) start the same way: this confirms a name or a type, it tells nothing alone.
bool hasTiffSignature(Uint8List head) =>
    head.length >= 4 &&
    ((head[0] == 0x49 && head[1] == 0x49 && head[2] == 0x2A && head[3] == 0x00) ||
        (head[0] == 0x4D && head[1] == 0x4D && head[2] == 0x00 && head[3] == 0x2A));

/// Whether the photo named [name], of the type [mimeType] when its source tells one, is a TIFF. A camera raw file never
/// is, whatever its structure or the type given.
bool isTiffPhoto(String name, {String? mimeType}) =>
    !_rawName.hasMatch(name) && (isTiffName(name) || isTiffMimeType(mimeType));

/// Whether this device decodes TIFF itself: iOS and macOS through Core Graphics, Windows through WIC, and the
/// computers keep their own path (Linux included, see the top of this file). Android has no TIFF decoder.
bool get thisDeviceDecodesTiff => !CurrentPlatform.isAndroid;

/// How a photo is decoded for the viewers
enum PhotoDecodePath {
  /// By the platform, as any photo: the native pipeline or the engine
  platform,

  /// The largest JPEG the server makes of it instead of its original
  serverPreview,

  /// In Dart, by the image package (see [decodeTiff])
  dartTiff,
}

/// How the photo named [name] (of the type [mimeType] when known) is decoded: from the server ([fromServer]) or from
/// the device or a share. [deviceDecodesTiff] stands for [thisDeviceDecodesTiff] in the tests.
PhotoDecodePath photoDecodePath(String name, {String? mimeType, required bool fromServer, bool? deviceDecodesTiff}) {
  if ((deviceDecodesTiff ?? thisDeviceDecodesTiff) || !isTiffPhoto(name, mimeType: mimeType)) {
    return PhotoDecodePath.platform;
  }
  return fromServer ? PhotoDecodePath.serverPreview : PhotoDecodePath.dartTiff;
}

/// A TIFF the Dart decoder did not decode, with why (for the log; the user is told "This device cannot decode this
/// TIFF")
class TiffDecodeException implements Exception {
  const TiffDecodeException(this.reason);

  final String reason;

  @override
  String toString() => 'TiffDecodeException: $reason';
}

/// The pixels of a decoded TIFF, RGBA with 8 bits per channel, [width] by [height]
class TiffPixels {
  const TiffPixels(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Most bytes of samples the first image of a TIFF may hold to be decoded (its width, height, samples per pixel and
/// bytes per sample): about 64 megapixels in 16 bit RGB, 128 in 8 bit RGB. The image package holds the whole image in
/// memory before it is scaled down.
const tiffMaxDecodedBytes = 384 * 1024 * 1024;

/// Most bytes of a TIFF file read for the Dart decoder, which holds the whole file in memory
const tiffMaxFileBytes = 512 * 1024 * 1024;

/// [bytes], a TIFF, decoded in a background isolate and scaled down to at most [maxSide] pixels on its long side,
/// upright as its orientation tag says. Throws [TiffDecodeException] when it does not decode.
Future<TiffPixels> decodeTiff(Uint8List bytes, {required int maxSide}) {
  if (bytes.length > tiffMaxFileBytes) {
    return Future.error(TiffDecodeException('${bytes.length} bytes is more than this device reads for a TIFF'));
  }
  final job = (bytes: TransferableTypedData.fromList([bytes]), maxSide: maxSide);
  return Isolate.run(() => _decodeTiffJob(job), debugName: 'TIFF decoder');
}

TiffPixels _decodeTiffJob(({TransferableTypedData bytes, int maxSide}) job) =>
    decodeTiffSync(job.bytes.materialize().asUint8List(), maxSide: job.maxSide);

/// [decodeTiff] on the calling isolate
@visibleForTesting
TiffPixels decodeTiffSync(Uint8List bytes, {required int maxSide}) {
  final decoder = img.TiffDecoder();
  final img.TiffInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } catch (error) {
    throw TiffDecodeException('unreadable header: $error');
  }
  final first = info?.images.firstOrNull;
  if (first == null || first.width <= 0 || first.height <= 0) {
    throw const TiffDecodeException('no image in the file');
  }
  final samples = math.max(1, first.samplesPerPixel);
  final sampleBytes = math.max(1, (first.bitsPerSample + 7) ~/ 8);
  final decodedBytes = first.width * first.height * samples * sampleBytes;
  if (decodedBytes > tiffMaxDecodedBytes) {
    throw TiffDecodeException('${first.width} x ${first.height} pixels is more than this device decodes');
  }
  img.Image? image;
  try {
    image = decoder.decodeFrame(0);
  } catch (error) {
    throw TiffDecodeException('$error');
  }
  if (image == null || image.width <= 0 || image.height <= 0) {
    throw const TiffDecodeException('the image did not decode');
  }
  final orientation = image.exif.imageIfd.hasOrientation ? image.exif.imageIfd.orientation : 1;
  if (orientation != null && orientation != 1) {
    image = img.bakeOrientation(image);
  }
  final longSide = math.max(image.width, image.height);
  if (longSide > maxSide) {
    final scale = maxSide / longSide;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  final rgba = image.format == img.Format.uint8 && image.numChannels == 4 && !image.hasPalette
      ? image
      : image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  return TiffPixels(rgba.getBytes(order: img.ChannelOrder.rgba), rgba.width, rgba.height);
}

/// The photos that did not decode in this session, by a key of their own (their URL, their asset), with the error
/// they gave: a photo is decoded once per session, a failure is told again at once, without reading the file again.
/// Only failures of the decoder are kept: a network error is tried again the next time the photo shows.
class UndecodablePhotos {
  UndecodablePhotos._();

  static final instance = UndecodablePhotos._();

  /// Most failures kept, the oldest dropped first
  static const maxEntries = 1000;

  final _failures = <String, Object>{};

  /// The error the photo [key] gave in this session, null when it was not tried or decoded
  Object? failureOf(String key) => _failures[key];

  /// Remembers that the photo [key] did not decode, with [error]
  void remember(String key, Object error) {
    _failures.remove(key);
    _failures[key] = error;
    while (_failures.length > maxEntries) {
      _failures.remove(_failures.keys.first);
    }
  }

  /// Forgets every failure (the tests, between cases)
  @visibleForTesting
  void clear() => _failures.clear();
}
