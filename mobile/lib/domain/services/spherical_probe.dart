// Spherical metadata of MP4 and MOV videos, as cameras and the Spatial Media tools write it: the st3d box tells the
// stereo layout, the sv3d box the projection (Spherical Video V2, https://github.com/google/spatial-media). VR180
// cameras write a mesh projection, or an equirectangular one cropped to the front half of the sphere. Older files
// carry the same in a uuid box of XML (Spherical Video V1).
//
// The same read gives what a decoder needs to know of the video track (its codec, profile and level, bit depth, frame
// size and frame rate), which the server does not tell: the players check it against the decoders of the device before
// they pick the original or the transcoded stream. It lists every track of the file too, by handler, track ID and
// codec: raw 360° videos hold one lens per video track (Insta360 X4 and later, DJI Osmo 360) or six cube faces in two
// tracks (GoPro .360), and the players pick their tracks by what the probe lists.
//
// It tells the Apple spatial videos too (MV-HEVC: a second layer for the other eye, see [MultiviewInfo]), which every
// player of the app shows in 2D, from their base layer.
//
// Pure Dart: the caller reads the bytes, from a file on the device or with HTTP range requests.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:immich_mobile/domain/models/stereo_layout.dart';

/// Reads up to [length] bytes of a file from [offset]: fewer at the end of the file, none past it.
typedef ByteRangeReader = Future<Uint8List> Function(int offset, int length);

/// The transfer function of a video: standard dynamic range, or one of the two HDR ones (hybrid log-gamma, which the
/// 360° cameras record, and PQ of HDR10 and Dolby Vision)
enum VideoDynamicRange { sdr, hlg, pq }

/// What an Apple spatial video declares about its two eyes: an MV-HEVC track (hvcC for the base layer, lhvC for the
/// second one) whose vexu box says both eyes are there ("ISO Base Media File Format and Apple HEVC Stereo Video Format
/// additions" v1.0). A plain HEVC decoder plays the base layer, one eye.
class MultiviewInfo {
  const MultiviewInfo({
    required this.heroEye,
    this.baselineMicrometres,
    this.disparityAdjustment,
    this.horizontalFovDegrees,
    this.eyesReversed = false,
  });

  /// The eye the file prefers to show in 2D (hero): 0 none said, 1 left, 2 right
  final int heroEye;

  /// Distance between the two cameras (cams/blin), in micrometres
  final int? baselineMicrometres;

  /// How far apart the eyes are shown (cmfy/dadj), in [-10000, 10000] of the width of an eye, half to each eye
  final int? disparityAdjustment;

  /// Horizontal field of view of the camera (hfov), in degrees
  final double? horizontalFovDegrees;

  /// Whether the layers hold the eyes the other way round (stri)
  final bool eyesReversed;

  @override
  bool operator ==(Object other) =>
      other is MultiviewInfo &&
      other.heroEye == heroEye &&
      other.baselineMicrometres == baselineMicrometres &&
      other.disparityAdjustment == disparityAdjustment &&
      other.horizontalFovDegrees == horizontalFovDegrees &&
      other.eyesReversed == eyesReversed;

  @override
  int get hashCode =>
      Object.hash(heroEye, baselineMicrometres, disparityAdjustment, horizontalFovDegrees, eyesReversed);

  @override
  String toString() =>
      'MultiviewInfo(hero: $heroEye, baseline: $baselineMicrometres µm, disparity: $disparityAdjustment, '
      'fov: $horizontalFovDegrees, reversed: $eyesReversed)';
}

/// A track of the moov box, in moov order
class ProbedTrack {
  const ProbedTrack({
    required this.index,
    this.trackId,
    this.handlerType,
    this.handlerName,
    this.codec,
    this.codecs,
    this.codedWidth,
    this.codedHeight,
    this.frameRate,
    this.durationMs,
    this.bitDepth,
  });

  /// Position among the trak boxes of the moov box, from 0
  final int index;

  /// The track_ID of its tkhd box, which Media3 gives as Format.id and AVFoundation as AVAssetTrack.trackID; null when
  /// missing or 0 (not a valid ID)
  final int? trackId;

  /// The handler_type of its hdlr box ("vide", "soun", "meta", "tmcd", ...), null when the box is missing or says 0
  final String? handlerType;

  /// The name of its hdlr box, "VideoHandler", "GoPro H.265", "CAM meta": for the logs
  final String? handlerName;

  /// Four character code of its first sample entry ("hvc1", "avc1", "mp4a", "djmd", ...); the first visual one when
  /// the sample description has several
  final String? codec;

  /// The codec with its profile and level as RFC 6381 writes it, see [SphericalProbe.codecs]; video tracks only
  final String? codecs;

  /// Size of the coded frames the visual sample entry declares; video tracks only
  final int? codedWidth;
  final int? codedHeight;

  /// Mean frame rate, from the time to sample table; video tracks only
  final double? frameRate;

  /// Duration of the media, from its media header
  final int? durationMs;

  /// Bits per luma sample, see [SphericalProbe.bitDepth]; video tracks only
  final int? bitDepth;

  /// Whether the players take the track for a video: Media3 and AVFoundation decide by the handler type ("vide"); a
  /// track without a usable one (a damaged hdlr box) is a video when its sample entry is a visual one
  bool get isVideo => handlerType == 'vide' || (handlerType == null && _visualSampleEntries.contains(codec));

  @override
  bool operator ==(Object other) =>
      other is ProbedTrack &&
      other.index == index &&
      other.trackId == trackId &&
      other.handlerType == handlerType &&
      other.handlerName == handlerName &&
      other.codec == codec &&
      other.codecs == codecs &&
      other.codedWidth == codedWidth &&
      other.codedHeight == codedHeight &&
      other.frameRate == frameRate &&
      other.durationMs == durationMs &&
      other.bitDepth == bitDepth;

  @override
  int get hashCode => Object.hash(
    index,
    trackId,
    handlerType,
    handlerName,
    codec,
    codecs,
    codedWidth,
    codedHeight,
    frameRate,
    durationMs,
    bitDepth,
  );

