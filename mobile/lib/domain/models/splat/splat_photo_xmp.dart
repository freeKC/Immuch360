// The splat photo (plan of 3 November 2026, store/m2/splat-photo-2026-11-03/plan.md): a Gaussian splat scene kept on
// the Immich server inside a photo, "<stem>_splat.jpg". The server refuses .spz and .ply files by their extension, and
// keeps a JPEG byte for byte; so the scene travels as the tail of a JPEG poster, as the 3D scenes of the computers do
// (_scene3D.jpg, scene_container.dart):
//
//  1. SOI, then APP0 JFIF when the poster has one;
//  2. APP1 EXIF: Orientation 1, the size, the scene's date, its place when known, Software, and 4 KiB of the Microsoft
//     padding tag 0xEA1C in IFD0, so that the details pane of Windows writes a rating or a title in place;
//  3. APP1 XMP: the packet of this file (SplatPhotoXmp), 4 KiB of whitespace before its end, ending before byte
//     65,536 (readers look within the first 128 KiB);
//  4. the poster's ICC profile, its pixels and its EOI;
//  5. the SPZ, byte for byte, as the last SplatLength bytes of the file, checked by SplatSha256.
//
// FormatVersion stays 1 for this kind: release 40 reads a packet of ours of another kind with FormatVersion 1 as a
// plain photo, and one of FormatVersion 2 as a 3D photo of a newer version (stereo_photo_probe.dart). A change an older
// reader would misread takes a new SplatFormat value instead. The class stands apart from ImmersiveXmp, whose kinds
// and exhaustive switches the splat maker's branch extends.

import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/splat/splat_header.dart';

/// Immuch360:Kind of a splat photo (ImmersiveKind.gaussianSplat of the splat maker's branch)
const splatPhotoKind = 'GaussianSplat';

/// Immuch360:FormatVersion of a splat photo, for good (see the top of this file)
const splatPhotoFormatVersion = 1;

/// Immuch360:SplatFormat of the payload this build writes and reads: one SPZ file, byte for byte
const splatPhotoFormatSpz = 'spz';

/// The newest SPZ version a splat photo of this build carries
const splatPhotoMaxSpzVersion = 4;

/// The word of the name of a splat photo, and what its name ends with before the extension
const splatPhotoNameWord = 'splat';
const splatPhotoNameSuffix = '_splat';
const splatPhotoExtension = '.jpg';

/// How much of the head of a file the readers look at for the packet
const splatPhotoHeadBytes = 128 * 1024;

/// The writer ends the packet before this byte
const splatPhotoPacketWithin = 65536;

/// The shortest and the longest scene: the format's limit (a Kotlin Int), and the writer's own, past which it refuses
const splatPhotoMinLength = 32;
const splatPhotoFormatMaxLength = 2147483647;
const splatPhotoMaxLength = 1 << 30;

/// Past this many bytes a save warns that some servers refuse such files (Cloudflare Tunnel stops at 100 MB)
const splatPhotoWarnLength = 95000000;

/// The poster: its long side, its JPEG quality, the shape of its frame (long side over short side) readers accept, and
/// the most bytes it may take
const splatPhotoPosterLongest = 1600;
const splatPhotoPosterMaxLongest = 2048;
const splatPhotoPosterQuality = 85;
const splatPhotoRatioMin = 1.25;
const splatPhotoRatioMax = 1.85;
const splatPhotoPosterMaxBytes = 1 << 20;

/// The bytes of padding in IFD0 (tag 0xEA1C) and at the end of the packet
const splatPhotoPadding = 4096;

/// The orientations of Turn upright a packet may name (SplatUp)
const splatPhotoUps = {'yUp', 'zUp', 'yDown'};

/// What made the poster (SplatPoster): the view on screen, a drawing of the scene, or a card with its name
enum SplatPosterKind {
  view,
  render,
  card;

  static SplatPosterKind? fromXmp(String? value) =>
      SplatPosterKind.values.where((kind) => kind.name == value).firstOrNull;
}

