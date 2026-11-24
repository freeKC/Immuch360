// The marks that make every player show a 3D video of a 360° video as a 360° 3D video (lot ai-360-3d-51): Spherical
// Video V2 (https://github.com/google/spatial-media/blob/master/docs/spherical-video-v2-rfc.md) in the sample entry of
// the video track, `st3d` (stereo_mode 1, top and bottom, the left eye on top) and `sv3d` (`svhd`, then `proj` with
// `prhd` all zero and `equi` with no bounds: the whole sphere), and the XML of Spherical Video V1 in a `uuid` box of
// the video track, which older players read and ExifTool gives as XMP-GSpherical:ProjectionType (the tag the Immich
// server reads to flag a video 360°). FFmpeg writes neither for frames that come from a pipe, so the MP4 of the final
// mux is written again once with them: its moov rebuilt (the ancestors of each new box grown, the chunk offsets of
// every track moved by the growth when the media data comes after the moov, as with +faststart), the rest copied.
//
// Spatial sound: an ambisonic track carries an `SA3D` box in its sample entry. When the source's track had one and
// the output's track (copied as it is by the mux) has none, the source's box is put back, track for track.
//
// Pure Dart for the boxes; writeSphericalMp4 does the I/O.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/stereo_layout.dart';

/// The usertype of the uuid box of Spherical Video V1
const sphericalV1Uuid = [
  0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd, //
];

/// The software named in svhd and the XML
const sphericalWriterName = 'Immuch360';

/// A box of the moov: its type, the bytes after its header and before its children ([prefix]: the version and flags
/// of a full box, the fixed fields of a sample entry, the usertype of a uuid box), its children when it is one of the
/// containers the writer walks, else its whole [payload]
class Mp4Box {
  Mp4Box(this.type, {Uint8List? prefix, this.children, this.payload}) : prefix = prefix ?? Uint8List(0);

  final String type;
  Uint8List prefix;
  List<Mp4Box>? children;
  Uint8List? payload;

  int get size {
    final body = prefix.length + (children?.fold<int>(0, (sum, child) => sum + child.size) ?? payload?.length ?? 0);
    return body + 8 > 0xffffffff ? body + 16 : body + 8;
  }

  Mp4Box? child(String name) => children?.where((box) => box.type == name).firstOrNull;

  void write(BytesBuilder out) {
    final total = size;
    final header = ByteData(total > 0xffffffff ? 16 : 8);
    if (total > 0xffffffff) {
      header
        ..setUint32(0, 1)
        ..setUint64(8, total);
    } else {
      header.setUint32(0, total);
    }
    final type = latin1.encode(this.type);
    for (var i = 0; i < 4; i++) {
      header.setUint8(4 + i, type[i]);
    }
    out
      ..add(header.buffer.asUint8List())
      ..add(prefix);
    final kids = children;
    if (kids != null) {
      for (final child in kids) {
        child.write(out);
      }
    } else if (payload != null) {
      out.add(payload!);
    }
  }

  Uint8List toBytes() {
    final out = BytesBuilder(copy: false);
    write(out);
    return out.takeBytes();
  }
}

/// The visual sample entries the writer marks
const _visualEntries = {'avc1', 'avc3', 'hvc1', 'hev1', 'av01', 'vp09', 'mp4v', 'dvh1', 'dvhe'};

/// The audio sample entries an SA3D box goes in
const _audioEntries = {
  'mp4a',
  'Opus',
  'opus',
  'alac',
  'fLaC',
  'ac-3',
  'ec-3',
  'lpcm',
  'sowt',
  'twos',
  'in24',
  'in32',
  'fl32',
  'fl64',
};

const _containers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf'};

