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
import 'package:uuid/uuid.dart';

const _xmpNamespace = 'http://ns.adobe.com/xap/1.0/';
const _dcNamespace = 'http://purl.org/dc/elements/1.1/';

/// The signature of an XMP packet in a JPEG APP1 segment
const xmpApp1Signature = '$_xmpNamespace\u0000';

/// The content of the Immuch360 XMP of a 3D photo. Every field may be null on a packet read from a file; a packet made
/// by the app has them all (see [StereoPhotoXmp.estimated]).
class StereoPhotoXmp {
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
  final int formatVersion;

  /// Immuch360:Kind; null for a kind this build does not know
  final ImmersiveKind? kind;
  final StereoEyes? eyes;
  final EyeOrder? eyeOrder;

  /// The size of one eye, in pixels
  final int? eyeWidth;
  final int? eyeHeight;
  final LeftEyeSource? leftEye;
  final ImmersiveOrigin? origin;

  /// The model that estimated the depth, and the SHA-256 of its file
  final String? depthModel;
  final String? depthModelSha256;

  /// The algorithm of the right eye, "relief-v1", and its settings
  final String? pipeline;
  final double? parallax;
  final double? convergence;

  /// "urn:uuid:..." of this file, which Replace and Delete check before touching it
  final String? derivativeId;

  /// The name and the size in bytes of the original
  final String? sourceName;
  final int? sourceSize;

  /// The SHA-1 of the bytes of the original, in base64 (as the checksum column of the library and Immich)
  final String? sourceSha1;

  /// The quarter turns clockwise the user gave the photo in the viewers (kept on the device, or a rotation saved on
  /// the server), applied after its EXIF orientation, 0 to 3
  final int? sourceQuarterTurns;
  final List<ReliefQualityFlag> qualityFlags;

  /// ISO 8601 with the offset of the computer, "2026-10-27T10:12:00+01:00" (see [xmpDateTime])
  final String? created;

  /// xmp:CreatorTool, "Immuch360 Desktop 3.3.0 (windows)"
  final String? creatorTool;

  /// dc:description, x-default
  final String? description;

  /// A packet made by a newer version of the format: shown flat, "made by a newer version"
  bool get isNewerFormat => formatVersion > immersiveFormatVersion;

  /// A side by side photo this build can show in 3D
  bool get isReadableStereoPhoto => kind == ImmersiveKind.stereoPhoto && !isNewerFormat;

  /// The relief of this file was estimated by AI (the honesty label goes with it)
  bool get isEstimatedRelief => origin == ImmersiveOrigin.estimatedDepth;

  /// What two versions of one original are compared on, "a version with the same settings exists": the model file,
  /// the pipeline, the parallax, the convergence and the quarter turns; null when one of them is missing
  String? get settingsKey {
    final model = depthModelSha256;
    final steps = pipeline;
    final shift = parallax;
    final plane = convergence;
    final turns = sourceQuarterTurns;
    if (model == null || steps == null || shift == null || plane == null || turns == null) {
      return null;
    }
    return '$model|$steps|${_decimal(shift)}|${_decimal(plane)}|$turns';
  }

  /// The XMP packet, wrapped for a file (xpacket), the fields in the order of the design; null fields are left out
  String toXml() {
    final attributes = <(String, String)>[
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
      if (parallax case final value?) ('$immuch360XmpPrefix:Parallax', _decimal(value)),
      if (convergence case final value?) ('$immuch360XmpPrefix:Convergence', _decimal(value)),
      if (derivativeId case final value?) ('$immuch360XmpPrefix:DerivativeId', value),
      if (sourceName case final value?) ('$immuch360XmpPrefix:SourceName', value),
      if (sourceSize case final value?) ('$immuch360XmpPrefix:SourceSize', '$value'),
      if (sourceSha1 case final value?) ('$immuch360XmpPrefix:SourceSha1', value),
      if (sourceQuarterTurns case final value?) ('$immuch360XmpPrefix:SourceQuarterTurns', '$value'),
      ('$immuch360XmpPrefix:QualityFlags', qualityFlagsToXmp(qualityFlags)),
      if (created case final value?) ('$immuch360XmpPrefix:Created', value),
    ];
    final buffer = StringBuffer()
      ..write('<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>\n')
      ..write('<x:xmpmeta xmlns:x="adobe:ns:meta/">\n')
      ..write(' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n')
      ..write('  <rdf:Description rdf:about=""\n')
      ..write('    xmlns:xmp="$_xmpNamespace"\n')
      ..write('    xmlns:dc="$_dcNamespace"\n')
      ..write('    xmlns:$immuch360XmpPrefix="$immuch360XmpNamespace"');
    for (final (name, value) in attributes) {
      buffer.write('\n    $name="${_escape(value)}"');
    }
    final text = description;
    if (text == null) {
      buffer.write('/>\n');
    } else {
      buffer
        ..write('>\n')
        ..write('   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">${_escape(text)}</rdf:li></rdf:Alt>')
        ..write('</dc:description>\n')
        ..write('  </rdf:Description>\n');
    }
    buffer
      ..write(' </rdf:RDF>\n')
      ..write('</x:xmpmeta>\n')
      ..write('<?xpacket end="w"?>\n');
    return buffer.toString();
  }

