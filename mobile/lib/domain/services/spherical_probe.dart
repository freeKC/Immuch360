// Spherical metadata of MP4 and MOV videos, as cameras and the Spatial Media tools write it: the st3d box tells the
// stereo layout, the sv3d box the projection (Spherical Video V2, https://github.com/google/spatial-media). VR180
// cameras write a mesh projection, or an equirectangular one cropped to the front half of the sphere. Older files
// carry the same in a uuid box of XML (Spherical Video V1).
//
// The same read gives what a decoder needs to know of the video track (its codec, profile and level, frame size and
// frame rate), which the server does not tell: the players check it against the decoders of the device before they
// pick the original or the transcoded stream.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/stereo_layout.dart';

/// Reads up to [length] bytes of a file from [offset]: fewer at the end of the file, none past it.
typedef ByteRangeReader = Future<Uint8List> Function(int offset, int length);

/// What a video file declares about its 360° projection and the layout of its eyes, and what its video track is.
class SphericalProbe {
  const SphericalProbe({
    this.stereo,
    this.halfSphere,
    this.hasSphericalMetadata = false,
    this.codec,
    this.codecs,
    this.codedWidth,
    this.codedHeight,
    this.frameRate,
  });

  /// Layout of the eyes the file declares (st3d box), null when it does not say
  final StereoLayout? stereo;

  /// Whether the image covers the front half of the sphere only (VR180): true for a projection cropped to about
  /// half the width, or a mesh projection; false for a full sphere; null when the file declares no projection.
  final bool? halfSphere;

  /// Whether the file declares a 360° projection (sv3d box, or the uuid box of Spherical Video V1)
  final bool hasSphericalMetadata;

  /// Four character code of the sample entry of the video track ("hvc1", "avc1", "av01", ...), null when no video
  /// track was read
  final String? codec;

  /// The codec with its profile and level, as RFC 6381 writes it ("avc1.640033", "hvc1.2.4.L153", "av01.0.13M.10",
  /// "dvh1.08.06"), read from the decoder configuration of an H.264, HEVC, AV1 or Dolby Vision track; null for another
  /// codec, or when it is missing. A Dolby Vision track without its own configuration (dvcC or dvvC) gives the one of
  /// its HEVC base layer ("hvc1.2.4.L153"), which a device without a Dolby Vision decoder plays: the decoders are then
  /// asked about that layer.
  final String? codecs;

  /// Size of the coded frames, as the sample entry gives it: what the decoder has to take, whatever rotation the
  /// player applies on top. Null when the file does not say.
  final int? codedWidth;
  final int? codedHeight;

  /// Mean frame rate of the video track, from its time scale and the durations of its samples; null when unknown, in
  /// a fragmented file for example, whose samples are described further on
  final double? frameRate;

  @override
  bool operator ==(Object other) =>
      other is SphericalProbe &&
      other.stereo == stereo &&
      other.halfSphere == halfSphere &&
      other.hasSphericalMetadata == hasSphericalMetadata &&
      other.codec == codec &&
      other.codecs == codecs &&
      other.codedWidth == codedWidth &&
      other.codedHeight == codedHeight &&
      other.frameRate == frameRate;

  @override
  int get hashCode =>
      Object.hash(stereo, halfSphere, hasSphericalMetadata, codec, codecs, codedWidth, codedHeight, frameRate);

  @override
  String toString() =>
      'SphericalProbe(stereo: $stereo, halfSphere: $halfSphere, hasSphericalMetadata: $hasSphericalMetadata, '
      'codec: $codec, codecs: $codecs, codedWidth: $codedWidth, codedHeight: $codedHeight, frameRate: $frameRate)';
}

// Bytes read at once while looking for the moov box: the head of a file usually holds it whole, when it was written
// for streaming
const _chunkLength = 64 * 1024;

/// Most bytes of the moov box the probe reads. The first video track comes first in it, and its sample description
/// before its large tables, so the head of a longer moov box is enough.
const sphericalProbeMaxMoovLength = 4 * 1024 * 1024;

// Bounds on the boxes walked, so that a damaged file cannot make the probe loop
const _maxTopLevelBoxes = 64;
const _maxChildBoxes = 1024;

// Sample entries of video tracks, whose child boxes hold st3d and sv3d
const _visualSampleEntries = {'avc1', 'avc3', 'hvc1', 'hev1', 'dvh1', 'dvhe', 'av01', 'vp08', 'vp09', 'mp4v'};

// Fields of a visual sample entry before its child boxes: 8 bytes of SampleEntry, then 70 of VisualSampleEntry
const _visualSampleEntryLength = 78;

