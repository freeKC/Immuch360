// The photos the JPEG codec does not read (PNG, WebP, GIF, BMP; HEIC, AVIF, TIFF and the raw files where the system
// has a decoder), decoded by the engine: the path the viewers and the thumbnails of the folder library take
// (desktop/library/local_image_codec.dart, desktop/platform/desktop_local_image_api.dart), so that a 3D photo starts
// from what the user sees, upright as the viewer shows it. Transparency is put on black (design-final 2026-10-26,
// section 2.3, point 9). dart:ui decodes on the root isolate only: a job decodes these photos there, then hands the
// pixels to its worker.
//
// The profile written with the pixels is always the one they are in (design-final 2.3, point 4):
// 1. Skia's own codecs (PNG, WebP, GIF, BMP): Impeller decodes into sRGB, so no profile.
// 2. Windows, the decoders of the system (WIC): Skia's WIC generator tags the pixels sRGB and converts nothing
//    (SkImageGeneratorWIC.cpp, MakeS32 and a format converter to 32bppPBGRA, at Skia 8df24be6, the revision of
//    Flutter 3.47.2), and the HEIF decoder of Windows gives the values of the file: measured on 26 October 2026 on a
//    Windows 11 PC with the HEIF and HEVC extensions, the red patch of test/fixtures/ai_immersive/codec/display_p3.heic
//    came out (185, 71, 65), its Display P3 value (185, 71, 66), not its sRGB value (200, 60, 60). So a HEIC or an
//    AVIF keeps the ICC profile of its colr box, as a JPEG keeps its own; without one, nothing is written (sRGB).
//    The AVIF follows the rule of the HEIC without a measure of its own. A file that gives its colours by an nclx
//    colr box rather than a profile (most AVIF files, the HEIC of some Android phones) gets no profile either: if
//    the decoder gives its values as they are, wide gamut colours come out dull, so they are not guaranteed.
// 3. macOS: Skia's Core Graphics generator draws the picture into an sRGB context (SkImageGeneratorCG.cpp and
//    SkCreateCGImageRef.cpp, same revision): the pixels are sRGB, no profile.
// 4. Linux has no HEIC decoder: the photo is not readable here.
// TIFF and the raw files through WIC are not measured: no profile is written for them.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/library/local_image_codec.dart';

