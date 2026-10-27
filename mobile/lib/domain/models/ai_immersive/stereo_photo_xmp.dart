// The XMP packet a 3D photo of Immuch360 carries (design-final 2026-10-26, section 4.1). It is what makes the app
// treat the file as a side by side 3D photo, whatever its name, and what links it to its original on any device:
// the SHA-1 of the original in base64, as the checksum column of the library and Immich compute it. The description
// and the creator tool tell other software (SKYBOX, DeoVR, the Explorer, Immich) what the file is.
//
// Written by the computers, read by the computers and the Meta Quest. The reader is tolerant: the attributes may have
// become elements, the prefix may have changed when another tool rewrote the packet, fields may be missing, and a
// newer FormatVersion is still read so that the viewer can say the file was made by a newer version.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:uuid/uuid.dart';

export 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart' show xmpSafeText;

/// The signature of an XMP packet in a JPEG APP1 segment
const xmpApp1Signature = '$xmpBasicNamespace\u0000';

/// The content of the Immuch360 XMP of a 3D photo. Every field may be null on a packet read from a file; a packet made
/// by the app has them all (see [StereoPhotoXmp.estimated]). It also reads the common fields of the other kinds for a
/// build that knows only this class (see ImmersiveXmp.parse for the kinds of phases 2 and 3).
class StereoPhotoXmp implements ImmersiveXmp {
  const StereoPhotoXmp({
    this.formatVersion = immersiveFormatVersion,
    this.kind = ImmersiveKind.stereoPhoto,
    this.eyes,
    this.eyeOrder,
    this.eyeWidth,
    this.eyeHeight,
    this.leftEye,
    this.origin,
    this.depthModel,
    this.depthModelSha256,
    this.pipeline,
    this.parallax,
    this.convergence,
    this.derivativeId,
    this.sourceName,
    this.sourceSize,
    this.sourceSha1,
    this.sourceQuarterTurns,
    this.qualityFlags = const [],
    this.created,
    this.creatorTool,
    this.description,
  });

  /// The packet of a full side by side photo whose right eye relief-v1 made from the estimated depth of [sourceName],
  /// the left eye being the original
  factory StereoPhotoXmp.estimated({
    required int eyeWidth,
    required int eyeHeight,
    required String depthModelSha256,
    required String sourceName,
    required int sourceSize,
    required String sourceSha1,
    required int sourceQuarterTurns,
    required String created,
    required String creatorTool,
    String? derivativeId,
    double parallax = ReliefV1.parallax,
    double convergence = ReliefV1.convergence,
    List<ReliefQualityFlag> qualityFlags = const [],
  }) => StereoPhotoXmp(
    eyes: StereoEyes.full,
    eyeOrder: EyeOrder.leftRight,
    eyeWidth: eyeWidth,
    eyeHeight: eyeHeight,
    leftEye: LeftEyeSource.original,
    origin: ImmersiveOrigin.estimatedDepth,
    depthModel: depthModelName,
    depthModelSha256: depthModelSha256,
    pipeline: ReliefV1.pipeline,
    parallax: parallax,
    convergence: convergence,
    derivativeId: derivativeId ?? newDerivativeId(),
    sourceName: sourceName,
    sourceSize: sourceSize,
    sourceSha1: sourceSha1,
    sourceQuarterTurns: sourceQuarterTurns & 3,
    // In the order the packet writes them, so that a packet read back equals the one made
    qualityFlags: [
      for (final flag in ReliefQualityFlag.values)
        if (qualityFlags.contains(flag)) flag,
    ],
    created: created,
    creatorTool: creatorTool,
    description: stereoPhotoDescription,
  );

  /// Immuch360:FormatVersion, 1 when a packet has the Kind but not the version
  @override
  final int formatVersion;

  /// Immuch360:Kind; null for a kind this build does not know
  @override
  final ImmersiveKind? kind;
  final StereoEyes? eyes;
  final EyeOrder? eyeOrder;

  /// The size of one eye, in pixels
  final int? eyeWidth;
  final int? eyeHeight;
  final LeftEyeSource? leftEye;
  @override
  final ImmersiveOrigin? origin;

  /// The model that estimated the depth, and the SHA-256 of its file
  final String? depthModel;
  final String? depthModelSha256;

  /// The algorithm of the right eye, "relief-v1", and its settings
  @override
  final String? pipeline;
  final double? parallax;
  final double? convergence;

  /// "urn:uuid:..." of this file, which Replace and Delete check before touching it
  @override
  final String? derivativeId;

  /// The name and the size in bytes of the original
  @override
  final String? sourceName;
  @override
  final int? sourceSize;

  /// The SHA-1 of the bytes of the original, in base64 (as the checksum column of the library and Immich)
  @override
  final String? sourceSha1;