  @override
  String toString() =>
      'ProbedTrack($index, trackId: $trackId, handler: $handlerType${handlerName == null ? '' : ' "$handlerName"'}, '
      'codec: $codec, codecs: $codecs, '
      'size: $codedWidth x $codedHeight, frameRate: $frameRate, durationMs: $durationMs, bitDepth: $bitDepth)';
}

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
    this.bitDepth,
    this.colourPrimaries,
    this.transferCharacteristics,
    this.dolbyVision = false,
    this.videoBitRate,
    this.declaredBitRate,
    this.mediaBitRate,
    this.tracks = const [],
    this.multiview,
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

  /// Bits per luma sample of the first video track: from its HEVC (hvcC), AV1 (av1C) or VP9 (vpcC) configuration, or
  /// its H.264 one (avcC, its high profile extension, else its profile); null when unknown
  final int? bitDepth;

  /// Colour description of the first video track, as ITU-T H.273 codes, from its colr box (nclx or nclc) or a VP9
  /// vpcC: primaries (1 BT.709, 9 BT.2020, 12 Display P3), transfer (1 BT.709, 16 PQ, 18 HLG). Null without one.
  final int? colourPrimaries;
  final int? transferCharacteristics;

  /// Whether the first video track carries a Dolby Vision configuration (dvcC or dvvC), in an HEVC sample entry too
  final bool dolbyVision;

  /// Bits per second of all the video tracks: the sizes of their samples (stsz) over their durations (stts and mdhd);
  /// null when a size table is missing or cut short in the bytes read
  final int? videoBitRate;

  /// Average bit rate the sample entry of the first video track declares (btrt), null without one or when it says 0
  final int? declaredBitRate;

  /// Bits per second of the media data (mdat boxes) over the duration of the movie (mvhd): audio and metadata tracks
  /// included; null when unknown
  final int? mediaBitRate;

  /// Every track of the moov box, in moov order (up to 16): the fields above describe the first video track only
  final List<ProbedTrack> tracks;

  /// The two eyes of an Apple spatial video (MV-HEVC), null for any other video: set when the first video track has a
  /// second layer (lhvC) and its vexu box says both eyes are there, the rule of Media3 1.10
  final MultiviewInfo? multiview;

  /// The tracks the players take for videos, in moov order
  List<ProbedTrack> get videoTracks => [
    for (final track in tracks)
      if (track.isVideo) track,
  ];

  /// The transfer of the video, null when the file does not say
  VideoDynamicRange? get dynamicRange => switch (transferCharacteristics) {
    16 => VideoDynamicRange.pq,
    18 => VideoDynamicRange.hlg,
    1 || 6 || 13 || 14 || 15 => VideoDynamicRange.sdr,
    _ => null,
  };

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
      other.frameRate == frameRate &&
      other.bitDepth == bitDepth &&
      other.colourPrimaries == colourPrimaries &&
      other.transferCharacteristics == transferCharacteristics &&
      other.dolbyVision == dolbyVision &&
      other.videoBitRate == videoBitRate &&
      other.declaredBitRate == declaredBitRate &&
      other.mediaBitRate == mediaBitRate &&
      _sameTracks(other.tracks, tracks) &&
      other.multiview == multiview;

  @override
  int get hashCode => Object.hash(
    stereo,
    halfSphere,
    hasSphericalMetadata,
    codec,
    codecs,
    codedWidth,
    codedHeight,
    frameRate,
    bitDepth,
    colourPrimaries,
    transferCharacteristics,
    dolbyVision,
    videoBitRate,
    declaredBitRate,
    mediaBitRate,
    Object.hashAll(tracks),
    multiview,
  );

  @override
  String toString() =>
      'SphericalProbe(stereo: $stereo, halfSphere: $halfSphere, hasSphericalMetadata: $hasSphericalMetadata, '
      'codec: $codec, codecs: $codecs, codedWidth: $codedWidth, codedHeight: $codedHeight, frameRate: $frameRate, '
      'bitDepth: $bitDepth, colourPrimaries: $colourPrimaries, transferCharacteristics: $transferCharacteristics, '
      'dolbyVision: $dolbyVision, videoBitRate: $videoBitRate, declaredBitRate: $declaredBitRate, '
      'mediaBitRate: $mediaBitRate, tracks: $tracks, multiview: $multiview)';
}