/// Immuch360:Origin of a splat photo: a file of another tool, or a scene the splat maker rebuilt from photos
const splatPhotoOriginUnknown = 'Unknown';
const splatPhotoOriginReconstructed = 'ReconstructedFromPhotos';

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

/// The packet of a splat photo (see the top of this file). Every field may be null on a packet read from a file; one
/// the writer makes has all the required ones.
final class SplatPhotoXmp {
  const SplatPhotoXmp({
    this.formatVersion = splatPhotoFormatVersion,
    this.splatFormat = splatPhotoFormatSpz,
    this.splatVersion,
    this.splatGaussians,
    this.splatShDegree,
    this.splatLength,
    this.splatSha256,
    this.splatName,
    this.splatSourceSha256,
    this.splatUp,
    this.splatPoster,
    this.origin = splatPhotoOriginUnknown,
    this.created,
    this.creatorTool,
    this.description,
  });

  final int formatVersion;

  /// "spz"; another value is a payload of a newer version
  final String? splatFormat;

  /// The version in the SPZ's header, 1 to 4
  final int? splatVersion;
  final int? splatGaussians;
  final int? splatShDegree;

  /// The bytes of the scene, the last ones of the file
  final int? splatLength;

  /// The SHA-256 of the scene, 64 lowercase hexadecimal characters
  final String? splatSha256;

  /// The name of the SPZ: the key of Turn upright and of the computers' answers, as for the .spz opened from a share
  final String? splatName;

  /// The SHA-256 of the file the user saved (a PLY converted, or the SPZ itself)
  final String? splatSourceSha256;

  /// yUp, zUp or yDown when the user chose Turn upright before saving
  final String? splatUp;
  final SplatPosterKind? splatPoster;

  /// Unknown or ReconstructedFromPhotos
  final String? origin;

  /// ISO 8601 with its offset
  final String? created;
  final String? creatorTool;

  /// dc:description, x-default: the caption Immich shows under the photo
  final String? description;

  /// Made by a newer version: a FormatVersion past 1, another payload than an SPZ, an SPZ past version 4. Shown as a
  /// photo, "made by a newer version of Immuch360"
  bool get isNewer =>
      formatVersion > splatPhotoFormatVersion ||
      (splatFormat != null && splatFormat != splatPhotoFormatSpz) ||
      (splatVersion != null && splatVersion! > splatPhotoMaxSpzVersion);

  /// Every required field is there and possible: the scene may be looked for
  bool get isComplete {
    final version = splatVersion;
    final gaussians = splatGaussians;
    final degree = splatShDegree;
    final length = splatLength;
    final sum = splatSha256;
    final name = splatName;
    return splatFormat == splatPhotoFormatSpz &&
        version != null &&
        version >= 1 &&
        gaussians != null &&
        gaussians > 0 &&
        degree != null &&
        degree >= 0 &&
        degree <= 4 &&
        length != null &&
        length >= splatPhotoMinLength &&
        length <= splatPhotoFormatMaxLength &&
        sum != null &&
        _sha256Hex.hasMatch(sum) &&
        name != null &&
        name.trim().isNotEmpty;
  }

  /// The head of the scene as the packet tells it, for the gate of a device before any byte of the scene is read; null
  /// for a packet of a newer version or an incomplete one
  SplatHead? get head => isComplete && !isNewer
      ? SplatHead(
          format: SplatFormat.spz,
          formatVersion: splatVersion!,
          gaussians: splatGaussians!,
          shDegree: splatShDegree!,
        )
      : null;

