// The JPEG codec of the AI features in pure Dart, on package:image (already in the lock for the thumbnails,
// desktop/library/local_image_codec.dart): an original decoded without any colour conversion, so that its ICC profile
// still describes its pixels, and the side by side pair encoded at the quality and the colour subsampling of the
// original (design-final 2026-10-26, section 2.3). The segments around the pixels are read and written by
// jpeg_segments.dart, the EXIF by exif_minimal.dart; the native codec of lot A2c takes over for the big photos and
// shares both. Synchronous and free of dart:ui, so that it runs in the worker isolate of a job.
//
// Also here, shared by both codecs: turning the decoded pixels upright (EXIF orientation) and by the quarter turns the
// user gave in the viewers, in one pass. The decoders give the pixels as stored; package:image would turn a JPEG by
// its orientation while decoding, so the codec hands it the pixels and tables only (JpegHeader.pixelsOnly).

import 'dart:typed_data';

// The pure Dart image codecs, already in the lock through maplibre_gl, as for the thumbnails (local_image_codec.dart)
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as img;
import 'package:immich_mobile/desktop/ai/codec/jpeg_segments.dart';
import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';

/// The codec on package:image
class DartSbsCodec implements SbsCodec {
  const DartSbsCodec();

  /// The largest pair this codec writes in reasonable time, in pixels: the pair of the 12 Mpx photo of a phone (4032 x
  /// 3024 makes 24.4 Mpx). Measured on real photos (lot A2b note): such a photo is decoded in 0.5 s and its pair
  /// encoded in 1.5 s on a Core i9-13980HX (Dart compiled AOT), while a 24 Mpx photo takes 1.3 s and 3.6 s. The
  /// native codec of lot A2c takes the larger ones.
  static const comfortablePairPixels = 25 * 1000 * 1000;

  @override
  String get name => 'dart';

  @override
  SbsDecoded decodeJpeg(Uint8List bytes) {
    final JpegHeader header;
    try {
      header = JpegHeader.read(bytes);
    } on FormatException catch (error) {
      throw SbsCodecException('Not a JPEG this codec reads: ${error.message}');
    }
    final img.Image image;
    try {
      final jpeg = img.JpegData()..read(header.pixelsOnly(bytes));
      image = jpeg.getImage();
    } catch (error) {
      // package:image throws its own exceptions, and range errors on damaged data
      throw SbsCodecException('The JPEG could not be decoded: $error');
    }
    // The profile of the pixels only: package:image gives RGB whatever the file holds
    final profile = header.iccProfile;
    return SbsDecoded(
      width: image.width,
      height: image.height,
      rgba: _rgbaOf(image),
      iccProfile: profile != null && isRgbIccProfile(profile) ? profile : null,
    );
  }

  @override
  Uint8List encodeSbs(SbsPicture picture, SbsEncodeOptions options) {
    final image = img.Image(width: picture.width, height: picture.height);
    _copyRgb(picture.rgba, image.toUint8List());
    final Uint8List encoded;
    try {
      encoded = img.JpegEncoder(quality: options.quality).encode(image, chroma: dartChromaFor(options.subsampling));
    } catch (error) {
      throw SbsCodecException('The pair could not be encoded: $error');
    }
    try {
      return withSegments(encoded, exif: options.exif, xmp: options.xmp, iccProfile: options.iccProfile);
    } on FormatException catch (error) {
      throw SbsCodecException(error.message);
    } on ArgumentError catch (error) {
      // An XMP packet too big for one APP1 segment, which the native codec refuses with its own status
      throw SbsCodecException('${error.message}');
    }
  }
}

/// The chroma package:image writes for [subsampling]: it writes 4:2:0 and 4:4:4 only, so the other layouts of an
/// original (4:2:2 from many cameras, 4:4:0, 4:1:1) are written 4:4:4, finer than the original, never coarser
img.JpegChroma dartChromaFor(ChromaSubsampling subsampling) =>
    subsampling == ChromaSubsampling.s420 ? img.JpegChroma.yuv420 : img.JpegChroma.yuv444;