bool _sameTracks(List<ProbedTrack> a, List<ProbedTrack> b) {
  if (identical(a, b)) {
    return true;
  }
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

// Bytes read at once while looking for the moov box: the head of a file usually holds it whole, when it was written
// for streaming
const _chunkLength = 64 * 1024;

/// Most bytes of the moov box the probe reads. The first video track comes first in it, and its sample description
/// before its large tables, so the head of a longer moov box is enough.
const sphericalProbeMaxMoovLength = 4 * 1024 * 1024;

// Bounds on the boxes walked, so that a damaged file cannot make the probe loop
const _maxTopLevelBoxes = 64;
const _maxChildBoxes = 1024;
const _maxTracks = 16;

// Top level boxes looked at after a moov box at the head of a file, for the media data that follows it
const _maxBoxesAfterMoov = 4;

// Most bytes read of a trak box past the head of the moov box: its sample description, its media header and its
// handler come before its tables, and the tables of a long recording run to megabytes
const _maxTrakReadLength = 256 * 1024;

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
/// at most [maxMoovLength] bytes of the moov box, and the trak boxes that start past them with one more read of at most
/// 256 KiB each. A file that is not an MP4, or that is truncated or damaged, gives what could be read, and nothing
/// declared when it is nothing at all. Errors of [read] are not caught.
Future<SphericalProbe> probeSphericalMetadata(ByteRangeReader read, {int maxMoovLength = sphericalProbeMaxMoovLength}) {
  return _TopLevelWalk(read).probe(maxMoovLength);
}

/// A top level box of a file: its type, where it starts, its size (null for a box that runs to the end of the file)
/// and the length of its header (8, or 16 with a 64 bit size)
typedef TopLevelBox = ({String type, int offset, int? size, int headerLength});

/// The top level boxes of the MP4 file that [read] reads, from its start, at most [maxBoxes]: the first 64 KiB in one
/// read, then a header read each. Stops at a box that runs to the end of the file, at a damaged header, and at bytes
/// that are no box: a type that is not printable ASCII, such as the bare trailer an Insta360 X3 appends after its moov
/// box. Errors of [read] are not caught.
Future<List<TopLevelBox>> listTopLevelBoxes(ByteRangeReader read, {int maxBoxes = 64}) =>
    _TopLevelWalk(read).list(maxBoxes);

// The header of a box: its size as written (0 runs to the end of its parent), its type and the length of the header
typedef _Header = ({int size, String type, int headerLength});

// The header of the box whose first bytes are [header], null when they are too few
_Header? _header(Uint8List header) {
  if (header.length < 8) {
    return null;
  }
  final bytes = ByteData.sublistView(header);
  final size = bytes.getUint32(0);
  final type = _fourCC(header, 4);
  if (size != 1) {
    return (size: size, type: type, headerLength: 8);
  }
  if (header.length < 16) {
    return null;
  }
  return (size: _uint64(bytes, 8), type: type, headerLength: 16);
}

bool _isPrintableType(Uint8List header) {
  for (var i = 4; i < 8; i++) {
    if (header[i] < 0x20 || header[i] > 0x7e) {
      return false;
    }
  }
  return true;
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
    _MoovContent? moov;
    // Payload bytes of the mdat boxes walked; null once one runs to the end of the file, its length unknown
    int? mediaBytes = 0;
    var mediaSeen = false;
    var boxesAfterMoov = 0;
    for (var count = 0; count < _maxTopLevelBoxes; count++) {
      final header = _header(await _bytesAt(offset, 16, readLength: moov == null ? _chunkLength : 16));
      if (header == null) {
        break;
      }
      final (:size, :type, :headerLength) = header;
      if (moov != null) {
        boxesAfterMoov++;
      }
      if (type == 'mdat') {
        mediaSeen = true;
        mediaBytes = size == 0 || mediaBytes == null || size < headerLength ? null : mediaBytes + size - headerLength;
        // The media data of a file written for streaming follows its moov box
        if (moov != null) {
          break;
        }
      } else if (type == 'moov' && moov == null) {
        if (size != 0 && size < headerLength) {
          break;
        }
        moov = await _readMoov(offset, size, headerLength, maxMoovLength);
        // A camera writes the moov box after the media data: nothing more to look for
        if (mediaSeen) {
          break;
        }
      }
      if (boxesAfterMoov >= _maxBoxesAfterMoov) {
        break;
      }
      // A box running to the end of the file has nothing after it, and a damaged size nothing to trust
      if (size == 0 || size < headerLength) {
        break;
      }
      offset += size;
    }
    if (moov == null) {
      return const SphericalProbe();
    }
    final (timescale, duration) = (moov.movieTimescale, moov.movieDuration);
    final mediaBitRate =
        mediaBytes != null && mediaBytes > 0 && timescale != null && duration != null && timescale > 0 && duration > 0
        ? (mediaBytes * 8 * timescale / duration).round()
        : null;
    return moov.probe(mediaBitRate: mediaBitRate);
  }

  // The moov box whose header of [headerLength] bytes is at [offset]: the head of its content, then its trak boxes
  Future<_MoovContent> _readMoov(int offset, int size, int headerLength, int maxMoovLength) async {
    // A size of 0 runs to the end of the file
    final contentLength = size == 0 ? maxMoovLength : math.min(size - headerLength, maxMoovLength);
    final head = await _bytesAt(offset + headerLength, contentLength);
    final reachesEnd = head.length < contentLength;
    final moovLength = size != 0 ? size - headerLength : (reachesEnd ? head.length : null);
    return _MoovWalk(_read, offset + headerLength, head, moovLength: moovLength, headReachesEnd: reachesEnd).walk();
  }

  Future<List<TopLevelBox>> list(int maxBoxes) async {
    final boxes = <TopLevelBox>[];
    var offset = 0;
    while (boxes.length < maxBoxes) {
      final bytes = await _bytesAt(offset, 16, readLength: boxes.isEmpty ? _chunkLength : 16);
      final header = _header(bytes);
      if (header == null || !_isPrintableType(bytes)) {
        break;
      }
      final (:size, :type, :headerLength) = header;
      if (size != 0 && size < headerLength) {
        break;
      }
      boxes.add((type: type, offset: offset, size: size == 0 ? null : size, headerLength: headerLength));
      if (size == 0) {
        break;
      }
      offset += size;
    }
    return boxes;
  }
}

/// What the moov box holds: its tracks as parsed, and the duration of the movie
class _MoovContent {
  const _MoovContent(this.tracks, {this.movieTimescale, this.movieDuration});

  final List<_ParsedTrack> tracks;
  final int? movieTimescale;
  final int? movieDuration;

  SphericalProbe probe({int? mediaBitRate}) {
    // The first track that is a video, or that carries the uuid box of Spherical Video V1, describes the file
    SphericalProbe? first;
    var videoBitRate = 0.0;
    var videoBitRateKnown = true;
    var videoSeen = false;
    for (final track in tracks) {
      first ??= track.probe;
      if (track.isVisual) {
        videoSeen = true;
        final rate = track.bitRate;
        if (rate == null) {
          videoBitRateKnown = false;
        } else {
          videoBitRate += rate;
        }
      }
    }
    final head = first ?? const SphericalProbe();
    return SphericalProbe(
      stereo: head.stereo,
      halfSphere: head.halfSphere,
      hasSphericalMetadata: head.hasSphericalMetadata,
      codec: head.codec,
      codecs: head.codecs,
      codedWidth: head.codedWidth,
      codedHeight: head.codedHeight,
      frameRate: head.frameRate,
      bitDepth: head.bitDepth,
      colourPrimaries: head.colourPrimaries,
      transferCharacteristics: head.transferCharacteristics,
      dolbyVision: head.dolbyVision,
      videoBitRate: videoSeen && videoBitRateKnown ? videoBitRate.round() : null,
      declaredBitRate: head.declaredBitRate,
      mediaBitRate: mediaBitRate,
      tracks: [for (final track in tracks) track.track],
      multiview: head.multiview,
    );
  }
}

/// The children of a moov box from [_head], the first bytes of its content, then by reads past them: a header each, and
/// a trak box at most 256 KiB long. An Insta360 X5 writes a moov box of 4 to 5 MB at the end of its recordings, the
/// second video track after the sample tables of the first: one more read reaches it.
class _MoovWalk {
  _MoovWalk(this._read, this._contentStart, this._head, {required this.moovLength, required this.headReachesEnd});

  final ByteRangeReader _read;
  final int _contentStart;
  final Uint8List _head;

  /// Length of the content of the moov box, null when unknown (a moov box of size 0, longer than its head)
  final int? moovLength;

