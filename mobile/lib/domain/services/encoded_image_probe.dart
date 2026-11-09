// What the first bytes of an encoded image say it is, and who decodes it on this device.
//
// On Android the engine hands every buffer that none of its own codecs reads (JPEG, PNG, GIF, WebP, BMP, ICO, WBMP) to
// Android's ImageDecoder through FlutterJNI.decodeImage. That decoder copies the whole file into the Java heap, then
// allocates the bitmap at the full size of the image, and the engine aborts the app on any Java exception other than an
// IOException ("Check failed: fml::jni::CheckException(env)" in android_image_generator.cc, the crash M1 of the Meta
// Quest store, report of 8 November 2026): an OutOfMemoryError on a large HEIF, AVIF or raw photo kills the app. So, on
// Android, only the formats of the engine's own codecs reach the engine; the others are decoded by the app's native
// decoder at a bounded size (NativeImageDecodeApi), or by the Dart TIFF decoder, or refused with an
// ImageDecodeException, which the viewers show as a photo that does not decode. iOS and the computers have no such
// fallback in their engine and keep it for every buffer.

import 'dart:typed_data';

import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

/// How many first bytes [sniffEncodedImage] reads at most
const encodedImageProbeLength = 64;

/// What an encoded image is, by its first bytes
enum EncodedImageKind {
  /// FF D8 FF
  jpeg,

  /// The 8 bytes of the PNG signature
  png,

  /// GIF87a or GIF89a
  gif,

  /// RIFF, then WEBPVP at offset 8
  webp,

  /// BM and a known size of its info header
  bmp,

  /// An icon or a cursor (00 00 01 00, 00 00 02 00) holding at least one image
  ico,

  /// ISO BMFF with a HEIF brand (heic, heix, hevc, mif1, msf1 and the others), Apple's spatial photos included
  heif,

  /// ISO BMFF with an AVIF brand (avif, avis)
  avif,

  /// A camera raw file that is not built on TIFF (Canon CR3 and CRW, Olympus ORF, Panasonic RW2, Fuji RAF, Sigma X3F)
  raw,

  /// II*\0 or MM\0*: a TIFF, or a raw file built on TIFF (DNG, CR2, NEF, ARW)
  tiff,

  /// JPEG XL, bare (FF 0A) or in its container
  jxl,

  /// Text: SVG, HTML, XML, JSON (a page of a server, an error message)
  text,

  /// ISO BMFF of another brand: a video (mp4, qt)
  notImage,

  /// No byte at all
  empty,

  /// Anything else, a buffer too short to tell included
  unknown,
}

/// Where an encoded image is decoded on this device
enum EncodedImageRoute {
  /// By the engine (ImageDescriptor.encoded and the image decoders of the painting library)
  engine,

  /// By the app's native decoder, at a bounded size (NativeImageDecodeApi, Android only)
  native,

  /// By the Dart TIFF decoder (see photoDecodePath)
  dartTiff,

  /// Nowhere: it is no image the device decodes, an ImageDecodeException
  refuse,
}

/// An encoded image kept away from the engine and not decoded otherwise: its [kind] and its [length] in bytes
class UnsupportedEncodedImage implements Exception {
  const UnsupportedEncodedImage(this.kind, this.length);

  final EncodedImageKind kind;
  final int length;

  @override
  String toString() => 'UnsupportedEncodedImage: ${kind.name}, $length bytes, not decoded on this device';
}

const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
const _jxlContainer = [0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A];
const _crw = [0x49, 0x49, 0x1A, 0x00, 0x00, 0x00, 0x48, 0x45, 0x41, 0x50, 0x43, 0x43, 0x44, 0x52];

// The sizes of the info header of a BMP that the engine's BMP codec reads (OS/2 1 and 2, Windows 3 to 5)
const _bmpInfoHeaderSizes = {12, 16, 40, 52, 56, 64, 108, 124};

// The brands of ISO BMFF that name an image of HEVC, or a HEIF image or sequence of any codec
const _heifBrands = {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'hevm', 'hevs'};
const _heifGenericBrands = {'mif1', 'msf1', 'mif2'};
const _avifBrands = {'avif', 'avis'};
const _cr3Brand = 'crx ';

/// What [bytes], the first bytes of an encoded image (at most [encodedImageProbeLength] are read), says it is. Each
/// format the engine decodes itself is told as strictly as its codec tells it, or more strictly: a buffer said to be
/// one of them is one the engine's own codecs open.
EncodedImageKind sniffEncodedImage(Uint8List bytes) {
  final head = bytes.length > encodedImageProbeLength
      ? Uint8List.sublistView(bytes, 0, encodedImageProbeLength)
      : bytes;
  final length = head.length;
  if (length == 0) {
    return EncodedImageKind.empty;
  }

  bool at(int offset, List<int> bytes) {
    if (offset + bytes.length > length) {
      return false;
    }
    for (var i = 0; i < bytes.length; i++) {
      if (head[offset + i] != bytes[i]) {
        return false;
      }
    }
    return true;
  }

  bool text(int offset, String ascii) => at(offset, ascii.codeUnits);

  if (at(0, const [0xFF, 0xD8, 0xFF])) {
    return EncodedImageKind.jpeg;
  }
  if (at(0, _png)) {
    return EncodedImageKind.png;
  }
  if (text(0, 'GIF87a') || text(0, 'GIF89a')) {
    return EncodedImageKind.gif;
  }
  if (text(0, 'RIFF') && text(8, 'WEBPVP')) {
    return EncodedImageKind.webp;
  }
  // Before the icons: a box of 256 or 512 bytes starts as an icon does
  if (text(4, 'ftyp')) {
    return _isoBmffKind(head);
  }
  if (at(0, _jxlContainer) || at(0, const [0xFF, 0x0A])) {
    return EncodedImageKind.jxl;
  }
  if (text(0, 'BM') && length >= 18 && _bmpInfoHeaderSizes.contains(_uint32LittleEndian(head, 14))) {
    return EncodedImageKind.bmp;
  }
  if (_isIcon(head)) {
    return EncodedImageKind.ico;
  }
  if (text(0, 'II*\x00') || text(0, 'MM\x00*')) {
    return EncodedImageKind.tiff;
  }
  if (text(0, 'IIRO') ||
      text(0, 'IIRS') ||
      text(0, 'MMOR') ||
      text(0, 'IIU\x00') ||
      text(0, 'FUJIFILMCCD-RAW') ||
      text(0, 'FOVb') ||
      at(0, _crw)) {
    return EncodedImageKind.raw;
  }
  if (_isText(head)) {
    return EncodedImageKind.text;
  }
  return EncodedImageKind.unknown;
}

