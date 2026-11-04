// Pictures for the tests of the inputs of a splat scene (lot SP5): a textured scene seen from a moving point, sharp or
// blurred, as RGBA, and as a JPEG with the EXIF of a camera, written by package:image so that the reader of the app is
// not its own witness.

import 'dart:math' as math;
import 'dart:typed_data';

// Pure Dart, already in the lock through maplibre_gl, as in lib/desktop/library/local_image_codec.dart
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;

/// A textured picture of [width] x [height] RGBA: blocks of [cell] pixels of three tones in a fixed pseudo random
/// pattern, moved by [shift] pixels as a camera that walks along; [blur] passes of a 5 x 5 box blur after
Uint8List texturedRgba(int width, int height, {int shift = 0, int blur = 0, int cell = 3, int seed = 7}) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final cx = (x + shift) ~/ cell;
      final cy = y ~/ cell;
      final hash = ((cx * 73856093) ^ (cy * 19349663) ^ seed) & 0x7fffffff;
      final tone = 40 + (hash % 3) * 80;
      final at = (y * width + x) * 4;
      rgba[at] = tone;
      rgba[at + 1] = (tone + 30) % 256;
      rgba[at + 2] = 255 - tone;
      rgba[at + 3] = 255;
    }
  }
  var out = rgba;
  for (var pass = 0; pass < blur; pass++) {
    out = boxBlurred(out, width, height, 2);
  }
  return out;
}

/// [rgba] blurred by a box of 2 [radius] + 1 pixels, borders clamped
Uint8List boxBlurred(Uint8List rgba, int width, int height, int radius) {
  final out = Uint8List(rgba.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < 3; c++) {
        var sum = 0;
        var count = 0;
        for (var dy = -radius; dy <= radius; dy++) {
          final yy = math.min(height - 1, math.max(0, y + dy));
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = math.min(width - 1, math.max(0, x + dx));
            sum += rgba[(yy * width + xx) * 4 + c];
            count++;
          }
        }
        out[(y * width + x) * 4 + c] = sum ~/ count;
      }
      out[(y * width + x) * 4 + 3] = 255;
    }
  }
  return out;
}

/// The camera fields a test photo carries in its EXIF
class TestCamera {
  const TestCamera({
    this.make,
    this.model,
    this.focalLength,
    this.focalLength35mm,
    this.focalPlaneXResolution,
    this.focalPlaneResolutionUnit,
  });

  final String? make;
  final String? model;
  final (int, int)? focalLength;
  final int? focalLength35mm;
  final (int, int)? focalPlaneXResolution;
  final int? focalPlaneResolutionUnit;
}

/// A JPEG of [rgba] ([width] x [height] as stored) with the EXIF [orientation] and [camera], written by package:image
Uint8List testJpeg(Uint8List rgba, int width, int height, {int orientation = 1, TestCamera? camera, int quality = 95}) {
  final image = img.Image.fromBytes(width: width, height: height, bytes: rgba.buffer, numChannels: 4);
  image.exif.imageIfd.orientation = orientation;
  if (camera != null) {
    if (camera.make case final make?) {
      image.exif.imageIfd['Make'] = make;
    }
    if (camera.model case final model?) {
      image.exif.imageIfd['Model'] = model;
    }
    if (camera.focalLength case final focal?) {
      image.exif.exifIfd['FocalLength'] = img.IfdValueRational(focal.$1, focal.$2);
    }
    if (camera.focalLength35mm case final focal?) {
      image.exif.exifIfd['FocalLengthIn35mmFilm'] = img.IfdValueShort(focal);
    }
    if (camera.focalPlaneXResolution case final resolution?) {
      image.exif.exifIfd['FocalPlaneXResolution'] = img.IfdValueRational(resolution.$1, resolution.$2);
      image.exif.exifIfd['FocalPlaneYResolution'] = img.IfdValueRational(resolution.$1, resolution.$2);
    }
    if (camera.focalPlaneResolutionUnit case final unit?) {
      image.exif.exifIfd['FocalPlaneResolutionUnit'] = img.IfdValueShort(unit);
    }
  }
  return img.encodeJpg(image, quality: quality);
}
