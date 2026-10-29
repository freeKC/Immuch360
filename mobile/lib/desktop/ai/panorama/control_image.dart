// The control frame a 360° panorama is generated from, pano-v1 (design-final 2026-10-27, section 4.3, point 3; lot
// P3), and the PNG files the generator and the upscaler read and write. The control frame is the photo projected at
// the centre of an equirectangular frame of 2048 x 1024, pure green elsewhere (erp_projection.dart), as the LoRA of
// nomadoor expects it; sd-cli reduces it to about a megapixel for its reference (M3), the generation itself being
// 1536 x 768. The photo is first reduced to the density of the frame (photoForFrame), so that its pixels do not alias.
//
// The PNG files are written and read with package:image (pure Dart, no Flutter), in the isolate of the step.

import 'dart:typed_data';

// Pure Dart image codecs, already in the lock through maplibre_gl (dart_sbs_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/desktop/ai/panorama/erp_projection.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// The control frame of [photo] seen with [hfov] degrees across, at [width] x [height] (those of pano-v1 by default)
ProjectedPhoto controlFrameOf(
  SbsDecoded photo, {
  required double hfov,
  int width = PanoV1.controlWidth,
  int height = PanoV1.controlHeight,
  bool Function()? isCancelled,
}) => projectPhoto(
  photoForFrame(photo, hfov: hfov, frameWidth: width),
  hfov: hfov,
  width: width,
  height: height,
  isCancelled: isCancelled,
);

/// [picture] as a PNG file of three channels (its alpha left out), fast rather than small: it only lives in the work
/// folder of the job
Uint8List encodePngPicture(SbsDecoded picture) {
  final image = img.Image.fromBytes(
    width: picture.width,
    height: picture.height,
    bytes: picture.rgba.buffer,
    bytesOffset: picture.rgba.offsetInBytes,
    numChannels: 4,
  );
  return img.encodePng(image.convert(numChannels: 3), level: 1);
}

/// The pixels of the PNG [bytes] as RGBA, opaque, whatever its channels and depth; throws [FormatException] when it is
/// no PNG this decoder reads
SbsDecoded decodePngPicture(Uint8List bytes) {
  final img.Image? image;
  try {
    image = img.PngDecoder().decode(bytes);
  } catch (error) {
    throw FormatException('Not a PNG this app reads: $error');
  }
  if (image == null) {
    throw const FormatException('Not a PNG this app reads');
  }
  final plain = image.format == img.Format.uint8 && !image.hasPalette && image.numChannels == 4
      ? image
      : image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  final rgba = Uint8List.fromList(plain.getBytes(order: img.ChannelOrder.rgba));
  for (var i = 3; i < rgba.length; i += 4) {
    rgba[i] = 255;
  }
  return SbsDecoded(width: image.width, height: image.height, rgba: rgba);
}