  /// Whether the file ends within [_head]: nothing to read past it
  final bool headReachesEnd;

  // Last bytes read past the head, from _windowOffset in the content, and whether they reach the end of the file
  Uint8List _window = Uint8List(0);
  int _windowOffset = 0;
  bool _windowReachesEnd = false;

  // At most [length] bytes of the content at [offset], fewer at its end or the end of the file
  Future<Uint8List> _bytes(int offset, int length) async {
    final end = moovLength;
    final wanted = end == null ? length : math.min(length, end - offset);
    if (wanted <= 0) {
      return Uint8List(0);
    }
    if (offset + wanted <= _head.length || headReachesEnd) {
      final start = math.min(offset, _head.length);
      return Uint8List.sublistView(_head, start, math.min(offset + wanted, _head.length));
    }
    final local = offset - _windowOffset;
    if (local >= 0 && local <= _window.length && (local + wanted <= _window.length || _windowReachesEnd)) {
      return Uint8List.sublistView(_window, local, math.min(local + wanted, _window.length));
    }
    // Past the head: read on, as far as a trak box needs, within the moov box
    final readLength = math.max(wanted, end == null ? _maxTrakReadLength : math.min(_maxTrakReadLength, end - offset));
    final bytes = await _read(_contentStart + offset, readLength);
    _window = bytes.length > readLength ? Uint8List.sublistView(bytes, 0, readLength) : bytes;
    _windowOffset = offset;
    _windowReachesEnd = _window.length < readLength;
    return Uint8List.sublistView(_window, 0, math.min(wanted, _window.length));
  }

  Future<_MoovContent> walk() async {
    final tracks = <_ParsedTrack>[];
    int? movieTimescale;
    int? movieDuration;
    var offset = 0;
    for (var count = 0; count < _maxChildBoxes && tracks.length < _maxTracks; count++) {
      final bytes = await _bytes(offset, 16);
      final header = _header(bytes);
      if (header == null) {
        break;
      }
      var (:size, :type, :headerLength) = header;
      if (size == 0) {
        // Runs to the end of the moov box
        size = (moovLength ?? _head.length) - offset;
      }
      if (size < headerLength) {
        break;
      }
      switch (type) {
        case 'trak':
          final trak = await _boxBytes(offset, size, _maxTrakReadLength);
          tracks.add(_parseTrack(trak, _Box('trak', headerLength, trak.length), tracks.length));
        case 'mvhd' when movieTimescale == null:
          final mvhd = await _boxBytes(offset, size, 64);
          (movieTimescale, movieDuration) = _timescaleAndDuration(mvhd, _Box('mvhd', headerLength, mvhd.length));
      }
      offset += size;
    }
    return _MoovContent(tracks, movieTimescale: movieTimescale, movieDuration: movieDuration);
  }