/// The boxes of [data] from [start] to [end], the containers of the path to the sample entries walked
List<Mp4Box> parseMp4Boxes(Uint8List data, [int start = 0, int? end, String? parent]) {
  final stop = end ?? data.length;
  final view = ByteData.sublistView(data);
  final boxes = <Mp4Box>[];
  var at = start;
  while (at + 8 <= stop) {
    var size = view.getUint32(at);
    final type = latin1.decode(data.sublist(at + 4, at + 8));
    var header = 8;
    if (size == 1) {
      if (at + 16 > stop) {
        throw const FormatException('A box cut short');
      }
      size = view.getUint64(at + 8);
      header = 16;
    } else if (size == 0) {
      size = stop - at;
    }
    if (size < header || at + size > stop) {
      throw FormatException('The box $type at $at of $size bytes passes its parent');
    }
    final bodyStart = at + header;
    final bodyEnd = at + size;
    if (_containers.contains(type)) {
      boxes.add(Mp4Box(type, children: parseMp4Boxes(data, bodyStart, bodyEnd, type)));
    } else if (type == 'stsd') {
      boxes.add(
        Mp4Box(
          type,
          prefix: Uint8List.fromList(data.sublist(bodyStart, bodyStart + 8)),
          children: parseMp4Boxes(data, bodyStart + 8, bodyEnd, type),
        ),
      );
    } else if (parent == 'stsd' ? _sampleEntryLength(type, data, bodyStart, bodyEnd) : null case final fixed?) {
      boxes.add(
        Mp4Box(
          type,
          prefix: Uint8List.fromList(data.sublist(bodyStart, bodyStart + fixed)),
          children: parseMp4Boxes(data, bodyStart + fixed, bodyEnd, type),
        ),
      );
    } else {
      boxes.add(Mp4Box(type, payload: Uint8List.fromList(data.sublist(bodyStart, bodyEnd))));
    }
    at += size;
  }
  return boxes;
}

/// The fixed fields of a sample entry whose children the writer reads: 78 bytes of a visual one, 28 of an audio one
/// (QuickTime's version 1 and 2 sound descriptions 16 and 36 more); null for any other entry, kept whole
int? _sampleEntryLength(String type, Uint8List data, int start, int end) {
  if (_visualEntries.contains(type)) {
    return start + 78 <= end ? 78 : null;
  }
  if (_audioEntries.contains(type) && start + 28 <= end) {
    final version = ByteData.sublistView(data).getUint16(start + 8);
    final fixed = switch (version) {
      0 => 28,
      1 => 44,
      2 => 64,
      _ => null,
    };
    return fixed != null && start + fixed <= end ? fixed : null;
  }
  return null;
}

/// The handler of a trak ('vide', 'soun'...), null when it has none
String? trackHandler(Mp4Box trak) {
  final payload = trak.child('mdia')?.child('hdlr')?.payload;
  if (payload == null || payload.length < 12) {
    return null;
  }
  return latin1.decode(payload.sublist(8, 12));
}

/// The sample entries of a trak
List<Mp4Box> sampleEntriesOf(Mp4Box trak) =>
    trak.child('mdia')?.child('minf')?.child('stbl')?.child('stsd')?.children ?? const [];

Uint8List _fullBoxPrefix() => Uint8List(4);

/// st3d of [stereo]: 0 mono, 1 top and bottom, 2 left and right
Mp4Box st3dBox(StereoLayout stereo) => Mp4Box(
  'st3d',
  prefix: _fullBoxPrefix(),
  payload: Uint8List.fromList([
    switch (stereo) {
      StereoLayout.mono => 0,
      StereoLayout.topBottom => 1,
      StereoLayout.leftRight => 2,
    },
  ]),
);

/// sv3d of a whole equirectangular sphere: svhd naming the writer, proj with prhd (no yaw, pitch or roll) and equi
/// with no bounds
Mp4Box sv3dEquirectangularBox() => Mp4Box(
  'sv3d',
  children: [
    Mp4Box('svhd', prefix: _fullBoxPrefix(), payload: Uint8List.fromList([...utf8.encode(sphericalWriterName), 0])),
    Mp4Box(
      'proj',
      children: [
        Mp4Box('prhd', prefix: _fullBoxPrefix(), payload: Uint8List(12)),
        Mp4Box('equi', prefix: _fullBoxPrefix(), payload: Uint8List(16)),
      ],
    ),
  ],
);