  /// The quarter turns clockwise the user gave the photo in the viewers (kept on the device, or a rotation saved on
  /// the server), applied after its EXIF orientation, 0 to 3
  @override
  final int? sourceQuarterTurns;
  @override
  final List<ReliefQualityFlag> qualityFlags;

  /// ISO 8601 with the offset of the computer, "2026-10-27T10:12:00+01:00" (see [xmpDateTime])
  @override
  final String? created;

  /// xmp:CreatorTool, "Immuch360 Desktop 3.3.0 (windows)"
  @override
  final String? creatorTool;

  /// dc:description, x-default
  @override
  final String? description;

  /// A packet made by a newer version of the format: shown flat, "made by a newer version"
  @override
  bool get isNewerFormat => formatVersion > immersiveFormatVersion;

  /// A side by side photo this build can show in 3D
  bool get isReadableStereoPhoto => kind == ImmersiveKind.stereoPhoto && !isNewerFormat;

  /// The relief of this file was estimated by AI (the honesty label goes with it)
  bool get isEstimatedRelief => origin == ImmersiveOrigin.estimatedDepth;

  /// What two versions of one original are compared on, "a version with the same settings exists": the model file,
  /// the pipeline, the parallax, the convergence and the quarter turns; null when one of them is missing
  @override
  String? get settingsKey {
    final model = depthModelSha256;
    final steps = pipeline;
    final shift = parallax;
    final plane = convergence;
    final turns = sourceQuarterTurns;
    if (model == null || steps == null || shift == null || plane == null || turns == null) {
      return null;
    }
    return '$model|$steps|${xmpDecimal(shift)}|${xmpDecimal(plane)}|$turns';
  }

  /// The XMP packet, wrapped for a file (xpacket), the fields in the order of the design; null fields are left out
  @override
  String toXml() => xmpPacket(
    namespaces: const [
      ('xmp', xmpBasicNamespace),
      ('dc', dublinCoreNamespace),
      (immuch360XmpPrefix, immuch360XmpNamespace),
    ],
    attributes: [
      for (final (name, value) in <(String, String)>[
        if (creatorTool case final tool?) ('xmp:CreatorTool', tool),
        ('$immuch360XmpPrefix:FormatVersion', '$formatVersion'),
        if (kind case final value?) ('$immuch360XmpPrefix:Kind', value.xmp),
        if (eyes case final value?) ('$immuch360XmpPrefix:StereoLayout', value.xmp),
        if (eyeOrder case final value?) ('$immuch360XmpPrefix:EyeOrder', value.xmp),
        if (eyeWidth case final value?) ('$immuch360XmpPrefix:EyeWidth', '$value'),
        if (eyeHeight case final value?) ('$immuch360XmpPrefix:EyeHeight', '$value'),
        if (leftEye case final value?) ('$immuch360XmpPrefix:LeftEye', value.xmp),
        if (origin case final value?) ('$immuch360XmpPrefix:Origin', value.xmp),
        if (depthModel case final value?) ('$immuch360XmpPrefix:DepthModel', value),
        if (depthModelSha256 case final value?) ('$immuch360XmpPrefix:DepthModelSha256', value),
        if (pipeline case final value?) ('$immuch360XmpPrefix:Pipeline', value),
        if (parallax case final value?) ('$immuch360XmpPrefix:Parallax', xmpDecimal(value)),
        if (convergence case final value?) ('$immuch360XmpPrefix:Convergence', xmpDecimal(value)),
        if (derivativeId case final value?) ('$immuch360XmpPrefix:DerivativeId', value),
        if (sourceName case final value?) ('$immuch360XmpPrefix:SourceName', value),
        if (sourceSize case final value?) ('$immuch360XmpPrefix:SourceSize', '$value'),
        if (sourceSha1 case final value?) ('$immuch360XmpPrefix:SourceSha1', value),
        if (sourceQuarterTurns case final value?) ('$immuch360XmpPrefix:SourceQuarterTurns', '$value'),
        ('$immuch360XmpPrefix:QualityFlags', qualityFlagsToXmp(qualityFlags)),
        if (created case final value?) ('$immuch360XmpPrefix:Created', value),
      ])
        XmpAttribute(name, value),
    ],
    description: description,
  );