  // The box of [size] bytes at [offset]: whole when the head holds it, else as much of it as the head holds when that
  // is at least [maxLength], else read up to [maxLength] bytes. A cut box parses as far as its boxes are whole.
  Future<Uint8List> _boxBytes(int offset, int size, int maxLength) {
    final wanted = math.min(size, maxLength);
    if (offset + size <= _head.length || offset + wanted <= _head.length || headReachesEnd) {
      final start = math.min(offset, _head.length);
      return Future.value(Uint8List.sublistView(_head, start, math.min(offset + size, _head.length)));
    }
    return _bytes(offset, wanted);
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

/// A track as parsed: what the probe lists of it, the metadata of the file it gives when it is a video (or carries the
/// uuid box of Spherical Video V1), and the bit rate of its samples
class _ParsedTrack {
  const _ParsedTrack(this.track, {this.probe, this.isVisual = false, this.bitRate});

  final ProbedTrack track;

  /// The fields of the file this track gives, null for a track that is no video and has no Spherical Video V1 box
  final SphericalProbe? probe;

  /// Whether the track has a visual sample entry
  final bool isVisual;

  /// Bits per second of its samples, null when unknown
  final double? bitRate;
}

/// The track [track] of [data], the [index]-th trak box of the moov box
_ParsedTrack _parseTrack(Uint8List data, _Box track, int index) {
  SphericalProbe? v1;
  _Box? mdia;
  int? trackId;
  for (final box in _boxes(data, track.start, track.end)) {
    if (box.type == 'tkhd') {
      trackId ??= _trackId(data, box);
    } else if (box.type == 'uuid' && _isSphericalV1(box.userType)) {
      v1 = _parseSphericalV1(data, box);
    } else if (box.type == 'mdia') {
      mdia ??= box;
    }
  }
  final handler = _child(data, mdia, 'hdlr');
  final (handlerType, handlerName) = handler == null ? (null, null) : _handler(data, handler);
  final stbl = _child(data, _child(data, mdia, 'minf'), 'stbl');
  final (firstEntry, visualEntry) = _sampleEntries(data, _child(data, stbl, 'stsd'));
  final durationMs = _durationMs(data, mdia);

  if (visualEntry == null) {
    return _ParsedTrack(
      ProbedTrack(
        index: index,
        trackId: trackId,
        handlerType: handlerType,
        handlerName: handlerName,
        codec: firstEntry?.type,
        durationMs: durationMs,
      ),
      probe: v1,
    );
  }

  final entry = _parseVisualSampleEntry(data, visualEntry);
  final (codedWidth, codedHeight) = _codedSize(data, visualEntry);
  final timing = mdia == null ? null : _timing(data, mdia);
  final frameRate = timing == null ? null : timing.timescale * timing.samples / timing.duration;
  return _ParsedTrack(
    ProbedTrack(
      index: index,
      trackId: trackId,
      handlerType: handlerType,
      handlerName: handlerName,
      codec: visualEntry.type,
      codecs: entry.codecs,
      codedWidth: codedWidth,
      codedHeight: codedHeight,
      frameRate: frameRate,
      durationMs: durationMs,
      bitDepth: entry.bitDepth,
    ),
    probe: SphericalProbe(
      stereo: entry.stereo ?? v1?.stereo,
      halfSphere: entry.halfSphere ?? v1?.halfSphere,
      hasSphericalMetadata: entry.hasSv3d || (v1?.hasSphericalMetadata ?? false),
      codec: visualEntry.type,
      codecs: entry.codecs,
      codedWidth: codedWidth,
      codedHeight: codedHeight,
      frameRate: frameRate,
      bitDepth: entry.bitDepth,
      colourPrimaries: entry.colourPrimaries,
      transferCharacteristics: entry.transferCharacteristics,
      dolbyVision: entry.dolbyVision,
      declaredBitRate: entry.declaredBitRate,
      multiview: entry.multiview,
    ),
    isVisual: true,
    bitRate: timing == null ? null : _sampleBitRate(data, stbl, timing),
  );
}

// tkhd: version and flags, then the creation and modification times, on 32 bits in version 0 and 64 in version 1, then
// the track_ID. 0 is no valid ID.
int? _trackId(Uint8List data, _Box tkhd) {
  if (tkhd.start + 4 > tkhd.end) {
    return null;
  }
  final offset = tkhd.start + (data[tkhd.start] == 1 ? 20 : 12);
  if (offset + 4 > tkhd.end) {
    return null;
  }
  final id = ByteData.sublistView(data).getUint32(offset);
  return id == 0 ? null : id;
}

// hdlr: version and flags, pre_defined, the handler type, 12 reserved bytes, then the name to the end of the box. MP4
// writes the name as a NUL terminated string ("VideoHandler"), QuickTime as a counted one, its length in its first
// byte, with or without a NUL after it ("\x0bGoPro H.265", "\rAmbarella AAC\0"). A type of zeros is unknown.
(String?, String?) _handler(Uint8List data, _Box hdlr) {
  String? type;
  if (hdlr.start + 12 <= hdlr.end) {
    final bytes = Uint8List.sublistView(data, hdlr.start + 8, hdlr.start + 12);
    if (bytes.any((byte) => byte != 0)) {
      type = latin1.decode(bytes);
    }
  }
  String? name;
  var start = hdlr.start + 24;
  var end = hdlr.end;
  if (start < end) {
    final counted = data[start];
    if (counted != 0 && counted < 0x20 && counted <= end - start - 1) {
      start++;
      end = start + counted;
    }
    for (var i = start; i < end; i++) {
      if (data[i] == 0) {
        end = i;
        break;
      }
    }
    final text = utf8.decode(Uint8List.sublistView(data, start, end), allowMalformed: true).trim();
    name = text.isEmpty ? null : text;
  }
  return (type, name);
}

// The first sample entry of a sample description (stsd: version and flags, then the entry count), and its first
// visual one, which the metadata and the decoders are about
(_Box?, _Box?) _sampleEntries(Uint8List data, _Box? stsd) {
  if (stsd == null) {
    return (null, null);
  }
  _Box? first;
  for (final entry in _boxes(data, stsd.start + 8, stsd.end)) {
    first ??= entry;
    if (_visualSampleEntries.contains(entry.type)) {
      return (first, entry);
    }
  }
  return (first, null);
}

/// What the child boxes of a visual sample entry say
typedef _VisualSampleEntry = ({
  StereoLayout? stereo,
  bool? halfSphere,
  bool hasSv3d,
  String? codecs,
  int? bitDepth,
  int? colourPrimaries,
  int? transferCharacteristics,
  bool dolbyVision,
  int? declaredBitRate,
  MultiviewInfo? multiview,
});

_VisualSampleEntry _parseVisualSampleEntry(Uint8List data, _Box sampleEntry) {
  StereoLayout? stereo;
  bool? halfSphere;
  var hasSv3d = false;
  String? codecs;
  String? dolbyVisionCodecs;
  int? bitDepth;
  (int, int)? colour;
  (int, int)? vp9Colour;
  var dolbyVision = false;
  int? declaredBitRate;
  var hasLayeredHevc = false;
  _Box? vexu;
  double? horizontalFov;
  final codec = sampleEntry.type;
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
          codecs ??= _codecsString(data, codec, box);
          bitDepth ??= _bitDepth(data, codec, box);
        case 'vpcC' when codec == 'vp09':
          final (depth, primaries, transfer) = _vpcC(data, box);
          bitDepth ??= depth;
          if (primaries != null && transfer != null) {
            vp9Colour ??= (primaries, transfer);
          }
        // Dolby Vision profiles up to 7 in dvcC, 8 to 10 in dvvC. An hvc1 entry may carry one too (an iPhone HDR
        // video): that track names HEVC, which every player decodes it as, and is still flagged Dolby Vision.
        case 'dvcC' || 'dvvC':
          dolbyVision = true;
          if (_dolbyVisionHevcBase.containsKey(codec)) {
            dolbyVisionCodecs ??= _dolbyVisionCodecsString(data, codec, box);
          }
        case 'colr':
          colour ??= _colour(data, box);
        case 'btrt':
          declaredBitRate ??= _averageBitRate(data, box);
        // The second layer of an MV-HEVC track, the other eye of an Apple spatial video
        case 'lhvC':
          hasLayeredHevc = true;
        case 'vexu':
          vexu ??= box;
        // Beside vexu: the field of view in thousandths of a degree
        case 'hfov' when box.start + 4 <= box.end:
          horizontalFov ??= ByteData.sublistView(data).getUint32(box.start) / 1000;
      }
    }
  }
  final (colourPrimaries, transferCharacteristics) = colour ?? vp9Colour ?? (null, null);
  return (
    stereo: stereo,
    halfSphere: halfSphere,
    hasSv3d: hasSv3d,
    codecs: dolbyVisionCodecs ?? codecs,
    bitDepth: bitDepth,
    colourPrimaries: colourPrimaries,
    transferCharacteristics: transferCharacteristics,
    dolbyVision: dolbyVision,
    declaredBitRate: declaredBitRate,
    multiview: hasLayeredHevc && vexu != null ? _multiview(data, vexu, horizontalFov) : null,
  );
}

// The child boxes of eyes the stereo video format lists; free for the padding of some writers
const _eyesChildren = {'must', 'stri', 'hero', 'cams', 'cmfy', 'proj', 'free'};