  /// The packet, wrapped for a file, its 4 KiB of padding before its end (see [splatPhotoPadding])
  String toXml() {
    const prefix = immuch360XmpPrefix;
    final packet = xmpPacket(
      namespaces: [('xmp', xmpBasicNamespace), ('dc', dublinCoreNamespace), (prefix, immuch360XmpNamespace)],
      attributes: [
        if (creatorTool case final tool?) XmpAttribute('xmp:CreatorTool', tool),
        XmpAttribute('$prefix:FormatVersion', '$formatVersion'),
        const XmpAttribute('$immuch360XmpPrefix:Kind', splatPhotoKind),
        if (origin case final value?) XmpAttribute('$prefix:Origin', value),
        if (created case final value?) XmpAttribute('$prefix:Created', value),
        if (splatFormat case final value?) XmpAttribute('$prefix:SplatFormat', value),
        if (splatVersion case final value?) XmpAttribute('$prefix:SplatVersion', '$value'),
        if (splatGaussians case final value?) XmpAttribute('$prefix:SplatGaussians', '$value'),
        if (splatShDegree case final value?) XmpAttribute('$prefix:SplatShDegree', '$value'),
        if (splatLength case final value?) XmpAttribute('$prefix:SplatLength', '$value'),
        if (splatSha256 case final value?) XmpAttribute('$prefix:SplatSha256', value),
        if (splatName case final value?) XmpAttribute('$prefix:SplatName', value),
        if (splatSourceSha256 case final value?) XmpAttribute('$prefix:SplatSourceSha256', value),
        if (splatUp case final value?) XmpAttribute('$prefix:SplatUp', value),
        if (splatPoster case final value?) XmpAttribute('$prefix:SplatPoster', value.name),
      ],
      description: description,
    );
    return withXmpPadding(packet);
  }

  /// The packet of a splat photo in [xmp], null without our namespace or with another Kind
  static SplatPhotoXmp? parse(String xmp) {
    final prefix = xmpPrefixOf(xmp, immuch360XmpNamespace);
    if (prefix == null || xmpValueOf(xmp, prefix, 'Kind') != splatPhotoKind) {
      return null;
    }
    String? field(String name) => xmpValueOf(xmp, prefix, name);
    int? integer(String name) => int.tryParse(field(name)?.trim() ?? '');
    final up = field('SplatUp');
    return SplatPhotoXmp(
      formatVersion: integer('FormatVersion') ?? splatPhotoFormatVersion,
      splatFormat: field('SplatFormat'),
      splatVersion: integer('SplatVersion'),
      splatGaussians: integer('SplatGaussians'),
      splatShDegree: integer('SplatShDegree'),
      splatLength: integer('SplatLength'),
      splatSha256: field('SplatSha256'),
      splatName: field('SplatName'),
      splatSourceSha256: field('SplatSourceSha256'),
      splatUp: splatPhotoUps.contains(up) ? up : null,
      splatPoster: SplatPosterKind.fromXmp(field('SplatPoster')),
      origin: field('Origin'),
      created: field('Created'),
      creatorTool: xmpValueOf(xmp, xmpPrefixOf(xmp, xmpBasicNamespace) ?? 'xmp', 'CreatorTool'),
      description: xmpDescriptionOf(xmp, xmpPrefixOf(xmp, dublinCoreNamespace) ?? 'dc'),
    );
  }

