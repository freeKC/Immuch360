// Apple spatial photos: a HEIC whose meta box holds two visible images grouped as a stereo pair (the ster entity group
// of grpl, entity 0 the left eye, entity 1 the right one). Every decoder shows the primary item, the left eye in the
// files seen so far: the pair matters only to the Meta Quest, which shows both eyes (docs
// 18-design-build19-sources-and-spatial.md, section 5).
//
// Pure Dart, as the spherical probe of the videos: the caller reads the bytes, from a file on the device or with HTTP
// range requests. The meta box sits at the head of the file, ahead of the image data: one read of 64 KiB is enough for
// nearly every file.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:logging/logging.dart';

final _log = Logger('HeicStereoProbe');

/// Bytes read at the start of a file to find its meta box
const heicStereoHeadLength = 64 * 1024;

/// Kind and version of the JSON the immersive viewer reads, see [HeicStereoPair.toImmersiveJson]
const heicStereoPairKind = 'heicStereoPair';
const heicStereoPairVersion = 1;

/// The two eyes of an Apple spatial photo, as its meta box declares them
class HeicStereoPair {
  const HeicStereoPair({
    required this.primaryItemId,
    required this.leftItemId,
    required this.rightItemId,
    required this.pitmIdOffset,
    required this.pitmIdBytes,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.disparityAdjustment,
    this.horizontalFovDegrees,
    this.unknownProperties = const [],
  });

  /// The item every decoder shows (pitm)
  final int primaryItemId;

  /// The image items of the eyes: entity 0 and entity 1 of the ster group, an altr group taken to its image
  final int leftItemId;
  final int rightItemId;

  /// Absolute file offset of the item_ID field of pitm, which the headset rewrites to decode the right eye
  final int pitmIdOffset;

  /// Length of that field: 2 in a pitm of version 0, else 4
  final int pitmIdBytes;

  /// Size of the left eye (its ispe)
  final int width;
  final int height;

  /// Rotation of the left eye (its irot), in quarter turns anticlockwise
  final int rotation;

  /// How far apart the eyes are shown, in [-10000, 10000] of the width of an eye, half applied to each eye (the same
  /// unit as the dadj box of spatial videos); null when the file does not tell
  final int? disparityAdjustment;

  /// Horizontal field of view of the camera, from its intrinsics; null when unknown
  final double? horizontalFovDegrees;

  /// The 4cc or the uuid of the properties of the eyes this probe does not know, for the logs
  final List<String> unknownProperties;

  /// The JSON object of the immersive viewer (see [toImmersiveJson]), the fields it does not know left out
  Map<String, Object> toImmersiveMap() {
    final disparity = disparityAdjustment;
    final fov = horizontalFovDegrees;
    return {
      'kind': heicStereoPairKind,
      'version': heicStereoPairVersion,
      'primaryItemId': primaryItemId,
      'leftItemId': leftItemId,
      'rightItemId': rightItemId,
      'pitmIdOffset': pitmIdOffset,
      'pitmIdBytes': pitmIdBytes,
      'width': width,
      'height': height,
      'rotation': rotation,
      'disparityAdjustment': ?disparity,
      // Hundredths of a degree are more than the headset needs
      if (fov != null) 'horizontalFovDeg': (fov * 100).round() / 100,
    };
  }

  /// The stereoPair JSON of the immersive viewer (ImmersiveApi.open), section 5.6 of the design
  String toImmersiveJson() => jsonEncode(toImmersiveMap());

