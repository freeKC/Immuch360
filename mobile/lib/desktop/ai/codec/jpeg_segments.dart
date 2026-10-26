// The segments of a JPEG around its pixels, read and written without any decoder: what the 3D photo takes from its
// original (the EXIF orientation, the ICC profile, the quality and the colour subsampling) and what it carries in front
// of its own pixels (a minimal EXIF, our XMP, the profile). Both codecs share it (package:image in DartSbsCodec, the
// Rust crate of lot A2c), so that the rules of design-final 2026-10-26, section 2.3, points 3, 9 and 10, live in one
// place and the native codec only has to move pixels.
//
// Why not the segments of package:image: its decoder keeps only the last APP2 chunk of a profile, with the chunk
// numbers inside, and its encoder writes a profile in a single APP2, whatever its size. A Display P3 profile fits in
// one chunk, but the profiles of some cameras and of edited photos do not.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/desktop/ai/codec/sbs_codec.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';

/// The payload of an APP2 chunk of an ICC profile: 65 535 for the length field, minus 2 for itself, minus 14 for the
/// signature, the chunk number and the count
const iccChunkPayload = 65519;

/// The quality of a pair whose original has no quantisation table (a PNG, a HEIC)
const sbsDefaultQuality = 92;

/// The bounds of the quality of a pair: no worse than 85, so that a low quality original does not get worse with a
/// second compression, and no better than 97, above which the file grows with nothing to see
const sbsMinQuality = 85;
const sbsMaxQuality = 97;

const _soi = 0xD8;
const _eoi = 0xD9;
const _sos = 0xDA;
const _dqt = 0xDB;
const _app0 = 0xE0;
const _app1 = 0xE1;
const _app2 = 0xE2;
const _app14 = 0xEE;

const _exifSignature = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
const _iccSignature = [0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00]; // "ICC_PROFILE\0"
const _adobeSignature = [0x41, 0x64, 0x6F, 0x62, 0x65]; // "Adobe"

/// Where the coefficients of an 8 x 8 block in zigzag order (the order of a DQT segment) sit in row order
const _zigzagToNatural = [
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5,
  12, 19, 26, 33, 40, 48, 41, 34,
  27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36,
  29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46,
  53, 60, 61, 54, 47, 55, 62, 63,
];

/// The luminance table of the JPEG standard (Annex K), row order, the one the IJG library scales by the quality
const _standardLuminance = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

/// One marker segment before the image data
class JpegSegment {
  const JpegSegment(this.marker, this.offset, this.length);

  /// The second byte of the marker: 0xE1 for APP1, 0xDB for DQT
  final int marker;

  /// Where its 0xFF is
  final int offset;

  /// Its length field: the payload and the two bytes of the field
  final int length;

  int get payloadOffset => offset + 4;
  int get payloadLength => length - 2;

  /// Just after it
  int get end => offset + 2 + length;
}

/// A component of the frame header: its sampling factors and its quantisation table
class JpegComponent {
  const JpegComponent(this.id, this.horizontal, this.vertical, this.table);

  final int id;
  final int horizontal;
  final int vertical;
  final int table;
}

/// What the head of a JPEG says, read up to its first scan
class JpegHeader {
  JpegHeader._({
    required this.segments,
    required this.tables,
    required this.frameMarker,
    required this.width,
    required this.height,
    required this.components,
    required this.exif,
    required this.iccProfile,
    required this.adobeTransform,
    required this.imageDataOffset,
  });

  /// Reads the segments of [bytes] up to the start of scan. Throws [FormatException] when it is not a JPEG or a
  /// segment runs past the end.
  factory JpegHeader.read(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != _soi) {
      throw const FormatException('Not a JPEG');
    }
    final segments = <JpegSegment>[];
    final tables = <int, Uint16List>{};
    final iccChunks = <int, Uint8List>{};
    int? iccCount;
    var iccBroken = false;
    int? frameMarker;
    var width = 0;
    var height = 0;
    var components = const <JpegComponent>[];
    Uint8List? exif;
    int? adobeTransform;