// 00 00, 1 (an icon) or 2 (a cursor) as a 16 bit number, then a count of images that is not 0
bool _isIcon(Uint8List head) =>
    head.length >= 6 &&
    head[0] == 0 &&
    head[1] == 0 &&
    (head[2] == 1 || head[2] == 2) &&
    head[3] == 0 &&
    (head[4] != 0 || head[5] != 0);

int _uint32LittleEndian(Uint8List bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16 | bytes[offset + 3] << 24;

String _brandAt(Uint8List bytes, int offset) => String.fromCharCodes(bytes, offset, offset + 4);

// An ISO BMFF file (ftyp at offset 4): its major brand, then its compatible brands within the box and the bytes read
EncodedImageKind _isoBmffKind(Uint8List head) {
  if (head.length < 12) {
    return EncodedImageKind.unknown;
  }
  final boxSize = head[0] << 24 | head[1] << 16 | head[2] << 8 | head[3];
  // 0 runs to the end of the file, 1 has its size further on: the bytes read bound the brands then
  final end = boxSize >= 16 && boxSize < head.length ? boxSize : head.length;
  final major = _brandAt(head, 8);
  final compatible = [for (var offset = 16; offset + 4 <= end; offset += 4) _brandAt(head, offset)];

  if (_avifBrands.contains(major)) {
    return EncodedImageKind.avif;
  }
  if (major == _cr3Brand) {
    return EncodedImageKind.raw;
  }
  if (_heifBrands.contains(major)) {
    return EncodedImageKind.heif;
  }
  // A generic major brand (mif1, msf1, miaf, isom): the compatible brands tell
  if (compatible.any(_avifBrands.contains)) {
    return EncodedImageKind.avif;
  }
  if (compatible.any(_heifBrands.contains)) {
    return EncodedImageKind.heif;
  }
  if (compatible.contains(_cr3Brand)) {
    return EncodedImageKind.raw;
  }
  if (_heifGenericBrands.contains(major) || compatible.any(_heifGenericBrands.contains)) {
    return EncodedImageKind.heif;
  }
  return EncodedImageKind.notImage;
}

// A byte order mark, or blanks then the first character of markup or JSON
bool _isText(Uint8List head) {
  if ((head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) ||
      (head.length >= 2 && ((head[0] == 0xFE && head[1] == 0xFF) || (head[0] == 0xFF && head[1] == 0xFE)))) {
    return true;
  }
  for (final byte in head) {
    if (byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
      continue;
    }
    return byte == 0x3C || byte == 0x7B || byte == 0x5B;
  }
  return false;
}

/// Whether the engine decodes [kind] with a codec of its own, without the platform's fallback decoder
bool engineDecodesKind(EncodedImageKind kind) => switch (kind) {
  EncodedImageKind.jpeg ||
  EncodedImageKind.png ||
  EncodedImageKind.gif ||
  EncodedImageKind.webp ||
  EncodedImageKind.bmp ||
  EncodedImageKind.ico => true,
  _ => false,
};

/// Where an encoded image of [kind] is decoded on this device ([isAndroid] stands for the platform in the tests). Off
/// Android, by the engine, as before. On Android: by the engine for its own formats; by the Dart TIFF decoder for a
/// TIFF whose name ([name]) or type ([mimeType]) says TIFF, as photoDecodePath decides; refused for text, a video and
/// no bytes; by the native decoder for the others (HEIF, AVIF, raw files, TIFF based raw files, JPEG XL, the unknown).
EncodedImageRoute encodedImageRoute(EncodedImageKind kind, {String? name, String? mimeType, bool? isAndroid}) {
  if (!(isAndroid ?? CurrentPlatform.isAndroid) || engineDecodesKind(kind)) {
    return EncodedImageRoute.engine;
  }
  return switch (kind) {
    EncodedImageKind.empty || EncodedImageKind.text || EncodedImageKind.notImage => EncodedImageRoute.refuse,
    EncodedImageKind.tiff when _isDartTiff(name, mimeType) => EncodedImageRoute.dartTiff,
    _ => EncodedImageRoute.native,
  };
}

bool _isDartTiff(String? name, String? mimeType) =>
    (name != null || mimeType != null) &&
    photoDecodePath(name ?? '', mimeType: mimeType, fromServer: false, platformKeepsTiffPath: false) ==
        PhotoDecodePath.dartTiff;
