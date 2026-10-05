// A tiny MP4 box builder for the tests of the spherical metadata probe: a box is its 32 bit size, its type, then its
// payload, child boxes included.

import 'dart:convert';
import 'dart:typed_data';

List<int> mp4Uint32(int value) => [value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff];

List<int> mp4Box(String type, [List<int> payload = const []]) => [
  ...mp4Uint32(8 + payload.length),
  ...ascii.encode(type),
  ...payload,
];

// A box with a 64 bit size (size 1, then the largesize)
List<int> mp4LargeBox(String type, List<int> payload) => [
  ...mp4Uint32(1),
  ...ascii.encode(type),
  ...mp4Uint32(0),
  ...mp4Uint32(16 + payload.length),
  ...payload,
];

// Version 0 and no flags, then the payload
List<int> mp4FullBox(String type, [List<int> payload = const []]) => mp4Box(type, [0, 0, 0, 0, ...payload]);

List<int> mp4Zeros(int length) => List.filled(length, 0);

List<int> mp4St3d(int stereoMode) => mp4FullBox('st3d', [stereoMode]);

// Equirectangular projection cropped by the given fractions of the frame, in 0.32 fixed point
List<int> mp4Sv3dEquirectangular({double top = 0, double bottom = 0, double left = 0, double right = 0}) {
  int fixed(double fraction) => (fraction * 0x100000000).round().clamp(0, 0xffffffff);
  return mp4Box('sv3d', [
    ...mp4FullBox('svhd', [...ascii.encode('Spherical Metadata Tool'), 0]),
    ...mp4Box('proj', [
      ...mp4FullBox('prhd', mp4Zeros(12)),
      ...mp4FullBox('equi', [
        ...mp4Uint32(fixed(top)),
        ...mp4Uint32(fixed(bottom)),
        ...mp4Uint32(fixed(left)),
        ...mp4Uint32(fixed(right)),
      ]),
    ]),
  ]);
}

List<int> mp4Sv3dProjection(List<int> projection) => mp4Box('sv3d', [
  ...mp4FullBox('svhd', [0]),
  ...mp4Box('proj', [...mp4FullBox('prhd', mp4Zeros(12)), ...projection]),
]);

// A mesh projection, as VR180 cameras write it: a CRC, the encoding, then the meshes
List<int> mp4Mshp() => mp4FullBox('mshp', [...mp4Uint32(0x12345678), ...ascii.encode('raw '), ...mp4Zeros(32)]);

List<int> mp4Uint16(int value) => [value >> 8 & 0xff, value & 0xff];

/// The fields of a visual sample entry before its child boxes, the frame [width] and [height] among zeros
List<int> mp4VisualSampleEntryFields({int width = 0, int height = 0}) => [
  ...mp4Zeros(24),
  ...mp4Uint16(width),
  ...mp4Uint16(height),
  ...mp4Zeros(50),
];

List<int> mp4SampleDescription(String codec, List<List<int>> children, {int width = 0, int height = 0}) =>
    mp4FullBox('stsd', [
      ...mp4Uint32(1),
      ...mp4Box(codec, [
        ...mp4VisualSampleEntryFields(width: width, height: height),
        for (final child in children) ...child,
      ]),
    ]);

/// The media header of a track: its [timescale] and its [duration] in that scale, in version 0 (32 bit times) or 1
/// (64 bit times)
List<int> mp4Mdhd({int timescale = 0, int version = 0, int duration = 0}) => version == 1
    ? mp4Box('mdhd', [
        1,
        0,
        0,
        0,
        ...mp4Zeros(16),
        ...mp4Uint32(timescale),
        ...mp4Uint32(duration >> 32),
        ...mp4Uint32(duration & 0xffffffff),
        ...mp4Zeros(4),
      ])
    : mp4FullBox('mdhd', [...mp4Zeros(8), ...mp4Uint32(timescale), ...mp4Uint32(duration), ...mp4Zeros(4)]);