/// The eyes the vexu box [vexu] of an MV-HEVC track declares, with [horizontalFov] (its hfov sibling); null unless its
/// stri box says both eyes are there. vexu holds eyes, which holds stri (a full box, then one byte: 4 reserved bits,
/// then whether the eyes are reversed, whether there are more views, the right eye, the left eye), hero (a full box,
/// then the eye on a byte), cams with blin (a full box, then the baseline in micrometres on 32 bits) and cmfy with dadj
/// (a full box, then the disparity adjustment, signed on 32 bits). A reserved bit set makes stri unusable.
MultiviewInfo? _multiview(Uint8List data, _Box vexu, double? horizontalFov) {
  final eyes = _child(data, vexu, 'eyes');
  if (eyes == null) {
    return null;
  }
  // A plain box by the specification; some writers made it a full box, its children 4 bytes further
  var children = _boxes(data, eyes.start, eyes.end).toList();
  if (children.isEmpty || !_eyesChildren.contains(children.first.type)) {
    children = eyes.start + 4 <= eyes.end ? _boxes(data, eyes.start + 4, eyes.end).toList() : const [];
  }
  final bytes = ByteData.sublistView(data);
  int? flags;
  var hero = 0;
  int? baseline;
  int? disparity;
  for (final box in children) {
    switch (box.type) {
      case 'stri' when box.start + 5 <= box.end:
        flags ??= data[box.start + 4];
      case 'hero' when box.start + 5 <= box.end:
        hero = data[box.start + 4];
      case 'cams':
        final blin = _child(data, box, 'blin');
        if (blin != null && blin.start + 8 <= blin.end) {
          baseline ??= bytes.getUint32(blin.start + 4);
        }
      case 'cmfy':
        final dadj = _child(data, box, 'dadj');
        if (dadj != null && dadj.start + 8 <= dadj.end) {
          disparity ??= bytes.getInt32(dadj.start + 4);
        }
    }
  }
  if (flags == null || flags & 0xf0 != 0 || flags & 0x03 != 0x03) {
    return null;
  }
  return MultiviewInfo(
    heroEye: hero <= 2 ? hero : 0,
    baselineMicrometres: baseline,
    disparityAdjustment: disparity,
    horizontalFovDegrees: horizontalFov,
    eyesReversed: flags & 0x08 != 0,
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
// without the optional fields. The hvcC of a Dolby Vision entry gives the string of its HEVC base layer; an hvcC whose
// profile and level are zeros, that of its sequence parameter set (see [_hevcSps]). Null when the configuration does
// not belong to the sample entry, or is cut short or of an unknown version.
String? _codecsString(Uint8List data, String codec, _Box config) {
  final length = config.end - config.start;
  final at = config.start;
  final hevc = _dolbyVisionHevcBase[codec] ?? codec;
  switch (config.type) {
    // AVCDecoderConfigurationRecord: version 1, then the profile, the compatibility flags and the level
    case 'avcC' when (codec == 'avc1' || codec == 'avc3') && length >= 4 && data[at] == 1:
      String hex(int value) => value.toRadixString(16).padLeft(2, '0').toUpperCase();
      return '$codec.${hex(data[at + 1])}${hex(data[at + 2])}${hex(data[at + 3])}';
    // HEVCDecoderConfigurationRecord: version 1, then the profile_tier_level of the stream (see [_hevcCodecsString])
    case 'hvcC' when (hevc == 'hvc1' || hevc == 'hev1') && length >= 13 && data[at] == 1:
      final header = Uint8List.sublistView(data, at + 1, at + 13);
      final sps = _hevcHeaderIsBlank(data, at) ? _hevcSps(data, config) : null;
      return _hevcCodecsString(hevc, sps?.profileTierLevel ?? header);
    // AV1CodecConfigurationRecord: the marker bit and version 1, then the profile on 3 bits and the level on 5, then
    // the tier, the high bit depth and the twelve bit flags. Media3 reads no profile from a string without all four.
    case 'av1C' when codec == 'av01' && length >= 3 && data[at] == 0x81:
      final profile = data[at + 1] >> 5;
      final level = data[at + 1] & 0x1f;
      final tier = (data[at + 2] & 0x80) == 0 ? 'M' : 'H';
      return '$codec.$profile.${_twoDigits(level)}$tier.${_twoDigits(_av1BitDepth(data[at + 2]))}';
  }
  return null;
}

// The high bit depth and twelve bit flags of an AV1 configuration
int _av1BitDepth(int flags) => (flags & 0x40) == 0 ? 8 : ((flags & 0x20) == 0 ? 10 : 12);

// Bits per luma sample from the decoder configuration [config] of a sample entry of type [codec]: the field the HEVC
// record has for it (its reserved bits set, as every writer does), else the profile (Main 8, Main 10 10), else for a
// record whose profile and level are zeros its sequence parameter set (see [_hevcSps]); the high profile extension of
// an H.264 record, else its profile; the flags of AV1. Null when the configuration does not belong to the entry or does
// not say.
int? _bitDepth(Uint8List data, String codec, _Box config) {
  final length = config.end - config.start;
  final at = config.start;
  final hevc = _dolbyVisionHevcBase[codec] ?? codec;
  switch (config.type) {
    // A record of zeros (the Insta360 X4) says nothing true of the stream: its sequence parameter set does
    case 'hvcC'
        when (hevc == 'hvc1' || hevc == 'hev1') && length >= 13 && data[at] == 1 && _hevcHeaderIsBlank(data, at):
      final sps = _hevcSps(data, config);
      if (sps != null) {
        return sps.bitDepth;
      }
      if (length < 19) {
        return null;
      }
      final depth = data[at + 17];
      return (depth & 0xf8) == 0xf8 ? (depth & 0x07) + 8 : null;
    case 'hvcC' when (hevc == 'hvc1' || hevc == 'hev1') && length >= 19 && data[at] == 1:
      // Byte 17: 5 reserved bits, then bitDepthLumaMinus8
      final depth = data[at + 17];
      if ((depth & 0xf8) == 0xf8) {
        return (depth & 0x07) + 8;
      }
      return switch (data[at + 1] & 0x1f) {
        1 => 8,
        2 => 10,
        _ => null,
      };
    case 'avcC' when (codec == 'avc1' || codec == 'avc3') && length >= 6 && data[at] == 1:
      return _avcBitDepth(Uint8List.sublistView(data, at, config.end));
    case 'av1C' when codec == 'av01' && length >= 3 && data[at] == 0x81:
      return _av1BitDepth(data[at + 2]);
  }
  return null;
}

// The RFC 6381 codecs string of an HEVC stream of the sample entry [hevc] from its profile_tier_level [ptl], 12 bytes as
// the hvcC and the sequence parameter set both write them: the profile space, the tier and the profile in a byte, the
// 32 compatibility flags, 6 bytes of constraint flags and the level. The flags are written in reverse bit order.
String _hevcCodecsString(String hevc, Uint8List ptl) {
  final profileByte = ptl[0];
  final space = const ['', 'A', 'B', 'C'][profileByte >> 6];
  final tier = (profileByte & 0x20) == 0 ? 'L' : 'H';
  final profile = profileByte & 0x1f;
  final flags = ByteData.sublistView(ptl).getUint32(1);
  var reversed = 0;
  for (var bit = 0; bit < 32; bit++) {
    reversed = (reversed << 1) | ((flags >> bit) & 1);
  }
  return '$hevc.$space$profile.${reversed.toRadixString(16).toUpperCase()}.$tier${ptl[11]}';
}

// Whether the hvcC at [at] gives neither a profile nor a level (byte 1, the profile space, the tier and the profile,
// and byte 12, the level, both 0): the Insta360 X4 writes the whole header as zeros, which reads hvc1.0.0.L0 for a
// Main stream of level 6.1 (docs/18-test-media.md, F6)
bool _hevcHeaderIsBlank(Uint8List data, int at) => data[at + 1] == 0 && data[at + 12] == 0;

// The NAL unit type of a sequence parameter set
const _hevcSpsNalType = 33;

// What the first sequence parameter set (NAL unit type 33) among the parameter sets of the hvcC [config] says: its
// profile_tier_level, the 12 bytes the header of the hvcC copies (see [_hevcCodecsString]), and its luma bit depth,
// null when the set is cut short before it. Null without such a set, or when it is cut short before its
// profile_tier_level. The reference is docs/18-test-media.md, F6: the NAL header of 2 bytes dropped and the emulation
// prevention bytes taken out (00 00 03 reads 00 00), a byte of the VPS id, the number of sub layers less one and the
// temporal nesting flag, then the profile_tier_level, the sub layers, the SPS id, the chroma format, the frame size,
// the conformance window, then bit_depth_luma_minus8 (ITU-T H.265, 7.3.2.2 and 7.3.3).
({Uint8List profileTierLevel, int? bitDepth})? _hevcSps(Uint8List data, _Box config) {
  final nal = _hevcParameterSet(data, config, _hevcSpsNalType);
  if (nal == null || nal.length < 3) {
    return null;
  }
  final rbsp = _unescapeRbsp(Uint8List.sublistView(nal, 2));
  if (rbsp.length < 13) {
    return null;
  }
  final maxSubLayersMinus1 = (rbsp[0] >> 1) & 0x07;
  final profileTierLevel = Uint8List.sublistView(rbsp, 1, 13);
  int? bitDepth;
  try {
    final bits = _BitReader(rbsp, 13 * 8);
    final profilePresent = <bool>[];
    final levelPresent = <bool>[];
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      profilePresent.add(bits.bits(1) == 1);
      levelPresent.add(bits.bits(1) == 1);
    }
    if (maxSubLayersMinus1 > 0) {
      // reserved_zero_2bits up to 8 sub layers
      bits.skip(2 * (8 - maxSubLayersMinus1));
    }
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      // The profile space, the tier, the profile, the flags and the constraints of a sub layer, then its level
      bits.skip((profilePresent[i] ? 88 : 0) + (levelPresent[i] ? 8 : 0));
    }
    bits.expGolomb(); // sps_seq_parameter_set_id
    final chromaFormat = bits.expGolomb();
    if (chromaFormat == 3) {
      bits.skip(1); // separate_colour_plane_flag
    }
    bits
      ..expGolomb() // pic_width_in_luma_samples
      ..expGolomb(); // pic_height_in_luma_samples
    if (bits.bits(1) == 1) {
      // The conformance window: its left, right, top and bottom offsets
      for (var i = 0; i < 4; i++) {
        bits.expGolomb();
      }
    }
    final lumaMinus8 = bits.expGolomb();
    // At most 16 bits per sample in any profile
    bitDepth = lumaMinus8 <= 8 ? lumaMinus8 + 8 : null;
  } on FormatException {
    // Cut short: the profile_tier_level still stands
  }
  return (profileTierLevel: profileTierLevel, bitDepth: bitDepth);
}

