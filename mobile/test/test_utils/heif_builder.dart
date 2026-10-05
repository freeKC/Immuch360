// A small HEIF writer for the tests of the HEIC stereo pair probe: ftyp, then a meta box with hdlr, pitm, iinf, iprp
// (ipco and ipma), grpl and the padding a test asks for, then an mdat of zeros. Each version and flag the probe reads
// differently can be chosen. Only the boxes are real: there is no image data.

import 'dart:convert';
import 'dart:typed_data';

List<int> heifUint16(int value) => [value >> 8 & 0xff, value & 0xff];

List<int> heifUint32(int value) => [value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff];

List<int> heifInt32(int value) => heifUint32(value & 0xffffffff);

/// A box: its 32 bit size, its type, then its payload; with [largeSize] the size is 1 and a 64 bit size follows
List<int> heifBox(String type, List<int> payload, {bool largeSize = false}) => largeSize
    ? [...heifUint32(1), ...ascii.encode(type), ...heifUint32(0), ...heifUint32(16 + payload.length), ...payload]
    : [...heifUint32(8 + payload.length), ...ascii.encode(type), ...payload];

/// A full box: [version] and 24 bits of [flags] before the payload
List<int> heifFullBox(String type, List<int> payload, {int version = 0, int flags = 0}) =>
    heifBox(type, [version, flags >> 16 & 0xff, flags >> 8 & 0xff, flags & 0xff, ...payload]);

/// The size of an image
List<int> heifIspe(int width, int height) => heifFullBox('ispe', [...heifUint32(width), ...heifUint32(height)]);

/// The rotation of an image, in quarter turns anticlockwise
List<int> heifIrot(int quarterTurns) => heifBox('irot', [quarterTurns & 3]);

/// A uuid box: [uuid] written as 16 bytes, then [payload]
List<int> heifUuidBox(String uuid, List<int> payload) {
  final hex = uuid.replaceAll('-', '');
  return heifBox('uuid', [for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16), ...payload]);
}

/// The disparity adjustment property Apple ImageIO writes
List<int> heifDisparity(int value) => heifUuidBox('de225085-36cb-4365-8743-2f8705e7c78a', heifInt32(value));

/// The intrinsics property Apple ImageIO writes: the focal length in 1/65536 pixel as its second u32
List<int> heifIntrinsics(double focalPixels) => heifUuidBox('22cc04c7-d6d9-4e07-9d90-4eb6ecbaf3a3', [
  ...heifUint32(0x1e00),
  ...heifUint32((focalPixels * 65536).round()),
  ...heifUint32(0x20000000),
  ...heifUint32(0x20000000),
]);

/// An item of iinf
class HeifItem {
  const HeifItem(this.id, this.type, {this.hidden = false, this.properties = const []});

  final int id;
  final String type;
  final bool hidden;

  /// Indices of its properties in ipco, from 1
  final List<int> properties;
}

/// An entity group of grpl: ster, altr, ...
class HeifGroup {
  const HeifGroup(this.type, this.id, this.entities, {this.properties = const []});

  final String type;
  final int id;
  final List<int> entities;

  /// Indices of the properties associated with the group itself, from 1
  final List<int> properties;
}

/// Writes a HEIF file with [items], [properties] (boxes, in ipco order) and [groups], [primaryItemId] as pitm
class HeifBuilder {
  HeifBuilder({
    required this.items,
    required this.properties,
    this.groups = const [],
    this.primaryItemId = 1,
    this.majorBrand = 'heic',
    this.compatibleBrands = const ['mif1', 'heic'],
    this.pitmVersion = 0,
    this.iinfVersion = 0,
    this.infeVersion = 2,
    this.ipmaVersion = 0,
    this.ipmaFlags = 0,
    this.metaPadding = 0,
    this.largeMetaSize = false,
    this.leadingBoxes = const [],
    this.mdatLength = 64,
  });

  final List<HeifItem> items;
  final List<List<int>> properties;
  final List<HeifGroup> groups;
  final int primaryItemId;
  final String majorBrand;
  final List<String> compatibleBrands;
  final int pitmVersion;
  final int iinfVersion;
  final int infeVersion;
  final int ipmaVersion;
  final int ipmaFlags;

  /// Bytes of a free box at the end of the meta box, to push its end where a test wants it
  final int metaPadding;

  /// Whether the meta box gets a 64 bit size
  final bool largeMetaSize;

  /// Top level boxes between ftyp and meta
  final List<List<int>> leadingBoxes;
  final int mdatLength;

  /// Offset of the item_ID field of pitm in the file [build] writes
  int get pitmIdOffset =>
      _ftyp().length + leadingBoxes.fold<int>(0, (sum, box) => sum + box.length) + _pitmIdOffsetInMeta;

  /// Offset of the meta box in the file [build] writes, and its length
  int get metaOffset => _ftyp().length + leadingBoxes.fold<int>(0, (sum, box) => sum + box.length);
  int get metaLength => _meta().length;

  int get _pitmIdOffsetInMeta {
    // meta header, version and flags, then hdlr, then the pitm header with its version and flags
    final metaHeader = largeMetaSize ? 16 : 8;
    return metaHeader + 4 + _hdlr().length + 12;
  }

  List<int> _ftyp() => heifBox('ftyp', [
    ...ascii.encode(majorBrand),
    ...heifUint32(0),
    for (final brand in compatibleBrands) ...ascii.encode(brand),
  ]);