// The sample entry of the HEVC base layer of each Dolby Vision sample entry that has one, whose hvcC box describes it
const _dolbyVisionHevcBase = {'dvh1': 'hvc1', 'dvhe': 'hev1'};

// Where the width and the height of the frames sit in a visual sample entry: after the 8 bytes of SampleEntry and 16
// of reserved and predefined fields, 16 bits each
const _visualSampleEntryWidthOffset = 24;

// User type of the uuid box of Spherical Video V1: ffcc8263-f855-4a93-8814-587a02521fdd
const _sphericalV1Uuid = [
  0xff,
  0xcc,
  0x82,
  0x63,
  0xf8,
  0x55,
  0x4a,
  0x93,
  0x88,
  0x14,
  0x58,
  0x7a,
  0x02,
  0x52,
  0x1f,
  0xdd,
];

/// Reads the spherical metadata of the MP4 or MOV file that [read] reads.
///
/// Walks the top level boxes from the start of the file to the moov box, which is at the head of a file written for
/// streaming and at the end of a file a camera recorded, reading a box header at a time past the media data. Reads
/// at most [maxMoovLength] bytes of the moov box. A file that is not an MP4, or that is truncated or damaged, gives
/// what could be read, and nothing declared when it is nothing at all. Errors of [read] are not caught.
Future<SphericalProbe> probeSphericalMetadata(ByteRangeReader read, {int maxMoovLength = sphericalProbeMaxMoovLength}) {
  return _TopLevelWalk(read).probe(maxMoovLength);
}

class _TopLevelWalk {
  _TopLevelWalk(this._read);

  final ByteRangeReader _read;

  // Last bytes read, from _chunkOffset, and whether they reach the end of the file
  Uint8List _chunk = Uint8List(0);
  int _chunkOffset = 0;
  bool _chunkReachesEnd = false;

  // At most [length] bytes from [offset], from the last bytes read when they hold them, else read with at least
  // [readLength] bytes
  Future<Uint8List> _bytesAt(int offset, int length, {int readLength = 0}) async {
    final local = offset - _chunkOffset;
    if (local >= 0 && local <= _chunk.length && (local + length <= _chunk.length || _chunkReachesEnd)) {
      return Uint8List.sublistView(_chunk, local, math.min(local + length, _chunk.length));
    }
    final requested = math.max(length, readLength);
    final bytes = await _read(offset, requested);
    _chunk = bytes.length > requested ? Uint8List.sublistView(bytes, 0, requested) : bytes;
    _chunkOffset = offset;
    _chunkReachesEnd = _chunk.length < requested;
    return Uint8List.sublistView(_chunk, 0, math.min(length, _chunk.length));
  }

  Future<SphericalProbe> probe(int maxMoovLength) async {
    var offset = 0;
    for (var count = 0; count < _maxTopLevelBoxes; count++) {
      final header = await _bytesAt(offset, 16, readLength: _chunkLength);
      if (header.length < 8) {
        break;
      }
      final bytes = ByteData.sublistView(header);
      var size = bytes.getUint32(0);
      final type = _fourCC(header, 4);
      var headerLength = 8;
      if (size == 1) {
        if (header.length < 16) {
          break;
        }
        size = _uint64(bytes, 8);
        headerLength = 16;
      }
      if (type == 'moov') {
        if (size != 0 && size < headerLength) {
          break;
        }
        // A size of 0 runs to the end of the file
        final contentLength = size == 0 ? maxMoovLength : math.min(size - headerLength, maxMoovLength);
        final moov = await _bytesAt(offset + headerLength, contentLength);
        return _parseMoov(moov);
      }
      // A box running to the end of the file has nothing after it, and a damaged size nothing to trust
      if (size == 0 || size < headerLength) {
        break;
      }
      offset += size;
    }
    return const SphericalProbe();
  }
}

/// A box in a buffer: its [type], and the offsets of its content, after the header, from [start] to [end].
class _Box {
  const _Box(this.type, this.start, this.end, {this.userType});

  final String type;
  final int start;
  final int end;

  /// Extended type of a uuid box
  final Uint8List? userType;
}

String _fourCC(Uint8List data, int offset) => latin1.decode(Uint8List.sublistView(data, offset, offset + 4));

// A 64 bit size, capped far beyond any real file so that it stays a positive int
int _uint64(ByteData bytes, int offset) =>
    math.min(bytes.getUint32(offset), 0x3fffffff) * 0x100000000 + bytes.getUint32(offset + 4);