/// The movie header: the [timescale] and the [duration] of the movie, in version 0 (32 bit times) or 1 (64 bit times)
List<int> mp4Mvhd({int timescale = 0, int duration = 0, int version = 0}) => version == 1
    ? mp4Box('mvhd', [
        1,
        0,
        0,
        0,
        ...mp4Zeros(16),
        ...mp4Uint32(timescale),
        ...mp4Uint32(duration >> 32),
        ...mp4Uint32(duration & 0xffffffff),
        ...mp4Zeros(80),
      ])
    : mp4FullBox('mvhd', [...mp4Zeros(8), ...mp4Uint32(timescale), ...mp4Uint32(duration), ...mp4Zeros(80)]);

/// The track header: version 0, the track_ID at offset 12 of its content (84 zero bytes when [trackId] is 0)
List<int> mp4Tkhd({int trackId = 0}) => mp4Box('tkhd', [...mp4Zeros(12), ...mp4Uint32(trackId), ...mp4Zeros(68)]);

/// The handler of a track: version and flags, pre_defined, [type] (4 zero bytes when null), 12 reserved bytes, then
/// [name] NUL terminated, or [counted] as QuickTime writes it: its length in a byte first, then the name and a NUL
List<int> mp4Hdlr(String? type, {String name = '', bool counted = false}) {
  final nameBytes = utf8.encode(name);
  return mp4FullBox('hdlr', [
    ...mp4Zeros(4),
    ...(type == null ? mp4Zeros(4) : ascii.encode(type)),
    ...mp4Zeros(12),
    if (counted) nameBytes.length,
    ...nameBytes,
    0,
  ]);
}

/// The sample size table: one [sampleSize] for every sample, or the [sizes] of each, under the sample [count] (the
/// number of [sizes] by default)
List<int> mp4Stsz({int sampleSize = 0, List<int> sizes = const [], int? count}) => mp4FullBox('stsz', [
  ...mp4Uint32(sampleSize),
  ...mp4Uint32(count ?? sizes.length),
  for (final size in sizes) ...mp4Uint32(size),
]);

/// A colour description: [type] nclx (MP4, with the full range flag) or nclc (QuickTime), and the H.273 codes of the
/// primaries, the transfer and the matrix (HLG BT.2020 by default)
List<int> mp4Colr({
  String type = 'nclx',
  int primaries = 9,
  int transfer = 18,
  int matrix = 9,
  bool fullRange = false,
}) => mp4Box('colr', [
  ...ascii.encode(type),
  ...mp4Uint16(primaries),
  ...mp4Uint16(transfer),
  ...mp4Uint16(matrix),
  if (type == 'nclx') fullRange ? 0x80 : 0,
]);

/// The bit rates a sample entry declares: the decoding buffer, the maximum and the average
List<int> mp4Btrt({int buffer = 0, int max = 0, int avg = 0}) =>
    mp4Box('btrt', [...mp4Uint32(buffer), ...mp4Uint32(max), ...mp4Uint32(avg)]);

/// A VP9 configuration (vpcC): profile 0, level 10, the [bitDepth] with 4:2:0 chroma, then the colour codes
List<int> mp4VpcC({int bitDepth = 8, int primaries = 1, int transfer = 1}) =>
    mp4FullBox('vpcC', [0, 10, bitDepth << 4 | 2 << 1, primaries, transfer, 1, 0, 0]);

/// The time to sample table: a sample count and a sample duration per entry
List<int> mp4Stts(List<(int, int)> entries) => mp4FullBox('stts', [
  ...mp4Uint32(entries.length),
  for (final (count, duration) in entries) ...[...mp4Uint32(count), ...mp4Uint32(duration)],
]);

