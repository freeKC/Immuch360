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

List<int> mp4SampleDescription(String codec, List<List<int>> children) => mp4FullBox('stsd', [
  ...mp4Uint32(1),
  ...mp4Box(codec, [...mp4Zeros(78), for (final child in children) ...child]),
]);

List<int> mp4Track(List<int> sampleDescription, {List<List<int>> trackBoxes = const []}) => mp4Box('trak', [
  ...mp4Box('tkhd', mp4Zeros(84)),
  for (final box in trackBoxes) ...box,
  ...mp4Box('mdia', [
    ...mp4FullBox('mdhd', mp4Zeros(20)),
    ...mp4FullBox('hdlr', mp4Zeros(21)),
    ...mp4Box('minf', [
      ...mp4FullBox('vmhd', mp4Zeros(8)),
      ...mp4Box('dinf', mp4Box('dref', mp4Zeros(8))),
      ...mp4Box('stbl', [
        ...sampleDescription,
        ...mp4FullBox('stts', mp4Zeros(4)),
        ...mp4FullBox('stsz', mp4Zeros(400)),
      ]),
    ]),
  ]),
]);

/// A video track whose visual sample entry, of [codec], holds [children] (st3d, sv3d, ...)
List<int> mp4VideoTrack(List<List<int>> children, {String codec = 'hvc1', List<List<int>> trackBoxes = const []}) =>
    mp4Track(mp4SampleDescription(codec, [mp4Box('hvcC', mp4Zeros(30)), ...children]), trackBoxes: trackBoxes);

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