// The first NAL unit of [type] among the arrays of parameter sets of the hvcC [config], after its 22 byte header: their
// number, then for each its type on the 6 low bits of a byte, the number of its units on 16 bits and each unit, its
// length on 16 bits then its bytes. Null when there is none, or the arrays are cut short before it.
Uint8List? _hevcParameterSet(Uint8List data, _Box config, int type) {
  final end = config.end;
  var offset = config.start + 22;
  if (offset >= end) {
    return null;
  }
  final arrays = data[offset++];
  for (var array = 0; array < arrays; array++) {
    if (offset + 3 > end) {
      return null;
    }
    final arrayType = data[offset] & 0x3f;
    final units = data[offset + 1] << 8 | data[offset + 2];
    offset += 3;
    for (var unit = 0; unit < units; unit++) {
      if (offset + 2 > end) {
        return null;
      }
      final length = data[offset] << 8 | data[offset + 1];
      offset += 2;
      if (offset + length > end) {
        return null;
      }
      if (arrayType == type) {
        return Uint8List.sublistView(data, offset, offset + length);
      }
      offset += length;
    }
  }
  return null;
}

// [payload] of a NAL unit without its emulation prevention bytes: a 3 after two zero bytes is left out
Uint8List _unescapeRbsp(Uint8List payload) {
  final rbsp = BytesBuilder(copy: false);
  var zeros = 0;
  for (final byte in payload) {
    if (zeros >= 2 && byte == 3) {
      zeros = 0;
      continue;
    }
    rbsp.addByte(byte);
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  return rbsp.takeBytes();
}

// Reads the bits of [_bytes] from the bit [_position] on, most significant first. Throws a [FormatException] past the
// end.
class _BitReader {
  _BitReader(this._bytes, this._position);

  final Uint8List _bytes;
  int _position;

  /// The next [count] bits (at most 32) as an unsigned number
  int bits(int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final index = _position >> 3;
      if (index >= _bytes.length) {
        throw const FormatException('Cut short');
      }
      value = (value << 1) | ((_bytes[index] >> (7 - (_position & 7))) & 1);
      _position++;
    }
    return value;
  }

  void skip(int count) {
    if (_position + count > _bytes.length * 8) {
      throw const FormatException('Cut short');
    }
    _position += count;
  }

  /// An unsigned exp-Golomb code, ue(v): n zero bits, a one, then n bits
  int expGolomb() {
    var zeros = 0;
    while (bits(1) == 0) {
      // No field of a sequence parameter set needs more than 32 bits
      if (++zeros > 31) {
        throw const FormatException('Exp-Golomb code too long');
      }
    }
    return (1 << zeros) - 1 + bits(zeros);
  }
}

