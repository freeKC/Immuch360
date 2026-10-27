// The XMP packets of every file Immuch360 makes from a photo (design-final 2026-10-27, section 8.1): what they share,
// and the packets of the kinds of phases 2 and 3, the 3D scene (SceneXmp), the 360° panorama generated beyond the
// edges of a photo (PanoramaXmp) and the 360° 3D panorama, also the 3D version of a 360° photo (StereoPanoramaXmp).
// The 3D photo of phase 1 keeps its own class, StereoPhotoXmp, which writes its packet with the same writer.
//
// Always one rdf:Description, our namespace under the prefix Immuch360 and FormatVersion 1: a build of phase 1 reads
// these kinds without mistaking them for a 3D photo (its probe returns null for another kind of ours). A panorama
// adds the GPano tags under the literal prefix GPano, which every 360° viewer of the app looks for as text: their
// values never go through an entity. Every new kind carries the IPTC digital source type
// compositeWithTrainedAlgorithmicMedia, the marking a machine reads. Immuch360:Sources, a list of SHA-1 for a scene
// made from several photos one day, is reserved: read when there, never written in version 1, and ignored by the
// reader of phase 1.
//
// The writers and readers here are those of StereoPhotoXmp too: = written as &#x3D; (ExifTool), a control character
// as U+FFFD, the reader tolerant of attributes become elements and of another prefix.

import 'dart:convert';
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_pair_requests.dart';
import 'package:immich_mobile/domain/models/ai_immersive/stereo_photo_xmp.dart';
import 'package:uuid/uuid.dart';

/// The namespace of xmp:CreatorTool
const xmpBasicNamespace = 'http://ns.adobe.com/xap/1.0/';

/// The namespace of dc:description
const dublinCoreNamespace = 'http://purl.org/dc/elements/1.1/';

/// The GPano namespace and the prefix the viewers of the app look for, as text
const gpanoNamespace = 'http://ns.google.com/photos/1.0/panorama/';
const gpanoPrefix = 'GPano';

/// The IPTC extension namespace of Iptc4xmpExt:DigitalSourceType
const iptcExtensionNamespace = 'http://iptc.org/std/Iptc4xmpExt/2008-02-29/';
const iptcExtensionPrefix = 'Iptc4xmpExt';

/// The reserved field of the photos a scene was made from (SHA-1 in base64), never written in version 1
const reservedSourcesField = 'Sources';

/// What every packet of Immuch360 tells, whatever its kind: StereoPhotoXmp, SceneXmp, PanoramaXmp, StereoPanoramaXmp
abstract interface class ImmersiveXmp {
  /// Immuch360:FormatVersion, 1 when a packet has the Kind but not the version
  int get formatVersion;

  /// Immuch360:Kind; null for a kind this build does not know
  ImmersiveKind? get kind;
  ImmersiveOrigin? get origin;

  /// "relief-v1", "scene-v1", "pano-v1", "relief-360-v1"
  String? get pipeline;

  /// "urn:uuid:..." of this file, which Replace and Delete check before touching it
  String? get derivativeId;

  /// The name, the size in bytes and the SHA-1 in base64 of the original, and the quarter turns the user gave it
  String? get sourceName;
  int? get sourceSize;
  String? get sourceSha1;
  int? get sourceQuarterTurns;
  List<ReliefQualityFlag> get qualityFlags;

  /// ISO 8601 with its offset, see StereoPhotoXmp.xmpDateTime
  String? get created;
  String? get creatorTool;
  String? get description;

  /// A packet made by a newer version of the format
  bool get isNewerFormat;

  /// "A version with the same settings exists" compares this; null when a part of it is missing
  String? get settingsKey;

  /// The packet, wrapped for a file (xpacket)
  String toXml();

  /// The packet of [xmp] as its kind reads it: a 3D scene, a panorama, a 360° 3D panorama, or the StereoPhotoXmp of
  /// phase 1 for a 3D photo and for a kind this build does not know; null without our namespace or a Kind
  static ImmersiveXmp? parse(String xmp) {
    final prefix = xmpPrefixOf(xmp, immuch360XmpNamespace);
    if (prefix == null) {
      return null;
    }
    return switch (ImmersiveKind.fromXmp(xmpValueOf(xmp, prefix, 'Kind'))) {
      ImmersiveKind.volumetricScene => SceneXmp.parse(xmp),
      ImmersiveKind.panorama360 => PanoramaXmp.parse(xmp),
      ImmersiveKind.stereoPanorama360 => StereoPanoramaXmp.parse(xmp),
      ImmersiveKind.stereoPhoto || null => StereoPhotoXmp.parse(xmp),
    };
  }

  /// The packet of Immuch360 in [bytes], the head of a file, as its kind reads it; null when there is none
  static ImmersiveXmp? findIn(Uint8List bytes) => findXmpPacketIn(bytes, parse);
}

/// An attribute of a packet: its qualified name and its value. A [literal] value is written as it is, never through an
/// entity (the GPano tags: the viewers read them as text), so it may only hold letters, digits, dots, signs.
class XmpAttribute {
  const XmpAttribute(this.name, this.value, {this.literal = false});

  final String name;
  final String value;
  final bool literal;
}

final _literalValue = RegExp(r'^[A-Za-z0-9.+-]*$');