  /// The packet of a splat photo in [bytes], the head of a file, null when there is none. Only a JPEG is read, and only
  /// its first [splatPhotoHeadBytes]: a PNG that carries our packet is never taken for a splat photo.
  static SplatPhotoXmp? findIn(Uint8List bytes) {
    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return null;
    }
    final head = bytes.length > splatPhotoHeadBytes ? Uint8List.sublistView(bytes, 0, splatPhotoHeadBytes) : bytes;
    return findXmpPacketIn(head, parse);
  }

  SplatPhotoXmp copyWith({String? description, String? splatUp, SplatPosterKind? splatPoster}) => SplatPhotoXmp(
    formatVersion: formatVersion,
    splatFormat: splatFormat,
    splatVersion: splatVersion,
    splatGaussians: splatGaussians,
    splatShDegree: splatShDegree,
    splatLength: splatLength,
    splatSha256: splatSha256,
    splatName: splatName,
    splatSourceSha256: splatSourceSha256,
    splatUp: splatUp ?? this.splatUp,
    splatPoster: splatPoster ?? this.splatPoster,
    origin: origin,
    created: created,
    creatorTool: creatorTool,
    description: description ?? this.description,
  );

  @override
  bool operator ==(Object other) =>
      other is SplatPhotoXmp &&
      other.formatVersion == formatVersion &&
      other.splatFormat == splatFormat &&
      other.splatVersion == splatVersion &&
      other.splatGaussians == splatGaussians &&
      other.splatShDegree == splatShDegree &&
      other.splatLength == splatLength &&
      other.splatSha256 == splatSha256 &&
      other.splatName == splatName &&
      other.splatSourceSha256 == splatSourceSha256 &&
      other.splatUp == splatUp &&
      other.splatPoster == splatPoster &&
      other.origin == origin &&
      other.created == created &&
      other.creatorTool == creatorTool &&
      other.description == description;

  @override
  int get hashCode => Object.hash(
    formatVersion,
    splatFormat,
    splatVersion,
    splatGaussians,
    splatShDegree,
    splatLength,
    splatSha256,
    splatName,
    splatSourceSha256,
    splatUp,
    splatPoster,
    origin,
    created,
    creatorTool,
    description,
  );

  @override
  String toString() =>
      'SplatPhotoXmp($splatName, $splatFormat $splatVersion, $splatGaussians gaussians, degree $splatShDegree, '
      '$splatLength bytes${isNewer ? ', newer' : ''})';
}

/// [packet] (an xpacket of xmpPacket) with [splatPhotoPadding] bytes of whitespace before its end: lines of 99 spaces
/// and a line feed, the last one shorter, so that a program that writes a field in place finds room for it
String withXmpPadding(String packet, {int padding = splatPhotoPadding}) {
  const end = '<?xpacket end="w"?>';
  final at = packet.lastIndexOf(end);
  if (at < 0) {
    return packet;
  }
  return '${packet.substring(0, at)}${xmpWhitespace(padding)}${packet.substring(at)}';
}

/// [length] bytes of whitespace: lines of 99 spaces and a line feed, the last one cut
String xmpWhitespace(int length) {
  final buffer = StringBuffer();
  var left = length;
  while (left > 0) {
    final line = left >= 100 ? 100 : left;
    buffer
      ..write(' ' * (line - 1))
      ..write('\n');
    left -= line;
  }
  return buffer.toString();
}

/// Whether a file named [name] may be a splat photo, so that its head is worth reading: the word "splat" in its name,
/// split as the probe of the 3D scenes splits one (on dots, underscores, dashes and spaces, in any case)
bool isSplatPhotoCandidate(String name) => name.toLowerCase().split(RegExp(r'[._\- ]+')).contains(splatPhotoNameWord);

/// Characters Windows refuses in a file name (and / for the other systems), plus the control characters
final _forbiddenCharacters = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Names Windows keeps for devices, with or without an extension
final _reservedNames = RegExp(r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$', caseSensitive: false);

/// The longest stem kept, so that the whole name stays well under 255 characters
const _maxStemLength = 180;

/// The name of the splat photo of the scene [sourceName] (a path or a name): its stem without a trailing "_splat",
/// made safe for every system, then "_splat.jpg". "salon.spz" and "salon_splat.spz" both give "salon_splat.jpg".
String splatPhotoNameFor(String sourceName) {
  final base = sourceName.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ?? sourceName;
  var stem = fileStem(base);
  if (stem.toLowerCase().endsWith(splatPhotoNameSuffix)) {
    stem = stem.substring(0, stem.length - splatPhotoNameSuffix.length);
  }
  stem = stem.replaceAll(_forbiddenCharacters, '_').trim();
  stem = stem.replaceAll(RegExp(r'[. ]+$'), '');
  if (stem.isEmpty || stem == '.' || stem == '..') {
    stem = 'scene';
  }
  if (_reservedNames.hasMatch(stem)) {
    stem = '_$stem';
  }
  if (stem.length > _maxStemLength) {
    stem = stem.substring(0, _maxStemLength);
  }
  return '$stem$splatPhotoNameSuffix$splatPhotoExtension';
}