/// The boxes of [data] from [start] to [end]. A box running past [end], in a truncated file, ends there and ends the
/// list; a damaged header ends it too.
Iterable<_Box> _boxes(Uint8List data, int start, int end) sync* {
  final bytes = ByteData.sublistView(data);
  final limit = math.min(end, data.length);
  var offset = start;
  for (var count = 0; count < _maxChildBoxes && offset + 8 <= limit; count++) {
    var size = bytes.getUint32(offset);
    final type = _fourCC(data, offset + 4);
    var headerLength = 8;
    if (size == 1) {
      if (offset + 16 > limit) {
        return;
      }
      size = _uint64(bytes, offset + 8);
      headerLength = 16;
    } else if (size == 0) {
      // Runs to the end of its parent
      size = limit - offset;
    }
    Uint8List? userType;
    if (type == 'uuid') {
      if (offset + headerLength + 16 > limit) {
        return;
      }
      userType = Uint8List.sublistView(data, offset + headerLength, offset + headerLength + 16);
      headerLength += 16;
    }
    if (size < headerLength) {
      return;
    }
    final truncated = size > limit - offset;
    yield _Box(type, offset + headerLength, truncated ? limit : offset + size, userType: userType);
    if (truncated) {
      return;
    }
    offset += size;
  }
}

_Box? _child(Uint8List data, _Box? parent, String type) {
  if (parent == null) {
    return null;
  }
  for (final box in _boxes(data, parent.start, parent.end)) {
    if (box.type == type) {
      return box;
    }
  }
  return null;
}

SphericalProbe _parseMoov(Uint8List moov) {
  for (final box in _boxes(moov, 0, moov.length)) {
    if (box.type == 'trak') {
      final probe = _parseTrack(moov, box);
      if (probe != null) {
        return probe;
      }
    }
  }
  return const SphericalProbe();
}

/// The metadata of a video track, null for another track
SphericalProbe? _parseTrack(Uint8List data, _Box track) {
  SphericalProbe? v1;
  _Box? mdia;
  _Box? sampleEntry;
  for (final box in _boxes(data, track.start, track.end)) {
    if (box.type == 'uuid' && _isSphericalV1(box.userType)) {
      v1 = _parseSphericalV1(data, box);
    } else if (box.type == 'mdia' && sampleEntry == null) {
      sampleEntry = _visualSampleEntry(data, box);
      mdia = box;
    }
  }
  if (sampleEntry == null) {
    return v1;
  }

  StereoLayout? stereo;
  bool? halfSphere;
  var hasSv3d = false;
  String? codecs;
  String? dolbyVisionCodecs;
  final childrenStart = sampleEntry.start + _visualSampleEntryLength;
  if (childrenStart <= sampleEntry.end) {
    for (final box in _boxes(data, childrenStart, sampleEntry.end)) {
      switch (box.type) {
        case 'st3d':
          stereo ??= _stereoMode(data, box);
        case 'sv3d':
          hasSv3d = true;
          halfSphere = _isHalfSphere(data, box);
        case 'avcC' || 'hvcC' || 'av1C':
          codecs ??= _codecsString(data, sampleEntry.type, box);
        // Dolby Vision profiles up to 7 in dvcC, 8 to 10 in dvvC. An hvc1 entry may carry one too (an iPhone HDR
        // video): that track names HEVC, which every player decodes it as.
        case 'dvcC' || 'dvvC' when _dolbyVisionHevcBase.containsKey(sampleEntry.type):
          dolbyVisionCodecs ??= _dolbyVisionCodecsString(data, sampleEntry.type, box);
      }
    }
  }
  final (codedWidth, codedHeight) = _codedSize(data, sampleEntry);
  return SphericalProbe(
    stereo: stereo ?? v1?.stereo,
    halfSphere: halfSphere ?? v1?.halfSphere,
    hasSphericalMetadata: hasSv3d || (v1?.hasSphericalMetadata ?? false),
    codec: sampleEntry.type,
    codecs: dolbyVisionCodecs ?? codecs,
    codedWidth: codedWidth,
    codedHeight: codedHeight,
    frameRate: mdia == null ? null : _frameRate(data, mdia),
  );
}

// The width and the height of a visual sample entry, null when the entry is cut short or says 0
(int?, int?) _codedSize(Uint8List data, _Box sampleEntry) {
  final offset = sampleEntry.start + _visualSampleEntryWidthOffset;
  if (offset + 4 > sampleEntry.end) {
    return (null, null);
  }
  final bytes = ByteData.sublistView(data);
  final width = bytes.getUint16(offset);
  final height = bytes.getUint16(offset + 2);
  return (width == 0 ? null : width, height == 0 ? null : height);
}