/// The packet of [attributes] in one rdf:Description that binds [namespaces] (prefix, URI) in their order, with the
/// x-default [description] when there is one, wrapped for a file (xpacket)
String xmpPacket({
  required List<(String, String)> namespaces,
  required List<XmpAttribute> attributes,
  String? description,
}) {
  final buffer = StringBuffer()
    ..write('<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>\n')
    ..write('<x:xmpmeta xmlns:x="adobe:ns:meta/">\n')
    ..write(' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n')
    ..write('  <rdf:Description rdf:about=""');
  for (final (prefix, uri) in namespaces) {
    buffer.write('\n    xmlns:$prefix="$uri"');
  }
  for (final attribute in attributes) {
    if (attribute.literal && !_literalValue.hasMatch(attribute.value)) {
      throw ArgumentError('${attribute.name}="${attribute.value}" cannot be written without an entity');
    }
    buffer.write('\n    ${attribute.name}="${attribute.literal ? attribute.value : xmpEscape(attribute.value)}"');
  }
  if (description == null) {
    buffer.write('/>\n');
  } else {
    buffer
      ..write('>\n')
      ..write('   <dc:description><rdf:Alt><rdf:li xml:lang="x-default">${xmpEscape(description)}</rdf:li></rdf:Alt>')
      ..write('</dc:description>\n')
      ..write('  </rdf:Description>\n');
  }
  buffer
    ..write(' </rdf:RDF>\n')
    ..write('</x:xmpmeta>\n')
    ..write('<?xpacket end="w"?>\n');
  return buffer.toString();
}