/// The XML of Spherical Video V1 for a whole equirectangular sphere stored as [stereo]
String sphericalV1Xml(StereoLayout stereo) {
  final mode = switch (stereo) {
    StereoLayout.mono => 'mono',
    StereoLayout.topBottom => 'top-bottom',
    StereoLayout.leftRight => 'left-right',
  };
  return '<?xml version="1.0"?><rdf:SphericalVideo xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" '
      'xmlns:GSpherical="http://ns.google.com/videos/1.0/spherical/">'
      '<GSpherical:Spherical>true</GSpherical:Spherical>'
      '<GSpherical:Stitched>true</GSpherical:Stitched>'
      '<GSpherical:StitchingSoftware>$sphericalWriterName</GSpherical:StitchingSoftware>'
      '<GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>'
      '<GSpherical:StereoMode>$mode</GSpherical:StereoMode>'
      '</rdf:SphericalVideo>';
}

Mp4Box _v1Box(StereoLayout stereo) => Mp4Box(
  'uuid',
  prefix: Uint8List.fromList(sphericalV1Uuid),
  payload: Uint8List.fromList(utf8.encode(sphericalV1Xml(stereo))),
);

bool _isV1(Mp4Box box) {
  if (box.type != 'uuid') {
    return false;
  }
  final head = box.prefix.isNotEmpty ? box.prefix : box.payload;
  if (head == null || head.length < 16) {
    return false;
  }
  for (var i = 0; i < 16; i++) {
    if (head[i] != sphericalV1Uuid[i]) {
      return false;
    }
  }
  return true;
}

/// What [markMoovSpherical] changed
class SphericalMoov {
  const SphericalMoov(this.moov, {required this.videoTracks, required this.sa3dAdded});

  final Mp4Box moov;
  final int videoTracks;
  final int sa3dAdded;
}

/// [moov] with every video track marked as a whole equirectangular sphere stored as [stereo] (st3d and sv3d in its
/// sample entries, those it had replaced; the V1 uuid box in the track, one it had replaced), and the SA3D box of
/// [audioSa3d] (the payloads of the source's audio tracks in order, null for a track without one) put in the audio
/// track of the same rank that has none
SphericalMoov markMoovSpherical(
  Mp4Box moov, {
  StereoLayout stereo = StereoLayout.topBottom,
  List<Uint8List?> audioSa3d = const [],
}) {
  var videoTracks = 0;
  var sa3dAdded = 0;
  var audioRank = 0;
  for (final trak in moov.children!.where((box) => box.type == 'trak')) {
    switch (trackHandler(trak)) {
      case 'vide':
        final entries = sampleEntriesOf(
          trak,
        ).where((entry) => _visualEntries.contains(entry.type) && entry.children != null);
        if (entries.isEmpty) {
          continue;
        }
        for (final entry in entries) {
          entry.children = [
            ...entry.children!.where((box) => box.type != 'st3d' && box.type != 'sv3d'),
            st3dBox(stereo),
            sv3dEquirectangularBox(),
          ];
        }
        trak.children = [...trak.children!.where((box) => !_isV1(box)), _v1Box(stereo)];
        videoTracks++;
      case 'soun':
        final rank = audioRank++;
        final sa3d = rank < audioSa3d.length ? audioSa3d[rank] : null;
        if (sa3d == null) {
          continue;
        }
        for (final entry in sampleEntriesOf(trak).where((entry) => entry.children != null)) {
          if (entry.child('SA3D') == null) {
            entry.children = [...entry.children!, Mp4Box('SA3D', payload: sa3d)];
            sa3dAdded++;
          }
        }
    }
  }
  return SphericalMoov(moov, videoTracks: videoTracks, sa3dAdded: sa3dAdded);
}