// The RFC 6381 codecs string of a sample entry of type [codec] from its decoder configuration [config] (avcC, hvcC or
// av1C), in the forms the native decoder checks read: the profile and the level, the tier and the bit depth for AV1,
// without the optional fields. The hvcC of a Dolby Vision entry gives the string of its HEVC base layer. Null when the
// configuration does not belong to the sample entry, or is cut short or of an unknown version.
String? _codecsString(Uint8List data, String codec, _Box config) {
  final length = config.end - config.start;
  final at = config.start;
  final hevc = _dolbyVisionHevcBase[codec] ?? codec;
  switch (config.type) {
    // AVCDecoderConfigurationRecord: version 1, then the profile, the compatibility flags and the level
    case 'avcC' when (codec == 'avc1' || codec == 'avc3') && length >= 4 && data[at] == 1:
      String hex(int value) => value.toRadixString(16).padLeft(2, '0').toUpperCase();
      return '$codec.${hex(data[at + 1])}${hex(data[at + 2])}${hex(data[at + 3])}';
    // HEVCDecoderConfigurationRecord: version 1, then the profile space, the tier and the profile in a byte, the 32
    // compatibility flags, 6 bytes of constraint flags and the level. The flags are written in reverse bit order.
    case 'hvcC' when (hevc == 'hvc1' || hevc == 'hev1') && length >= 13 && data[at] == 1:
      final profileByte = data[at + 1];
      final space = const ['', 'A', 'B', 'C'][profileByte >> 6];
      final tier = (profileByte & 0x20) == 0 ? 'L' : 'H';
      final profile = profileByte & 0x1f;
      final flags = ByteData.sublistView(data).getUint32(at + 2);
      var reversed = 0;
      for (var bit = 0; bit < 32; bit++) {
        reversed = (reversed << 1) | ((flags >> bit) & 1);
      }
      return '$hevc.$space$profile.${reversed.toRadixString(16).toUpperCase()}.$tier${data[at + 12]}';
    // AV1CodecConfigurationRecord: the marker bit and version 1, then the profile on 3 bits and the level on 5, then
    // the tier, the high bit depth and the twelve bit flags. Media3 reads no profile from a string without all four.
    case 'av1C' when codec == 'av01' && length >= 3 && data[at] == 0x81:
      final profile = data[at + 1] >> 5;
      final level = data[at + 1] & 0x1f;
      final flags = data[at + 2];
      final tier = (flags & 0x80) == 0 ? 'M' : 'H';
      final bitDepth = (flags & 0x40) == 0 ? 8 : ((flags & 0x20) == 0 ? 10 : 12);
      return '$codec.$profile.${_twoDigits(level)}$tier.${_twoDigits(bitDepth)}';
  }
  return null;
}

