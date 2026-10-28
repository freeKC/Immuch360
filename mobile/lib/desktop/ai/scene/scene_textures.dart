// The pictures of a scene (design-final 2026-10-27, sections 2.3, steps 2, 12 and 13, 8.2 and 8.7; lot S1): from the
// photo decoded upright, the texture of the photo layer at 4 096 pixels on its longest side at most, the preview of the
// file at 2 048, and the map MoGe-2 reads at 1 024, each made from the one before by the area average of phase 1
// (fitEye), never enlarged. The pixels keep the space of the photo and its ICC profile goes with them, as in phase 1;
// a profile other than sRGB raises wideGamut ("Colours may look duller in other 3D apps"), the conversion by lcms2
// being a lot after V2.
//
// The preview carries a small "3D SCENE" mark in its bottom left corner (design D11, applied by V2): Immich took each
// photo of the lot V and its scene for duplicates, the preview being the photo itself, and may offer to keep the
// heavier file, often the scene. The mark lets the eye tell them apart there and wherever the file shows as a plain
// photo. It is drawn on a copy of the preview when it is written, never on the texture the headset and the computers
// draw the scene with, nor on the map MoGe-2 reads; a preview under 256 pixels on its short side has none.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/engine/immersive_chain.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The three pictures a scene is made of
class ScenePictures {
  const ScenePictures({required this.texture, required this.preview, required this.map});

  /// [photo] at SceneV1.photoTextureMax, then SceneV1.previewMax, then SceneV1.mapLongSide at most
  factory ScenePictures.of(SbsDecoded photo, {int mapLongSide = SceneV1.mapLongSide}) {
    final texture = fitEye(photo, maxWidth: SceneV1.photoTextureMax, maxHeight: SceneV1.photoTextureMax);
    final preview = fitEye(texture, maxWidth: SceneV1.previewMax, maxHeight: SceneV1.previewMax);
    final map = fitEye(preview, maxWidth: mapLongSide, maxHeight: mapLongSide);
    return ScenePictures(texture: texture, preview: preview, map: map);
  }

  final SbsDecoded texture;
  final SbsDecoded preview;
  final SbsDecoded map;
}