/// The SA3D payloads of the audio tracks of [moov], in their order, null for a track without one
List<Uint8List?> audioSa3dOf(Mp4Box moov) => [
  for (final trak in moov.children!.where((box) => box.type == 'trak' && trackHandler(box) == 'soun'))
    sampleEntriesOf(trak).map((entry) => entry.child('SA3D')?.payload).nonNulls.firstOrNull,
];

/// Each stco table of [moov] that an offset moved by [delta] would take past 32 bits rewritten as co64 (8 byte
/// offsets, unmoved); whether one was. FFmpeg writes co64 only for its own offsets, so a faststart MP4 whose media data
/// ends just under 4 GiB passes that line once the moov grows with the marks.
bool widenChunkOffsets(Mp4Box moov, int delta) {
  var widened = false;
  for (final trak in moov.children!.where((box) => box.type == 'trak')) {
    final stbl = trak.child('mdia')?.child('minf')?.child('stbl');
    final tables = stbl?.children;
    if (tables == null) {
      continue;
    }
    for (var t = 0; t < tables.length; t++) {
      final payload = tables[t].payload;
      if (tables[t].type != 'stco' || payload == null || payload.length < 8) {
        continue;
      }
      final view = ByteData.sublistView(payload);
      final count = view.getUint32(4);
      if (8 + count * 4 > payload.length) {
        throw FormatException('stco of $count entries in ${payload.length} bytes');
      }
      var passes = false;
      for (var i = 0; i < count && !passes; i++) {
        passes = view.getUint32(8 + i * 4) + delta > 0xffffffff;
      }
      if (!passes) {
        continue;
      }
      final wide = Uint8List(8 + count * 8);
      final wideView = ByteData.sublistView(wide)
        ..setUint32(0, view.getUint32(0))
        ..setUint32(4, count);
      for (var i = 0; i < count; i++) {
        wideView.setUint64(8 + i * 8, view.getUint32(8 + i * 4));
      }
      tables[t] = Mp4Box('co64', payload: wide);
      widened = true;
    }
  }
  return widened;
}

/// The chunk offsets of [moov], read from a file where it took [oldSize] bytes before its media data, moved by its
/// growth: the stco tables that would pass 32 bits made co64 first (their own growth counted in), then every offset
/// moved. Returns the growth.
int relocateChunkOffsets(Mp4Box moov, int oldSize) {
  var delta = moov.size - oldSize;
  // Each table widened grows the moov, which may take another one past the line: at most one round per table
  while (widenChunkOffsets(moov, delta)) {
    delta = moov.size - oldSize;
  }
  shiftChunkOffsets(moov, delta);
  return delta;
}

/// Every chunk offset of [moov] (stco, co64) moved by [delta] bytes; throws when an offset of stco would leave 32 bits
void shiftChunkOffsets(Mp4Box moov, int delta) {
  if (delta == 0) {
    return;
  }
  for (final trak in moov.children!.where((box) => box.type == 'trak')) {
    final stbl = trak.child('mdia')?.child('minf')?.child('stbl');
    for (final table in stbl?.children ?? const <Mp4Box>[]) {
      final payload = table.payload;
      if (payload == null || (table.type != 'stco' && table.type != 'co64') || payload.length < 8) {
        continue;
      }
      final view = ByteData.sublistView(payload);
      final count = view.getUint32(4);
      final wide = table.type == 'co64';
      final width = wide ? 8 : 4;
      if (8 + count * width > payload.length) {
        throw FormatException('${table.type} of $count entries in ${payload.length} bytes');
      }
      for (var i = 0; i < count; i++) {
        final at = 8 + i * width;
        final moved = (wide ? view.getUint64(at) : view.getUint32(at)) + delta;
        if (moved < 0 || (!wide && moved > 0xffffffff)) {
          throw FormatException('A chunk offset of ${table.type} moved out of range: $moved');
        }
        if (wide) {
          view.setUint64(at, moved);
        } else {
          view.setUint32(at, moved);
        }
      }
    }
  }
}