// The RFC 6381 codecs string of a Dolby Vision sample entry of type [codec] from its DOVIDecoderConfigurationRecord
// [config] (dvcC or dvvC): the version on two bytes, then the profile on 7 bits and the level on 6, written on two
// digits each as Media3 reads them ("dvh1.08.06"). Null when cut short or without a level, the HEVC base layer then
// standing for the track.
String? _dolbyVisionCodecsString(Uint8List data, String codec, _Box config) {
  final at = config.start;
  if (config.end - at < 4) {
    return null;
  }
  final profile = data[at + 2] >> 1;
  final level = (data[at + 2] & 0x01) << 5 | data[at + 3] >> 3;
  if (level == 0) {
    return null;
  }
  return '$codec.${_twoDigits(profile)}.${_twoDigits(level)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

// The mean frame rate of a track: its samples over their total duration, in the time scale of its mdhd box. Reads the
// time to sample table (stts) as far as it is in the bytes read, which the head of a long moov box may cut.
double? _frameRate(Uint8List data, _Box mdia) {
  final mdhd = _child(data, mdia, 'mdhd');
  final stts = _child(data, _child(data, _child(data, mdia, 'minf'), 'stbl'), 'stts');
  if (mdhd == null || stts == null || mdhd.start + 4 > mdhd.end) {
    return null;
  }
  final bytes = ByteData.sublistView(data);
  // Version and flags, then the creation and modification times, on 32 bits in version 0 and 64 in version 1
  final timescaleOffset = mdhd.start + (data[mdhd.start] == 1 ? 20 : 12);
  if (timescaleOffset + 4 > mdhd.end) {
    return null;
  }
  final timescale = bytes.getUint32(timescaleOffset);
  // Version and flags, the entry count, then a sample count and a sample duration per entry
  if (stts.start + 8 > stts.end) {
    return null;
  }
  final entries = bytes.getUint32(stts.start + 4);
  var samples = 0;
  var duration = 0;
  for (var index = 0, offset = stts.start + 8; index < entries && offset + 8 <= stts.end; index++, offset += 8) {
    final count = bytes.getUint32(offset);
    samples += count;
    duration += count * bytes.getUint32(offset + 4);
  }
  if (timescale == 0 || samples == 0 || duration == 0) {
    return null;
  }
  return timescale * samples / duration;
}

// moov/trak/mdia/minf/stbl/stsd/<visual sample entry>
_Box? _visualSampleEntry(Uint8List data, _Box mdia) {
  final stsd = _child(data, _child(data, _child(data, mdia, 'minf'), 'stbl'), 'stsd');
  if (stsd == null) {
    return null;
  }
  // Version and flags, then the entry count
  for (final entry in _boxes(data, stsd.start + 8, stsd.end)) {
    if (_visualSampleEntries.contains(entry.type)) {
      return entry;
    }
  }
  return null;
}

// Version and flags, then stereo_mode: 0 mono, 1 top and bottom, 2 left and right. Other modes are not layouts the
// viewers know.
StereoLayout? _stereoMode(Uint8List data, _Box st3d) {
  if (st3d.start + 5 > st3d.end) {
    return null;
  }
  return switch (data[st3d.start + 4]) {
    0 => StereoLayout.mono,
    1 => StereoLayout.topBottom,
    2 => StereoLayout.leftRight,
    _ => null,
  };
}

// sv3d/proj: an equirectangular projection (equi) cropped to about half the width, or a mesh (mshp, which VR180
// cameras write), is a half sphere; a cube map or a full equirectangular projection is not. Null when the box does
// not say, truncated for example.
bool? _isHalfSphere(Uint8List data, _Box sv3d) {
  final proj = _child(data, sv3d, 'proj');
  if (proj == null) {
    return null;
  }
  for (final box in _boxes(data, proj.start, proj.end)) {
    switch (box.type) {
      case 'mshp':
        return true;
      case 'cbmp':
        return false;
      case 'equi':
        // Version and flags, then the bounds cropped from the top, bottom, left and right edges, in 0.32 fixed point
        if (box.start + 20 > box.end) {
          return null;
        }
        final bytes = ByteData.sublistView(data);
        final left = bytes.getUint32(box.start + 12) / 0x100000000;
        final right = bytes.getUint32(box.start + 16) / 0x100000000;
        final cropped = left + right;
        return cropped >= 0.4 && cropped <= 0.6;
    }
  }
  return null;
}

bool _isSphericalV1(Uint8List? userType) {
  if (userType == null || userType.length != _sphericalV1Uuid.length) {
    return false;
  }
  for (var i = 0; i < _sphericalV1Uuid.length; i++) {
    if (userType[i] != _sphericalV1Uuid[i]) {
      return false;
    }
  }
  return true;
}

// The XML of Spherical Video V1: GSpherical:Spherical, StereoMode, and a crop in the same pixel tags as GPano
SphericalProbe _parseSphericalV1(Uint8List data, _Box uuid) {
  final xml = utf8.decode(Uint8List.sublistView(data, uuid.start, uuid.end), allowMalformed: true);
  String? tag(String name) => RegExp('<GSpherical:$name>\\s*([^<]*?)\\s*</GSpherical:$name>').firstMatch(xml)?.group(1);
  double? number(String name) => double.tryParse(tag(name) ?? '');

  final isSpherical = tag('Spherical')?.toLowerCase() == 'true';
  final stereo = switch (tag('StereoMode')?.toLowerCase()) {
    'mono' => StereoLayout.mono,
    'top-bottom' => StereoLayout.topBottom,
    'left-right' => StereoLayout.leftRight,
    _ => null,
  };
  final croppedWidth = number('CroppedAreaImageWidthPixels');
  final fullWidth = number('FullPanoWidthPixels');
  final bool? halfSphere;
  if (croppedWidth != null && fullWidth != null && fullWidth > 0) {
    final covered = croppedWidth / fullWidth;
    halfSphere = covered >= 0.4 && covered <= 0.6;
  } else {
    halfSphere = isSpherical ? false : null;
  }
  return SphericalProbe(stereo: stereo, halfSphere: halfSphere, hasSphericalMetadata: isSpherical);
}
