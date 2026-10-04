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

/// The media header of a track: its [timescale], in version 0 (32 bit times) or 1 (64 bit times)
List<int> mp4Mdhd({int timescale = 0, int version = 0}) => version == 1
    ? mp4Box('mdhd', [1, 0, 0, 0, ...mp4Zeros(16), ...mp4Uint32(timescale), ...mp4Zeros(12)])
    : mp4FullBox('mdhd', [...mp4Zeros(8), ...mp4Uint32(timescale), ...mp4Zeros(8)]);

/// The time to sample table: a sample count and a sample duration per entry
List<int> mp4Stts(List<(int, int)> entries) => mp4FullBox('stts', [
  ...mp4Uint32(entries.length),
  for (final (count, duration) in entries) ...[...mp4Uint32(count), ...mp4Uint32(duration)],
]);

List<int> mp4Track(
  List<int> sampleDescription, {
  List<List<int>> trackBoxes = const [],
  int timescale = 0,
  int mdhdVersion = 0,
  List<(int, int)> timeToSample = const [],
}) => mp4Box('trak', [
  ...mp4Box('tkhd', mp4Zeros(84)),
  for (final box in trackBoxes) ...box,
  ...mp4Box('mdia', [
    ...mp4Mdhd(timescale: timescale, version: mdhdVersion),
    ...mp4FullBox('hdlr', mp4Zeros(21)),
    ...mp4Box('minf', [
      ...mp4FullBox('vmhd', mp4Zeros(8)),
      ...mp4Box('dinf', mp4Box('dref', mp4Zeros(8))),
      ...mp4Box('stbl', [...sampleDescription, ...mp4Stts(timeToSample), ...mp4FullBox('stsz', mp4Zeros(400))]),
    ]),
  ]),
]);

/// An H.264 decoder configuration (avcC): version 1, then [profile], the [compatibility] flags and [level]
List<int> mp4AvcC({int profile = 0x64, int compatibility = 0, int level = 0x33}) =>
    mp4Box('avcC', [1, profile, compatibility, level, 0xff, 0xe1, ...mp4Zeros(10)]);

/// An HEVC decoder configuration (hvcC): version 1, then the profile space, the tier and the profile, the
/// compatibility [flags], 6 bytes of constraint flags and the level
List<int> mp4HvcC({int space = 0, bool highTier = false, int profile = 1, int flags = 0x60000000, int level = 153}) =>
    mp4Box('hvcC', [
      1,
      space << 6 | (highTier ? 0x20 : 0) | profile,
      ...mp4Uint32(flags),
      0x90,
      ...mp4Zeros(5),
      level,
      ...mp4Zeros(10),
    ]);

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
}) => mp4Track(
  mp4SampleDescription(codec, [config ?? mp4Box('hvcC', mp4Zeros(30)), ...children], width: width, height: height),
  trackBoxes: trackBoxes,
  timescale: timescale,
  mdhdVersion: mdhdVersion,
  timeToSample: timeToSample,
);

List<int> mp4AudioTrack() => mp4Track(mp4FullBox('stsd', [...mp4Uint32(1), ...mp4Box('mp4a', mp4Zeros(28))]));

List<int> mp4Moov(List<List<int>> tracks) => mp4Box('moov', [
  ...mp4FullBox('mvhd', mp4Zeros(96)),
  for (final track in tracks) ...track,
  ...mp4Box('udta', mp4Box('meta', mp4Zeros(20))),
]);

final mp4Ftyp = mp4Box('ftyp', [...ascii.encode('isom'), ...mp4Zeros(4), ...ascii.encode('isomiso2mp41')]);

/// An MP4 file: ftyp, then the moov box before or after the media data ([mdat])
Uint8List mp4File(List<int> moov, {bool moovAtEnd = false, List<int>? mdat}) {
  final media = mdat ?? mp4Box('mdat', mp4Zeros(4096));
  return Uint8List.fromList([...mp4Ftyp, if (!moovAtEnd) ...moov, ...media, if (moovAtEnd) ...moov]);
}