/// Where the mark of a preview goes, in pixels: [left] and [top] included, [right] and [bottom] excluded
class SceneMarkBox {
  const SceneMarkBox(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;
}

/// The short side a preview needs for its mark
const sceneMarkMinSide = 256;

/// The words of the mark, and its letters in cells of 5 x 7, a row of 5 bits per line from the top
const _markText = '3D SCENE';
const _markGlyphs = {
  '3': [0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E],
  'D': [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
  'S': [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
  'C': [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
  'E': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
  'N': [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
};

/// The width of a letter of the mark in cells, a space being 3, and the cell between two letters
int _markCells(String letter) => letter == ' ' ? 3 : 5;
const _markGap = 1;

/// The cell of the mark of a preview of [width] x [height], in pixels: some 3 on a preview of 2048 x 1366
int _markCell(int width, int height) => math.max(1, (math.min(width, height) / 450).round());

/// Where the mark of a preview of [width] x [height] goes, in its bottom left corner; null for a preview under
/// [sceneMarkMinSide] on its short side
SceneMarkBox? sceneMarkBox(int width, int height) {
  if (math.min(width, height) < sceneMarkMinSide) {
    return null;
  }
  final cell = _markCell(width, height);
  var cells = 0;
  for (var i = 0; i < _markText.length; i++) {
    cells += _markCells(_markText[i]) + (i == 0 ? 0 : _markGap);
  }
  final padding = 2 * cell;
  final margin = 4 * cell;
  final boxWidth = cells * cell + 2 * padding;
  final boxHeight = 7 * cell + 2 * padding;
  return SceneMarkBox(margin, height - margin - boxHeight, margin + boxWidth, height - margin);
}

/// [preview] with the mark of a scene: a copy, its ground a quarter of the photo under it, its letters white; the
/// preview itself when it is too small for one
SbsDecoded withSceneMark(SbsDecoded preview) {
  final box = sceneMarkBox(preview.width, preview.height);
  if (box == null) {
    return preview;
  }
  final rgba = Uint8List.fromList(preview.rgba);
  final width = preview.width;
  for (var y = box.top; y < box.bottom; y++) {
    for (var x = box.left; x < box.right; x++) {
      final at = 4 * (y * width + x);
      rgba[at] = rgba[at] ~/ 4;
      rgba[at + 1] = rgba[at + 1] ~/ 4;
      rgba[at + 2] = rgba[at + 2] ~/ 4;
    }
  }
  final cell = _markCell(preview.width, preview.height);
  var left = box.left + 2 * cell;
  final top = box.top + 2 * cell;
  for (var i = 0; i < _markText.length; i++) {
    final letter = _markText[i];
    final rows = _markGlyphs[letter];
    if (rows != null) {
      for (var row = 0; row < 7; row++) {
        for (var column = 0; column < 5; column++) {
          if (rows[row] & (0x10 >> column) == 0) {
            continue;
          }
          for (var y = top + row * cell; y < top + (row + 1) * cell; y++) {
            for (var x = left + column * cell; x < left + (column + 1) * cell; x++) {
              final at = 4 * (y * width + x);
              rgba[at] = 255;
              rgba[at + 1] = 255;
              rgba[at + 2] = 255;
            }
          }
        }
      }
    }
    left += (_markCells(letter) + _markGap) * cell;
  }
  return SbsDecoded(width: preview.width, height: preview.height, rgba: rgba, iccProfile: preview.iccProfile);
}

/// The size of the map of a photo of [width] x [height] upright: the size [ScenePictures.of] gives it, through the
/// texture and the preview (each reduction rounds), so that the step of its grid is known before the photo is decoded
(int, int) sceneMapSizeOf(int width, int height, {int mapLongSide = SceneV1.mapLongSide}) {
  final texture = fittedEyeSize(width, height, maxWidth: SceneV1.photoTextureMax, maxHeight: SceneV1.photoTextureMax);
  final preview = fittedEyeSize(texture.$1, texture.$2, maxWidth: SceneV1.previewMax, maxHeight: SceneV1.previewMax);
  return fittedEyeSize(preview.$1, preview.$2, maxWidth: mapLongSide, maxHeight: mapLongSide);
}

/// [picture] as the input of MoGe-2: [1, 3, height, width] float32 in [0, 1]
Float32List nchwOf(SbsDecoded picture) {
  final plane = picture.width * picture.height;
  final out = Float32List(3 * plane);
  final rgba = picture.rgba;
  for (var i = 0; i < plane; i++) {
    out[i] = rgba[4 * i] / 255;
    out[plane + i] = rgba[4 * i + 1] / 255;
    out[2 * plane + i] = rgba[4 * i + 2] / 255;
  }
  return out;
}

/// The red, green and blue bytes of [rgba], three a pixel
Uint8List rgbOf(Uint8List rgba) {
  final out = Uint8List(rgba.length ~/ 4 * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    out[j] = rgba[i];
    out[j + 1] = rgba[i + 1];
    out[j + 2] = rgba[i + 2];
  }
  return out;
}

/// The mean luma of [picture] (0.2126 R + 0.7152 G + 0.0722 B, as relief-v1 takes it): dark under ReliefV1.darkLuma
double meanLumaOf(SbsDecoded picture) {
  final rgba = picture.rgba;
  var total = 0.0;
  for (var i = 0; i < rgba.length; i += 4) {
    total += 0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2];
  }
  return rgba.isEmpty ? 0 : total / (rgba.length ~/ 4);
}

/// Whether the ICC [profile] of a photo describes a space other than sRGB: an RGB profile whose description does not
/// name sRGB (Display P3, Adobe RGB, ProPhoto). No profile, or a grey one, is not.
bool isWideGamutProfile(Uint8List? profile) {
  if (profile == null || !isRgbIccProfile(profile)) {
    return false;
  }
  final description = iccDescriptionOf(profile)?.toLowerCase();
  return description == null || !(description.contains('srgb') || description.contains('61966'));
}

/// The text of the description tag ('desc') of the ICC [profile]: the ASCII of a version 2 profile, the first record
/// of a version 4 one (mluc); null when it cannot be read
String? iccDescriptionOf(Uint8List profile) {
  if (profile.length < 132) {
    return null;
  }
  final data = ByteData.sublistView(profile);
  final count = data.getUint32(128);
  for (var i = 0; i < count && 132 + 12 * (i + 1) <= profile.length; i++) {
    final entry = 132 + 12 * i;
    if (ascii.decode(profile.sublist(entry, entry + 4), allowInvalid: true) != 'desc') {
      continue;
    }
    final offset = data.getUint32(entry + 4);
    final size = data.getUint32(entry + 8);
    if (offset + size > profile.length || size < 12) {
      return null;
    }
    final type = ascii.decode(profile.sublist(offset, offset + 4), allowInvalid: true);
    if (type == 'desc') {
      final length = data.getUint32(offset + 8);
      if (offset + 12 + length > profile.length) {
        return null;
      }
      return latin1.decode(profile.sublist(offset + 12, offset + 12 + length)).replaceAll('\u0000', '').trim();
    }
    if (type == 'mluc' && size >= 28) {
      final length = data.getUint32(offset + 20);
      final start = offset + data.getUint32(offset + 24);
      if (start + length > profile.length) {
        return null;
      }
      final units = [for (var k = 0; k + 1 < length; k += 2) data.getUint16(start + k)];
      return String.fromCharCodes(units).replaceAll('\u0000', '').trim();
    }
    return null;
  }
  return null;
}

/// A JPEG of [picture] at [quality], with [exif], [xmp] and the ICC profile of its pixels (an RGB one only, the rule
/// of the codecs), by the first of [codecs] that writes it, and the name of that codec. Throws [SbsCodecException] when
/// none does (the message of the last), at once when the memory is refused.
(Uint8List, String) encodeScenePicture(
  List<SbsCodec> codecs,
  SbsDecoded picture, {
  required int quality,
  Uint8List? exif,
  String? xmp,
}) {
  final profile = picture.iccProfile;
  final options = SbsEncodeOptions(
    quality: quality,
    exif: exif,
    xmp: xmp,
    iccProfile: profile != null && isRgbIccProfile(profile) ? profile : null,
  );
  final single = SbsPicture.single(width: picture.width, height: picture.height, rgba: picture.rgba);
  SbsCodecException? last;
  for (final codec in codecs) {
    try {
      return (codec.encodeSbs(single, options), codec.name);
    } on SbsCodecException catch (error) {
      if (isMemoryRefusal(error)) {
        rethrow;
      }
      last = error;
    }
  }
  throw last ?? const SbsCodecException('No codec');
}
