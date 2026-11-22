// A small MP4 for the tests of the marks of the 360° 3D videos: ftyp, a moov with a video track (avc1 with its avcC)
// and an audio track (mp4a), each with its chunk offsets (stco) into the media data, and the mdat; the moov before
// the mdat as +faststart writes it, or after it.

import 'dart:convert';
import 'dart:typed_data';

Uint8List _box(String type, List<int> body) {
  final out = BytesBuilder()
    ..add((ByteData(4)..setUint32(0, 8 + body.length)).buffer.asUint8List())
    ..add(latin1.encode(type))
    ..add(body);
  return out.takeBytes();
}

Uint8List _full(String type, List<int> body, {int version = 0}) => _box(type, [version, 0, 0, 0, ...body]);

List<int> _u32(int value) => (ByteData(4)..setUint32(0, value)).buffer.asUint8List();
List<int> _u16(int value) => (ByteData(2)..setUint16(0, value)).buffer.asUint8List();

Uint8List _hdlr(String handler) => _full('hdlr', [..._u32(0), ...latin1.encode(handler), ...List.filled(12, 0), 0]);

Uint8List _mdhd() => _full('mdhd', [..._u32(0), ..._u32(0), ..._u32(1000), ..._u32(1000), 0x55, 0xc4, 0, 0]);

Uint8List _avc1(int width, int height, List<Uint8List> extra) => _box('avc1', [
  ...List.filled(6, 0), ..._u16(1), // reserved, data reference index
  ...List.filled(16, 0), // pre defined, reserved
  ..._u16(width), ..._u16(height),
  ..._u32(0x00480000), ..._u32(0x00480000), ..._u32(0), ..._u16(1),
  ...List.filled(32, 0), // compressor name
  ..._u16(0x18), ..._u16(0xffff),
  ..._box('avcC', [1, 0x64, 0, 0x28, 0xff, 0xe0, 0]),
  for (final box in extra) ...box,
]);

Uint8List _mp4a(List<Uint8List> extra) => _box('mp4a', [
  ...List.filled(6, 0), ..._u16(1),
  ...List.filled(8, 0), // version 0 and reserved
  ..._u16(4), ..._u16(16), ..._u32(0), ..._u32(48000 << 16),
  ..._full('esds', [3, 0x19, 0, 1, 0]),
  for (final box in extra) ...box,
]);

Uint8List _trak(String handler, Uint8List entry, int chunkOffset, {List<Uint8List> trakExtra = const []}) =>
    _box('trak', [
      ..._full('tkhd', List.filled(80, 0)),
      ..._box('mdia', [
        ..._mdhd(),
        ..._hdlr(handler),
        ..._box('minf', [
          ..._box('stbl', [
            ..._full('stsd', [..._u32(1), ...entry]),
            ..._full('stts', _u32(0)),
            ..._full('stsc', _u32(0)),
            ..._full('stsz', [..._u32(0), ..._u32(0)]),
            ..._full('stco', [..._u32(1), ..._u32(chunkOffset)]),
          ]),
        ]),
      ]),
      for (final box in trakExtra) ...box,
    ]);

/// The bytes of the media data of [tinyMp4]: the video chunk, then the audio chunk
final tinyVideoChunk = Uint8List.fromList(List.generate(64, (i) => (i * 7 + 1) & 0xff));
final tinyAudioChunk = Uint8List.fromList(List.generate(32, (i) => (i * 13 + 5) & 0xff));

/// An MP4 of a [width] x [height] video track and an audio track, its moov before its mdat (or after it with
/// [moovLast]); [videoExtra] and [audioExtra] go in the sample entries, [trakExtra] in the video track, [mediaData]
/// replaces the chunks (the offsets then both point at its start)
Uint8List tinyMp4({
  int width = 64,
  int height = 64,
  bool moovLast = false,
  List<Uint8List> videoExtra = const [],
  List<Uint8List> audioExtra = const [],
  List<Uint8List> trakExtra = const [],
  Uint8List? mediaData,
}) {
  final ftyp = _box('ftyp', [...latin1.encode('isom'), ..._u32(0x200), ...latin1.encode('isomiso2avc1mp41')]);
  final data = mediaData ?? Uint8List.fromList([...tinyVideoChunk, ...tinyAudioChunk]);
  Uint8List moovWith(int videoAt, int audioAt) => _box('moov', [
    ..._full('mvhd', List.filled(96, 0)),
    ..._trak('vide', _avc1(width, height, videoExtra), videoAt, trakExtra: trakExtra),
    ..._trak('soun', _mp4a(audioExtra), audioAt),
  ]);
  final size = moovWith(0, 0).length;
  final dataStart = moovLast ? ftyp.length + 8 : ftyp.length + size + 8;
  final audioAt = mediaData == null ? dataStart + tinyVideoChunk.length : dataStart;
  final moov = moovWith(dataStart, audioAt);
  final mdat = _box('mdat', data);
  return Uint8List.fromList(moovLast ? [...ftyp, ...mdat, ...moov] : [...ftyp, ...moov, ...mdat]);
}

/// A box of [type] with [body], for the extras of [tinyMp4]
Uint8List tinyBox(String type, List<int> body) => _box(type, body);