/// The pixels of [decoded] as a viewer shows them: turned upright for the EXIF [orientation] (1 to 8, anything else
/// counts as 1), then by [quarterTurns] clockwise. One pass over the pixels, none when there is nothing to turn. The
/// profile goes with the pixels.
SbsDecoded orientDecoded(SbsDecoded decoded, {int orientation = 1, int quarterTurns = 0}) {
  final turns = quarterTurns % 4;
  final width = decoded.width;
  final height = decoded.height;
  var transform = _exifTransform(orientation, width, height);
  var outWidth = transform.swaps ? height : width;
  var outHeight = transform.swaps ? width : height;
  for (var turn = 0; turn < turns; turn++) {
    transform = _clockwise(outHeight).after(transform);
    final swapped = outWidth;
    outWidth = outHeight;
    outHeight = swapped;
  }
  if (transform.isIdentity) {
    return decoded;
  }

  // Each pixel of the result reads its source: the inverse of a signed permutation is its transpose
  final rgba = decoded.rgba.offsetInBytes % 4 == 0 ? decoded.rgba : Uint8List.fromList(decoded.rgba);
  final source = rgba.buffer.asUint32List(rgba.offsetInBytes, width * height);
  final out = Uint32List(outWidth * outHeight);
  final t = transform;
  // source x = a (X - c) + d (Y - f), source y = b (X - c) + e (Y - f)
  final step = t.a + t.b * width;
  var at = 0;
  for (var y = 0; y < outHeight; y++) {
    final sourceX = t.a * -t.c + t.d * (y - t.f);
    final sourceY = t.b * -t.c + t.e * (y - t.f);
    var index = sourceY * width + sourceX;
    for (var x = 0; x < outWidth; x++) {
      out[at++] = source[index];
      index += step;
    }
  }
  return SbsDecoded(width: outWidth, height: outHeight, rgba: out.buffer.asUint8List(), iccProfile: decoded.iccProfile);
}

/// A map of the pixel grid onto itself, turned or mirrored: x' = a x + b y + c, y' = d x + e y + f
class _Turn {
  const _Turn(this.a, this.b, this.c, this.d, this.e, this.f);

  final int a;
  final int b;
  final int c;
  final int d;
  final int e;
  final int f;

  bool get swaps => a == 0;

  bool get isIdentity => a == 1 && b == 0 && c == 0 && d == 0 && e == 1 && f == 0;

  /// This map after [first]
  _Turn after(_Turn first) => _Turn(
    a * first.a + b * first.d,
    a * first.b + b * first.e,
    a * first.c + b * first.f + c,
    d * first.a + e * first.d,
    d * first.b + e * first.e,
    d * first.c + e * first.f + f,
  );
}

/// Where each stored pixel of a [width] x [height] picture goes to show it upright, for an EXIF orientation
_Turn _exifTransform(int orientation, int width, int height) => switch (orientation) {
  2 => _Turn(-1, 0, width - 1, 0, 1, 0), // mirrored left to right
  3 => _Turn(-1, 0, width - 1, 0, -1, height - 1), // half a turn
  4 => _Turn(1, 0, 0, 0, -1, height - 1), // mirrored top to bottom
  5 => const _Turn(0, 1, 0, 1, 0, 0), // transposed
  6 => _Turn(0, -1, height - 1, 1, 0, 0), // a quarter turn clockwise
  7 => _Turn(0, -1, height - 1, -1, 0, width - 1), // transposed the other way
  8 => _Turn(0, 1, 0, -1, 0, width - 1), // a quarter turn anticlockwise
  _ => const _Turn(1, 0, 0, 0, 1, 0),
};

/// A quarter turn clockwise of a picture [height] pixels high
_Turn _clockwise(int height) => _Turn(0, -1, height - 1, 1, 0, 0);

/// The RGBA bytes of a decoded [image], opaque
Uint8List _rgbaOf(img.Image image) {
  final pixels = image.width * image.height;
  final out = Uint8List(pixels * 4);
  if (image.numChannels == 3 && image.format == img.Format.uint8) {
    final rgb = image.toUint8List();
    final words = out.buffer.asUint32List();
    final little = Endian.host == Endian.little;
    for (var pixel = 0, at = 0; pixel < pixels; pixel++, at += 3) {
      final r = rgb[at];
      final g = rgb[at + 1];
      final b = rgb[at + 2];
      words[pixel] = little ? 0xFF000000 | b << 16 | g << 8 | r : r << 24 | g << 16 | b << 8 | 0xFF;
    }
    return out;
  }
  // Any other layout package:image may give: through its own conversion
  final converted = image.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
  out.setAll(0, converted.toUint8List());
  return out;
}

/// The RGB of [rgba] into [rgb], dropping the alpha: the pair is opaque, and an RGB picture spares the encoder its
/// blending of every pixel with a background
void _copyRgb(Uint8List rgba, Uint8List rgb) {
  for (var from = 0, to = 0; to < rgb.length; from += 4, to += 3) {
    rgb[to] = rgba[from];
    rgb[to + 1] = rgba[from + 1];
    rgb[to + 2] = rgba[from + 2];
  }
}
