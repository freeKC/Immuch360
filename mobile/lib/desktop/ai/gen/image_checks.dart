// The checks of an image sd-cli wrote, before the panorama engine takes it (design-final 2026-10-27, section 4.3,
// point 5; measure M3, phase23/m3-measures-2026-10-27.md, sections 1 and 3): its size is the one asked for, its luminance
// varies (a Vulkan driver short of memory while decoding has given a uniform grey image "with success", issue 1220 of
// stable-diffusion.cpp), and almost no pure green of the control frame is left where the photo is not. Pure green is
// the test of M3: G at least 200, R and B at most 60. The photo's area is where the control frame is not pure green.
//
// An upscale is checked for its size only, read from the header of its PNG without decoding it.
//
// Pure Dart (package:image), run in an isolate of its own by the runner: decoding 1536 x 768 takes a while.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// The pure Dart image codecs, already in the lock through maplibre_gl (dart_sbs_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';

/// What the checks found on a generated image
class GeneratedImageReport {
  const GeneratedImageReport({
    required this.width,
    required this.height,
    required this.lumaDeviation,
    required this.greenLeft,
  });

  final int width;
  final int height;

  /// The standard deviation of the luminance, 0 to 255: at most [PanoV1.minLumaDeviation] is a grey image
  final double lumaDeviation;

  /// The fraction of the pixels outside the photo that stayed pure green
  final double greenLeft;

  /// Why the image is refused for a generation of [expectedWidth] x [expectedHeight], null when it is good
  String? problemFor(int expectedWidth, int expectedHeight) {
    if (width != expectedWidth || height != expectedHeight) {
      return 'an image of $width x $height, not $expectedWidth x $expectedHeight';
    }
    if (lumaDeviation <= PanoV1.minLumaDeviation) {
      return 'a grey image (luminance deviation ${lumaDeviation.toStringAsFixed(2)})';
    }
    if (greenLeft > PanoV1.maxGreen) {
      return '${(greenLeft * 100).toStringAsFixed(2)} % of pure green left outside the photo';
    }
    return null;
  }

  @override
  String toString() =>
      'GeneratedImageReport($width x $height, deviation ${lumaDeviation.toStringAsFixed(2)}, green '
      '${(greenLeft * 100).toStringAsFixed(3)} %)';
}

/// Whether a pixel is the pure green of the control frame, as M3 counts it
bool isPureGreen(num r, num g, num b) => g >= 200 && r <= 60 && b <= 60;

/// The checks of [image]; [control] is the control frame it was generated from (any size: it is read at the same
/// relative place), without it every pixel is outside the photo
GeneratedImageReport checkGeneratedImage(img.Image image, {img.Image? control}) {
  final width = image.width;
  final height = image.height;
  final rgb = _rgb8(image);
  final reference = control == null ? null : _rgb8(control);
  var sum = 0.0;
  var squares = 0.0;
  var outside = 0;
  var green = 0;
  for (var y = 0; y < height; y++) {
    final int controlRow = control == null ? 0 : _below(y * control.height ~/ height, control.height) * control.width;
    for (var x = 0; x < width; x++) {
      final at = 3 * (y * width + x);
      final r = rgb[at];
      final g = rgb[at + 1];
      final b = rgb[at + 2];
      final luma = 0.299 * r + 0.587 * g + 0.114 * b;
      sum += luma;
      squares += luma * luma;
      if (reference != null) {
        final int from = 3 * (controlRow + _below(x * control!.width ~/ width, control.width));
        if (!isPureGreen(reference[from], reference[from + 1], reference[from + 2])) {
          continue;
        }
      }
      outside++;
      if (isPureGreen(r, g, b)) {
        green++;
      }
    }
  }
  final count = math.max(1, width * height);
  final mean = sum / count;
  return GeneratedImageReport(
    width: width,
    height: height,
    lumaDeviation: math.sqrt(math.max(0, squares / count - mean * mean)),
    greenLeft: outside == 0 ? 0 : green / outside,
  );
}

/// [index] kept under [length]
int _below(int index, int length) => index < length ? index : length - 1;

/// Three bytes a pixel, whatever the depth and the channels of [image]
Uint8List _rgb8(img.Image image) {
  final plain = image.format == img.Format.uint8 && !image.hasPalette && image.numChannels >= 3;
  final eight = plain ? image : image.convert(format: img.Format.uint8, numChannels: 3);
  return eight.getBytes(order: img.ChannelOrder.rgb);
}

/// The checks of the image file at [path] against the control frame at [controlPath]; throws [FormatException] when
/// it is no image
GeneratedImageReport checkGeneratedFile(String path, {String? controlPath}) {
  final image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) {
    throw FormatException('Not an image: $path');
  }
  final control = controlPath == null ? null : img.decodeImage(File(controlPath).readAsBytesSync());
  return checkGeneratedImage(image, control: control);
}

/// The width and height a PNG says in its header, null when [header] (its first 24 bytes at least) is no PNG
(int, int)? pngSize(Uint8List header) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (header.length < 24) {
    return null;
  }
  for (var i = 0; i < signature.length; i++) {
    if (header[i] != signature[i]) {
      return null;
    }
  }
  if (String.fromCharCodes(header.sublist(12, 16)) != 'IHDR') {
    return null;
  }
  final view = ByteData.sublistView(header);
  return (view.getUint32(16), view.getUint32(20));
}

/// The size of the PNG file at [path], null when it is missing or no PNG
(int, int)? pngFileSize(String path) {
  try {
    final file = File(path).openSync();
    try {
      return pngSize(file.readSync(24));
    } finally {
      file.closeSync();
    }
  } on FileSystemException {
    return null;
  }
}
