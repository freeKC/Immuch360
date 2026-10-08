// The images of the folder library through the engine's own codecs (dart:ui): the thumbnails the cache keeps,
// whether a file is one the engine can show at all, and the tiles that stand for what it cannot. The phones decode
// natively (MediaStore, PhotoKit); a computer has the file and the engine, which reads JPEG, PNG, GIF, WebP, BMP and
// WBMP itself and asks the system for the rest where the system offers a decoder.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show IconData;
// The JPEG encoder of the thumbnails (dart:ui writes PNG only). Pure Dart, already in the lock through maplibre_gl, so
// no plugin list changes; listing it in pubspec.yaml would remove the need for the ignore.
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;

/// What the first bytes of a file say it is
enum SniffedFormat { jpeg, png, gif, webp, bmp, ico, heif, avif, tiff, unknown }

/// The formats every desktop engine decodes by itself (Skia's codecs), so that their files are never probed
const engineFormats = {
  SniffedFormat.jpeg,
  SniffedFormat.png,
  SniffedFormat.gif,
  SniffedFormat.webp,
  SniffedFormat.bmp,
  SniffedFormat.ico,
};

/// The format of [head], the first bytes of a file (16 are enough)
SniffedFormat sniffImageFormat(Uint8List head) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (head.length < offset + magic.length) {
      return false;
    }
    for (var index = 0; index < magic.length; index++) {
      if (head[offset + index] != magic[index]) {
        return false;
      }
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF])) {
    return SniffedFormat.jpeg;
  }
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return SniffedFormat.png;
  }
  if (startsWith('GIF8'.codeUnits)) {
    return SniffedFormat.gif;
  }
  if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
    return SniffedFormat.webp;
  }
  if (startsWith('BM'.codeUnits)) {
    return SniffedFormat.bmp;
  }
  if (startsWith(const [0x00, 0x00, 0x01, 0x00])) {
    return SniffedFormat.ico;
  }
  if (startsWith('II*\u0000'.codeUnits) || startsWith('MM\u0000*'.codeUnits)) {
    // TIFF, and the camera raw files built on it (DNG, CR2, NEF, ARW)
    return SniffedFormat.tiff;
  }
  if (startsWith('ftyp'.codeUnits, 4) && head.length >= 12) {
    final brand = String.fromCharCodes(head.sublist(8, 12));
    if (brand == 'avif' || brand == 'avis') {
      return SniffedFormat.avif;
    }
    if (const {'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'}.contains(brand)) {
      return SniffedFormat.heif;
    }
  }
  return SniffedFormat.unknown;
}

/// Whether the engine can show [bytes]: at once for the formats it decodes itself; for the others, whether a decoder
/// of the system reads their header (HEIF where the system has one, for example). Reading a header decodes nothing.
Future<bool> engineCanDecode(Uint8List bytes) async {
  if (bytes.isEmpty) {
    return false;
  }
  if (engineFormats.contains(sniffImageFormat(bytes))) {
    return true;
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return descriptor.width > 0 && descriptor.height > 0;
  } catch (_) {
    return false;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The size that covers a [box] by [box] square without enlarging: what a request for that box decodes to (the
/// image request code scales by the larger ratio, image_request.dart)
(int, int) coverSize(int width, int height, int box) {
  if (width <= 0 || height <= 0) {
    return (width, height);
  }
  final scale = math.max(box / width, box / height);
  if (scale >= 1) {
    return (width, height);
  }
  return (math.max(1, (width * scale).ceil()), math.max(1, (height * scale).ceil()));
}

/// The quality of the JPEG thumbnails, with the colours at half resolution: what photo thumbnails usually use, and
/// no visible difference at the size of a timeline tile
const thumbnailJpegQuality = 85;

/// A thumbnail of [encoded] decoded to cover a [box] by [box] square; null when the engine cannot decode it.
///
/// An opaque picture is kept as a JPEG, about a seventh of the PNG of the same photograph (28 to 54 KB against 269 to
/// 348 KB for the 640 by 320 tile of an 8K 360 photo, in about the same time), so that the cache holds the thumbnails
/// of a whole library under its size limit rather than decoding the originals again and again; a picture with
/// transparency is kept as a PNG, which keeps it. The JPEG is encoded in a background isolate, so that the timeline
/// keeps scrolling meanwhile.
Future<Uint8List?> renderThumbnail(Uint8List encoded, int box) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    buffer = null;
    final (width, height) = coverSize(descriptor.width, descriptor.height, box);
    codec = await descriptor.instantiateCodec(targetWidth: width, targetHeight: height);
    image = (await codec.getNextFrame()).image;
    final jpeg = await _jpegOf(image);
    if (jpeg != null) {
      return jpeg;
    }
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// [image] as a JPEG, null when it has transparency or the encoder failed: the PNG of the engine is then kept, so
/// that a photo the engine decoded never ends up as the tile of an undecodable file
Future<Uint8List?> _jpegOf(ui.Image image) async {
  try {
    final pixels = await image.toByteData();
    if (pixels == null) {
      return null;
    }
    return await _opaqueJpegInBackground(
      pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
      image.width,
      image.height,
    );
  } catch (_) {
    return null;
  }
}

/// [opaqueJpeg] in another isolate. Its own function, so that the closure sent there holds only the pixels and the
/// size, never the engine objects of the caller, which cannot be sent.
Future<Uint8List?> _opaqueJpegInBackground(Uint8List rgba, int width, int height) =>
    Isolate.run(() => opaqueJpeg(rgba, width, height));

/// [rgba], [width] by [height] pixels of four bytes, as a JPEG; null when a pixel is not fully opaque, since JPEG
/// would turn its transparency black
@visibleForTesting
Uint8List? opaqueJpeg(Uint8List rgba, int width, int height) {
  if (rgba.length != width * height * 4) {
    return null;
  }
  for (var alpha = 3; alpha < rgba.length; alpha += 4) {
    if (rgba[alpha] != 0xFF) {
      return null;
    }
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
  );
  return img.encodeJpg(image, quality: thumbnailJpegQuality, chroma: img.JpegChroma.yuv420);
}

/// A square PNG of [size] pixels standing for a file the engine cannot show: [icon] in the middle, and [label] (the
/// format, HEIC for example) under it. Grey on dark grey, readable in the light and the dark themes.
Future<Uint8List> renderTile({required int size, required IconData icon, String? label}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final extent = size.toDouble();
  canvas.drawRect(Rect.fromLTWH(0, 0, extent, extent), Paint()..color = const Color(0xFF3A3A40));

  final iconPainter = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        fontSize: extent * 0.3,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
        color: const Color(0xCCFFFFFF),
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final hasLabel = label != null && label.isNotEmpty;
  final iconTop = (extent - iconPainter.height) / 2 - (hasLabel ? extent * 0.06 : 0);
  iconPainter.paint(canvas, Offset((extent - iconPainter.width) / 2, iconTop));
  final iconBottom = iconTop + iconPainter.height;
  iconPainter.dispose();

  if (hasLabel) {
    final labelPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(fontSize: extent * 0.09, fontWeight: FontWeight.w600, color: const Color(0xCCFFFFFF)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: extent * 0.9);
    labelPainter.paint(canvas, Offset((extent - labelPainter.width) / 2, iconBottom + extent * 0.04));
    labelPainter.dispose();
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}