/// The top-level boxes of a file, as listTopLevelBoxes gives them: where each starts and its size
typedef _TopBox = ({String type, int offset, int size});

Future<List<_TopBox>> _topBoxes(RandomAccessFile file) async {
  final length = await file.length();
  final boxes = <_TopBox>[];
  var at = 0;
  while (at + 8 <= length) {
    await file.setPosition(at);
    final head = await file.read(16);
    final view = ByteData.sublistView(head);
    var size = view.getUint32(0);
    final type = latin1.decode(head.sublist(4, 8));
    if (size == 1) {
      size = view.getUint64(8);
    } else if (size == 0) {
      size = length - at;
    }
    if (size < 8 || at + size > length) {
      throw FormatException('The box $type at $at of $size bytes passes the end of the file');
    }
    boxes.add((type: type, offset: at, size: size));
    at += size;
  }
  return boxes;
}

/// The moov of the MP4 or MOV at [path], null when it has none or cannot be read
Future<Mp4Box?> readMoov(String path) async {
  try {
    final file = await File(path).open();
    try {
      final moov = (await _topBoxes(file)).where((box) => box.type == 'moov').firstOrNull;
      if (moov == null || moov.size > 256 * 1024 * 1024) {
        return null;
      }
      await file.setPosition(moov.offset);
      final bytes = await file.read(moov.size);
      return parseMp4Boxes(bytes).single;
    } finally {
      await file.close();
    }
  } on Object {
    return null;
  }
}

/// The SA3D payloads of the audio tracks of the file at [path] (see [audioSa3dOf]); empty when it is no MP4 or MOV
Future<List<Uint8List?>> readAudioSa3d(String path) async {
  final moov = await readMoov(path);
  return moov == null ? const [] : audioSa3dOf(moov);
}

/// [input], an MP4 of the final mux, written to [output] with the marks of a 360° video stored as [stereo] (see the top
/// of this file): the boxes before the moov copied, the moov rebuilt, the rest copied, every chunk offset moved by the
/// growth of the moov when the media data comes after it. Returns what changed; throws [FormatException] for a file
/// with no moov or no video track.
Future<SphericalMoov> writeSphericalMp4(
  String input,
  String output, {
  StereoLayout stereo = StereoLayout.topBottom,
  List<Uint8List?> audioSa3d = const [],
}) async {
  final source = await File(input).open();
  final target = await File(output).open(mode: FileMode.write);
  try {
    final boxes = await _topBoxes(source);
    final at = boxes.indexWhere((box) => box.type == 'moov');
    if (at < 0) {
      throw const FormatException('No moov box');
    }
    final old = boxes[at];
    await source.setPosition(old.offset);
    final moov = parseMp4Boxes(await source.read(old.size)).single;
    final marked = markMoovSpherical(moov, stereo: stereo, audioSa3d: audioSa3d);
    if (marked.videoTracks == 0) {
      throw const FormatException('No video track to mark');
    }
    // The media data after the moov moves by its growth; before it, it stays where it is
    final dataAfter = boxes.skip(at + 1).any((box) => box.type == 'mdat');
    final dataBefore = boxes.take(at).any((box) => box.type == 'mdat');
    if (dataAfter && dataBefore) {
      throw const FormatException('Media data on both sides of the moov');
    }
    if (dataAfter) {
      relocateChunkOffsets(moov, old.size);
    }
    Future<void> copy(int from, int length) async {
      await source.setPosition(from);
      var left = length;
      while (left > 0) {
        final chunk = await source.read(math.min(left, 8 * 1024 * 1024));
        if (chunk.isEmpty) {
          throw const FormatException('The file ended early');
        }
        await target.writeFrom(chunk);
        left -= chunk.length;
      }
    }

    await copy(0, old.offset);
    await target.writeFrom(moov.toBytes());
    final end = boxes.last.offset + boxes.last.size;
    await copy(old.offset + old.size, end - old.offset - old.size);
    await target.flush();
    return marked;
  } finally {
    await source.close();
    await target.close();
  }
}