/// The pixels of the photo [bytes] as the engine decodes it, transparency on black, with the profile they are in;
/// a photo wider than [maxWidth] is decoded straight to that width, its height in proportion. [windows] stands for
/// the system in the tests. Root isolate only. Throws [SbsCodecException] when the engine cannot decode it here.
Future<SbsDecoded> decodeWithEngine(Uint8List bytes, {int? maxWidth, bool? windows}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    int? targetWidth;
    int? targetHeight;
    if (maxWidth != null && descriptor.width > maxWidth) {
      targetWidth = maxWidth;
      targetHeight = math.max(1, (descriptor.height * maxWidth / descriptor.width).round());
    }
    codec = await descriptor.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);
    image = (await codec.getNextFrame()).image;
    // Premultiplied RGBA: a pixel of alpha a holds its colour times a, the colour it has over black
    final pixels = await image.toByteData();
    if (pixels == null) {
      throw const SbsCodecException('The engine gave no pixels');
    }
    final rgba = pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes);
    for (var alpha = 3; alpha < rgba.length; alpha += 4) {
      rgba[alpha] = 0xFF;
    }
    return SbsDecoded(
      width: image.width,
      height: image.height,
      rgba: rgba,
      iccProfile: enginePixelsProfile(bytes, windows: windows ?? Platform.isWindows),
    );
  } on SbsCodecException {
    rethrow;
  } catch (error) {
    throw SbsCodecException('The engine could not decode the photo: $error');
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// The ICC profile the pixels the engine decodes from [bytes] are in, by the rules at the top of this file: the
/// profile of a HEIC or an AVIF on Windows, else none
Uint8List? enginePixelsProfile(Uint8List bytes, {required bool windows}) {
  if (!windows) {
    return null;
  }
  final format = sniffImageFormat(Uint8List.sublistView(bytes, 0, math.min(bytes.length, 16)));
  return format == SniffedFormat.heif || format == SniffedFormat.avif ? heifIccProfile(bytes) : null;
}

/// The ICC profile of the colr box ('prof' or 'rICC') of the primary item of a HEIF or AVIF file, or of its first
/// image property when the primary item has none (the tiles of a grid may carry it); null without one or when the
/// boxes do not read
Uint8List? heifIccProfile(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final meta = _boxes(data, 0, bytes.length).where((box) => box.type == 'meta').firstOrNull;
  if (meta == null) {
    return null;
  }
  int? primary;
  final properties = <_Box>[];
  final associations = <int, List<int>>{};
  // meta is a full box: its version and flags come before its children
  for (final child in _boxes(data, meta.content + 4, meta.end)) {
    switch (child.type) {
      case 'pitm':
        if (child.content + 6 <= child.end) {
          primary = bytes[child.content] == 0
              ? data.getUint16(child.content + 4)
              : _u32(data, child.content + 4, child.end);
        }
      case 'iprp':
        for (final inner in _boxes(data, child.content, child.end)) {
          if (inner.type == 'ipco') {
            properties.addAll(_boxes(data, inner.content, inner.end));
          } else if (inner.type == 'ipma') {
            associations.addAll(_associations(data, inner));
          }
        }
    }
  }

  Uint8List? profileOf(_Box box) {
    if (box.type != 'colr' || box.content + 4 > box.end) {
      return null;
    }
    final kind = String.fromCharCodes(bytes, box.content, box.content + 4);
    return kind == 'prof' || kind == 'rICC' ? Uint8List.fromList(bytes.sublist(box.content + 4, box.end)) : null;
  }

  for (final index in associations[primary] ?? const <int>[]) {
    if (index >= 1 && index <= properties.length) {
      final profile = profileOf(properties[index - 1]);
      if (profile != null) {
        return profile;
      }
    }
  }
  for (final property in properties) {
    final profile = profileOf(property);
    if (profile != null) {
      return profile;
    }
  }
  return null;
}

typedef _Box = ({String type, int content, int end});

/// The boxes between [from] and [to]; stops at the first that does not fit
List<_Box> _boxes(ByteData data, int from, int to) {
  final boxes = <_Box>[];
  var at = from;
  while (at + 8 <= to && boxes.length < 512) {
    var size = data.getUint32(at);
    var header = 8;
    if (size == 1) {
      if (at + 16 > to) {
        break;
      }
      size = data.getUint32(at + 8) * 0x100000000 + data.getUint32(at + 12);
      header = 16;
    } else if (size == 0) {
      size = to - at;
    }
    if (size < header || at + size > to) {
      break;
    }
    final type = String.fromCharCodes(Uint8List.sublistView(data, at + 4, at + 8));
    boxes.add((type: type, content: at + header, end: at + size));
    at += size;
  }
  return boxes;
}

/// The property indexes (from 1) of each item of an ipma box
Map<int, List<int>> _associations(ByteData data, _Box ipma) {
  final out = <int, List<int>>{};
  if (ipma.content + 8 > ipma.end) {
    return out;
  }
  final version = data.getUint8(ipma.content);
  final wideIndexes = data.getUint8(ipma.content + 3) & 1 == 1;
  final count = data.getUint32(ipma.content + 4);
  var at = ipma.content + 8;
  for (var entry = 0; entry < count; entry++) {
    final idSize = version < 1 ? 2 : 4;
    if (at + idSize + 1 > ipma.end) {
      break;
    }
    final item = idSize == 2 ? data.getUint16(at) : data.getUint32(at);
    at += idSize;
    final associations = data.getUint8(at);
    at++;
    final indexes = <int>[];
    for (var index = 0; index < associations; index++) {
      if (at + (wideIndexes ? 2 : 1) > ipma.end) {
        return out;
      }
      indexes.add(wideIndexes ? data.getUint16(at) & 0x7FFF : data.getUint8(at) & 0x7F);
      at += wideIndexes ? 2 : 1;
    }
    out[item] = indexes;
  }
  return out;
}

int? _u32(ByteData data, int at, int end) => at + 4 <= end ? data.getUint32(at) : null;