  /// The Immuch360 fields of the XMP packet [xmp], null when it has no Immuch360 namespace or no Kind
  static StereoPhotoXmp? parse(String xmp) {
    final prefix = _prefixOf(xmp, immuch360XmpNamespace);
    if (prefix == null) {
      return null;
    }
    String? field(String name) => _valueOf(xmp, prefix, name);
    final kindText = field('Kind');
    if (kindText == null) {
      return null;
    }
    int? integer(String name) => int.tryParse(field(name) ?? '');
    double? decimal(String name) => double.tryParse(field(name) ?? '');
    final xmpPrefix = _prefixOf(xmp, _xmpNamespace) ?? 'xmp';
    final dcPrefix = _prefixOf(xmp, _dcNamespace) ?? 'dc';
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
      creatorTool: _valueOf(xmp, xmpPrefix, 'CreatorTool'),
      description: _descriptionOf(xmp, dcPrefix),
    );
  }

  /// The Immuch360 packet found in [bytes], the head of a file (a JPEG, a PNG, anything that keeps its XMP as text),
  /// null when there is none
  static StereoPhotoXmp? findIn(Uint8List bytes) {
    final text = latin1.decode(bytes);
    var from = 0;
    while (true) {
      final at = text.indexOf(immuch360XmpNamespace, from);
      if (at < 0) {
        return null;
      }
      final start = text.lastIndexOf('<x:xmpmeta', at);
      final end = text.indexOf('</x:xmpmeta>', at);
      final packetStart = start < 0 ? _orZero(text.lastIndexOf('<rdf:RDF', at)) : start;
      final packetEnd = end < 0 ? _orLength(text.indexOf('</rdf:RDF>', at), text.length) : end + '</x:xmpmeta>'.length;
      final packet = utf8.decode(bytes.sublist(packetStart, packetEnd), allowMalformed: true);
      final parsed = parse(packet);
      if (parsed != null) {
        return parsed;
      }
      from = at + immuch360XmpNamespace.length;
    }
  }

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

/// A double as the XMP and the cache key write it: the shortest form that reads back the same, "0.02", "0.5"
String _decimal(double value) => value.toString();

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

int _orZero(int index) => index < 0 ? 0 : index;

int _orLength(int index, int length) => index < 0 ? length : index + '</rdf:RDF>'.length;

/// The prefix [xmp] binds to [namespace], null when it binds none
String? _prefixOf(String xmp, String namespace) {
  final match = RegExp('xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*["\']${RegExp.escape(namespace)}["\']').firstMatch(xmp);
  return match?.group(1);
}

/// The value of [prefix]:[name], as an attribute (either quote) or as a simple element, entities decoded
String? _valueOf(String xmp, String prefix, String name) {
  final qualified = RegExp.escape('$prefix:$name');
  final attribute = RegExp('(?<![\\w:.-])$qualified\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')').firstMatch(xmp);
  if (attribute != null) {
    return _unescape(attribute.group(1) ?? attribute.group(2) ?? '');
  }
  final element = RegExp('<$qualified(?:\\s[^>]*)?>([^<]*)</$qualified\\s*>').firstMatch(xmp);
  return element == null ? null : _unescape(element.group(1)!.trim());
}

/// The x-default text of dc:description, or its first alternative
String? _descriptionOf(String xmp, String prefix) {
  final qualified = RegExp.escape('$prefix:description');
  final block = RegExp('<$qualified(?:\\s[^>]*)?>(.*?)</$qualified\\s*>', dotAll: true).firstMatch(xmp);
  if (block == null) {
    return _valueOf(xmp, prefix, 'description');
  }
  final items = RegExp(r'<rdf:li(\s[^>]*)?>([^<]*)</rdf:li\s*>').allMatches(block.group(1)!).toList();
  if (items.isEmpty) {
    return null;
  }
  final preferred = items.firstWhere((item) => (item.group(1) ?? '').contains('x-default'), orElse: () => items.first);
  return _unescape(preferred.group(2)!);
}

// = is written as &#x3D;: ExifTool reads a value that ends with = (every SHA-1 in base64 does) as the start of another
// attribute, and loses that field and the next one. An XML reader, ours included, reads the same character.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll('=', '&#x3D;')
    .replaceAll('\n', '&#xA;')
    .replaceAll('\r', '&#xD;')
    .replaceAll('\t', '&#x9;');

final _entity = RegExp(r'&(#x[0-9A-Fa-f]+|#[0-9]+|amp|lt|gt|quot|apos);');

// An entity that names no character ("&#x110000;", a number too long for an int) is left as written: a damaged field
// never costs the rest of the packet, nor the rest of what the file says
String _unescape(String value) => value.replaceAllMapped(_entity, (match) {
  final name = match.group(1)!;
  return switch (name) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    'apos' => "'",
    _ when name.startsWith('#x') => _character(int.tryParse(name.substring(2), radix: 16)) ?? match.group(0)!,
    _ => _character(int.tryParse(name.substring(1))) ?? match.group(0)!,
  };
});

String? _character(int? code) => code == null || code > 0x10ffff ? null : String.fromCharCode(code);
