// The JPEG side of the AI features on a computer: the original decoded without any colour conversion, and the side by
// side pair encoded with its EXIF, XMP and ICC segments (design-final 2026-10-26, sections 2.3 and 2.8). Two
// implementations: DartSbsCodec on package:image (lot A2b) and NativeSbsCodec on a Rust crate for the big photos
// (lot A2c), chosen by measure. Synchronous, as everything in the body of a job (see DepthBackend).

import 'dart:typed_data';

/// The chroma subsampling of a JPEG, read from the sampling factors of its frame header and written the same way
enum ChromaSubsampling { s444, s422, s420, s440, s411 }

/// A decoded JPEG: RGBA pixels as stored in the file, no orientation applied, no colour conversion
class SbsDecoded {
  SbsDecoded({required this.width, required this.height, required this.rgba, this.iccProfile})
    : assert(rgba.length == width * height * 4, 'RGBA of $width x $height');

  final int width;
  final int height;

  /// Rows of RGBA bytes, top to bottom
  final Uint8List rgba;

  /// The ICC profile of the file (its APP2 chunks joined), null when it has none
  final Uint8List? iccProfile;
}

/// The pair to encode: one RGBA picture twice as wide as an eye, the left eye on the left
class SbsPicture {
  SbsPicture({required this.width, required this.height, required this.rgba})
    : assert(width.isEven, 'Two eyes side by side'),
      assert(rgba.length == width * height * 4, 'RGBA of $width x $height');

  /// One picture of any width rather than a pair: a texture or the preview of a 3D scene (lot S1), which the codecs
  /// write the same way
  SbsPicture.single({required this.width, required this.height, required this.rgba})
    : assert(rgba.length == width * height * 4, 'RGBA of $width x $height');

  /// The width of the pair, two eyes
  final int width;
  final int height;
  final Uint8List rgba;
}

/// How the pair is written
class SbsEncodeOptions {
  const SbsEncodeOptions({
    required this.quality,
    this.subsampling = ChromaSubsampling.s444,
    this.exif,
    this.xmp,
    this.iccProfile,
  }) : assert(quality >= 1 && quality <= 100, 'A JPEG quality is 1 to 100');

  /// 1 to 100: the quality of the original estimated from its tables, kept between 85 and 97, 92 without tables
  final int quality;
  final ChromaSubsampling subsampling;

  /// The APP1 payload of the EXIF, "Exif\0\0" and its TIFF structure, written first
  final Uint8List? exif;

  /// The XMP packet, written in its own APP1 segment after the EXIF
  final String? xmp;

  /// The ICC profile, written last in APP2 chunks of 65 519 bytes; only the profile the pixels are in
  final Uint8List? iccProfile;
}

/// Thrown when a JPEG cannot be decoded or the pair cannot be encoded
class SbsCodecException implements Exception {
  const SbsCodecException(this.message);

  final String message;

  @override
  String toString() => 'SbsCodecException: $message';
}

/// Decodes the originals and encodes the pairs
abstract interface class SbsCodec {
  /// "dart" or "native", for the logs and the measures
  String get name;

  /// The pixels of the JPEG [bytes]. Throws [SbsCodecException].
  SbsDecoded decodeJpeg(Uint8List bytes);

  /// The JPEG of [picture]: SOI, the EXIF, the XMP, the ICC chunks, then the image. Throws [SbsCodecException].
  Uint8List encodeSbs(SbsPicture picture, SbsEncodeOptions options);
}