/// A track of [sampleDescription]: its header gives [trackId], its handler [handlerType] and [handlerName], its media
/// header [timescale] and [durationTicks], its tables the durations of its samples ([timeToSample]) and their sizes
/// ([stsz], 400 zero bytes by default). The defaults give the bytes of the first fixtures, which had no handler type.
List<int> mp4Track(
  List<int> sampleDescription, {
  List<List<int>> trackBoxes = const [],
  int timescale = 0,
  int mdhdVersion = 0,
  List<(int, int)> timeToSample = const [],
  int trackId = 0,
  String? handlerType,
  String handlerName = '',
  bool countedHandlerName = false,
  int durationTicks = 0,
  List<int>? stsz,
}) => mp4Box('trak', [
  ...mp4Tkhd(trackId: trackId),
  for (final box in trackBoxes) ...box,
  ...mp4Box('mdia', [
    ...mp4Mdhd(timescale: timescale, version: mdhdVersion, duration: durationTicks),
    ...mp4Hdlr(handlerType, name: handlerName, counted: countedHandlerName),
    ...mp4Box('minf', [
      ...mp4FullBox('vmhd', mp4Zeros(8)),
      ...mp4Box('dinf', mp4Box('dref', mp4Zeros(8))),
      ...mp4Box('stbl', [...sampleDescription, ...mp4Stts(timeToSample), ...stsz ?? mp4FullBox('stsz', mp4Zeros(400))]),
    ]),
  ]),
]);

/// An H.264 decoder configuration (avcC): version 1, then [profile], the [compatibility] flags and [level]. With a
/// [highExtension], one empty sequence parameter set, no picture parameter set, then those bytes (the chroma format and
/// the bit depths of the high profiles).
List<int> mp4AvcC({int profile = 0x64, int compatibility = 0, int level = 0x33, List<int>? highExtension}) =>
    highExtension == null
    ? mp4Box('avcC', [1, profile, compatibility, level, 0xff, 0xe1, ...mp4Zeros(10)])
    : mp4Box('avcC', [1, profile, compatibility, level, 0xff, 0xe1, 0x00, 0x00, 0x00, ...highExtension]);

/// An HEVC decoder configuration (hvcC): version 1, then the profile space, the tier and the profile, the
/// compatibility [flags], 6 bytes of constraint flags (none when [blank]) and the level, then the parallelism, the
/// chroma format, the luma and chroma [bitDepth] (with their reserved bits set unless [reservedBits] is false), and the
/// NAL units of [parameterSets] (with their 2 byte header, see [hevcSpsNal]), one array per unit
List<int> mp4HvcC({
  int space = 0,
  bool highTier = false,
  int profile = 1,
  int flags = 0x60000000,
  int level = 153,
  int bitDepth = 8,
  bool reservedBits = true,
  bool blank = false,
  List<List<int>> parameterSets = const [],
}) {
  final depth = (reservedBits ? 0xf8 : 0) | (bitDepth - 8);
  return mp4Box('hvcC', [
    1,
    space << 6 | (highTier ? 0x20 : 0) | profile,
    ...mp4Uint32(flags),
    blank ? 0 : 0x90,
    ...mp4Zeros(5),
    level,
    ...mp4Zeros(3),
    0xfd,
    depth,
    depth,
    ...mp4Zeros(3),
    parameterSets.length,
    for (final unit in parameterSets) ...[
      0x80 | (unit[0] >> 1 & 0x3f),
      ...mp4Uint16(1),
      ...mp4Uint16(unit.length),
      ...unit,
    ],
  ]);
}

/// An HEVC configuration as the Insta360 X4 writes it (docs/18-test-media.md, F6): version 1, every field of the
/// header 0, then its parameter sets, [sps] among them
List<int> mp4HvcCOfX4(List<int> sps) =>
    mp4HvcC(profile: 0, flags: 0, level: 0, bitDepth: 8, reservedBits: false, blank: true, parameterSets: [sps]);