// AVCDecoderConfigurationRecord [record]: version, profile, compatibility, level, the length size, then the sequence
// and picture parameter sets, each a 16 bit length and its bytes; the high profiles (100 and up) may end with the
// chroma format and the bit depths, each byte with its reserved bits set. Without that extension the profile tells:
// Baseline, Main, Extended and High are 8 bits, High 10 is 10.
int? _avcBitDepth(Uint8List record) {
  final profile = record[1];
  int? fromProfile() => switch (profile) {
    66 || 77 || 88 || 100 => 8,
    110 => 10,
    _ => null,
  };
  if (!const {100, 110, 122, 144, 244}.contains(profile)) {
    return fromProfile();
  }
  var offset = 6;
  int? skipSets(int count) {
    for (var i = 0; i < count; i++) {
      if (offset + 2 > record.length) {
        return null;
      }
      offset += 2 + (record[offset] << 8 | record[offset + 1]);
    }
    return offset > record.length ? null : offset;
  }

  if (skipSets(record[5] & 0x1f) == null || offset + 1 > record.length) {
    return fromProfile();
  }
  final pictureSets = record[offset++];
  if (skipSets(pictureSets) == null || offset + 3 > record.length) {
    return fromProfile();
  }
  final chroma = record[offset];
  final luma = record[offset + 1];
  if ((chroma & 0xfc) == 0xfc && (luma & 0xf8) == 0xf8) {
    return (luma & 0x07) + 8;
  }
  return fromProfile();
}

// vpcC (a full box): profile, level, then the bit depth on 4 bits, the chroma subsampling and the range, then the
// colour primaries, the transfer and the matrix
(int?, int?, int?) _vpcC(Uint8List data, _Box vpcC) {
  final at = vpcC.start;
  if (vpcC.end - at < 10) {
    return (null, null, null);
  }
  final depth = data[at + 6] >> 4;
  return (const {8, 10, 12}.contains(depth) ? depth : null, data[at + 7], data[at + 8]);
}

// colr: the colour type, then for nclx (MP4) and nclc (QuickTime) the primaries, the transfer and the matrix on 16 bits
// each. An ICC profile (rICC, prof) says nothing the details show.
(int, int)? _colour(Uint8List data, _Box colr) {
  final at = colr.start;
  if (colr.end - at < 10) {
    return null;
  }
  final type = _fourCC(data, at);
  if (type != 'nclx' && type != 'nclc') {
    return null;
  }
  final bytes = ByteData.sublistView(data);
  return (bytes.getUint16(at + 4), bytes.getUint16(at + 6));
}

// btrt: the size of the decoding buffer, the maximum bit rate, then the average one; 0 is unknown
int? _averageBitRate(Uint8List data, _Box btrt) {
  if (btrt.end - btrt.start < 12) {
    return null;
  }
  final average = ByteData.sublistView(data).getUint32(btrt.start + 8);
  return average == 0 ? null : average;
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

// The time scale and the duration of a media header (mdhd) or a movie header (mvhd): version and flags, the creation
// and modification times, then the time scale on 32 bits and the duration, on 32 bits in version 0 and 64 in
// version 1
(int?, int?) _timescaleAndDuration(Uint8List data, _Box header) {
  if (header.start + 4 > header.end) {
    return (null, null);
  }
  final version1 = data[header.start] == 1;
  final timescaleOffset = header.start + (version1 ? 20 : 12);
  final durationLength = version1 ? 8 : 4;
  if (timescaleOffset + 4 + durationLength > header.end) {
    return (null, null);
  }
  final bytes = ByteData.sublistView(data);
  final timescale = bytes.getUint32(timescaleOffset);
  final duration = version1 ? _uint64(bytes, timescaleOffset + 4) : bytes.getUint32(timescaleOffset + 4);
  return (timescale, duration);
}

// The duration of a track in milliseconds, from its media header; null when unknown
int? _durationMs(Uint8List data, _Box? mdia) {
  final mdhd = _child(data, mdia, 'mdhd');
  if (mdhd == null) {
    return null;
  }
  final (timescale, duration) = _timescaleAndDuration(data, mdhd);
  if (timescale == null || duration == null || timescale == 0 || duration == 0) {
    return null;
  }
  return duration * 1000 ~/ timescale;
}

/// The samples of a track and their total duration, in the time scale of its media header
typedef _Timing = ({int samples, int duration, int timescale});

// The samples of a track over their total duration, in the time scale of its mdhd box. Reads the time to sample table
// (stts) as far as it is in the bytes read, which the head of a long moov box may cut.
_Timing? _timing(Uint8List data, _Box mdia) {
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
  return (samples: samples, duration: duration, timescale: timescale);
}

// Bits per second of the samples of a track: the sizes of its sample size table (stsz: version and flags, a size for
// every sample or 0, the sample count, then a size per sample) over the duration of [timing]. Null without the table,
// with a table cut short in the bytes read, or with a compact table (stz2), which no camera writes.
double? _sampleBitRate(Uint8List data, _Box? stbl, _Timing timing) {
  final stsz = _child(data, stbl, 'stsz');
  if (stsz == null || stsz.start + 12 > stsz.end) {
    return null;
  }
  final bytes = ByteData.sublistView(data);
  final sampleSize = bytes.getUint32(stsz.start + 4);
  final count = bytes.getUint32(stsz.start + 8);
  if (count == 0) {
    return null;
  }
  var total = 0;
  if (sampleSize != 0) {
    total = sampleSize * count;
  } else {
    if (12 + 4 * count > stsz.end - stsz.start) {
      return null;
    }
    for (var i = 0, offset = stsz.start + 12; i < count; i++, offset += 4) {
      total += bytes.getUint32(offset);
    }
  }
  return total * 8 * timing.timescale / timing.duration;
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