    var at = 2;
    while (true) {
      if (at + 2 > bytes.length) {
        throw const FormatException('The JPEG ends before its image data');
      }
      if (bytes[at] != 0xFF) {
        throw FormatException('No marker at $at');
      }
      var marker = bytes[at + 1];
      // Fill bytes: any number of 0xFF before a marker
      while (marker == 0xFF && at + 2 < bytes.length) {
        at++;
        marker = bytes[at + 1];
      }
      if (marker == _sos || marker == _eoi) {
        break;
      }
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        at += 2;
        continue;
      }
      if (at + 4 > bytes.length) {
        throw const FormatException('The JPEG ends in a marker');
      }
      final length = bytes[at + 2] << 8 | bytes[at + 3];
      final segment = JpegSegment(marker, at, length);
      if (length < 2 || segment.end > bytes.length) {
        throw FormatException('The segment 0x${marker.toRadixString(16)} at $at runs past the end');
      }
      segments.add(segment);
      final payload = Uint8List.sublistView(bytes, segment.payloadOffset, segment.end);

      if (marker == _dqt) {
        _readTables(payload, tables);
      } else if (_isFrameMarker(marker) && frameMarker == null) {
        if (payload.length < 6) {
          throw const FormatException('A frame header too short');
        }
        frameMarker = marker;
        height = payload[1] << 8 | payload[2];
        width = payload[3] << 8 | payload[4];
        final count = payload[5];
        if (payload.length < 6 + 3 * count) {
          throw const FormatException('A frame header too short for its components');
        }
        components = [
          for (var index = 0; index < count; index++)
            JpegComponent(
              payload[6 + 3 * index],
              payload[7 + 3 * index] >> 4,
              payload[7 + 3 * index] & 0x0F,
              payload[8 + 3 * index],
            ),
        ];
      } else if (marker == _app1 && exif == null && _startsWith(payload, _exifSignature)) {
        exif = payload;
      } else if (marker == _app2 && _startsWith(payload, _iccSignature)) {
        if (payload.length < 14) {
          iccBroken = true;
        } else {
          final number = payload[12];
          final count = payload[13];
          if (number == 0 ||
              number > count ||
              (iccCount != null && iccCount != count) ||
              iccChunks.containsKey(number)) {
            iccBroken = true;
          }
          iccCount = count;
          iccChunks[number] = Uint8List.sublistView(payload, 14);
        }
      } else if (marker == _app14 && payload.length >= 12 && _startsWith(payload, _adobeSignature)) {
        adobeTransform = payload[11];
      }
      at = segment.end;
    }

    return JpegHeader._(
      segments: segments,
      tables: tables,
      frameMarker: frameMarker,
      width: width,
      height: height,
      components: components,
      exif: exif,
      iccProfile: iccBroken ? null : _joinChunks(iccChunks, iccCount),
      adobeTransform: adobeTransform,
      imageDataOffset: at,
    );
  }

  /// The segments before the start of scan, in their order
  final List<JpegSegment> segments;

  /// The quantisation tables by their number, in row order
  final Map<int, Uint16List> tables;

  /// The marker of the frame header: 0xC0 baseline, 0xC1 extended, 0xC2 progressive; null without one
  final int? frameMarker;
  final int width;
  final int height;
  final List<JpegComponent> components;

  /// The APP1 payload of the EXIF, from "Exif\0\0" on; null without one
  final Uint8List? exif;

  /// The ICC profile, its APP2 chunks joined in their order; null without one, or when the chunks do not make a whole
  /// profile (a number missing or twice, counts that differ), as libjpeg does
  final Uint8List? iccProfile;

  /// The colour transform of an Adobe APP14 segment (0 none, 1 YCbCr, 2 YCCK), null without one
  final int? adobeTransform;

  /// Where the start of scan marker is
  final int imageDataOffset;

  /// The quality the IJG library was given to make the luminance table, 1 to 100: the quality whose scaled standard
  /// table is the closest (sum of the differences), the higher one on a tie. Exact for the files of libjpeg,
  /// libjpeg-turbo, Pillow and package:image; the nearest IJG quality for the tables of a camera. Null without a
  /// table.
  int? get estimatedQuality {
    final luminance = tables[components.isEmpty ? 0 : components.first.table] ?? tables[0];
    if (luminance == null) {
      return null;
    }
    int? best;
    var bestDistance = 0;
    for (var quality = 100; quality >= 1; quality--) {
      final scale = quality < 50 ? 5000 ~/ quality : 200 - 2 * quality;
      var distance = 0;
      for (var index = 0; index < 64; index++) {
        final value = ((_standardLuminance[index] * scale + 50) ~/ 100).clamp(1, 255);
        distance += (value - luminance[index]).abs();
      }
      if (best == null || distance < bestDistance) {
        best = quality;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// The colour subsampling of the frame, from the sampling factors of the luminance and of the first chroma
  /// component; null for a grey picture or an unusual layout
  ChromaSubsampling? get subsampling {
    if (components.length < 3) {
      return null;
    }
    final luma = components[0];
    final chroma = components[1];
    if (chroma.horizontal == 0 || chroma.vertical == 0 || components[2].horizontal != chroma.horizontal) {
      return null;
    }
    if (components[2].vertical != chroma.vertical ||
        luma.horizontal % chroma.horizontal != 0 ||
        luma.vertical % chroma.vertical != 0) {
      return null;
    }
    return switch ((luma.horizontal ~/ chroma.horizontal, luma.vertical ~/ chroma.vertical)) {
      (1, 1) => ChromaSubsampling.s444,
      (2, 1) => ChromaSubsampling.s422,
      (2, 2) => ChromaSubsampling.s420,
      (1, 2) => ChromaSubsampling.s440,
      (4, 1) => ChromaSubsampling.s411,
      _ => null,
    };
  }

  /// [bytes] with only the segments a decoder needs for the pixels: the tables, the frame header, JFIF and the
  /// Adobe colour transform. The EXIF, the XMP, the profile and the comments are left out, so that a decoder neither
  /// turns the picture by its orientation nor trips on a damaged EXIF; this header keeps them.
  Uint8List pixelsOnly(Uint8List bytes) {
    final kept = [
      for (final segment in segments)
        if (!_isMetadata(segment.marker)) segment,
    ];
    if (kept.length == segments.length) {
      return bytes;
    }
    var length = 2 + bytes.length - imageDataOffset;
    for (final segment in kept) {
      length += segment.end - segment.offset;
    }
    final out = Uint8List(length);
    out[0] = 0xFF;
    out[1] = _soi;
    var at = 2;
    for (final segment in kept) {
      out.setRange(at, at + segment.end - segment.offset, bytes, segment.offset);
      at += segment.end - segment.offset;
    }
    out.setRange(at, length, bytes, imageDataOffset);
    return out;
  }

  static bool _isMetadata(int marker) => (marker >= _app1 && marker <= 0xEF && marker != _app14) || marker == 0xFE;

  static bool _isFrameMarker(int marker) =>
      marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC;

  static void _readTables(Uint8List payload, Map<int, Uint16List> tables) {
    var at = 0;
    while (at < payload.length) {
      final precision = payload[at] >> 4;
      final number = payload[at] & 0x0F;
      final size = precision == 0 ? 64 : 128;
      if (at + 1 + size > payload.length) {
        throw const FormatException('A quantisation table runs past its segment');
      }
      final table = Uint16List(64);
      for (var index = 0; index < 64; index++) {
        final value = precision == 0
            ? payload[at + 1 + index]
            : payload[at + 1 + 2 * index] << 8 | payload[at + 2 + 2 * index];
        table[_zigzagToNatural[index]] = value;
      }
      tables[number] = table;
      at += 1 + size;
    }
  }

  static Uint8List? _joinChunks(Map<int, Uint8List> chunks, int? count) {
    if (count == null || chunks.length != count) {
      return null;
    }
    final builder = BytesBuilder(copy: false);
    for (var number = 1; number <= count; number++) {
      builder.add(chunks[number]!);
    }
    return builder.takeBytes();
  }
}

/// The quality of the pair made from an original whose luminance table gives [originalQuality]: the same, kept
/// between [sbsMinQuality] and [sbsMaxQuality]; [sbsDefaultQuality] without one (design-final 2.3, point 9)
int sbsQualityFor(int? originalQuality) =>
    originalQuality == null ? sbsDefaultQuality : originalQuality.clamp(sbsMinQuality, sbsMaxQuality);

/// The subsampling asked for the pair: the original's, 4:4:4 when it has none (a PNG, a grey JPEG)
ChromaSubsampling sbsSubsamplingFor(ChromaSubsampling? original) => original ?? ChromaSubsampling.s444;

/// [jpeg] as an encoder wrote it, with ours in front of its own: SOI, then the APP1 of [exif] (its payload from
/// "Exif\0\0" on), the APP1 of the [xmp] packet, the APP2 chunks of [iccProfile], then the rest of [jpeg]. The
/// metadata segments the encoder wrote (APP1 to APP15 but Adobe, comments) are dropped, and so is its JFIF APP0 when
/// an EXIF is given, which the EXIF standard wants right after SOI. Throws [FormatException] for an EXIF that does not
/// fit one segment or does not start with its signature, or a profile of more than 255 chunks.
Uint8List withSegments(Uint8List jpeg, {Uint8List? exif, String? xmp, Uint8List? iccProfile}) {
  final header = JpegHeader.read(jpeg);
  final ours = BytesBuilder(copy: false);
  if (exif != null) {
    if (!_startsWith(exif, _exifSignature)) {
      throw const FormatException('An EXIF payload starts with "Exif\\0\\0"');
    }
    ours.add(_segment(_app1, exif));
  }
  if (xmp != null) {
    ours.add(xmpApp1Segment(xmp));
  }
  if (iccProfile != null && iccProfile.isNotEmpty) {
    for (final chunk in iccChunks(iccProfile)) {
      ours.add(chunk);
    }
  }
  final out = BytesBuilder(copy: false)..add(const [0xFF, _soi]);
  var wroteOurs = false;
  void writeOurs() {
    if (!wroteOurs) {
      out.add(ours.takeBytes());
      wroteOurs = true;
    }
  }

  for (final segment in header.segments) {
    final marker = segment.marker;
    final isJfif = marker == _app0;
    if (JpegHeader._isMetadata(marker) || (isJfif && exif != null)) {
      continue;
    }
    if (!isJfif) {
      // Ours go after a kept JFIF, before the tables
      writeOurs();
    }
    out.add(Uint8List.sublistView(jpeg, segment.offset, segment.end));
  }
  writeOurs();
  out.add(Uint8List.sublistView(jpeg, header.imageDataOffset));
  return out.takeBytes();
}

/// The APP2 segments of [profile]: "ICC_PROFILE\0", the chunk number from 1, the count, then up to
/// [iccChunkPayload] bytes of the profile each
List<Uint8List> iccChunks(Uint8List profile) {
  final count = (profile.length + iccChunkPayload - 1) ~/ iccChunkPayload;
  if (count > 255) {
    throw FormatException('An ICC profile of ${profile.length} bytes needs more than 255 chunks');
  }
  return [
    for (var number = 1; number <= count; number++)
      _segment(_app2, [
        ..._iccSignature,
        number,
        count,
        ...Uint8List.sublistView(
          profile,
          (number - 1) * iccChunkPayload,
          number == count ? profile.length : number * iccChunkPayload,
        ),
      ]),
  ];
}

/// The payload of the XMP APP1 segments of [bytes], decoded as UTF-8, in their order
List<String> xmpPacketsOf(Uint8List bytes) {
  final header = JpegHeader.read(bytes);
  final signature = ascii.encode(xmpApp1Signature);
  return [
    for (final segment in header.segments)
      if (segment.marker == _app1 &&
          _startsWith(Uint8List.sublistView(bytes, segment.payloadOffset, segment.end), signature))
        utf8.decode(Uint8List.sublistView(bytes, segment.payloadOffset + signature.length, segment.end)),
  ];
}

Uint8List _segment(int marker, List<int> payload) {
  final length = payload.length + 2;
  if (length > 0xFFFF) {
    throw FormatException('A segment of ${payload.length} bytes does not fit its length field');
  }
  return Uint8List(payload.length + 4)
    ..[0] = 0xFF
    ..[1] = marker
    ..[2] = length >> 8
    ..[3] = length & 0xFF
    ..setRange(4, payload.length + 4, payload);
}

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) {
      return false;
    }
  }
  return true;
}