  /// The Immuch360 fields of the XMP packet [xmp], null when it has no Immuch360 namespace or no Kind. A field this
  /// class does not know (Immuch360:Sources, the fields of a 3D scene or of a panorama) is left aside.
  static StereoPhotoXmp? parse(String xmp) {
    final prefix = xmpPrefixOf(xmp, immuch360XmpNamespace);
    if (prefix == null) {
      return null;
    }
    String? field(String name) => xmpValueOf(xmp, prefix, name);
    final kindText = field('Kind');
    if (kindText == null) {
      return null;
    }
    int? integer(String name) => int.tryParse(field(name) ?? '');
    double? decimal(String name) => double.tryParse(field(name) ?? '');
    final xmpPrefix = xmpPrefixOf(xmp, xmpBasicNamespace) ?? 'xmp';
    final dcPrefix = xmpPrefixOf(xmp, dublinCoreNamespace) ?? 'dc';
    final turns = integer('SourceQuarterTurns');
    return StereoPhotoXmp(
      formatVersion: integer('FormatVersion') ?? immersiveFormatVersion,
      kind: ImmersiveKind.fromXmp(kindText),
      eyes: StereoEyes.fromXmp(field('StereoLayout')),
      eyeOrder: EyeOrder.fromXmp(field('EyeOrder')),
      eyeWidth: integer('EyeWidth'),
      eyeHeight: integer('EyeHeight'),
      leftEye: LeftEyeSource.fromXmp(field('LeftEye')),
      origin: ImmersiveOrigin.fromXmp(field('Origin')),
      depthModel: field('DepthModel'),
      depthModelSha256: field('DepthModelSha256'),
      pipeline: field('Pipeline'),
      parallax: decimal('Parallax'),
      convergence: decimal('Convergence'),
      derivativeId: field('DerivativeId'),
      sourceName: field('SourceName'),
      sourceSize: integer('SourceSize'),
      sourceSha1: field('SourceSha1'),
      sourceQuarterTurns: turns == null ? null : turns & 3,
      qualityFlags: qualityFlagsFromXmp(field('QualityFlags')),
      created: field('Created'),
      creatorTool: xmpValueOf(xmp, xmpPrefix, 'CreatorTool'),
      description: xmpDescriptionOf(xmp, dcPrefix),
    );
  }

  /// The Immuch360 packet found in [bytes], the head of a file (a JPEG, a PNG, anything that keeps its XMP as text),
  /// null when there is none
  static StereoPhotoXmp? findIn(Uint8List bytes) => findXmpPacketIn(bytes, parse);

  /// A new "urn:uuid:..." for [derivativeId]
  static String newDerivativeId() => 'urn:uuid:${const Uuid().v4()}';

  /// [time] as Immuch360:Created writes it, with its offset: "2026-10-27T10:12:00+01:00"
  static String xmpDateTime(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    final offset = time.timeZoneOffset;
    final minutes = offset.inMinutes.abs();
    final sign = offset.isNegative ? '-' : '+';
    return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-${two(time.day)}'
        'T${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
  }

  @override
  bool operator ==(Object other) =>
      other is StereoPhotoXmp &&
      other.formatVersion == formatVersion &&
      other.kind == kind &&
      other.eyes == eyes &&
      other.eyeOrder == eyeOrder &&
      other.eyeWidth == eyeWidth &&
      other.eyeHeight == eyeHeight &&
      other.leftEye == leftEye &&
      other.origin == origin &&
      other.depthModel == depthModel &&
      other.depthModelSha256 == depthModelSha256 &&
      other.pipeline == pipeline &&
      other.parallax == parallax &&
      other.convergence == convergence &&
      other.derivativeId == derivativeId &&
      other.sourceName == sourceName &&
      other.sourceSize == sourceSize &&
      other.sourceSha1 == sourceSha1 &&
      other.sourceQuarterTurns == sourceQuarterTurns &&
      _sameFlags(other.qualityFlags, qualityFlags) &&
      other.created == created &&
      other.creatorTool == creatorTool &&
      other.description == description;

  @override
  int get hashCode => Object.hashAll([
    formatVersion,
    kind,
    eyes,
    eyeOrder,
    eyeWidth,
    eyeHeight,
    leftEye,
    origin,
    depthModel,
    depthModelSha256,
    pipeline,
    parallax,
    convergence,
    derivativeId,
    sourceName,
    sourceSize,
    sourceSha1,
    sourceQuarterTurns,
    Object.hashAll(qualityFlags),
    created,
    creatorTool,
    description,
  ]);

  @override
  String toString() => 'StereoPhotoXmp(${kind?.xmp} v$formatVersion, ${eyes?.xmp}, ${origin?.xmp}, $sourceName)';
}

/// The APP1 segment of a JPEG that carries [packet]: the marker, its length, the XMP signature and the packet in
/// UTF-8. A packet of more than 65 502 bytes needs the extended XMP, which the app never writes.
Uint8List xmpApp1Segment(String packet) {
  final payload = [...ascii.encode(xmpApp1Signature), ...utf8.encode(packet)];
  final length = payload.length + 2;
  if (length > 0xffff) {
    throw ArgumentError('An XMP packet of ${payload.length} bytes does not fit in one APP1 segment');
  }
  return Uint8List.fromList([0xff, 0xe1, length >> 8, length & 0xff, ...payload]);
}

bool _sameFlags(List<ReliefQualityFlag> a, List<ReliefQualityFlag> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