/// The first packet of our namespace in [bytes] that [parse] reads, null when there is none. [bytes] is the head of a
/// file: a JPEG, a PNG, anything that keeps its XMP as text.
T? findXmpPacketIn<T>(Uint8List bytes, T? Function(String packet) parse) {
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

int _orZero(int index) => index < 0 ? 0 : index;

int _orLength(int index, int length) => index < 0 ? length : index + '</rdf:RDF>'.length;

/// The prefix [xmp] binds to [namespace], null when it binds none
String? xmpPrefixOf(String xmp, String namespace) {
  final match = RegExp('xmlns:([A-Za-z_][\\w.-]*)\\s*=\\s*["\']${RegExp.escape(namespace)}["\']').firstMatch(xmp);
  return match?.group(1);
}

/// The value of [prefix]:[name], as an attribute (either quote) or as a simple element, entities decoded
String? xmpValueOf(String xmp, String prefix, String name) {
  final qualified = RegExp.escape('$prefix:$name');
  final attribute = RegExp('(?<![\\w:.-])$qualified\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')').firstMatch(xmp);
  if (attribute != null) {
    return xmpUnescape(attribute.group(1) ?? attribute.group(2) ?? '');
  }
  final element = RegExp('<$qualified(?:\\s[^>]*)?>([^<]*)</$qualified\\s*>').firstMatch(xmp);
  return element == null ? null : xmpUnescape(element.group(1)!.trim());
}

/// The items of the list [prefix]:[name] (an rdf:Seq or rdf:Bag of rdf:li), entities decoded; empty when there is none
List<String> xmpListOf(String xmp, String prefix, String name) {
  final qualified = RegExp.escape('$prefix:$name');
  final block = RegExp('<$qualified(?:\\s[^>]*)?>(.*?)</$qualified\\s*>', dotAll: true).firstMatch(xmp);
  if (block == null) {
    return const [];
  }
  return [
    for (final item in RegExp(r'<rdf:li(?:\s[^>]*)?>([^<]*)</rdf:li\s*>').allMatches(block.group(1)!))
      xmpUnescape(item.group(1)!.trim()),
  ];
}

/// The x-default text of dc:description, or its first alternative
String? xmpDescriptionOf(String xmp, String prefix) {
  final qualified = RegExp.escape('$prefix:description');
  final block = RegExp('<$qualified(?:\\s[^>]*)?>(.*?)</$qualified\\s*>', dotAll: true).firstMatch(xmp);
  if (block == null) {
    return xmpValueOf(xmp, prefix, 'description');
  }
  final items = RegExp(r'<rdf:li(\s[^>]*)?>([^<]*)</rdf:li\s*>').allMatches(block.group(1)!).toList();
  if (items.isEmpty) {
    return null;
  }
  final preferred = items.firstWhere((item) => (item.group(1) ?? '').contains('x-default'), orElse: () => items.first);
  return xmpUnescape(preferred.group(2)!);
}

final _notInXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

/// [value] as an XMP packet can hold it. A control character other than tab, line feed and carriage return has no
/// place in XML 1.0, not even as a reference: it is written as U+FFFD, and a packet that held one raw would be refused
/// whole by ExifTool or Immich. A name read from a packet is compared with a file name in this form.
String xmpSafeText(String value) => value.replaceAll(_notInXml, '\uFFFD');

// = is written as &#x3D;: ExifTool reads a value that ends with = (every SHA-1 in base64 does) as the start of another
// attribute, and loses that field and the next one. An XML reader, ours included, reads the same character.
/// [value] as an attribute or a text of a packet
String xmpEscape(String value) => xmpSafeText(value)
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
/// [value] with its entities decoded
String xmpUnescape(String value) => value.replaceAllMapped(_entity, (match) {
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

/// A double as the packets and the keys write it: the shortest form that reads back the same, "0.22", "1.0"
String xmpDecimal(double value) => value.toString();

/// Where the field of view of a scene comes from: the EXIF of the photo, or the model of the geometry
enum FieldOfViewSource {
  exif('Exif'),
  model('Model');

  const FieldOfViewSource(this.xmp);

  /// The value of Immuch360:FieldOfViewSource
  final String xmp;

  static FieldOfViewSource? fromXmp(String? value) {
    for (final source in values) {
      if (source.xmp == value) {
        return source;
      }
    }
    return null;
  }
}

/// The fields of a packet of phases 2 and 3 that every kind shares, read and written in one place. The kinds add their
/// own fields between the Pipeline and the DerivativeId, and GPano for the panoramas.
abstract base class ImmersiveVersionXmp implements ImmersiveXmp {
  const ImmersiveVersionXmp({
    this.formatVersion = immersiveFormatVersion,
    this.origin,
    this.pipeline,
    this.derivativeId,
    this.sourceName,
    this.sourceSize,
    this.sourceSha1,
    this.sourceQuarterTurns,
    this.qualityFlags = const [],
    this.created,
    this.creatorTool,
    this.description,
    this.digitalSourceType,
    this.sources = const [],
  });

  @override
  final int formatVersion;
  @override
  final ImmersiveOrigin? origin;
  @override
  final String? pipeline;
  @override
  final String? derivativeId;
  @override
  final String? sourceName;
  @override
  final int? sourceSize;
  @override
  final String? sourceSha1;
  @override
  final int? sourceQuarterTurns;
  @override
  final List<ReliefQualityFlag> qualityFlags;
  @override
  final String? created;
  @override
  final String? creatorTool;
  @override
  final String? description;

  /// Iptc4xmpExt:DigitalSourceType, [iptcCompositeWithTrainedAlgorithmicMedia] on every file made by the app
  final String? digitalSourceType;

  /// Immuch360:Sources, reserved: the SHA-1 of the photos of a scene made from several; read, never written
  final List<String> sources;

  @override
  bool get isNewerFormat => formatVersion > immersiveFormatVersion;

  /// The Immuch360 fields of the kind, after Kind, Origin and Pipeline (name without prefix, value)
  List<(String, String)> get kindFields;

  /// The fields written after the kind's own and before DerivativeId (ParentDerivativeId of a 3D panorama)
  List<(String, String)> get linkFields => const [];

  /// The GPano tags, written as they are; none but for a panorama
  List<(String, String)> get gpanoTags => const [];

  /// The fields compared by ==, beyond the shared ones
  List<Object?> get kindValues;

  @override
  String toXml() {
    final gpano = gpanoTags;
    final source = digitalSourceType;
    return xmpPacket(
      namespaces: [
        ('xmp', xmpBasicNamespace),
        ('dc', dublinCoreNamespace),
        if (gpano.isNotEmpty) (gpanoPrefix, gpanoNamespace),
        if (source != null) (iptcExtensionPrefix, iptcExtensionNamespace),
        (immuch360XmpPrefix, immuch360XmpNamespace),
      ],
      attributes: [
        if (creatorTool case final tool?) XmpAttribute('xmp:CreatorTool', tool),
        for (final (name, value) in gpano) XmpAttribute('$gpanoPrefix:$name', value, literal: true),
        if (source != null) XmpAttribute('$iptcExtensionPrefix:DigitalSourceType', source),
        XmpAttribute('$immuch360XmpPrefix:FormatVersion', '$formatVersion'),
        if (kind case final value?) XmpAttribute('$immuch360XmpPrefix:Kind', value.xmp),
        if (origin case final value?) XmpAttribute('$immuch360XmpPrefix:Origin', value.xmp),
        if (pipeline case final value?) XmpAttribute('$immuch360XmpPrefix:Pipeline', value),
        for (final (name, value) in [...kindFields, ...linkFields]) XmpAttribute('$immuch360XmpPrefix:$name', value),
        if (derivativeId case final value?) XmpAttribute('$immuch360XmpPrefix:DerivativeId', value),
        if (sourceName case final value?) XmpAttribute('$immuch360XmpPrefix:SourceName', value),
        if (sourceSize case final value?) XmpAttribute('$immuch360XmpPrefix:SourceSize', '$value'),
        if (sourceSha1 case final value?) XmpAttribute('$immuch360XmpPrefix:SourceSha1', value),
        if (sourceQuarterTurns case final value?) XmpAttribute('$immuch360XmpPrefix:SourceQuarterTurns', '$value'),
        XmpAttribute('$immuch360XmpPrefix:QualityFlags', qualityFlagsToXmp(qualityFlags)),
        if (created case final value?) XmpAttribute('$immuch360XmpPrefix:Created', value),
      ],
      description: description,
    );
  }

  List<Object?> get _sharedValues => [
    formatVersion,
    kind,
    origin,
    pipeline,
    derivativeId,
    sourceName,
    sourceSize,
    sourceSha1,
    sourceQuarterTurns,
    ReliefQualityFlag.values.where(qualityFlags.contains).toList(),
    created,
    creatorTool,
    description,
    digitalSourceType,
    sources,
  ];

  @override
  bool operator ==(Object other) =>
      other is ImmersiveVersionXmp &&
      other.runtimeType == runtimeType &&
      _sameValues([..._sharedValues, ...kindValues], [...other._sharedValues, ...other.kindValues]);

  @override
  int get hashCode => Object.hashAll([..._flat(_sharedValues), ..._flat(kindValues)]);

  @override
  String toString() => '$runtimeType(${kind?.xmp} v$formatVersion, ${origin?.xmp}, $pipeline, $sourceName)';
}

bool _sameValues(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    final x = a[i];
    final y = b[i];
    if (x is List && y is List) {
      if (!_sameValues(x.cast<Object?>(), y.cast<Object?>())) {
        return false;
      }
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

Iterable<Object?> _flat(List<Object?> values) => values.map((value) => value is List ? Object.hashAll(value) : value);

/// The fields every kind of phases 2 and 3 reads the same way, from [xmp] whose namespace has [prefix]
class _Shared {
  _Shared(this.xmp, this.prefix);

  final String xmp;
  final String prefix;

  String? field(String name) => xmpValueOf(xmp, prefix, name);

  int? integer(String name) => int.tryParse(field(name) ?? '');

  double? decimal(String name) {
    final value = double.tryParse(field(name) ?? '');
    return value != null && value.isFinite ? value : null;
  }

  int get formatVersion => integer('FormatVersion') ?? immersiveFormatVersion;

  ImmersiveOrigin? get origin => ImmersiveOrigin.fromXmp(field('Origin'));

  int? get turns => switch (integer('SourceQuarterTurns')) {
    final int value => value & 3,
    null => null,
  };

  List<ReliefQualityFlag> get flags => qualityFlagsFromXmp(field('QualityFlags'));

  String? get creatorTool => xmpValueOf(xmp, xmpPrefixOf(xmp, xmpBasicNamespace) ?? 'xmp', 'CreatorTool');

  String? get description => xmpDescriptionOf(xmp, xmpPrefixOf(xmp, dublinCoreNamespace) ?? 'dc');

  String? get digitalSourceType =>
      xmpValueOf(xmp, xmpPrefixOf(xmp, iptcExtensionNamespace) ?? iptcExtensionPrefix, 'DigitalSourceType');

  List<String> get sources => xmpListOf(xmp, prefix, reservedSourcesField);

  /// The GPano tag [name], whatever the prefix the packet binds to the GPano namespace
  String? gpano(String name) => xmpValueOf(xmp, xmpPrefixOf(xmp, gpanoNamespace) ?? gpanoPrefix, name);

  int? gpanoInteger(String name) => int.tryParse(gpano(name) ?? '');
}

/// The part of [xmp] our namespace holds when its Kind is [kind], null otherwise
_Shared? _sharedOf(String xmp, ImmersiveKind kind) {
  final prefix = xmpPrefixOf(xmp, immuch360XmpNamespace);
  if (prefix == null || ImmersiveKind.fromXmp(xmpValueOf(xmp, prefix, 'Kind')) != kind) {
    return null;
  }
  return _Shared(xmp, prefix);
}

/// A new "urn:uuid:..." for a DerivativeId
String newImmersiveDerivativeId() => 'urn:uuid:${const Uuid().v4()}';

/// The packet of a 3D scene, `<name>_scene3D.jpg`: its JPEG preview carries it, the glb-layers-v1 scene follows the end
/// of the JPEG, SceneLength bytes long and checked by SceneSha256 (see scene_container.dart). Every field may be null
/// on a packet read from a file; one made by the app has them all (see [SceneXmp.reconstructed]).
final class SceneXmp extends ImmersiveVersionXmp {
  const SceneXmp({
    super.formatVersion = immersiveFormatVersion,
    super.origin,
    super.pipeline,
    this.sceneFormat,
    this.sceneLength,
    this.sceneSha256,
    this.sceneMeshes,
    this.sceneVertices,
    this.sceneTriangles,
    this.sceneTextureMax,
    this.sceneScale,
    this.gridStep,
    this.safe,
    this.fieldOfView,
    this.fieldOfViewSource,
    this.geometryModel,
    this.geometryModelSha256,
    this.inpaintModel,
    this.inpaintModelSha256,
    this.hiddenFraction,
    super.derivativeId,
    super.sourceName,
    super.sourceSize,
    super.sourceSha1,
    super.sourceQuarterTurns,
    super.qualityFlags = const [],
    super.created,
    super.creatorTool,
    super.description,
    super.digitalSourceType,
    super.sources = const [],
  });

  /// The packet of a scene made by scene-v1 from [sourceName]
  factory SceneXmp.reconstructed({
    required int sceneLength,
    required String sceneSha256,
    required int sceneMeshes,
    required int sceneVertices,
    required int sceneTriangles,
    required int sceneTextureMax,
    required double sceneScale,
    required SceneSafeZone safe,
    required double fieldOfView,
    required FieldOfViewSource fieldOfViewSource,
    required String geometryModel,
    required String geometryModelSha256,
    required String inpaintModel,
    required String inpaintModelSha256,
    required double hiddenFraction,
    required String sourceName,
    required int sourceSize,
    required String sourceSha1,
    required int sourceQuarterTurns,
    required String created,
    required String creatorTool,
    String? derivativeId,
    List<ReliefQualityFlag> qualityFlags = const [],
  }) => SceneXmp(
    origin: ImmersiveOrigin.reconstructedFromPhoto,
    pipeline: SceneV1.pipeline,
    sceneFormat: SceneV1.format,
    sceneLength: sceneLength,
    sceneSha256: sceneSha256,
    sceneMeshes: sceneMeshes,
    sceneVertices: sceneVertices,
    sceneTriangles: sceneTriangles,
    sceneTextureMax: sceneTextureMax,
    sceneScale: sceneScale,
    gridStep: SceneV1.gridStep,
    safe: safe,
    fieldOfView: fieldOfView,
    fieldOfViewSource: fieldOfViewSource,
    geometryModel: geometryModel,
    geometryModelSha256: geometryModelSha256,
    inpaintModel: inpaintModel,
    inpaintModelSha256: inpaintModelSha256,
    hiddenFraction: hiddenFraction,
    derivativeId: derivativeId ?? newImmersiveDerivativeId(),
    sourceName: sourceName,
    sourceSize: sourceSize,
    sourceSha1: sourceSha1,
    sourceQuarterTurns: sourceQuarterTurns & 3,
    qualityFlags: ReliefQualityFlag.values.where(qualityFlags.contains).toList(),
    created: created,
    creatorTool: creatorTool,
    description: sceneDescription,
    digitalSourceType: iptcCompositeWithTrainedAlgorithmicMedia,
  );

  @override
  ImmersiveKind get kind => ImmersiveKind.volumetricScene;

  /// "glb-layers-v1"
  final String? sceneFormat;

  /// The bytes of the scene at the end of the file, and their SHA-256 in lowercase hexadecimal
  final int? sceneLength;
  final String? sceneSha256;

  /// Its meshes, vertices and triangles, and the longest side of its largest texture
  final int? sceneMeshes;
  final int? sceneVertices;
  final int? sceneTriangles;
  final int? sceneTextureMax;

  /// The comfort scale the scene was enlarged by around the eye
  final double? sceneScale;

  /// One vertex every this many pixels of the map
  final int? gridStep;

  /// The zone the eye may move in, in metres
  final SceneSafeZone? safe;

  /// The horizontal field of view of the photo, in degrees, and where it comes from
  final double? fieldOfView;
  final FieldOfViewSource? fieldOfViewSource;

  /// The models of the geometry and of the filling, by their catalogue id, and the SHA-256 of their files
  final String? geometryModel;
  final String? geometryModelSha256;
  final String? inpaintModel;
  final String? inpaintModelSha256;

  /// The fraction of the photo the near layer hides and the filling invented
  final double? hiddenFraction;

  /// A scene this build can read: version 1 of the format and of the scene format
  bool get isReadableScene => !isNewerFormat && sceneFormat == SceneV1.format;

  @override
  String? get settingsKey {
    final geometry = geometryModelSha256;
    final inpaint = inpaintModelSha256;
    final steps = pipeline;
    final step = gridStep;
    final turns = sourceQuarterTurns;
    if (geometry == null || inpaint == null || steps == null || step == null || turns == null) {
      return null;
    }
    return '$geometry|$inpaint|$steps|$step|$turns';
  }

  /// The request the immersive viewer of the Meta Quest gets for this scene; null when the packet misses a part of it
  /// or the scene is of a format this build does not read
  VolumetricSceneRequest? get request {
    final length = sceneLength;
    final sum = sceneSha256;
    final meshes = sceneMeshes;
    final vertices = sceneVertices;
    final triangles = sceneTriangles;
    final texture = sceneTextureMax;
    final zone = safe;
    final fov = fieldOfView;
    if (!isReadableScene ||
        length == null ||
        sum == null ||
        meshes == null ||
        vertices == null ||
        triangles == null ||
        texture == null ||
        zone == null ||
        fov == null) {
      return null;
    }
    return VolumetricSceneRequest.fromJson(
      VolumetricSceneRequest(
        sceneLength: length,
        sceneSha256: sum,
        meshes: meshes,
        vertices: vertices,
        triangles: triangles,
        textureMax: texture,
        scale: sceneScale ?? 1.0,
        safe: zone,
        fovDegrees: fov,
        origin: origin ?? ImmersiveOrigin.unknown,
        flags: qualityFlags,
      ).toJson(),
    );
  }

  @override
  List<(String, String)> get kindFields => [
    if (sceneFormat case final value?) ('SceneFormat', value),
    if (sceneLength case final value?) ('SceneLength', '$value'),
    if (sceneSha256 case final value?) ('SceneSha256', value),
    if (sceneMeshes case final value?) ('SceneMeshes', '$value'),
    if (sceneVertices case final value?) ('SceneVertices', '$value'),
    if (sceneTriangles case final value?) ('SceneTriangles', '$value'),
    if (sceneTextureMax case final value?) ('SceneTextureMax', '$value'),
    if (sceneScale case final value?) ('SceneScale', xmpDecimal(value)),
    if (gridStep case final value?) ('GridStep', '$value'),
    if (safe case final zone?) ...[
      ('SafeLateral', xmpDecimal(zone.lateral)),
      ('SafeVertical', xmpDecimal(zone.vertical)),
      ('SafeForward', xmpDecimal(zone.forward)),
      ('SafeBackward', xmpDecimal(zone.backward)),
    ],
    if (fieldOfView case final value?) ('FieldOfView', xmpDecimal(value)),
    if (fieldOfViewSource case final value?) ('FieldOfViewSource', value.xmp),
    if (geometryModel case final value?) ('GeometryModel', value),
    if (geometryModelSha256 case final value?) ('GeometryModelSha256', value),
    if (inpaintModel case final value?) ('InpaintModel', value),
    if (inpaintModelSha256 case final value?) ('InpaintModelSha256', value),
    if (hiddenFraction case final value?) ('HiddenFraction', xmpDecimal(value)),
  ];

  @override
  List<Object?> get kindValues => [
    sceneFormat,
    sceneLength,
    sceneSha256,
    sceneMeshes,
    sceneVertices,
    sceneTriangles,
    sceneTextureMax,
    sceneScale,
    gridStep,
    safe,
    fieldOfView,
    fieldOfViewSource,
    geometryModel,
    geometryModelSha256,
    inpaintModel,
    inpaintModelSha256,
    hiddenFraction,
  ];

  /// The scene fields of the packet [xmp], null when it is not ours or not of a scene
  static SceneXmp? parse(String xmp) {
    final read = _sharedOf(xmp, ImmersiveKind.volumetricScene);
    if (read == null) {
      return null;
    }
    final lateral = read.decimal('SafeLateral');
    final vertical = read.decimal('SafeVertical');
    final forward = read.decimal('SafeForward');
    final backward = read.decimal('SafeBackward');
    return SceneXmp(
      formatVersion: read.formatVersion,
      origin: read.origin,
      pipeline: read.field('Pipeline'),
      sceneFormat: read.field('SceneFormat'),
      sceneLength: read.integer('SceneLength'),
      sceneSha256: read.field('SceneSha256'),
      sceneMeshes: read.integer('SceneMeshes'),
      sceneVertices: read.integer('SceneVertices'),
      sceneTriangles: read.integer('SceneTriangles'),
      sceneTextureMax: read.integer('SceneTextureMax'),
      sceneScale: read.decimal('SceneScale'),
      gridStep: read.integer('GridStep'),
      safe: lateral == null || vertical == null || forward == null || backward == null
          ? null
          : SceneSafeZone(lateral: lateral, vertical: vertical, forward: forward, backward: backward),
      fieldOfView: read.decimal('FieldOfView'),
      fieldOfViewSource: FieldOfViewSource.fromXmp(read.field('FieldOfViewSource')),
      geometryModel: read.field('GeometryModel'),
      geometryModelSha256: read.field('GeometryModelSha256'),
      inpaintModel: read.field('InpaintModel'),
      inpaintModelSha256: read.field('InpaintModelSha256'),
      hiddenFraction: read.decimal('HiddenFraction'),
      derivativeId: read.field('DerivativeId'),
      sourceName: read.field('SourceName'),
      sourceSize: read.integer('SourceSize'),
      sourceSha1: read.field('SourceSha1'),
      sourceQuarterTurns: read.turns,
      qualityFlags: read.flags,
      created: read.field('Created'),
      creatorTool: read.creatorTool,
      description: read.description,
      digitalSourceType: read.digitalSourceType,
      sources: read.sources,
    );
  }
}

/// Where the photo itself lies in a panorama made from it, in degrees: the centre of its frame (yaw from the centre
/// column of the panorama, positive to the right; pitch positive upwards), and its horizontal and vertical fields of
/// view. The panorama viewers outline it at the opening.
class PhotoRegion {
  const PhotoRegion({required this.yaw, required this.pitch, required this.hfov, required this.vfov});

  final double yaw;
  final double pitch;
  final double hfov;
  final double vfov;

  @override
  bool operator ==(Object other) =>
      other is PhotoRegion && other.yaw == yaw && other.pitch == pitch && other.hfov == hfov && other.vfov == vfov;

  @override
  int get hashCode => Object.hash(yaw, pitch, hfov, vfov);

  @override
  String toString() => 'PhotoRegion($yaw, $pitch, $hfov x $vfov)';
}

List<(String, String)> _regionFields(PhotoRegion? region, double? coverage) => [
  if (region != null) ...[
    ('PhotoYaw', xmpDecimal(region.yaw)),
    ('PhotoPitch', xmpDecimal(region.pitch)),
    ('PhotoHfov', xmpDecimal(region.hfov)),
    ('PhotoVfov', xmpDecimal(region.vfov)),
  ],
  if (coverage != null) ('SourceCoverage', xmpDecimal(coverage)),
];

PhotoRegion? _regionOf(_Shared read) {
  final yaw = read.decimal('PhotoYaw');
  final pitch = read.decimal('PhotoPitch');
  final hfov = read.decimal('PhotoHfov');
  final vfov = read.decimal('PhotoVfov');
  return yaw == null || pitch == null || hfov == null || vfov == null
      ? null
      : PhotoRegion(yaw: yaw, pitch: pitch, hfov: hfov, vfov: vfov);
}

/// The GPano tags of a whole sphere of [width] x [height] pixels: equirectangular, the crop the whole frame
List<(String, String)> _sphereTags(int? width, int? height) => width == null || height == null
    ? const []
    : [
        ('ProjectionType', 'equirectangular'),
        ('UsePanoramaViewer', 'True'),
        ('FullPanoWidthPixels', '$width'),
        ('FullPanoHeightPixels', '$height'),
        ('CroppedAreaImageWidthPixels', '$width'),
        ('CroppedAreaImageHeightPixels', '$height'),
        ('CroppedAreaLeftPixels', '0'),
        ('CroppedAreaTopPixels', '0'),
      ];

/// The packet of a 360° panorama generated beyond the edges of a photo, `<name>_360.jpg`: an equirectangular JPEG of
/// [width] x [height] with GPano, the photo itself pasted back where [region] says, [sourceCoverage] the fraction of
/// the sphere it covers. No initial view is written: the viewers open on the centre column, the photo.
final class PanoramaXmp extends ImmersiveVersionXmp {
  const PanoramaXmp({
    super.formatVersion = immersiveFormatVersion,
    super.origin,
    super.pipeline,
    this.width,
    this.height,
    this.region,
    this.sourceCoverage,
    this.generator,
    this.generatorSha256,
    this.generatorLora,
    this.generatorLoraSha256,
    this.seed,
    this.steps,
    this.upscaler,
    super.derivativeId,
    super.sourceName,
    super.sourceSize,
    super.sourceSha1,
    super.sourceQuarterTurns,
    super.qualityFlags = const [],
    super.created,
    super.creatorTool,
    super.description,
    super.digitalSourceType,
    super.sources = const [],
  });

  /// The packet of a panorama made by pano-v1 around [sourceName]
  factory PanoramaXmp.generated({
    required int width,
    required int height,
    required PhotoRegion region,
    required double sourceCoverage,
    required String generator,
    required String generatorSha256,
    required String generatorLora,
    required String generatorLoraSha256,
    required int seed,
    required int steps,
    required String upscaler,
    required String sourceName,
    required int sourceSize,
    required String sourceSha1,
    required int sourceQuarterTurns,
    required String created,
    required String creatorTool,
    String? derivativeId,
    List<ReliefQualityFlag> qualityFlags = const [],
  }) => PanoramaXmp(
    origin: ImmersiveOrigin.generatedContent,
    pipeline: PanoV1.pipeline,
    width: width,
    height: height,
    region: region,
    sourceCoverage: sourceCoverage,
    generator: generator,
    generatorSha256: generatorSha256,
    generatorLora: generatorLora,
    generatorLoraSha256: generatorLoraSha256,
    seed: seed,
    steps: steps,
    upscaler: upscaler,
    derivativeId: derivativeId ?? newImmersiveDerivativeId(),
    sourceName: sourceName,
    sourceSize: sourceSize,
    sourceSha1: sourceSha1,
    sourceQuarterTurns: sourceQuarterTurns & 3,
    qualityFlags: ReliefQualityFlag.values.where(qualityFlags.contains).toList(),
    created: created,
    creatorTool: creatorTool,
    description: panoramaDescription,
    digitalSourceType: iptcCompositeWithTrainedAlgorithmicMedia,
  );

  @override
  ImmersiveKind get kind => ImmersiveKind.panorama360;

  /// The frame, which GPano declares whole
  final int? width;
  final int? height;

  /// Where the photo itself lies, and the fraction of the sphere it covers
  final PhotoRegion? region;
  final double? sourceCoverage;

  /// The generator and its LoRA by their catalogue id, and the SHA-256 of their files
  final String? generator;
  final String? generatorSha256;
  final String? generatorLora;
  final String? generatorLoraSha256;

  /// The seed, drawn at random, and the steps of the generation
  final int? seed;
  final int? steps;

  /// The upscaler by its catalogue id
  final String? upscaler;

  /// The fraction of the sphere invented, 1 minus [sourceCoverage]
  double? get inventedFraction => sourceCoverage == null ? null : 1 - sourceCoverage!;

  /// The seed is not part of it: another seed is "Make a new version"
  @override
  String? get settingsKey {
    final transformer = generatorSha256;
    final lora = generatorLoraSha256;
    final scheme = pipeline;
    final count = steps;
    final turns = sourceQuarterTurns;
    if (transformer == null || lora == null || scheme == null || count == null || turns == null) {
      return null;
    }
    return '$transformer|$lora|$scheme|$count|$turns';
  }

  @override
  List<(String, String)> get gpanoTags => _sphereTags(width, height);

  @override
  List<(String, String)> get kindFields => [
    ..._regionFields(region, sourceCoverage),
    if (generator case final value?) ('Generator', value),
    if (generatorSha256 case final value?) ('GeneratorSha256', value),
    if (generatorLora case final value?) ('GeneratorLora', value),
    if (generatorLoraSha256 case final value?) ('GeneratorLoraSha256', value),
    if (seed case final value?) ('Seed', '$value'),
    if (steps case final value?) ('Steps', '$value'),
    if (upscaler case final value?) ('Upscaler', value),
  ];

  @override
  List<Object?> get kindValues => [
    width,
    height,
    region,
    sourceCoverage,
    generator,
    generatorSha256,
    generatorLora,
    generatorLoraSha256,
    seed,
    steps,
    upscaler,
  ];

  /// The panorama fields of the packet [xmp], null when it is not ours or not of a panorama
  static PanoramaXmp? parse(String xmp) {
    final read = _sharedOf(xmp, ImmersiveKind.panorama360);
    if (read == null) {
      return null;
    }
    return PanoramaXmp(
      formatVersion: read.formatVersion,
      origin: read.origin,
      pipeline: read.field('Pipeline'),
      width: read.gpanoInteger('FullPanoWidthPixels'),
      height: read.gpanoInteger('FullPanoHeightPixels'),
      region: _regionOf(read),
      sourceCoverage: read.decimal('SourceCoverage'),
      generator: read.field('Generator'),
      generatorSha256: read.field('GeneratorSha256'),
      generatorLora: read.field('GeneratorLora'),
      generatorLoraSha256: read.field('GeneratorLoraSha256'),
      seed: read.integer('Seed'),
      steps: read.integer('Steps'),
      upscaler: read.field('Upscaler'),
      derivativeId: read.field('DerivativeId'),
      sourceName: read.field('SourceName'),
      sourceSize: read.integer('SourceSize'),
      sourceSha1: read.field('SourceSha1'),
      sourceQuarterTurns: read.turns,
      qualityFlags: read.flags,
      created: read.field('Created'),
      creatorTool: read.creatorTool,
      description: read.description,
      digitalSourceType: read.digitalSourceType,
      sources: read.sources,
    );
  }
}

/// The packet of a 360° 3D panorama, top and bottom with the left eye on top in a frame of [width] x [height] (1:1),
/// with GPano: `<name>_360_3D.jpg`, or `<name>_3D.jpg` when the name of the source already says 360 or pano. Made
/// from a panorama the app generated ([origin] GeneratedContent, [relief] EstimatedDepth, [parentDerivativeId] the
/// DerivativeId of the mono panorama, its [region] and [sourceCoverage] copied), or from a 360° photo of the user
/// ([origin] EstimatedDepth). Either way a version of the original photo: SourceSha1 is that of the photo.
final class StereoPanoramaXmp extends ImmersiveVersionXmp {
  const StereoPanoramaXmp({
    super.formatVersion = immersiveFormatVersion,
    super.origin,
    this.relief,
    super.pipeline,
    this.width,
    this.height,
    this.depthModel,
    this.depthModelSha256,
    this.maxShiftDegrees,
    this.region,
    this.sourceCoverage,
    this.parentDerivativeId,
    super.derivativeId,
    super.sourceName,
    super.sourceSize,
    super.sourceSha1,
    super.sourceQuarterTurns,
    super.qualityFlags = const [],
    super.created,
    super.creatorTool,
    super.description,
    super.digitalSourceType,
    super.sources = const [],
  });

  /// The packet of the 3D version that relief-360-v1 made of a panorama: of [parent], a panorama the app generated,
  /// when given, otherwise of a 360° photo of the user named [sourceName]
  factory StereoPanoramaXmp.estimated({
    required int width,
    required int height,
    required String depthModelSha256,
    required String sourceName,
    required int sourceSize,
    required String sourceSha1,
    required int sourceQuarterTurns,
    required String created,
    required String creatorTool,
    PanoramaXmp? parent,
    String? derivativeId,
    List<ReliefQualityFlag> qualityFlags = const [],
  }) => StereoPanoramaXmp(
    origin: parent == null ? ImmersiveOrigin.estimatedDepth : ImmersiveOrigin.generatedContent,
    relief: parent == null ? null : ImmersiveOrigin.estimatedDepth,
    pipeline: Relief360V1.pipeline,
    width: width,
    height: height,
    depthModel: depthModelName,
    depthModelSha256: depthModelSha256,
    maxShiftDegrees: Relief360V1.maxShiftDegrees,
    region: parent?.region,
    sourceCoverage: parent?.sourceCoverage,
    parentDerivativeId: parent?.derivativeId,
    derivativeId: derivativeId ?? newImmersiveDerivativeId(),
    sourceName: sourceName,
    sourceSize: sourceSize,
    sourceSha1: sourceSha1,
    sourceQuarterTurns: sourceQuarterTurns & 3,
    qualityFlags: ReliefQualityFlag.values.where(qualityFlags.contains).toList(),
    created: created,
    creatorTool: creatorTool,
    description: parent == null ? stereo360Description : stereoPanoramaDescription,
    digitalSourceType: iptcCompositeWithTrainedAlgorithmicMedia,
  );

  @override
  ImmersiveKind get kind => ImmersiveKind.stereoPanorama360;

  /// Immuch360:Relief, EstimatedDepth when the panorama itself was generated ([origin] then says so)
  final ImmersiveOrigin? relief;

  /// The whole frame, both eyes
  final int? width;
  final int? height;

  /// The depth model and the SHA-256 of its file
  final String? depthModel;
  final String? depthModelSha256;

  /// The largest shift, at the equator, in degrees
  final double? maxShiftDegrees;

  /// Copied from the generated panorama it was made from
  final PhotoRegion? region;
  final double? sourceCoverage;

  /// The DerivativeId of the generated panorama it was made from
  final String? parentDerivativeId;

  /// Its world was generated, not only its relief estimated
  bool get isGenerated => origin == ImmersiveOrigin.generatedContent;

  @override
  String? get settingsKey {
    final model = depthModelSha256;
    final steps = pipeline;
    final shift = maxShiftDegrees;
    final turns = sourceQuarterTurns;
    if (model == null || steps == null || shift == null || turns == null) {
      return null;
    }
    return '$model|$steps|${xmpDecimal(shift)}|$turns';
  }

  @override
  List<(String, String)> get gpanoTags => _sphereTags(width, height);

  @override
  List<(String, String)> get kindFields => [
    if (relief case final value?) ('Relief', value.xmp),
    if (depthModel case final value?) ('DepthModel', value),
    if (depthModelSha256 case final value?) ('DepthModelSha256', value),
    if (maxShiftDegrees case final value?) ('MaxShiftDegrees', xmpDecimal(value)),
    ..._regionFields(region, sourceCoverage),
  ];

  @override
  List<(String, String)> get linkFields => [if (parentDerivativeId case final value?) ('ParentDerivativeId', value)];

  @override
  List<Object?> get kindValues => [
    relief,
    width,
    height,
    depthModel,
    depthModelSha256,
    maxShiftDegrees,
    region,
    sourceCoverage,
    parentDerivativeId,
  ];

  /// The fields of the packet [xmp], null when it is not ours or not of a 360° 3D panorama
  static StereoPanoramaXmp? parse(String xmp) {
    final read = _sharedOf(xmp, ImmersiveKind.stereoPanorama360);
    if (read == null) {
      return null;
    }
    return StereoPanoramaXmp(
      formatVersion: read.formatVersion,
      origin: read.origin,
      relief: ImmersiveOrigin.fromXmp(read.field('Relief')),
      pipeline: read.field('Pipeline'),
      width: read.gpanoInteger('FullPanoWidthPixels'),
      height: read.gpanoInteger('FullPanoHeightPixels'),
      depthModel: read.field('DepthModel'),
      depthModelSha256: read.field('DepthModelSha256'),
      maxShiftDegrees: read.decimal('MaxShiftDegrees'),
      region: _regionOf(read),
      sourceCoverage: read.decimal('SourceCoverage'),
      parentDerivativeId: read.field('ParentDerivativeId'),
      derivativeId: read.field('DerivativeId'),
      sourceName: read.field('SourceName'),
      sourceSize: read.integer('SourceSize'),
      sourceSha1: read.field('SourceSha1'),
      sourceQuarterTurns: read.turns,
      qualityFlags: read.flags,
      created: read.field('Created'),
      creatorTool: read.creatorTool,
      description: read.description,
      digitalSourceType: read.digitalSourceType,
      sources: read.sources,
    );
  }
}