  List<int> _hdlr() => heifFullBox('hdlr', [...heifUint32(0), ...ascii.encode('pict'), ...List.filled(12, 0), 0]);

  List<int> _pitm() => heifFullBox(
    'pitm',
    pitmVersion == 0 ? heifUint16(primaryItemId) : heifUint32(primaryItemId),
    version: pitmVersion,
  );

  List<int> _iinf() => heifFullBox('iinf', [
    ...(iinfVersion == 0 ? heifUint16(items.length) : heifUint32(items.length)),
    for (final item in items)
      ...heifFullBox(
        'infe',
        [
          ...(infeVersion == 2 ? heifUint16(item.id) : heifUint32(item.id)),
          ...heifUint16(0),
          ...ascii.encode(item.type),
          // An empty item name
          0,
        ],
        version: infeVersion,
        flags: item.hidden ? 1 : 0,
      ),
  ], version: iinfVersion);

  List<int> _ipma() {
    final entries = [
      for (final item in items) (item.id, item.properties),
      for (final group in groups)
        if (group.properties.isNotEmpty) (group.id, group.properties),
    ];
    final wide = ipmaFlags & 1 == 1;
    return heifFullBox(
      'ipma',
      [
        ...heifUint32(entries.length),
        for (final (id, indices) in entries) ...[
          ...(ipmaVersion == 0 ? heifUint16(id) : heifUint32(id)),
          indices.length,
          // The essential bit set on the first association, as writers do for the decoder configuration
          for (var i = 0; i < indices.length; i++)
            ...(wide ? heifUint16(indices[i] | (i == 0 ? 0x8000 : 0)) : [indices[i] | (i == 0 ? 0x80 : 0)]),
        ],
      ],
      version: ipmaVersion,
      flags: ipmaFlags,
    );
  }

  List<int> _grpl() => heifBox('grpl', [
    for (final group in groups)
      ...heifFullBox(group.type, [
        ...heifUint32(group.id),
        ...heifUint32(group.entities.length),
        for (final entity in group.entities) ...heifUint32(entity),
      ]),
  ]);

  List<int> _meta() => heifBox('meta', [
    0,
    0,
    0,
    0,
    ..._hdlr(),
    ..._pitm(),
    ..._iinf(),
    ...heifBox('iprp', [
      ...heifBox('ipco', [for (final property in properties) ...property]),
      ..._ipma(),
    ]),
    if (groups.isNotEmpty) ..._grpl(),
    if (metaPadding > 0) ...heifBox('free', List.filled(metaPadding, 0)),
  ], largeSize: largeMetaSize);

  Uint8List build() => Uint8List.fromList([
    ..._ftyp(),
    for (final box in leadingBoxes) ...box,
    ..._meta(),
    ...heifBox('mdat', List.filled(mdatLength, 0)),
  ]);
}

/// A spatial photo laid out like the files of Apple ImageIO: two visible grid items of [width] x [height] (ids 10 and
/// 20), each made of hidden hvc1 tiles (not listed), grouped by ster 30 with the disparity on the group; the left eye
/// primary. [disparity] null leaves the property out, [focalPixels] null the intrinsics.
HeifBuilder spatialPhotoBuilder({
  int width = 3072,
  int height = 3072,
  int? disparity = -1000,
  double? focalPixels = 2661.74,
  int rotation = 0,
  int pitmVersion = 0,
  int iinfVersion = 0,
  int infeVersion = 2,
  int ipmaVersion = 0,
  int ipmaFlags = 0,
  int metaPadding = 0,
  bool largeMetaSize = false,
  List<List<int>> extraEyeProperties = const [],
}) {
  final properties = <List<int>>[
    heifBox('colr', [...ascii.encode('nclx'), 0, 1, 0, 13, 0, 1, 0x80]),
    heifIspe(width, height),
    heifIrot(rotation),
    ?(disparity == null ? null : heifDisparity(disparity)),
    ?(focalPixels == null ? null : heifIntrinsics(focalPixels)),
    ...extraEyeProperties,
  ];
  final count = properties.length;
  final eyeProperties = [1, 2, 3, for (var index = 4; index <= count; index++) index];
  return HeifBuilder(
    items: [
      HeifItem(10, 'grid', properties: eyeProperties),
      HeifItem(20, 'grid', properties: eyeProperties),
    ],
    properties: properties,
    groups: [
      HeifGroup('ster', 30, [10, 20], properties: disparity == null ? const [] : [4]),
    ],
    primaryItemId: 10,
    pitmVersion: pitmVersion,
    iinfVersion: iinfVersion,
    infeVersion: infeVersion,
    ipmaVersion: ipmaVersion,
    ipmaFlags: ipmaFlags,
    metaPadding: metaPadding,
    largeMetaSize: largeMetaSize,
  );
}

/// Reads [bytes] by ranges, as a file or a server does, recording each read
class RecordingReader {
  RecordingReader(this.bytes);

  final Uint8List bytes;
  final reads = <(int, int)>[];

  Future<Uint8List> call(int offset, int length) async {
    reads.add((offset, length));
    if (offset >= bytes.length) {
      return Uint8List(0);
    }
    final end = offset + length > bytes.length ? bytes.length : offset + length;
    return Uint8List.sublistView(bytes, offset, end);
  }
}
