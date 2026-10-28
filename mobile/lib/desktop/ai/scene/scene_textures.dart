// The pictures of a scene (design-final 2026-10-27, sections 2.3, steps 2, 12 and 13, 8.2 and 8.7; lot S1): from the
// photo decoded upright, the texture of the photo layer at 4 096 pixels on its longest side at most, the preview of the
// file at 2 048, and the map MoGe-2 reads at 1 024, each made from the one before by the area average of phase 1
// (fitEye), never enlarged. The pixels keep the space of the photo and its ICC profile goes with them, as in phase 1;
// a profile other than sRGB raises wideGamut ("Colours may look duller in other 3D apps"), the conversion by lcms2
// being a lot after V2.

import 'dart:convert';
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