/// A sequence parameter set of HEVC (NAL unit type 33) as far as its bit depths (ITU-T H.265, 7.3.2.2): its 2 byte
/// header, the VPS id 0, [maxSubLayersMinus1] and the temporal nesting flag, the profile_tier_level of [space],
/// [highTier], [profile], the compatibility [flags], the progressive and frame only constraint flags and [level], then
/// for each sub layer the flags of [subLayers] (whether its profile and its level are present, written as zeros), the
/// SPS id 0, [chromaFormat], the frame of [width] x [height], a conformance window of [conformanceWindow] (left, right,
/// top, bottom) when given, the luma [bitDepth] and the chroma one, then the stop bit. Emulation prevention bytes go
/// where the payload holds two zero bytes before a byte of 3 or less, as an encoder writes them; [length] cuts the
/// unit short.
List<int> hevcSpsNal({
  int space = 0,
  bool highTier = false,
  int profile = 1,
  int flags = 0x60000000,
  int level = 183,
  int maxSubLayersMinus1 = 0,
  List<(bool, bool)>? subLayers,
  int chromaFormat = 1,
  int width = 3840,
  int height = 3840,
  List<int>? conformanceWindow,
  int bitDepth = 8,
  int? length,
}) {
  final bits = <int>[];
  void write(int count, int value) {
    for (var bit = count - 1; bit >= 0; bit--) {
      bits.add(value >> bit & 1);
    }
  }

  void writeExpGolomb(int value) {
    final code = value + 1;
    final size = code.bitLength;
    write(size - 1, 0);
    write(size, code);
  }

  write(4, 0);
  write(3, maxSubLayersMinus1);
  // sps_temporal_id_nesting_flag, which must be 1 for a single sub layer: 0 otherwise, as the X4 writes it
  write(1, maxSubLayersMinus1 == 0 ? 1 : 0);
  write(2, space);
  write(1, highTier ? 1 : 0);
  write(5, profile);
  write(32, flags);
  // progressive_source_flag and frame_only_constraint_flag, then 44 zero bits
  write(4, 0x9);
  write(44, 0);
  write(8, level);
  final present = subLayers ?? List.filled(maxSubLayersMinus1, (false, false));
  for (final (profilePresent, levelPresent) in present) {
    write(1, profilePresent ? 1 : 0);
    write(1, levelPresent ? 1 : 0);
  }
  if (maxSubLayersMinus1 > 0) {
    write(2 * (8 - maxSubLayersMinus1), 0);
  }
  for (final (profilePresent, levelPresent) in present) {
    write((profilePresent ? 88 : 0) + (levelPresent ? 8 : 0), 0);
  }
  writeExpGolomb(0);
  writeExpGolomb(chromaFormat);
  if (chromaFormat == 3) {
    write(1, 0);
  }
  writeExpGolomb(width);
  writeExpGolomb(height);
  write(1, conformanceWindow == null ? 0 : 1);
  for (final offset in conformanceWindow ?? const <int>[]) {
    writeExpGolomb(offset);
  }
  writeExpGolomb(bitDepth - 8);
  writeExpGolomb(bitDepth - 8);
  write(1, 1);
  while (bits.length % 8 != 0) {
    bits.add(0);
  }

  final unit = <int>[0x42, 0x01];
  var zeros = 0;
  for (var index = 0; index < bits.length; index += 8) {
    var byte = 0;
    for (var bit = 0; bit < 8; bit++) {
      byte = byte << 1 | bits[index + bit];
    }
    if (zeros >= 2 && byte <= 3) {
      unit.add(3);
      zeros = 0;
    }
    unit.add(byte);
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  return length == null ? unit : unit.sublist(0, length);
}

/// An AV1 decoder configuration (av1C): the marker and version 1, then the [profile] and the [level], then the tier
/// ([highTier]) and the bit depth flags ([highBitDepth], [twelveBit]) before 4:2:0 chroma subsampling
List<int> mp4Av1C({
  int profile = 0,
  int level = 13,
  bool highTier = false,
  bool highBitDepth = false,
  bool twelveBit = false,
}) => mp4Box('av1C', [
  0x81,
  profile << 5 | level,
  (highTier ? 0x80 : 0) | (highBitDepth ? 0x40 : 0) | (twelveBit ? 0x20 : 0) | 0x0c,
  0,
]);

/// A Dolby Vision decoder configuration ([type] dvcC up to profile 7, dvvC from 8): version 1.0, then the [profile]
/// on 7 bits, the [level] on 6, and the RPU and base layer present flags
List<int> mp4DoviC({String type = 'dvvC', int profile = 8, int level = 6}) =>
    mp4Box(type, [1, 0, profile << 1 | level >> 5, (level & 0x1f) << 3 | 0x05, ...mp4Zeros(20)]);

/// A video track whose visual sample entry, of [codec] and frames of [width] x [height], holds [config], an HEVC
/// decoder configuration of zeros by default, then [children] (st3d, sv3d, ...). Its media header and its time to
/// sample table give its [timescale] and the durations of its samples, [timeToSample].
List<int> mp4VideoTrack(
  List<List<int>> children, {
  String codec = 'hvc1',
  List<List<int>> trackBoxes = const [],
  int width = 0,
  int height = 0,
  List<int>? config,
  int timescale = 0,
  int mdhdVersion = 0,
  List<(int, int)> timeToSample = const [],
  int trackId = 0,
  String? handlerType,
  String handlerName = '',
  bool countedHandlerName = false,
  int durationTicks = 0,
  List<int>? stsz,
}) => mp4Track(
  mp4SampleDescription(codec, [config ?? mp4Box('hvcC', mp4Zeros(30)), ...children], width: width, height: height),
  trackBoxes: trackBoxes,
  timescale: timescale,
  mdhdVersion: mdhdVersion,
  timeToSample: timeToSample,
  trackId: trackId,
  handlerType: handlerType,
  handlerName: handlerName,
  countedHandlerName: countedHandlerName,
  durationTicks: durationTicks,
  stsz: stsz,
);

List<int> mp4AudioTrack({
  int trackId = 0,
  String? handlerType,
  String handlerName = '',
  bool countedHandlerName = false,
}) => mp4Track(
  mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box('mp4a', mp4Zeros(28))]),
  trackId: trackId,
  handlerType: handlerType,
  handlerName: handlerName,
  countedHandlerName: countedHandlerName,
);