  /// The pair [toImmersiveMap] wrote, null for anything else
  static HeicStereoPair? fromImmersiveMap(Object? map) {
    if (map is! Map || map['kind'] != heicStereoPairKind || map['version'] != heicStereoPairVersion) {
      return null;
    }
    int? integer(String key) => switch (map[key]) {
      final int value => value,
      _ => null,
    };
    final primary = integer('primaryItemId');
    final left = integer('leftItemId');
    final right = integer('rightItemId');
    final offset = integer('pitmIdOffset');
    final bytes = integer('pitmIdBytes');
    final width = integer('width');
    final height = integer('height');
    if (primary == null ||
        left == null ||
        right == null ||
        offset == null ||
        bytes == null ||
        width == null ||
        height == null) {
      return null;
    }
    final fov = map['horizontalFovDeg'];
    return HeicStereoPair(
      primaryItemId: primary,
      leftItemId: left,
      rightItemId: right,
      pitmIdOffset: offset,
      pitmIdBytes: bytes,
      width: width,
      height: height,
      rotation: integer('rotation') ?? 0,
      disparityAdjustment: integer('disparityAdjustment'),
      horizontalFovDegrees: fov is num ? fov.toDouble() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HeicStereoPair &&
      other.primaryItemId == primaryItemId &&
      other.leftItemId == leftItemId &&
      other.rightItemId == rightItemId &&
      other.pitmIdOffset == pitmIdOffset &&
      other.pitmIdBytes == pitmIdBytes &&
      other.width == width &&
      other.height == height &&
      other.rotation == rotation &&
      other.disparityAdjustment == disparityAdjustment &&
      other.horizontalFovDegrees == horizontalFovDegrees;

  @override
  int get hashCode => Object.hash(
    primaryItemId,
    leftItemId,
    rightItemId,
    pitmIdOffset,
    pitmIdBytes,
    width,
    height,
    rotation,
    disparityAdjustment,
    horizontalFovDegrees,
  );

  @override
  String toString() =>
      'HeicStereoPair(primary: $primaryItemId, left: $leftItemId, right: $rightItemId, pitm id at $pitmIdOffset '
      '($pitmIdBytes bytes), $width x $height, rotation: $rotation, disparity: $disparityAdjustment, '
      'fov: $horizontalFovDegrees, unknown properties: $unknownProperties)';
}

// Brands of the HEIF files (ISO/IEC 23008-12): HEVC images, HEVC image sequences, any image or sequence
const _heifBrands = {'heic', 'heix', 'mif1', 'msf1'};

// Item types an eye may be: an HEVC image, a grid of tiles, an overlay, a derived image, an AV1 or a JPEG one
const _eyeItemTypes = {'hvc1', 'grid', 'iovl', 'iden', 'av01', 'jpeg'};

// Item types an altr group stands for as an eye; a gain map (tmap) is no picture to show
const _alternativeItemTypes = {'hvc1', 'grid', 'iden', 'av01', 'jpeg'};

// Properties of an eye that say nothing about the pair
const _knownEyeProperties = {
  'ispe',
  'hvcC',
  'colr',
  'pixi',
  'irot',
  'imir',
  'clap',
  'clli',
  'mdcv',
  'auxC',
  'av1C',
  'rloc',
  'lsel',
  'a1op',
  'a1lx',
  'cmin',
  'cmex',
};

/// The disparity adjustment Apple ImageIO writes, an int32 (kCGImagePropertyGroupImageDisparityAdjustment)
const _disparityUuid = 'de225085-36cb-4365-8743-2f8705e7c78a';

/// The intrinsics of the camera, the focal length in 1/65536 pixel as the second u32
const _intrinsicsUuid = '22cc04c7-d6d9-4e07-9d90-4eb6ecbaf3a3';

/// The extrinsics of the camera (its position, the baseline for the right eye)
const _extrinsicsUuid = '4363e914-5b7d-4aab-97ae-bea69803b434';

const _knownUuids = {_disparityUuid, _intrinsicsUuid, _extrinsicsUuid};

// Bounds on the boxes walked, so that a damaged file cannot make the probe loop
const _maxTopLevelBoxes = 32;
const _maxChildBoxes = 4096;

/// The stereo pair of the HEIF file that [read] reads, null when it is no HEIF or holds no pair of two image items
/// grouped by a ster entity group.
///
/// Reads the first 64 KiB, and the meta box with one more read when it ends past them, at most [maxMetaLength] bytes
/// (a longer meta box gives null). A truncated or damaged file gives null, it never throws; errors of [read] are not
/// caught.
Future<HeicStereoPair?> probeHeicStereoPair(ByteRangeReader read, {int maxMetaLength = 4 * 1024 * 1024}) async {
  final head = await read(0, heicStereoHeadLength);
  try {
    if (!_isHeif(head)) {
      return null;
    }
    final meta = await _readMeta(read, head, maxMetaLength);
    return meta == null ? null : _parseMeta(meta.bytes, meta.offset);
  } on RangeError catch (error) {
    // The bounds are checked as the boxes are walked: a damaged box that slips through ends here
    _log.fine('Damaged HEIF meta box: $error');
    return null;
  }
}

/// A box in a buffer: its [type], where it starts ([offset]), where its content starts after the header and the user
/// type of a uuid box ([start]), and where it ends ([end])
class _Box {
  const _Box(this.type, this.offset, this.start, this.end, {this.userType});

  final String type;
  final int offset;
  final int start;
  final int end;

  /// The extended type of a uuid box, as a lower case uuid string
  final String? userType;
}

int _uint16(Uint8List data, int offset) => data[offset] << 8 | data[offset + 1];

int _uint32(Uint8List data, int offset) => ByteData.sublistView(data).getUint32(offset);

int _int32(Uint8List data, int offset) => ByteData.sublistView(data).getInt32(offset);

String _fourCC(Uint8List data, int offset) => latin1.decode(Uint8List.sublistView(data, offset, offset + 4));

String _uuid(Uint8List data, int offset) {
  final hex = [for (var i = 0; i < 16; i++) data[offset + i].toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

// The header of the box at [offset] of [data]: its size (null for a box that runs to the end of its parent), its type
// and the length of its header; null when the bytes are too few or the size is damaged
({int? size, String type, int headerLength})? _header(Uint8List data, int offset) {
  if (offset + 8 > data.length) {
    return null;
  }
  final size = _uint32(data, offset);
  final type = _fourCC(data, offset + 4);
  if (size == 0) {
    return (size: null, type: type, headerLength: 8);
  }
  if (size != 1) {
    return size < 8 ? null : (size: size, type: type, headerLength: 8);
  }
  if (offset + 16 > data.length) {
    return null;
  }
  final high = _uint32(data, offset + 8);
  // Far beyond any meta box: nothing this probe reads
  if (high > 0x1fffff) {
    return null;
  }
  final large = high * 0x100000000 + _uint32(data, offset + 12);
  return large < 16 ? null : (size: large, type: type, headerLength: 16);
}

/// The boxes of [data] from [start] to [end]. A box running past [end] ends the list, without being listed: a cut box
/// is no box to trust.
Iterable<_Box> _boxes(Uint8List data, int start, int end) sync* {
  final limit = math.min(end, data.length);
  var offset = start;
  for (var count = 0; count < _maxChildBoxes && offset + 8 <= limit; count++) {
    final header = _header(data, offset);
    if (header == null) {
      return;
    }
    final boxEnd = header.size == null ? limit : offset + header.size!;
    if (boxEnd > limit) {
      return;
    }
    var contentStart = offset + header.headerLength;
    String? userType;
    if (header.type == 'uuid') {
      if (contentStart + 16 > boxEnd) {
        return;
      }
      userType = _uuid(data, contentStart);
      contentStart += 16;
    }
    if (contentStart > boxEnd) {
      return;
    }
    yield _Box(header.type, offset, contentStart, boxEnd, userType: userType);
    offset = boxEnd;
  }
}

_Box? _child(Uint8List data, _Box parent, String type) {
  for (final box in _boxes(data, parent.start, parent.end)) {
    if (box.type == type) {
      return box;
    }
  }
  return null;
}

// The first box must be ftyp, with a HEIF brand as its major brand or among its compatible ones
bool _isHeif(Uint8List head) {
  final header = _header(head, 0);
  if (header == null || header.type != 'ftyp') {
    return false;
  }
  final end = math.min(header.size ?? head.length, head.length);
  final start = header.headerLength;
  if (start + 4 > end) {
    return false;
  }
  if (_heifBrands.contains(_fourCC(head, start))) {
    return true;
  }
  // The minor version, then the compatible brands
  for (var offset = start + 8; offset + 4 <= end; offset += 4) {
    if (_heifBrands.contains(_fourCC(head, offset))) {
      return true;
    }
  }
  return false;
}

/// The bytes of the meta box and the offset of its first byte in the file: from [head] when it holds the box whole,
/// else read once. Null without a meta box, for one longer than [maxMetaLength], and for one cut short by the end of
/// the file.
Future<({Uint8List bytes, int offset})?> _readMeta(ByteRangeReader read, Uint8List head, int maxMetaLength) async {
  var offset = 0;
  for (var count = 0; count < _maxTopLevelBoxes; count++) {
    final bytes = offset + 16 <= head.length ? Uint8List.sublistView(head, offset) : await read(offset, 16);
    final header = _header(bytes, 0);
    if (header == null) {
      return null;
    }
    final size = header.size;
    if (header.type == 'meta') {
      if (size != null && size > maxMetaLength) {
        _log.info('HEIF meta box of $size bytes, past the $maxMetaLength bytes read');
        return null;
      }
      if (size != null && offset + size <= head.length) {
        return (bytes: Uint8List.sublistView(head, offset, offset + size), offset: offset);
      }
      // A short file read whole already
      if (size == null && head.length < heicStereoHeadLength) {
        return (bytes: Uint8List.sublistView(head, offset), offset: offset);
      }
      // A meta box that runs to the end of the file holds the whole file: as much as allowed
      final length = size ?? maxMetaLength;
      final meta = await read(offset, length);
      if (size != null && meta.length < size) {
        return null;
      }
      return (bytes: meta.length > length ? Uint8List.sublistView(meta, 0, length) : meta, offset: offset);
    }
    if (size == null) {
      return null;
    }
    offset += size;
  }
  return null;
}

/// An item of iinf: its type and whether it is hidden
typedef _Item = ({String type, bool hidden});

/// A property of ipco: its type, or for a uuid box its extended type, and where its content lies in the meta bytes
typedef _Property = ({String type, String? uuid, int start, int end});

HeicStereoPair? _parseMeta(Uint8List data, int metaOffset) {
  final header = _header(data, 0);
  if (header == null) {
    return null;
  }
  // A FullBox: its children start after the version and the flags
  final meta = _Box('meta', 0, header.headerLength, data.length);
  int? primaryItemId;
  var pitmIdOffset = 0;
  var pitmIdBytes = 0;
  final items = <int, _Item>{};
  final properties = <_Property>[];
  final associations = <int, List<int>>{};
  final groups = <({String type, int id, List<int> entities})>[];
  for (final box in _boxes(data, meta.start + 4, meta.end)) {
    switch (box.type) {
      case 'pitm':
        final field = box.start + 4;
        final version = data[box.start];
        pitmIdBytes = version == 0 ? 2 : 4;
        if (field + pitmIdBytes > box.end) {
          return null;
        }
        primaryItemId = version == 0 ? _uint16(data, field) : _uint32(data, field);
        pitmIdOffset = metaOffset + field;
      case 'iinf':
        _parseItems(data, box, items);
      case 'iprp':
        _parseProperties(data, box, properties, associations);
      case 'grpl':
        for (final group in _boxes(data, box.start, box.end)) {
          final at = group.start + 4;
          if (at + 8 > group.end) {
            continue;
          }
          final count = _uint32(data, at + 4);
          final entities = [
            for (var i = 0, offset = at + 8; i < count && offset + 4 <= group.end; i++, offset += 4)
              _uint32(data, offset),
          ];
          groups.add((type: group.type, id: _uint32(data, at), entities: entities));
        }
    }
  }
  final primary = primaryItemId;
  if (primary == null) {
    return null;
  }
  final ster = groups.where((group) => group.type == 'ster' && group.entities.length >= 2).firstOrNull;
  if (ster == null) {
    return null;
  }
  final alternatives = {
    for (final group in groups)
      if (group.type == 'altr') group.id: group.entities,
  };
  // An entity that is an altr group stands for the first of its pictures
  int? resolve(int entity) {
    final members = alternatives[entity];
    if (members == null) {
      return entity;
    }
    return members.where((id) => _alternativeItemTypes.contains(items[id]?.type)).firstOrNull;
  }

  final left = resolve(ster.entities[0]);
  final right = resolve(ster.entities[1]);
  if (left == null || right == null) {
    return null;
  }
  List<_Property> propertiesOf(int id) => [
    for (final index in associations[id] ?? const <int>[])
      if (index >= 1 && index <= properties.length) properties[index - 1],
  ];
  final leftProperties = propertiesOf(left);
  final rightProperties = propertiesOf(right);
  final leftSize = _spatialExtent(data, leftProperties);
  final rightSize = _spatialExtent(data, rightProperties);
  // Hidden or not: the tiles of a grid are hidden, an eye that is one still shows
  if (!_eyeItemTypes.contains(items[left]?.type) ||
      !_eyeItemTypes.contains(items[right]?.type) ||
      leftSize == null ||
      rightSize == null) {
    return null;
  }
  if (leftSize != rightSize) {
    _log.warning('Eyes of different sizes: left $leftSize, right $rightSize');
  }

  final irot = leftProperties.where((property) => property.type == 'irot').firstOrNull;
  final rotation = irot != null && irot.start < irot.end ? data[irot.start] & 3 : 0;

  int? disparity;
  for (final candidates in [propertiesOf(ster.id), leftProperties, rightProperties]) {
    final property = candidates.where((property) => property.uuid == _disparityUuid).firstOrNull;
    if (property != null) {
      if (property.start + 4 <= property.end) {
        final value = _int32(data, property.start);
        disparity = value >= -10000 && value <= 10000 ? value : null;
      }
      break;
    }
  }

  double? fov;
  final intrinsics = leftProperties.where((property) => property.uuid == _intrinsicsUuid).firstOrNull;
  if (intrinsics != null && intrinsics.start + 8 <= intrinsics.end) {
    final focal = _uint32(data, intrinsics.start + 4) / 65536;
    if (focal > 0) {
      final degrees = 2 * math.atan(leftSize.$1 / 2 / focal) * 180 / math.pi;
      fov = degrees > 10 && degrees < 179 ? degrees : null;
    }
  }

  final unknown = <String>{
    for (final property in [...leftProperties, ...rightProperties])
      if (property.uuid == null && !_knownEyeProperties.contains(property.type))
        property.type
      else if (property.uuid != null && !_knownUuids.contains(property.uuid))
        property.uuid!,
  }.toList();
  if (unknown.isNotEmpty) {
    // iPhone files may put more there than the sample this probe was written from: the logs tell what
    _log.info('Spatial photo with eye properties this probe does not know: ${unknown.join(', ')}');
  }

  return HeicStereoPair(
    primaryItemId: primary,
    leftItemId: left,
    rightItemId: right,
    pitmIdOffset: pitmIdOffset,
    pitmIdBytes: pitmIdBytes,
    width: leftSize.$1,
    height: leftSize.$2,
    rotation: rotation,
    disparityAdjustment: disparity,
    horizontalFovDegrees: fov,
    unknownProperties: unknown,
  );
}

// iinf: version and flags, the entry count (16 bits in version 0, else 32), then the infe boxes. infe version 2 has a
// 16 bit item_ID, version 3 a 32 bit one, then the protection index and the item type; earlier versions have no type.
// Bit 0 of the flags hides the item.
void _parseItems(Uint8List data, _Box iinf, Map<int, _Item> items) {
  final childrenStart = iinf.start + (data[iinf.start] == 0 ? 6 : 8);
  for (final infe in _boxes(data, childrenStart, iinf.end)) {
    if (infe.type != 'infe' || infe.start + 4 > infe.end) {
      continue;
    }
    final version = data[infe.start];
    final hidden = data[infe.start + 3] & 1 == 1;
    if (version == 2 && infe.start + 12 <= infe.end) {
      items[_uint16(data, infe.start + 4)] = (type: _fourCC(data, infe.start + 8), hidden: hidden);
    } else if (version == 3 && infe.start + 14 <= infe.end) {
      items[_uint32(data, infe.start + 4)] = (type: _fourCC(data, infe.start + 10), hidden: hidden);
    }
  }
}

// iprp: ipco, the properties in order (index 1 for the first), then one or more ipma: version and flags, the entry
// count, and per entry the item id (16 bits in version 0, else 32), the association count, and each association on 8
// bits, or 16 when bit 0 of the flags is set, the top bit telling an essential property and the rest its index. Group
// ids get associations too.
void _parseProperties(Uint8List data, _Box iprp, List<_Property> properties, Map<int, List<int>> associations) {
  final ipco = _child(data, iprp, 'ipco');
  if (ipco != null) {
    for (final property in _boxes(data, ipco.start, ipco.end)) {
      properties.add((type: property.type, uuid: property.userType, start: property.start, end: property.end));
    }
  }
  for (final ipma in _boxes(data, iprp.start, iprp.end)) {
    if (ipma.type != 'ipma' || ipma.start + 8 > ipma.end) {
      continue;
    }
    final version = data[ipma.start];
    final wide = data[ipma.start + 3] & 1 == 1;
    final entries = _uint32(data, ipma.start + 4);
    var offset = ipma.start + 8;
    for (var entry = 0; entry < entries; entry++) {
      final idLength = version == 0 ? 2 : 4;
      if (offset + idLength + 1 > ipma.end) {
        return;
      }
      final id = version == 0 ? _uint16(data, offset) : _uint32(data, offset);
      final count = data[offset + idLength];
      offset += idLength + 1;
      final indices = associations.putIfAbsent(id, () => []);
      for (var i = 0; i < count; i++) {
        if (offset + (wide ? 2 : 1) > ipma.end) {
          return;
        }
        indices.add(wide ? _uint16(data, offset) & 0x7fff : data[offset] & 0x7f);
        offset += wide ? 2 : 1;
      }
    }
  }
}

// ispe: version and flags, then the width and the height on 32 bits each; null without one, or with a size of 0
(int, int)? _spatialExtent(Uint8List data, List<_Property> properties) {
  final ispe = properties.where((property) => property.type == 'ispe').firstOrNull;
  if (ispe == null || ispe.start + 12 > ispe.end) {
    return null;
  }
  final width = _uint32(data, ispe.start + 4);
  final height = _uint32(data, ispe.start + 8);
  return width == 0 || height == 0 ? null : (width, height);
}
