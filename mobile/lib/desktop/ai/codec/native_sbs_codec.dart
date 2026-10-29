// The SbsCodec of the big photos: the Rust crate of mobile/packages/immuch_sbs_codec (zune-jpeg and jpeg-encoder)
// through dart:ffi, where package:image takes seconds (design-final 2026-10-26, sections 2.3 and 2.8, lot A2c). Same
// contract as DartSbsCodec: an original decoded without any colour conversion with the ICC profile of its pixels, and
// a pair written as SOI, EXIF, XMP, ICC chunks, then the image. The library is in the Windows, Linux and macOS builds
// only; [NativeSbsCodec.available] says whether this process has it, and the job falls back to the Dart codec when
// it does not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immuch_sbs_codec/immuch_sbs_codec.dart' as native;

class NativeSbsCodec implements SbsCodec {
  const NativeSbsCodec();

  /// Whether the library is in this build and loads
  static bool get available => native.nativeCodecAvailable;

  /// Why it cannot be used, for the logs; null when it can
  static String? get unavailableReason => native.nativeCodecUnavailableReason;

  @override
  String get name => 'native';

  @override
  SbsDecoded decodeJpeg(Uint8List bytes) {
    final decoded = _call(() => native.decodeJpeg(bytes));
    return SbsDecoded(width: decoded.width, height: decoded.height, rgba: decoded.rgba, iccProfile: decoded.iccProfile);
  }

  @override
  Uint8List encodeSbs(SbsPicture picture, SbsEncodeOptions options) => _call(
    () => native.encodeJpeg(
      picture.rgba,
      width: picture.width,
      height: picture.height,
      quality: options.quality,
      subsampling: nativeSubsampling(options.subsampling),
      exif: options.exif,
      xmp: options.xmp == null ? null : utf8.encode(options.xmp!),
      icc: options.iccProfile,
    ),
  );
}

/// The subsampling as the C interface numbers it
native.NativeSubsampling nativeSubsampling(ChromaSubsampling subsampling) => switch (subsampling) {
  ChromaSubsampling.s444 => native.NativeSubsampling.s444,
  ChromaSubsampling.s422 => native.NativeSubsampling.s422,
  ChromaSubsampling.s420 => native.NativeSubsampling.s420,
  ChromaSubsampling.s440 => native.NativeSubsampling.s440,
  ChromaSubsampling.s411 => native.NativeSubsampling.s411,
};

T _call<T>(T Function() body) {
  try {
    return body();
  } on native.NativeCodecException catch (error) {
    // The status word first ("outOfMemory: ..."), for the job to tell a photo too big from a broken file
    throw SbsCodecException('${error.status.name}: ${error.message}');
  }
}