/// A timed metadata track (handler meta) of one sample entry of [entryType], as the djmd and dbgi tracks of a DJI
/// Osmo 360 file
List<int> mp4MetaTrack(String entryType, {String handlerName = 'CAM meta', int trackId = 0}) => mp4Track(
  mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box(entryType, mp4Zeros(16))]),
  trackId: trackId,
  handlerType: 'meta',
  handlerName: handlerName,
);

/// The moov box of [tracks], after its movie header ([mvhd], 96 zero bytes by default)
List<int> mp4Moov(List<List<int>> tracks, {List<int>? mvhd}) => mp4Box('moov', [
  ...mvhd ?? mp4FullBox('mvhd', mp4Zeros(96)),
  for (final track in tracks) ...track,
  ...mp4Box('udta', mp4Box('meta', mp4Zeros(20))),
]);

final mp4Ftyp = mp4Box('ftyp', [...ascii.encode('isom'), ...mp4Zeros(4), ...ascii.encode('isomiso2mp41')]);

/// An MP4 file: ftyp, then the moov box before or after the media data ([mdat]), then [trailing] bytes (a camd box, an
/// Insta360 trailer)
Uint8List mp4File(List<int> moov, {bool moovAtEnd = false, List<int>? mdat, List<int> trailing = const []}) {
  final media = mdat ?? mp4Box('mdat', mp4Zeros(4096));
  return Uint8List.fromList([...mp4Ftyp, if (!moovAtEnd) ...moov, ...media, if (moovAtEnd) ...moov, ...trailing]);
}
